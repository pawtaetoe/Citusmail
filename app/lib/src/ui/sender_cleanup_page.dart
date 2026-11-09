// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_sync/mail_sync.dart';

import '../app.dart' show appName;
import '../mail/mail_controller.dart';
import '../mail/sender_cleanup_model.dart';
import 'app_icons.dart';
import 'avatar.dart';
import 'badge.dart';
import 'block_dialog.dart';
import 'citusmail_theme.dart';
import 'mail_shell.dart';
import 'page_scaffold.dart';
import 'unsubscribe_dialog.dart';

/// Senders whose mail piles up: who sends the most, and whose mail is
/// rarely opened, with ways to stop it and clear it out. Worked out on
/// the device from the stored mail.
final class SenderCleanupPage extends StatefulWidget {
  const SenderCleanupPage({super.key, required this.controller, this.now});

  final MailController controller;

  /// Today (tests).
  final DateTime Function()? now;

  @override
  State<SenderCleanupPage> createState() => _SenderCleanupPageState();
}

/// What can be done to senders.
enum _Action { unsubscribe, archive, delete, block, keep }

final class _SenderCleanupPageState extends State<SenderCleanupPage> {
  late final SenderCleanupModel _model = SenderCleanupModel(
    widget.controller,
    now: widget.now,
  );

  /// Picked senders, by key.
  Set<String> _selected = const {};

  /// The sender being prepared for unsubscribing (its message may need
  /// downloading).
  String? _preparing;
  bool _showKept = false;

  MailController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _model.load();
  }

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  List<SenderGroup> get _selectedGroups => [
    for (final g in _model.shown)
      if (_selected.contains(g.key)) g,
  ];

  void _toggle(SenderGroup g) => setState(() {
    final next = {..._selected};
    if (!next.remove(g.key)) next.add(g.key);
    _selected = next;
  });

  void _clearSelection() => setState(() => _selected = const {});

  void _notice(String text, {VoidCallback? undo}) {
    if (_c.onNotice case final notice?) return notice(text, undo: undo);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          persist: false,
          action: undo == null
              ? null
              : SnackBarAction(label: 'Undo', onPressed: undo),
        ),
      );
  }

  static String _who(List<SenderGroup> groups) =>
      groups.length == 1 ? groups.single.name : '${groups.length} senders';

  static String _emails(int n) => n == 1 ? '1 email' : '$n emails';

  Future<void> _act(_Action action, List<SenderGroup> groups) async {
    if (groups.isEmpty) return;
    switch (action) {
      case _Action.unsubscribe:
        await _unsubscribe(groups.single);
      case _Action.archive:
        _archive(groups);
      case _Action.delete:
        await _delete(groups);
      case _Action.block:
        await _block(groups.single);
      case _Action.keep:
        _keep(groups);
    }
  }

  /// Every message from them in the inboxes goes to Archive, as one queued
  /// move per folder; Undo puts it back.
  void _archive(List<SenderGroup> groups) {
    final mail = _model.inboxMail(groups);
    if (mail.isEmpty) {
      _notice('Nothing from ${_who(groups)} is in your Inbox.');
      return;
    }
    _clearSelection();
    _c.archive(
      mail,
      done: 'Archived ${_emails(mail.length)} from ${_who(groups)}',
    );
  }

  Future<void> _delete(List<SenderGroup> groups) async {
    final mail = _model.inboxMail(groups);
    if (mail.isEmpty) {
      _notice('Nothing from ${_who(groups)} is in your Inbox.');
      return;
    }
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${_emails(mail.length)}?'),
        content: Text(
          'The ${_emails(mail.length)} from ${_who(groups)} in your Inbox '
          'go to Trash. Pinned emails stay where they are.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Move to Trash'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    _clearSelection();
    _c.delete(mail);
  }

  void _keep(List<SenderGroup> groups) {
    final keys = [for (final g in groups) g.key];
    _model.keep(groups);
    _clearSelection();
    final text = groups.length == 1
        ? '${groups.single.name} won\'t be listed here'
        : '${groups.length} senders won\'t be listed here';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          behavior: SnackBarBehavior.floating,
          persist: false,
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => _model.unkeep(keys),
          ),
        ),
      );
  }

  Future<void> _block(SenderGroup group) async {
    final message = _model.newest(group);
    if (message == null) return;
    await BlockDialog.show(context, _c, message);
    if (mounted) {
      _clearSelection();
      await _model.load();
    }
  }

  /// The usual Unsubscribe, with its checks, on the sender's newest
  /// message that offers it.
  Future<void> _unsubscribe(SenderGroup group) async {
    final message = _model.unsubscribeMessage(group);
    if (message == null) return;
    setState(() => _preparing = group.key);
    String? problem;
    ReaderReady? ready;
    try {
      ready = await _c.readerFor(message);
    } on BodyUnavailableException {
      problem = 'Their latest email is no longer on the server.';
    } on SyncWorkerException {
      problem = 'Can\'t reach your mail server. Try again when you\'re online.';
    }
    if (!mounted) return;
    setState(() => _preparing = null);
    if (ready == null) return _notice(problem!);
    if (!ready.unsubscribe.available) {
      final reason = ready.unsubscribe.reason;
      return _notice(
        'Unsubscribe isn\'t offered for ${group.name}.'
        '${reason == null ? '' : ' $reason'}',
      );
    }
    await UnsubscribeDialog.show(context, _c, ready);
    if (mounted) {
      _clearSelection();
      await _model.load();
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final phone = constraints.maxWidth < MailShell.mediumWidth;
      return ListenableBuilder(
        listenable: _model,
        builder: (context, _) {
          final picked = _selectedGroups;
          final selecting = picked.isNotEmpty;
          final actions = _ActionBar(
            groups: picked,
            model: _model,
            onAction: (a) => _act(a, picked),
            compact: phone,
          );
          return PageScaffold(
            title: 'Clean up',
            help: (
              tooltip: 'How is this worked out?',
              onPressed: () => _HowDialog.show(context),
            ),
            maxWidth: 820,
            appBar: selecting
                ? AppBar(
                    backgroundColor: Theme.of(context)
                        .extension<ListColors>()
                        ?.checked,
                    leading: IconButton(
                      tooltip: 'Cancel selection',
                      icon: const Icon(AppIcons.close),
                      onPressed: _clearSelection,
                    ),
                    title: Text('${picked.length} selected'),
                    actions: [if (!phone) actions, const SizedBox(width: 8)],
                  )
                : null,
            bottomNavigationBar: phone && selecting
                ? Material(
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    child: SafeArea(
                      top: false,
                      child: SizedBox(height: 64, child: actions),
                    ),
                  )
                : null,
            body: SafeArea(top: false, child: _body(context)),
          );
        },
      );
    },
  );

  Widget _body(BuildContext context) {
    if (_model.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final shown = _model.shown;
    final kept = _model.keptGroups;
    // Header, senders, then the kept ones.
    final header = <Widget>[
      _Summary(model: _model),
      _Filters(model: _model),
      if (shown.isEmpty) _Empty(bulkOnly: _model.bulkOnly),
    ];
    final footer = <Widget>[
      if (kept.isNotEmpty) ...[
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() => _showKept = !_showKept),
            child: Text(
              _showKept
                  ? 'Hide the senders you keep'
                  : 'Show ${kept.length} sender${kept.length == 1 ? '' : 's'} you keep',
            ),
          ),
        ),
        if (_showKept)
          for (final g in kept)
            ListTile(
              leading: Avatar(name: g.name, address: g.label),
              title: Text(g.name),
              subtitle: Text(g.label),
              trailing: TextButton(
                onPressed: () => _model.unkeep([g.key]),
                child: const Text('List again'),
              ),
            ),
      ],
    ];
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          itemCount: header.length + shown.length + footer.length,
          itemBuilder: (context, i) {
            if (i < header.length) return header[i];
            i -= header.length;
            if (i < shown.length) {
              final g = shown[i];
              return _SenderTile(
                group: g,
                model: _model,
                selected: _selected.contains(g.key),
                selecting: _selected.isNotEmpty,
                preparing: _preparing == g.key,
                onToggle: () => _toggle(g),
                onAction: (a) => _act(a, [g]),
              );
            }
            return footer[i - shown.length];
          },
        ),
      ),
    );
  }
}

/// "120 emails from 14 senders you rarely open", over what is listed.
final class _Summary extends StatelessWidget {
  const _Summary({required this.model});

  final SenderCleanupModel model;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = model.shown;
    final rare = SenderCleanup.rarelyOpenedTotal(shown);
    final total = shown.fold(0, (sum, g) => sum + g.count);
    final title = rare.senders == 0
        ? 'Nothing you rarely open'
        : '${_SenderCleanupPageState._emails(rare.emails)} from '
              '${rare.senders} sender${rare.senders == 1 ? '' : 's'} you rarely open';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              '${_SenderCleanupPageState._emails(total)} from '
              '${shown.length} sender${shown.length == 1 ? '' : 's'} in the '
              'last 3 months. Pick senders to unsubscribe, archive or delete '
              'their mail.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Which senders, in which order.
final class _Filters extends StatelessWidget {
  const _Filters({required this.model});

  final SenderCleanupModel model;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: true,
              label: Text('Newsletters and notifications'),
            ),
            ButtonSegment(value: false, label: Text('All senders')),
          ],
          selected: {model.bulkOnly},
          onSelectionChanged: (v) => model.bulkOnly = v.single,
        ),
        DropdownButton<SenderOrder>(
          value: model.order,
          underline: const SizedBox.shrink(),
          borderRadius: BorderRadius.circular(CitusmailTheme.radiusSmall),
          items: const [
            DropdownMenuItem(
              value: SenderOrder.mostMail,
              child: Text('Most mail'),
            ),
            DropdownMenuItem(
              value: SenderOrder.leastOpened,
              child: Text('Least opened'),
            ),
          ],
          onChanged: (v) => model.order = v ?? model.order,
        ),
      ],
    ),
  );
}

/// One sender: who, how much mail and how much of it was opened, when the
/// last came, and what it is.
final class _SenderTile extends StatelessWidget {
  const _SenderTile({
    required this.group,
    required this.model,
    required this.selected,
    required this.selecting,
    required this.preparing,
    required this.onToggle,
    required this.onAction,
  });

  final SenderGroup group;
  final SenderCleanupModel model;
  final bool selected;
  final bool selecting;
  final bool preparing;
  final VoidCallback onToggle;
  final void Function(_Action) onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final g = group;
    final material = MaterialLocalizations.of(context);
    final pct = (g.openRate * 100).round();
    final opened = g.opened == 0
        ? 'none opened'
        : g.opened == g.count
        ? 'all opened'
        : '${g.opened} opened ($pct%)';
    final unsubscribed = model.unsubscribed(g);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return Card(
      key: ValueKey('sender-${g.key}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      color: selected ? theme.extension<ListColors>()?.checked : null,
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    checked: selected,
                    label: selected ? 'Selected' : 'Select ${g.name}',
                    child: selected || selecting
                        ? SizedBox(
                            width: 36,
                            height: 36,
                            child: Checkbox(
                              value: selected,
                              onChanged: (_) => onToggle(),
                            ),
                          )
                        : Avatar(name: g.name, address: g.label),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          g.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                        Text(
                          g.byDomain
                              ? '${g.label} · ${g.addresses.length} address${g.addresses.length == 1 ? '' : 'es'}'
                              : g.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muted,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${_SenderCleanupPageState._emails(g.count)} · '
                          '$opened · last ${material.formatShortMonthDay(g.last.toLocal())}',
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            if (g.kind == SenderKind.newsletter)
                              const AppBadge('Newsletter'),
                            if (g.kind == SenderKind.notification)
                              const AppBadge('Notifications'),
                            if (unsubscribed != null)
                              AppBadge(
                                'Unsubscribed ${material.formatShortMonthDay(unsubscribed.at.toLocal())}',
                              )
                            else if (g.canUnsubscribe)
                              const AppBadge('Can unsubscribe'),
                          ],
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<_Action>(
                    tooltip: 'What to do with ${g.name}',
                    onSelected: onAction,
                    itemBuilder: (_) => [
                      if (g.canUnsubscribe && unsubscribed == null)
                        const PopupMenuItem(
                          value: _Action.unsubscribe,
                          child: _MenuRow(
                            Icons.unsubscribe_outlined,
                            'Unsubscribe',
                          ),
                        ),
                      const PopupMenuItem(
                        value: _Action.archive,
                        child: _MenuRow(AppIcons.archive, 'Archive all'),
                      ),
                      const PopupMenuItem(
                        value: _Action.delete,
                        child: _MenuRow(AppIcons.delete, 'Delete all'),
                      ),
                      const PopupMenuItem(
                        value: _Action.block,
                        child: _MenuRow(AppIcons.block, 'Block sender'),
                      ),
                      const PopupMenuItem(
                        value: _Action.keep,
                        child: _MenuRow(Icons.check, 'Keep'),
                      ),
                    ],
                  ),
                ],
              ),
              if (preparing) ...[
                const SizedBox(height: 8),
                const LinearProgressIndicator(),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

final class _MenuRow extends StatelessWidget {
  const _MenuRow(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [Icon(icon, size: 20), const SizedBox(width: 12), Text(text)],
  );
}

/// What can be done to the picked senders: in the top bar on wide
/// screens, at the bottom on phones. Unsubscribe and Block take one
/// sender at a time.
final class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.groups,
    required this.model,
    required this.onAction,
    required this.compact,
  });

  final List<SenderGroup> groups;
  final SenderCleanupModel model;
  final void Function(_Action) onAction;

  /// At the bottom of a phone screen.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final one = groups.length == 1 ? groups.single : null;
    final canUnsubscribe =
        one != null && one.canUnsubscribe && model.unsubscribed(one) == null;
    // Labelled: in a column at the bottom on phones, in a row on top.
    Widget button(_Action action, IconData icon, String label) => compact
        ? Expanded(
            child: Tooltip(
              message: label,
              child: InkWell(
                borderRadius: BorderRadius.circular(CitusmailTheme.radiusSmall),
                onTap: () => onAction(action),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon),
                    const SizedBox(height: 2),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
            ),
          )
        : Tooltip(
            message: label,
            child: TextButton.icon(
              icon: Icon(icon),
              label: Text(label),
              onPressed: () => onAction(action),
            ),
          );
    return Row(
      mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.min,
      children: [
        if (canUnsubscribe)
          button(
            _Action.unsubscribe,
            Icons.unsubscribe_outlined,
            'Unsubscribe',
          ),
        button(_Action.archive, AppIcons.archive, 'Archive all'),
        button(_Action.delete, AppIcons.delete, 'Delete all'),
        if (one != null) button(_Action.block, AppIcons.block, 'Block sender'),
        button(_Action.keep, Icons.check, 'Keep'),
      ],
    );
  }
}

final class _Empty extends StatelessWidget {
  const _Empty({required this.bulkOnly});

  final bool bulkOnly;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
      child: Column(
        children: [
          Icon(
            AppIcons.cleanUp,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text('Nothing to clean up', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            bulkOnly
                ? 'No newsletters or notifications in the last 3 months.'
                : 'No mail from senders in the last 3 months.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

final class _HowDialog extends StatelessWidget {
  const _HowDialog();

  static Future<void> show(BuildContext context) =>
      showDialog<void>(context: context, builder: (_) => const _HowDialog());

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('How is this worked out?'),
    content: const Text(
      '$appName counts the mail you received in the last 3 months that is '
      'on this device, per sender, and how much of it you opened. A '
      'company\'s no-reply addresses count as one sender. People you have '
      'written to and your own addresses are never listed. Nothing is sent '
      'anywhere.\n\n'
      'Archive all and Delete all move the sender\'s mail in your Inbox; '
      'pinned emails stay. Keep takes a sender off this page; you can list '
      'them again at the bottom.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('OK'),
      ),
    ],
  );
}
