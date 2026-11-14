// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_ai/mail_ai.dart';

import '../services/ai_assistant.dart';
import '../ui/app_icons.dart';
import '../ui/citusmail_theme.dart';
import '../ui/snooze_sheet.dart';
import 'writing_help.dart';

/// What the user chose to do with the AI's text.
final class WritingChoice {
  const WritingChoice(this.text, {required this.replace});

  final String text;

  /// Instead of the body; else below it.
  final bool replace;
}

/// "Write with AI": draft a reply, or rewrite what was written. The text
/// streams into a preview; the user then chooses Replace, Insert below or
/// Discard. A bottom sheet on phones, a dialog on larger screens.
abstract final class WritingSheet {
  /// What to put into the body, or null (Discard, or closed).
  static Future<WritingChoice?> show(
    BuildContext context, {
    required AiFeatureProvider provider,
    required WritingAssistant assistant,
    required String body,
    PromptMail? source,
    bool forward = false,
    String? userName,
    String? signOff,
  }) {
    final panel = WritingPanel(
      model: provider.model,
      recipient: provider.recipient,
      stream: provider.stream,
      assistant: assistant,
      body: body,
      source: source,
      forward: forward,
      userName: userName,
      signOff: signOff,
    );
    if (MediaQuery.sizeOf(context).width < SnoozeSheet.sheetWidth) {
      return showModalBottomSheet<WritingChoice>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => Padding(
          // Above the keyboard while typing an instruction.
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SafeArea(child: SingleChildScrollView(child: panel)),
        ),
      );
    }
    return showDialog<WritingChoice>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(top: 20),
            child: panel,
          ),
        ),
      ),
    );
  }
}

/// The sheet's content: the choices, then the preview of one answer.
final class WritingPanel extends StatefulWidget {
  const WritingPanel({
    super.key,
    required this.model,
    required this.recipient,
    required this.stream,
    required this.assistant,
    required this.body,
    this.source,
    this.forward = false,
    this.userName,
    this.signOff,
  });

  final String model;
  final String recipient;
  final Stream<AiEvent> Function(AiRequest, {AiCancel? cancel}) stream;
  final WritingAssistant assistant;

  /// What the user wrote so far (the body only).
  final String body;

  /// The email answered or forwarded; null for a new message.
  final PromptMail? source;
  final bool forward;
  final String? userName;

  /// The sign-off's text, kept out of the answer (the app adds it).
  final String? signOff;

  @override
  State<WritingPanel> createState() => _WritingPanelState();
}

final class _WritingPanelState extends State<WritingPanel> {
  final _note = TextEditingController();
  final _instruction = TextEditingController();
  WritingRun? _run;

  @override
  void dispose() {
    _run?.dispose();
    _note.dispose();
    _instruction.dispose();
    super.dispose();
  }

  void _start(WritingTask task, {bool fresh = false}) {
    _run?.dispose();
    final run = widget.assistant.run(
      task,
      model: widget.model,
      recipient: widget.recipient,
      stream: widget.stream,
      userName: widget.userName,
      signOff: widget.signOff,
      fresh: fresh,
    );
    run.addListener(() {
      if (mounted) setState(() {});
    });
    setState(() => _run = run);
  }

  void _draft() {
    final source = widget.source;
    if (source == null) return;
    _start(
      DraftReplyTask(source: source, note: _note.text, forward: widget.forward),
    );
  }

  void _rewrite(RewriteStyle style, {String? language}) {
    final instruction = _instruction.text.trim();
    if (style == RewriteStyle.custom && instruction.isEmpty) return;
    _start(
      RewriteTask(
        body: widget.body,
        style: style,
        language: language,
        instruction: style == RewriteStyle.custom ? instruction : '',
      ),
    );
  }

  void _back() {
    _run?.dispose();
    setState(() => _run = null);
  }

  void _use({required bool replace}) {
    final run = _run;
    if (run == null || run.text.trim().isEmpty) return;
    Navigator.of(context).pop(WritingChoice(run.text, replace: replace));
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
    child: switch (_run) {
      final run? => _preview(context, run),
      null => _choices(context),
    },
  );

  Widget _title(BuildContext context, String text, {VoidCallback? onBack}) {
    final theme = Theme.of(context);
    return Row(
      children: [
        if (onBack != null)
          IconButton(
            tooltip: 'Back',
            icon: const Icon(AppIcons.back),
            onPressed: onBack,
          )
        else
          Icon(AppIcons.writeWithAi, color: theme.colorScheme.primary),
        const SizedBox(width: CitusSpace.s),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _heading(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(top: CitusSpace.l, bottom: CitusSpace.s),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );

  Widget _choices(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final hasBody = widget.body.trim().isNotEmpty;
    final source = widget.source;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _title(context, 'Write with AI'),
        if (source != null) ...[
          _heading(
            context,
            widget.forward ? 'Write a note for the forward' : 'Draft a reply',
          ),
          TextField(
            key: const ValueKey('writing-note'),
            controller: _note,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _draft(),
            decoration: const InputDecoration(
              hintText: 'Optional: what to say, like "yes, but on Friday"',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: CitusSpace.s),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.icon(
              key: const ValueKey('writing-draft'),
              onPressed: _draft,
              icon: const Icon(AppIcons.writeWithAi, size: 18),
              label: Text(widget.forward ? 'Write the note' : 'Draft reply'),
            ),
          ),
        ],
        if (hasBody) ...[
          _heading(context, 'Rewrite what you wrote'),
          Wrap(
            spacing: CitusSpace.s,
            runSpacing: CitusSpace.s,
            children: [
              for (final style in const [
                RewriteStyle.shorter,
                RewriteStyle.friendlier,
                RewriteStyle.formal,
                RewriteStyle.fix,
              ])
                ActionChip(
                  label: Text(style.label),
                  onPressed: () => _rewrite(style),
                ),
              PopupMenuButton<String>(
                key: const ValueKey('writing-translate'),
                tooltip: 'Translate into another language',
                onSelected: (language) =>
                    _rewrite(RewriteStyle.translate, language: language),
                itemBuilder: (_) => [
                  for (final language in WritingHelp.languages)
                    PopupMenuItem(value: language, child: Text(language)),
                ],
                child: IgnorePointer(
                  child: ActionChip(
                    avatar: const Icon(AppIcons.translate, size: 18),
                    label: Text(RewriteStyle.translate.label),
                    onPressed: () {},
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: CitusSpace.m),
          TextField(
            key: const ValueKey('writing-instruction'),
            controller: _instruction,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _rewrite(RewriteStyle.custom),
            decoration: InputDecoration(
              hintText: 'Or say how to change it',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: IconButton(
                tooltip: 'Rewrite',
                icon: const Icon(AppIcons.send),
                onPressed: () => _rewrite(RewriteStyle.custom),
              ),
            ),
          ),
        ],
        if (source == null && !hasBody)
          Padding(
            padding: const EdgeInsets.only(top: CitusSpace.m),
            child: Text(
              'Write a few words first. Then this can make them shorter, '
              'friendlier, more formal, corrected or translated.',
              style: theme.textTheme.bodyMedium,
            ),
          ),
        const SizedBox(height: CitusSpace.l),
        Text(
          'Only when you choose, it is sent to ${widget.recipient} with '
          'your key. You see the text first; nothing is sent to anyone '
          'else, and your recipients, sign-off and quote stay as they are.',
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
      ],
    );
  }

  Widget _preview(BuildContext context, WritingRun run) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final muted = colors.onSurfaceVariant;
    final running = run.state == WritingState.running;
    final failed = run.state == WritingState.failed;
    final usable = !running && !failed && run.text.trim().isNotEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _title(context, run.task.label, onBack: _back),
        const SizedBox(height: CitusSpace.m),
        if (failed)
          Container(
            key: const ValueKey('writing-error'),
            padding: const EdgeInsets.all(CitusSpace.m),
            decoration: BoxDecoration(
              color: colors.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              run.error ?? 'Something went wrong.',
              style: TextStyle(color: colors.onErrorContainer),
            ),
          )
        else
          Container(
            key: const ValueKey('writing-preview'),
            constraints: const BoxConstraints(minHeight: 80, maxHeight: 320),
            padding: const EdgeInsets.all(CitusSpace.m),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              reverse: running,
              child: SelectableText(
                run.text.isEmpty && running ? 'Writing…' : run.text,
                style: theme.textTheme.bodyLarge?.copyWith(
                  height: 1.45,
                  color: run.text.isEmpty ? muted : null,
                ),
              ),
            ),
          ),
        if (running) ...[
          const SizedBox(height: CitusSpace.s),
          const LinearProgressIndicator(),
        ],
        if (run.cutOff || run.state == WritingState.stopped)
          Padding(
            padding: const EdgeInsets.only(top: CitusSpace.s),
            child: Text(
              run.cutOff
                  ? 'This reached its length limit and may be cut off.'
                  : 'Stopped before the end.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
        const SizedBox(height: CitusSpace.m),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: CitusSpace.s,
          runSpacing: CitusSpace.s,
          children: [
            if (running)
              TextButton.icon(
                onPressed: run.stop,
                icon: const Icon(AppIcons.stop, size: 18),
                label: const Text('Stop'),
              )
            else ...[
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Discard'),
              ),
              TextButton.icon(
                onPressed: () => _start(run.task, fresh: true),
                icon: const Icon(AppIcons.retry, size: 18),
                label: const Text('Try again'),
              ),
            ],
            if (usable) ...[
              OutlinedButton(
                key: const ValueKey('writing-insert'),
                onPressed: () => _use(replace: false),
                child: const Text('Insert below'),
              ),
              FilledButton(
                key: const ValueKey('writing-replace'),
                onPressed: () => _use(replace: true),
                child: const Text('Replace'),
              ),
            ],
          ],
        ),
        const SizedBox(height: CitusSpace.m),
        Text(
          run.fromCache
              ? 'The same as your last request, so nothing was sent again.'
              : WritingHelp.sentNote(run.task, widget.recipient),
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
      ],
    );
  }
}
