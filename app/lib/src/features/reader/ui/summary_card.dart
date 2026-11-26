// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mail_store/mail_store.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/citusmail_theme.dart';
import '../../../services/ai_assistant.dart';
import '../../ai/state/ai_task.dart';
import '../../ai/ui/ai_confirm_dialog.dart';
import '../../inbox/state/mail_controller.dart';
import '../state/summaries.dart';

/// A finished summary: its text, and how it was kept.
typedef _Answer = ({String text, SavedSummary? saved});

/// The summary of the open email (or its conversation), in the reader
/// above the text: written as it arrives, with who made it and where it
/// was sent. A kept summary shows again at once, without sending
/// anything. Nothing shows while summaries are off.
final class SummaryPanel extends StatefulWidget {
  const SummaryPanel({
    super.key,
    required this.controller,
    required this.message,
  });

  final MailController controller;
  final StoredMessage message;

  @override
  State<SummaryPanel> createState() => _SummaryPanelState();
}

final class _SummaryPanelState extends State<SummaryPanel> {
  MessageSummaries get _summaries => widget.controller.services.summaries;
  AiAssistant get _ai => widget.controller.services.ai;

  /// Asking for the summary: running, done, failed or stopped.
  final _task = AiTask<_Answer>();

  SummaryScope? _scope;
  String _text = '';
  SavedSummary? _saved;
  String? _recipient;
  String? _model;
  int _emails = 1;

  @override
  void initState() {
    super.initState();
    _summaries.requests.addListener(_asked);
    _ai.changes.addListener(_changed);
    _task.addListener(_progress);
    _showSaved();
  }

  @override
  void didUpdateWidget(SummaryPanel old) {
    super.didUpdateWidget(old);
    if (old.message.id != widget.message.id) {
      _reset();
      _showSaved();
    }
  }

  @override
  void dispose() {
    _summaries.requests.removeListener(_asked);
    _ai.changes.removeListener(_changed);
    _task
      ..removeListener(_progress)
      ..dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (!_summaries.available) _reset();
    setState(() {});
  }

  /// The text so far as it streams in; the kept summary once done. A
  /// failure keeps what had arrived; a stop closes the card.
  void _progress() {
    switch (_task.state) {
      case AiRunning(:final text):
        _text = text;
      case AiDone(result: (:final text, :final saved)):
        _text = text;
        _saved = saved;
      case AiStopped():
        _reset();
      case AiIdle() || AiFailed():
        break;
    }
  }

  /// Closes the card, stopping a summary under way.
  void _reset() {
    _task.reset();
    _scope = null;
    _text = '';
    _saved = null;
  }

  /// A summary kept from before, shown without sending anything.
  void _showSaved() {
    if (!_summaries.available) return;
    for (final scope in SummaryScope.values) {
      if (_summaries.saved(widget.message, scope) case final saved?) {
        _show(scope, saved);
        return;
      }
    }
  }

  void _show(SummaryScope scope, SavedSummary saved) {
    _scope = scope;
    _recipient = saved.recipient;
    _model = saved.model;
    _emails = saved.emails;
    _task.answered((text: saved.text, saved: saved));
  }

  void _asked() {
    final request = _summaries.requests.value;
    if (request == null || request.messageId != widget.message.id) return;
    unawaited(_start(request.scope));
  }

  Future<void> _start(SummaryScope scope) async {
    // One under way stops here; what it showed stays until the next.
    if (_task.isRunning) _task.reset();
    if (_summaries.saved(widget.message, scope) case final saved?) {
      setState(() => _show(scope, saved));
      return;
    }
    final provider = await _ai.providerFor(MessageSummaries.feature.id);
    if (!mounted) return;
    if (provider == null) {
      setState(() {
        _reset();
        _scope = scope;
        _task.failed(
          'Summaries need a provider and key: see Settings, AI assistant.',
        );
      });
      return;
    }
    if (!await confirmAiSend(context, provider) || !mounted) return;
    setState(() {
      _reset();
      _scope = scope;
      _recipient = provider.recipient;
      _model = provider.model;
      _emails = scope == SummaryScope.message
          ? 1
          : _summaries.conversationOf(widget.message).length;
    });
    _task.recipient = provider.recipient;
    await _task.run((run) async {
      var text = '';
      await for (final piece in _summaries.summarise(
        provider,
        widget.message,
        scope,
        cancel: run.cancel,
      )) {
        run.partial(text = piece);
      }
      return (text: text, saved: _summaries.saved(widget.message, scope));
    });
  }

  void _close() => setState(_reset);

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: _task, builder: (context, _) => _card());

  Widget _card() {
    final scope = _scope;
    if (scope == null || !_summaries.available) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    final parts = SummaryParts.parse(_text);
    final state = _task.state;
    final running = state is AiRunning;
    final title = scope == SummaryScope.message
        ? 'Summary'
        : 'Summary of the conversation ($_emails emails)';
    return Semantics(
      container: true,
      label: title,
      liveRegion: running,
      child: Container(
        key: const ValueKey('summary-card'),
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.fromLTRB(14, 8, 4, 12),
        decoration: BoxDecoration(
          color: colors.surfaceContainer,
          borderRadius: BorderRadius.circular(CitusmailTheme.radius),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(AppIcons.summarise, size: 20, color: colors.primary),
                const SizedBox(width: 10),
                Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
                if (running)
                  IconButton(
                    key: const ValueKey('summary-stop'),
                    tooltip: 'Stop',
                    icon: const Icon(AppIcons.stop),
                    onPressed: _close,
                  )
                else
                  IconButton(
                    key: const ValueKey('summary-close'),
                    tooltip: 'Close summary',
                    icon: const Icon(AppIcons.close),
                    onPressed: _close,
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (running && _text.isEmpty) ...[
                    const SizedBox(height: 4),
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    Text('Asking $_recipient…', style: muted),
                  ],
                  if (state case AiFailed(:final message))
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(AppIcons.problem, size: 18, color: colors.error),
                        const SizedBox(width: 8),
                        Expanded(child: Text(message)),
                      ],
                    ),
                  if (parts.overview.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 4),
                      child: Text(parts.overview),
                    ),
                  for (final section in parts.sections) ...[
                    const SizedBox(height: 8),
                    Text(
                      section.title,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: colors.primary,
                      ),
                    ),
                    for (final item in section.items)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('•  '),
                            Expanded(child: Text(item)),
                          ],
                        ),
                      ),
                  ],
                  if (state is AiFailed)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () => _start(scope),
                        child: const Text('Try again'),
                      ),
                    ),
                  if (_recipient != null && state is! AiFailed) ...[
                    const SizedBox(height: 10),
                    Text(
                      key: const ValueKey('summary-sent-to'),
                      _saved != null && !running
                          ? 'Made by $_model. Sent to $_recipient with your '
                                'key; kept on this device, not sent again.'
                          : 'By $_model. Sent to $_recipient with your key.',
                      style: muted,
                    ),
                    Text(
                      'AI can get things wrong: check what matters in the '
                      'email itself.',
                      style: muted,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
