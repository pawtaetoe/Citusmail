// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mail_ai/mail_ai.dart';

import '../mail/ai_quick_replies.dart';
import '../mail/ai_reader_mail.dart';
import '../mail/mail_controller.dart';
import 'ai_confirm.dart';
import 'app_icons.dart';

/// "Suggest replies" under a personal email (an AI feature, off by
/// default). Nothing is sent until the user taps the button; then up to
/// three short replies show as chips. Picking one opens a normal reply
/// with that text, the sign-off and the quote, to edit and send as the
/// user likes: nothing is ever sent from here.
final class QuickReplySection extends StatelessWidget {
  const QuickReplySection({
    super.key,
    required this.controller,
    required this.reader,
  });

  final MailController controller;
  final ReaderReady reader;

  @override
  Widget build(BuildContext context) {
    final ai = controller.services.ai;
    final suggestions = QuickReplySuggestions.of(ai);
    return ListenableBuilder(
      listenable: Listenable.merge([ai.changes, suggestions]),
      builder: (context, _) {
        if (!ai.isOn(AiFeatures.quickReplies.id) ||
            !AiReaderMail.personal(controller, reader)) {
          return const SizedBox.shrink();
        }
        final theme = Theme.of(context);
        final muted = theme.colorScheme.onSurfaceVariant;
        final id = reader.message.id;
        void ask() => unawaited(
          suggestions.suggest(
            id,
            AiReaderMail.of(reader),
            confirm: (provider) => context.mounted
                ? AiConfirm.ask(context, provider)
                : Future.value(false),
          ),
        );
        final s = suggestions.find(id);
        final Widget content = switch (s?.status) {
          null => Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('suggest-replies'),
              onPressed: ask,
              icon: const Icon(AppIcons.quickReply, size: 18),
              label: const Text('Suggest replies'),
            ),
          ),
          SuggestionStatus.working => Row(
            children: [
              const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  'Asking ${s!.recipient} for replies…',
                  style: TextStyle(color: muted),
                ),
              ),
              TextButton(
                onPressed: () => suggestions.stop(id),
                child: const Text('Stop'),
              ),
            ],
          ),
          SuggestionStatus.done when s!.replies.isEmpty => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'No replies to suggest for this one.',
                style: TextStyle(color: muted),
              ),
              const SizedBox(height: 6),
              AiSentNote(recipient: s.recipient),
            ],
          ),
          SuggestionStatus.done => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final reply in s!.replies)
                    ActionChip(
                      avatar: const Icon(AppIcons.reply, size: 18),
                      // Only text: a chip starts a reply, never sends one.
                      label: Text(reply),
                      tooltip: 'Start a reply with this text',
                      onPressed: () => _reply(reply),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Suggested by ${s.recipient}. Pick one to start a reply you '
                'can change before sending.',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
              const SizedBox(height: 2),
              AiSentNote(recipient: s.recipient),
            ],
          ),
          SuggestionStatus.failed => Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                s!.problem ?? 'Couldn\'t suggest replies.',
                style: TextStyle(color: muted),
              ),
              TextButton(onPressed: ask, child: const Text('Try again')),
            ],
          ),
        };
        return Padding(
          key: const ValueKey('quick-replies'),
          padding: const EdgeInsets.only(top: 20),
          child: content,
        );
      },
    );
  }

  /// A normal reply to the sender with [text] written in, above the
  /// sign-off and the quote, open for editing.
  void _reply(String text) => controller.onCompose?.call(
    controller.services.replies
        .reply(reader.message, reader.view)
        .copyWith(body: text),
  );
}
