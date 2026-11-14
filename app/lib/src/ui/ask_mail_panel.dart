// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mail_ai/mail_ai.dart';
import 'package:mail_store/mail_store.dart';

import '../mail/ask_mail_model.dart';
import '../mail/mail_controller.dart';
import '../mail/mail_location.dart';
import 'app_icons.dart';
import 'citusmail_theme.dart';
import 'mail_text.dart';

/// "Ask your mail", above the search results while the feature is on: a
/// search that reads as a question is answered from the user's own
/// mail, other searches get an "Ask AI" button. The answer names the
/// emails it comes from (tap to read one) and says what was sent where;
/// follow-up questions keep the conversation. Nothing shows while the
/// feature is off.
final class AskMailPanel extends StatefulWidget {
  const AskMailPanel({super.key, required this.controller, this.hints});

  final MailController controller;

  /// The "Found in your mail" emails a question is about (tests).
  final AskHints? hints;

  @override
  State<AskMailPanel> createState() => _AskMailPanelState();
}

/// The conversation about the current search: kept while the list is
/// not shown (on a phone, while one of the emails is read), and ended
/// when the search changes or ends.
final class _Session {
  _Session(this.search, this.model);

  final String search;
  final AskMailModel model;

  /// Closed by the user, for this search.
  bool closed = false;
}

final _sessions = Expando<_Session>();

final class _AskMailPanelState extends State<AskMailPanel> {
  final _followUp = TextEditingController();

  MailController get _c => widget.controller;

  @override
  void dispose() {
    _followUp.dispose();
    super.dispose();
  }

  /// The conversation about [search], new when the search changes (a
  /// question is asked at once).
  _Session _sessionFor(String search) {
    final current = _sessions[_c];
    if (current != null && current.search == search) return current;
    current?.model.dispose();
    _followUp.clear();
    final session = _sessions[_c] = _Session(
      search,
      AskMailModel(_c.services, hints: widget.hints),
    );
    if (AskMail.looksLikeQuestion(search)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(_sessions[_c], session)) _ask(search);
      });
    }
    return session;
  }

  void _end() {
    _sessions[_c]?.model.dispose();
    _sessions[_c] = null;
  }

  Future<void> _ask(String question) async {
    final session = _sessions[_c];
    if (session == null || question.trim().isEmpty) return;
    setState(() => session.closed = false);
    _followUp.clear();
    await session.model.ask(question, confirm: _confirm);
  }

  /// Once per provider: what this feature sends, and where.
  Future<bool> _confirm(String recipient) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Send to $recipient?'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Text(
              'Ask your mail sends ${AiFeatures.ask.sends} to $recipient, '
              'with your key. It looks for the matches on this device; '
              'nothing else from your mailbox is sent. You are asked this '
              'once.',
            ),
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
      ) ??
      false;

  /// Reads [message] where the search results open: beside the list, or
  /// on a phone in its place (Back returns to the answer).
  void _open(StoredMessage message) {
    final fresh = _c.services.store.messages.byId(message.id);
    if (fresh != null) unawaited(_c.open(fresh));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_c.location, _c.services.ai.changes]),
    builder: (context, _) {
      final location = _c.location.value;
      if (location is! SearchLocation ||
          !_c.services.ai.isOn(AiFeatures.ask.id)) {
        _end();
        return const SizedBox.shrink();
      }
      final session = _sessionFor(location.text);
      final model = session.model;
      return ListenableBuilder(
        listenable: model,
        builder: (context, _) => Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: model.turns.isEmpty || session.closed
              ? _Offer(
                  onAsk: model.turns.isEmpty
                      ? () => _ask(location.text)
                      : () => setState(() => session.closed = false),
                )
              : _Conversation(
                  model: model,
                  followUp: _followUp,
                  onAsk: _ask,
                  onOpen: _open,
                  onClose: () {
                    model.stop();
                    setState(() => session.closed = true);
                  },
                ),
        ),
      );
    },
  );
}

/// Before anything is asked: a way to ask.
final class _Offer extends StatelessWidget {
  const _Offer({required this.onAsk});

  final VoidCallback onAsk;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            'Want an answer rather than a list?',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: 8),
        ActionChip(
          key: const ValueKey('ask-ai'),
          avatar: const Icon(AppIcons.assistant, size: 18),
          label: const Text('Ask AI'),
          onPressed: onAsk,
        ),
      ],
    );
  }
}

/// The questions and answers, and a field for the next question.
final class _Conversation extends StatelessWidget {
  const _Conversation({
    required this.model,
    required this.followUp,
    required this.onAsk,
    required this.onOpen,
    required this.onClose,
  });

  final AskMailModel model;
  final TextEditingController followUp;
  final void Function(String question) onAsk;
  final void Function(StoredMessage message) onOpen;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(CitusmailTheme.radius),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: ConstrainedBox(
        // The results stay in view below.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.45,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 4, 0),
              child: Row(
                children: [
                  Icon(AppIcons.assistant, size: 18, color: colors.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Ask your mail',
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('ask-close'),
                    tooltip: 'Close',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(AppIcons.close, size: 18),
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                reverse: true,
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, turn) in model.turns.indexed) ...[
                      if (i > 0) const Divider(height: 20),
                      _Turn(turn: turn, model: model, onOpen: onOpen),
                    ],
                  ],
                ),
              ),
            ),
            if (!model.busy)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                child: TextField(
                  key: const ValueKey('ask-follow-up'),
                  controller: followUp,
                  textInputAction: TextInputAction.send,
                  onSubmitted: onAsk,
                  decoration: InputDecoration(
                    hintText: 'Ask a follow-up question',
                    isDense: true,
                    fillColor: colors.surface,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    suffixIcon: IconButton(
                      tooltip: 'Ask',
                      icon: const Icon(AppIcons.send, size: 18),
                      onPressed: () => onAsk(followUp.text),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One question and what became of it.
final class _Turn extends StatelessWidget {
  const _Turn({required this.turn, required this.model, required this.onOpen});

  final AskTurn turn;
  final AskMailModel model;
  final void Function(StoredMessage message) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    final sent = turn.sent.length;
    final what =
        'your question and $sent email${sent == 1 ? '' : 's'} (sender, '
        'date, subject and part of the text)';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          turn.question,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        ...switch (turn.phase) {
          AskPhase.searching => [
            _Working(text: 'Looking in your mail…', onStop: model.stop),
          ],
          AskPhase.asking => [
            _Working(
              text:
                  'Asking ${turn.recipient} about $sent '
                  'email${sent == 1 ? '' : 's'}…',
              onStop: model.stop,
            ),
          ],
          AskPhase.failed => [
            Text(
              turn.error ?? 'No answer.',
              style: theme.textTheme.bodyMedium?.copyWith(color: colors.error),
            ),
          ],
          AskPhase.answered when turn.nothingMatched => [
            const Text('Nothing in your mail matched this question.'),
            const SizedBox(height: 4),
            Text(
              'No emails were sent, only your question to '
              '${turn.recipient}, for words to search for. Try other '
              'words, or the name of who wrote.',
              style: muted,
            ),
          ],
          AskPhase.answered => [
            SelectableText(turn.answer!.text),
            if (!turn.answer!.found) ...[
              const SizedBox(height: 4),
              Text('The search results below may still help.', style: muted),
            ],
            for (final (n, message) in turn.cited)
              _Source(number: n, message: message, onOpen: onOpen),
            const SizedBox(height: 6),
            Text('Sent $what to ${turn.recipient}.', style: muted),
          ],
        },
      ],
    );
  }
}

final class _Working extends StatelessWidget {
  const _Working({required this.text, required this.onStop});

  final String text;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const SizedBox.square(
        dimension: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      const SizedBox(width: 10),
      Expanded(child: Text(text)),
      TextButton.icon(
        onPressed: onStop,
        icon: const Icon(AppIcons.stop, size: 18),
        label: const Text('Stop'),
      ),
    ],
  );
}

/// An email the answer used: its number in the answer, subject, sender
/// and date; a tap reads it.
final class _Source extends StatelessWidget {
  const _Source({
    required this.number,
    required this.message,
    required this.onOpen,
  });

  final int number;
  final StoredMessage message;
  final void Function(StoredMessage message) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return InkWell(
      key: ValueKey('ask-source-${message.id}'),
      borderRadius: BorderRadius.circular(CitusmailTheme.radiusSmall),
      onTap: () => onOpen(message),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 32,
              child: Text(
                '[$number]',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colors.primary,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    MailText.subject(message),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.primary,
                      decoration: TextDecoration.underline,
                      decorationColor: colors.primary,
                    ),
                  ),
                  Text(
                    '${MailText.sender(message)} · '
                    '${MailText.listDate(context, message.receivedAt)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
