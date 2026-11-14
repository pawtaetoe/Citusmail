// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mail_ai/mail_ai.dart';
import 'package:mail_store/mail_store.dart';

import '../mail/mail_controller.dart';
import '../mail/summaries.dart';
import '../services/ai_assistant.dart';
import 'ai_confirm_dialog.dart';
import 'app_icons.dart';
import 'citusmail_theme.dart';

enum _Status { running, done, failed }

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

  SummaryScope? _scope;
  _Status _status = _Status.done;
  String _text = '';
  SavedSummary? _saved;
  String? _problem;
  String? _recipient;
  String? _model;
  int _emails = 1;
  AiCancel? _cancel;
  StreamSubscription<String>? _subscription;

  @override
  void initState() {
    super.initState();
    _summaries.requests.addListener(_asked);
    _ai.changes.addListener(_changed);
    _showSaved();
  }

  @override
  void didUpdateWidget(SummaryPanel old) {
    super.didUpdateWidget(old);
    if (old.message.id != widget.message.id) {
      _stop();
      _reset();
      _showSaved();
    }
  }

  @override
  void dispose() {
    _summaries.requests.removeListener(_asked);
    _ai.changes.removeListener(_changed);
    _stop();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (!_summaries.available) {
      _stop();
      _reset();
    }
    setState(() {});
  }

  void _reset() {
    _scope = null;
    _text = '';
    _saved = null;
    _problem = null;
  }

  void _stop() {
    _cancel?.cancel();
    unawaited(_subscription?.cancel());
    _subscription = null;
    _cancel = null;
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
    _saved = saved;
    _text = saved.text;
    _status = _Status.done;
    _recipient = saved.recipient;
    _model = saved.model;
    _emails = saved.emails;
    _problem = null;
  }

  void _asked() {
    final request = _summaries.requests.value;
    if (request == null || request.messageId != widget.message.id) return;
    unawaited(_start(request.scope));
  }

  Future<void> _start(SummaryScope scope) async {
    _stop();
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
        _status = _Status.failed;
        _problem =
            'Summaries need a provider and key: see Settings, AI assistant.';
      });
      return;
    }
    if (!await confirmAiSend(context, provider) || !mounted) return;
    final cancel = AiCancel();
    setState(() {
      _reset();
      _scope = scope;
      _status = _Status.running;
      _recipient = provider.recipient;
      _model = provider.model;
      _emails = scope == SummaryScope.message
          ? 1
          : _summaries.conversationOf(widget.message).length;
      _cancel = cancel;
    });
    _subscription = _summaries
        .summarise(provider, widget.message, scope, cancel: cancel)
        .listen(
          (text) => setState(() => _text = text),
          onError: (Object e) {
            if (!mounted) return;
            setState(() {
              _status = _Status.failed;
              _problem = switch (e) {
                AiException(problem: AiProblem.cancelled) => null,
                final AiException a => a.explain(provider.recipient),
                _ => 'Something went wrong.',
              };
              if (_problem == null) _reset();
            });
          },
          onDone: () {
            if (!mounted || _status == _Status.failed) return;
            setState(() {
              _status = _Status.done;
              _saved = _summaries.saved(widget.message, scope);
            });
          },
        );
  }

  void _close() {
    _stop();
    setState(_reset);
  }

  @override
  Widget build(BuildContext context) {
    final scope = _scope;
    if (scope == null || !_summaries.available) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    final parts = SummaryParts.parse(_text);
    final running = _status == _Status.running;
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
                  if (_status == _Status.failed)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(AppIcons.problem, size: 18, color: colors.error),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_problem ?? '')),
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
                  if (_status == _Status.failed)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () => _start(scope),
                        child: const Text('Try again'),
                      ),
                    ),
                  if (_recipient != null && _status != _Status.failed) ...[
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
