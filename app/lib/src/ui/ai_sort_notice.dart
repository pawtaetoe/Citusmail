// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_store/mail_store.dart';

import '../mail/mail_controller.dart';
import '../services/app_settings.dart';
import 'app_icons.dart';
import 'citusmail_theme.dart';
import 'mail_text.dart';

/// In the reader, on a message the AI sorting backup placed: who sorted
/// it and why ("Sorted into Notifications by Anthropic because: …"), and
/// "Not right?" to choose where it belongs. Nothing when the feature is
/// off, or when the rules or the user placed the message.
final class AiSortNotice extends StatelessWidget {
  const AiSortNotice({
    super.key,
    required this.controller,
    required this.message,
  });

  final MailController controller;
  final StoredMessage message;

  /// Where a category shows in the inbox.
  static SmartSection sectionOf(MessageCategory category) => switch (category) {
    MessageCategory.general => SmartSection.general,
    MessageCategory.notifications => SmartSection.notifications,
    MessageCategory.newsletters => SmartSection.newsletters,
    MessageCategory.codes => SmartSection.codes,
  };

  @override
  Widget build(BuildContext context) {
    final services = controller.services;
    return ListenableBuilder(
      listenable: Listenable.merge([services.ai.changes, services.resorted]),
      builder: (context, _) {
        // The stored message: a correction moves it.
        final now = services.store.messages.byId(message.id) ?? message;
        final entry = services.aiSort.decisionFor(now);
        if (entry == null) return const SizedBox.shrink();
        final colors = Theme.of(context).colorScheme;
        final section = MailText.section(sectionOf(now.category));
        return Container(
          key: ValueKey('ai-sort-notice-${message.id}'),
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 4),
          decoration: BoxDecoration(
            color: colors.surfaceContainer,
            borderRadius: BorderRadius.circular(CitusmailTheme.radius),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                      AppIcons.assistant,
                      size: 18,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      // The reason is the model's text: shown as plain
                      // text, nothing more.
                      child: Text(
                        'Sorted into $section by ${entry.by ?? 'the AI '
                                'assistant'} because: ${entry.reason ?? '…'}',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ),
                  ),
                ],
              ),
              Align(
                alignment: Alignment.centerRight,
                child: _NotRight(controller: controller, message: now),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// "Not right?": the other sections, to choose where it belongs.
final class _NotRight extends StatelessWidget {
  const _NotRight({required this.controller, required this.message});

  final MailController controller;
  final StoredMessage message;

  @override
  Widget build(BuildContext context) => PopupMenuButton<MessageCategory>(
    key: const ValueKey('ai-sort-not-right'),
    tooltip: 'Choose where it belongs',
    itemBuilder: (_) => [
      for (final category in const [
        MessageCategory.general,
        MessageCategory.notifications,
        MessageCategory.newsletters,
        MessageCategory.codes,
      ])
        if (category != message.category)
          PopupMenuItem(
            key: ValueKey('ai-sort-to-${category.name}'),
            value: category,
            child: Text(
              'Put it in '
              '${MailText.section(AiSortNotice.sectionOf(category))}',
            ),
          ),
    ],
    onSelected: (category) => _correct(context, category),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Text(
        'Not right?',
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );

  void _correct(BuildContext context, MessageCategory category) {
    final services = controller.services;
    final messenger = ScaffoldMessenger.maybeOf(context);
    services.aiSort.correct(message, category);
    final section = MailText.section(AiSortNotice.sectionOf(category));
    final sender = message.from?.address;
    final learns =
        sender != null &&
        category != MessageCategory.codes &&
        AppSettings(services.store).learnFromCorrections;
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          learns
              ? 'Moved to $section. Mail from $sender will go there too.'
              : 'Moved to $section.',
        ),
      ),
    );
  }
}
