// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_ai/mail_ai.dart';
import 'package:mail_store/mail_store.dart';

import '../app.dart' show appName;
import '../mail/ai_tidy.dart';
import '../mail/ai_tidy_model.dart';
import '../mail/mail_controller.dart';
import '../mail/mail_location.dart';
import '../services/ai_assistant.dart';
import 'app_icons.dart';
import 'mail_text.dart';
import 'snooze_sheet.dart';

/// "Ask AI to tidy", on the list's header and on the bar for selected
/// mail: there only while the feature is on (and has a provider).
final class AiTidyButton extends StatelessWidget {
  const AiTidyButton({super.key, required this.controller});

  final MailController controller;

  @override
  Widget build(BuildContext context) {
    final ai = controller.services.ai;
    return ValueListenableBuilder(
      valueListenable: ai.changes,
      builder: (context, _, _) {
        if (!ai.isOn(AiTidy.featureId) ||
            !AiTidy.worksIn(controller.location.value)) {
          return const SizedBox.shrink();
        }
        return IconButton(
          tooltip: 'Ask AI to tidy',
          icon: const Icon(AppIcons.assistant),
          onPressed: () => AiTidySheet.show(context, controller),
        );
      },
    );
  }
}

/// Asks what to do in plain words, shows the model's proposal as a
/// checklist grouped by change, and does only what is still ticked when
/// the user taps "Do it" (as one batch, with Undo). Cancel changes
/// nothing. A bottom sheet on phones, a dialog on larger screens.
abstract final class AiTidySheet {
  static Future<void> show(
    BuildContext context,
    MailController controller, {
    AiTidy? tidy,
  }) async {
    final t = tidy ?? AiTidy(controller);
    final candidates = t.candidates();
    if (candidates.isEmpty) {
      controller.onNotice?.call('There is no mail here to tidy.');
      return;
    }
    final provider = await controller.services.ai.providerFor(AiTidy.featureId);
    if (!context.mounted) return;
    if (provider == null) {
      controller.onNotice?.call(
        'Suggested actions are off. Turn them on in Settings, AI assistant.',
      );
      return;
    }
    final panel = _TidyPanel(
      tidy: t,
      provider: provider,
      candidates: candidates,
      scope: _scope(controller, candidates),
    );
    final List<TidyStep>? steps;
    if (MediaQuery.sizeOf(context).width < SnoozeSheet.sheetWidth) {
      steps = await showModalBottomSheet<List<TidyStep>>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.85,
            ),
            child: SafeArea(child: panel),
          ),
        ),
      );
    } else {
      steps = await showDialog<List<TidyStep>>(
        context: context,
        builder: (_) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 540, maxHeight: 640),
            child: Padding(
              padding: const EdgeInsets.only(top: 20),
              child: panel,
            ),
          ),
        ),
      );
    }
    // Cancel, or nothing ticked: nothing happens.
    if (steps == null || steps.isEmpty) return;
    t.run(steps);
  }

  /// What the request works on, for the panel: "12 selected emails",
  /// "the 200 newest emails in Inbox".
  static String _scope(MailController controller, TidyCandidates c) {
    final n = c.length;
    final emails = n == 1 ? '1 email' : '$n emails';
    if (controller.selection.value.isNotEmpty) {
      return c.trimmed
          ? 'The first ${TidyCandidates.cap} of the emails you selected'
          : (n == 1 ? 'The email you selected' : 'The $n emails you selected');
    }
    final store = controller.services.store;
    final where = switch (controller.location.value) {
      InboxLocation() => 'Inbox',
      SectionLocation(:final section) => MailText.section(section),
      FolderLocation(:final mailboxId) => switch (store.mailboxes.byId(
        mailboxId,
      )) {
        final box? => MailText.folder(box),
        null => 'this folder',
      },
      PinsLocation() => 'Pins',
      SearchLocation() => 'these search results',
      SnoozedLocation() => 'Snoozed',
      OutboxLocation() || FollowUpsLocation() => 'this list',
    };
    return c.trimmed
        ? 'The ${TidyCandidates.cap} newest emails in $where'
        : 'The $emails in $where';
  }

  /// "Archive 12 emails", "Move 3 emails to Receipts".
  static String label(BuildContext context, TidyStep step, [int? count]) {
    final n = count ?? step.messages.length;
    final emails = n == 1 ? '1 email' : '$n emails';
    return switch (step.kind) {
      TidyKind.archive => 'Archive $emails',
      TidyKind.move => 'Move $emails to ${step.folder}',
      TidyKind.markRead => 'Mark $emails as read',
      TidyKind.markUnread => 'Mark $emails as unread',
      TidyKind.pin => 'Pin $emails',
      TidyKind.unpin => 'Unpin $emails',
      TidyKind.snooze =>
        'Snooze $emails until ${SnoozeSheet.describe(context, step.until!)}',
    };
  }

  static IconData icon(TidyKind kind) => switch (kind) {
    TidyKind.archive => AppIcons.archive,
    TidyKind.move => AppIcons.move,
    TidyKind.markRead => AppIcons.markRead,
    TidyKind.markUnread => AppIcons.markUnread,
    TidyKind.pin => AppIcons.pinOn,
    TidyKind.unpin => AppIcons.pinOff,
    TidyKind.snooze => AppIcons.snooze,
  };
}

enum _Phase { ask, asking, plan, failed }

final class _TidyPanel extends StatefulWidget {
  const _TidyPanel({
    required this.tidy,
    required this.provider,
    required this.candidates,
    required this.scope,
  });

  final AiTidy tidy;
  final AiFeatureProvider provider;
  final TidyCandidates candidates;
  final String scope;

  @override
  State<_TidyPanel> createState() => _TidyPanelState();
}

final class _TidyPanelState extends State<_TidyPanel> {
  final _words = TextEditingController();
  _Phase _phase = _Phase.ask;
  AiCancel? _cancel;
  String? _problem;
  TidyPlan _plan = TidyPlan.empty;

  /// Per step, the messages still ticked.
  List<Set<int>> _ticked = const [];
  final _open = <int>{};

  String get _to => widget.provider.recipient;

  @override
  void dispose() {
    _cancel?.cancel();
    _words.dispose();
    super.dispose();
  }

  Future<void> _suggest() async {
    final words = _words.text.trim();
    if (words.isEmpty) return;
    if (widget.provider.needsConfirmation) {
      final ok = await _confirm();
      if (ok != true || !mounted) return;
      widget.provider.confirm();
    }
    final cancel = _cancel = AiCancel();
    setState(() => _phase = _Phase.asking);
    try {
      final plan = await widget.tidy.suggest(
        widget.provider,
        words,
        widget.candidates,
        cancel: cancel,
      );
      if (!mounted || cancel.isCancelled) return;
      setState(() {
        _plan = plan;
        _ticked = [
          for (final s in plan.steps) {for (final m in s.messages) m.id},
        ];
        _open.clear();
        _phase = _Phase.plan;
      });
    } on AiException catch (e) {
      if (!mounted || e.problem == AiProblem.cancelled) return;
      setState(() {
        _problem = e.explain(_to);
        _phase = _Phase.failed;
      });
    }
  }

  void _stop() {
    _cancel?.cancel();
    setState(() => _phase = _Phase.ask);
  }

  Future<bool?> _confirm() => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Send to $_to?'),
      content: Text(
        'To suggest changes, $appName sends ${widget.provider.feature.sends} '
        'to $_to, with your key. Nothing else from your mailbox is sent, '
        'and nothing changes until you tap Do it.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Send'),
        ),
      ],
    ),
  );

  /// The steps with only the ticked messages.
  List<TidyStep> get _chosen => [
    for (final (i, step) in _plan.steps.indexed)
      if (_ticked[i].isNotEmpty)
        step.withMessages([
          for (final m in step.messages)
            if (_ticked[i].contains(m.id)) m,
        ]),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
          child: Text('Ask AI to tidy', style: theme.textTheme.titleLarge),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(
            widget.scope,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Flexible(
          child: switch (_phase) {
            _Phase.ask => _ask(theme),
            _Phase.asking => _asking(theme),
            _Phase.plan => _planView(theme),
            _Phase.failed => _failed(theme),
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: _buttons(),
        ),
      ],
    );
  }

  Widget _ask(ThemeData theme) => SingleChildScrollView(
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('tidy-words'),
          controller: _words,
          autofocus: true,
          minLines: 1,
          maxLines: 3,
          maxLength: TidyPlanner.maxRequestChars,
          textInputAction: TextInputAction.go,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _suggest(),
          decoration: const InputDecoration(
            hintText: 'For example: archive newsletters older than a month',
          ),
        ),
        if (widget.candidates.trimmed)
          _line(
            theme,
            'Only the first ${TidyCandidates.cap} emails are looked at. '
            'Select emails to choose others.',
          ),
        _line(
          theme,
          'Sends your request, your folder names and the sender, subject '
          'and date of these emails (not their text) to $_to. It can '
          'archive, move, mark read or unread, pin and snooze; nothing '
          'changes until you tap Do it.',
        ),
      ],
    ),
  );

  Widget _asking(ThemeData theme) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
    child: Row(
      children: [
        const SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 16),
        Expanded(child: Text('Asking $_to…')),
      ],
    ),
  );

  Widget _failed(ThemeData theme) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(AppIcons.problem, color: theme.colorScheme.error),
        const SizedBox(width: 12),
        Expanded(child: Text(_problem ?? '')),
      ],
    ),
  );

  Widget _planView(ThemeData theme) {
    final plan = _plan;
    return ListView(
      shrinkWrap: true,
      children: [
        if (plan.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text('No changes to suggest.'),
          ),
        for (final (i, step) in plan.steps.indexed) ..._step(theme, i, step),
        if (plan.note case final note?)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text(
              '$_to says: $note',
              key: const ValueKey('tidy-note'),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        if (plan.leftOut > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: _line(
              theme,
              plan.leftOut == 1
                  ? 'One suggestion was left out: it named an email or '
                        'folder that isn\'t here, or a change $appName '
                        'can\'t make this way.'
                  : '${plan.leftOut} suggestions were left out: they named '
                        'emails or folders that aren\'t here, or changes '
                        '$appName can\'t make this way.',
            ),
          ),
        if (!plan.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: _line(
              theme,
              'Nothing has changed yet. Untick what you don\'t want, then '
              'tap Do it. You can undo it afterwards.',
            ),
          ),
      ],
    );
  }

  List<Widget> _step(ThemeData theme, int i, TidyStep step) {
    final ticked = _ticked[i];
    final all = ticked.length == step.messages.length;
    final open = _open.contains(i);
    return [
      ListTile(
        contentPadding: const EdgeInsets.only(left: 12, right: 8),
        leading: Checkbox(
          key: ValueKey('tidy-step-$i'),
          tristate: true,
          value: all ? true : (ticked.isEmpty ? false : null),
          onChanged: (_) => setState(() {
            _ticked[i] = all ? {} : {for (final m in step.messages) m.id};
          }),
        ),
        title: Row(
          children: [
            Icon(
              AiTidySheet.icon(step.kind),
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                AiTidySheet.label(context, step, ticked.length),
                key: ValueKey('tidy-label-$i'),
              ),
            ),
          ],
        ),
        trailing: Icon(open ? AppIcons.expand : AppIcons.chevron),
        onTap: () => setState(() => open ? _open.remove(i) : _open.add(i)),
      ),
      if (open)
        for (final m in step.messages) _message(theme, i, m),
    ];
  }

  Widget _message(ThemeData theme, int i, StoredMessage m) => CheckboxListTile(
    key: ValueKey('tidy-message-$i-${m.id}'),
    dense: true,
    controlAffinity: ListTileControlAffinity.leading,
    contentPadding: const EdgeInsets.only(left: 40, right: 16),
    value: _ticked[i].contains(m.id),
    onChanged: (on) => setState(() {
      on == true ? _ticked[i].add(m.id) : _ticked[i].remove(m.id);
    }),
    title: Text(
      MailText.sender(m),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    subtitle: Text(
      '${MailText.subject(m)} · ${MailText.listDate(context, m.receivedAt)}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
  );

  Widget _line(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _buttons() {
    final cancel = TextButton(
      onPressed: () => Navigator.pop(context),
      child: const Text('Cancel'),
    );
    final again = TextButton(
      onPressed: () => setState(() => _phase = _Phase.ask),
      child: const Text('Change request'),
    );
    final List<Widget> buttons = switch (_phase) {
      _Phase.ask => [
        cancel,
        FilledButton(
          onPressed: _words.text.trim().isEmpty ? null : _suggest,
          child: const Text('Suggest'),
        ),
      ],
      _Phase.asking => [
        TextButton.icon(
          onPressed: _stop,
          icon: const Icon(AppIcons.stop),
          label: const Text('Stop'),
        ),
      ],
      _Phase.failed => [
        cancel,
        FilledButton(
          onPressed: () => setState(() => _phase = _Phase.ask),
          child: const Text('Try again'),
        ),
      ],
      _Phase.plan => [
        again,
        cancel,
        FilledButton(
          onPressed: _ticked.any((t) => t.isNotEmpty)
              ? () => Navigator.pop(context, _chosen)
              : null,
          child: const Text('Do it'),
        ),
      ],
    };
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 4,
      children: buttons,
    );
  }
}
