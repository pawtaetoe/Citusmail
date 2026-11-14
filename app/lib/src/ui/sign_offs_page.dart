// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_store/mail_store.dart';

import '../services/app_services.dart';
import 'app_icons.dart';
import 'citusmail_theme.dart';
import 'empty_state.dart';
import 'page_scaffold.dart';

/// What the sign-off editor returns.
typedef WrittenSignOff = ({
  String name,
  String text,
  bool separator,
  bool save,
});

/// A small window to write or edit a sign-off: its name, its text and
/// whether it starts with the standard separator. In the compose window
/// ([offerSaveForLater]) it can also be for this email only.
final class SignOffEditor extends StatefulWidget {
  const SignOffEditor({
    super.key,
    this.initial,
    this.example = '',
    this.offerSaveForLater = false,
  });

  final SignOff? initial;

  /// Text to start a new sign-off with.
  final String example;
  final bool offerSaveForLater;

  static Future<WrittenSignOff?> show(
    BuildContext context, {
    SignOff? initial,
    String example = '',
    bool offerSaveForLater = false,
  }) => showDialog<WrittenSignOff>(
    context: context,
    builder: (_) => SignOffEditor(
      initial: initial,
      example: example,
      offerSaveForLater: offerSaveForLater,
    ),
  );

  @override
  State<SignOffEditor> createState() => _SignOffEditorState();
}

final class _SignOffEditorState extends State<SignOffEditor> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _text = TextEditingController(
    text: widget.initial?.text ?? widget.example,
  );
  late bool _separator = widget.initial?.separator ?? false;
  bool _save = true;

  @override
  void dispose() {
    _name.dispose();
    _text.dispose();
    super.dispose();
  }

  bool get _ready => _text.text.trim().isNotEmpty;

  void _done() {
    if (!_ready) return;
    Navigator.pop<WrittenSignOff>(context, (
      name: _name.text.trim(),
      text: _text.text.trimRight(),
      separator: _separator,
      save: _save,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.initial != null;
    final named = !widget.offerSaveForLater || _save;
    return AlertDialog(
      title: Text(editing ? 'Edit sign-off' : 'New sign-off'),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (named) ...[
              TextField(
                key: const ValueKey('sign-off-name'),
                controller: _name,
                autofocus: !editing,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Work, Casual…',
                ),
              ),
              const SizedBox(height: CitusSpace.m),
            ],
            TextField(
              key: const ValueKey('sign-off-text'),
              controller: _text,
              autofocus: !named,
              minLines: 3,
              maxLines: 8,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Sign-off',
                hintText: 'Best regards,\nYour name',
                helperText: 'Plain text, like a signature',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: CitusSpace.s),
            CheckboxListTile(
              key: const ValueKey('sign-off-separator'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _separator,
              onChanged: (on) => setState(() => _separator = on ?? false),
              title: const Text('Use the standard signature separator (-- )'),
              subtitle: const Text(
                'A line many mail apps recognise, and leave out of replies',
              ),
            ),
            if (widget.offerSaveForLater)
              CheckboxListTile(
                key: const ValueKey('sign-off-save'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _save,
                onChanged: (on) => setState(() => _save = on ?? false),
                title: const Text('Save for later'),
                subtitle: const Text(
                  'Add it to your sign-offs; untick to use it for this '
                  'email only',
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _ready ? _done : null,
          child: Text(
            editing
                ? 'Save'
                : widget.offerSaveForLater
                ? 'Use'
                : 'Add',
          ),
        ),
      ],
    );
  }
}

/// Settings > Sign-offs: the texts that end the user's emails (their
/// signatures), and which one each account starts with.
final class SignOffsPage extends StatefulWidget {
  const SignOffsPage({super.key, required this.services});

  final AppServices services;

  @override
  State<SignOffsPage> createState() => _SignOffsPageState();
}

final class _SignOffsPageState extends State<SignOffsPage> {
  SignOffRepository get _signOffs => widget.services.store.signOffs;

  /// "Best regards," and the user's name, to start from.
  String get _example {
    final name = widget.services.store.accounts
        .all()
        .map((a) => a.displayName?.trim() ?? '')
        .where((n) => n.isNotEmpty)
        .firstOrNull;
    return name == null ? 'Best regards,\n' : 'Best regards,\n$name';
  }

  Future<void> _add() async {
    final first = _signOffs.all().isEmpty;
    final written = await SignOffEditor.show(context, example: _example);
    if (written == null || !mounted) return;
    final added = _signOffs.add(
      name: written.name.isEmpty ? 'Sign-off' : written.name,
      text: written.text,
      separator: written.separator,
    );
    // The first one becomes every account's default.
    if (first) {
      for (final account in widget.services.store.accounts.all()) {
        if (_signOffs.defaultsFor(account.email).newMail == null) {
          _setDefaults(
            account,
            (d) => SignOffDefaults(
              newMail: added.id,
              repliesSameAsNew: d.repliesSameAsNew,
              replies: d.replies,
              changedAt: DateTime.now().toUtc(),
            ),
          );
        }
      }
    }
    setState(() {});
  }

  Future<void> _edit(SignOff signOff) async {
    final written = await SignOffEditor.show(context, initial: signOff);
    if (written == null || !mounted) return;
    _signOffs.update(
      signOff.copyWith(
        name: written.name.isEmpty ? signOff.name : written.name,
        text: written.text,
        separator: written.separator,
      ),
    );
    setState(() {});
  }

  void _delete(SignOff signOff) {
    _signOffs.remove(signOff.id);
    setState(() {});
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Deleted "${signOff.name}".'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              // Newer than the removal, so other devices get it back too.
              _signOffs.restore(
                signOff.copyWith(changedAt: DateTime.now().toUtc()),
              );
              if (mounted) setState(() {});
            },
          ),
        ),
      );
  }

  void _reorder(List<SignOff> list, int from, int to) {
    final ids = [for (final s in list) s.id];
    // [to] already counts without the moved one.
    ids.insert(to, ids.removeAt(from));
    _signOffs.reorder(ids);
    setState(() {});
  }

  void _setDefaults(
    Account account,
    SignOffDefaults Function(SignOffDefaults) change,
  ) {
    _signOffs.setDefaults(
      account.email,
      change(_signOffs.defaultsFor(account.email)),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final list = _signOffs.all();
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    if (list.isEmpty) {
      return PageScaffold(
        title: 'Sign-offs',
        boundBody: true,
        body: EmptyState(
          icon: AppIcons.signOff,
          text: 'No sign-offs yet',
          hint:
              'A sign-off ends your emails, like a signature: "Best '
              'regards" and your name. Keep several, and choose one '
              'while you write.',
          action: 'Add your first sign-off',
          onAction: _add,
        ),
      );
    }
    final accounts = widget.services.store.accounts.all();
    return PageScaffold(
      title: 'Sign-offs',
      boundBody: true,
      body: ReorderableListView.builder(
        padding: const EdgeInsets.only(bottom: 24),
        buildDefaultDragHandles: false,
        header: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            'A sign-off ends your emails, like a signature. While you write, '
            'tap the sign-off to choose another, or none.',
            style: TextStyle(color: muted),
          ),
        ),
        itemCount: list.length,
        onReorderItem: (from, to) => _reorder(list, from, to),
        itemBuilder: (context, i) {
          final s = list[i];
          return ListTile(
            key: ValueKey('sign-off-${s.id}'),
            leading: list.length > 1
                ? ReorderableDragStartListener(
                    index: i,
                    child: const Icon(AppIcons.dragHandle),
                  )
                : const Icon(AppIcons.signOff),
            title: Text(s.name),
            subtitle: Text(
              s.block,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            isThreeLine: true,
            onTap: () => _edit(s),
            trailing: PopupMenuButton<String>(
              tooltip: 'More for ${s.name}',
              onSelected: (action) => switch (action) {
                'edit' => _edit(s),
                _ => _delete(s),
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          );
        },
        footer: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton.tonalIcon(
                  onPressed: _add,
                  icon: const Icon(AppIcons.add),
                  label: const Text('Add a sign-off'),
                ),
              ),
            ),
            if (accounts.isNotEmpty) ...[
              const SizedBox(height: CitusSpace.xl),
              const Divider(height: 1, indent: 16, endIndent: 16),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
                child: Text(
                  'Each account starts with',
                  style: Theme.of(context).textTheme.labelLarge
                      ?.copyWith(color: Theme.of(context).colorScheme.primary),
                ),
              ),
              for (final account in accounts)
                _AccountDefaults(
                  account: account,
                  signOffs: list,
                  defaults: _signOffs.defaultsFor(account.email),
                  onChanged: (d) => _setDefaults(account, (_) => d),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One account's choices: the sign-off for new mail, and for replies
/// and forwards.
final class _AccountDefaults extends StatelessWidget {
  const _AccountDefaults({
    required this.account,
    required this.signOffs,
    required this.defaults,
    required this.onChanged,
  });

  final Account account;
  final List<SignOff> signOffs;
  final SignOffDefaults defaults;
  final ValueChanged<SignOffDefaults> onChanged;

  static const _none = '';
  static const _same = '=';

  /// An id that is still in the list, or none.
  String _known(String? id) => signOffs.any((s) => s.id == id) ? id! : _none;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now().toUtc();
    final email = account.email.toLowerCase();
    Widget choice({
      required String label,
      required Key key,
      required String value,
      required bool offerSame,
      required ValueChanged<String> onSelected,
    }) => Padding(
      padding: const EdgeInsets.only(top: CitusSpace.s),
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, isDense: true),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            key: key,
            value: value,
            isDense: true,
            isExpanded: true,
            items: [
              if (offerSame)
                const DropdownMenuItem(
                  value: _same,
                  child: Text('Same as new mail'),
                ),
              const DropdownMenuItem(value: _none, child: Text('None')),
              for (final s in signOffs)
                DropdownMenuItem(value: s.id, child: Text(s.name)),
            ],
            onChanged: (v) {
              if (v != null) onSelected(v);
            },
          ),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(account.email, style: theme.textTheme.titleSmall),
          choice(
            label: 'New mail',
            key: ValueKey('sign-off-new-$email'),
            value: _known(defaults.newMail),
            offerSame: false,
            onSelected: (v) => onChanged(
              SignOffDefaults(
                newMail: v == _none ? null : v,
                repliesSameAsNew: defaults.repliesSameAsNew,
                replies: defaults.replies,
                changedAt: now,
              ),
            ),
          ),
          choice(
            label: 'Replies and forwards',
            key: ValueKey('sign-off-replies-$email'),
            value: defaults.repliesSameAsNew ? _same : _known(defaults.replies),
            offerSame: true,
            onSelected: (v) => onChanged(
              SignOffDefaults(
                newMail: defaults.newMail,
                repliesSameAsNew: v == _same,
                replies: v == _same || v == _none ? null : v,
                changedAt: now,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
