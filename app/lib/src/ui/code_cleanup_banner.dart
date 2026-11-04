// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_sync/mail_sync.dart';

import '../mail/mail_controller.dart';
import 'citusmail_theme.dart';

/// The clean-up choices in words.
abstract final class CodeCleanupText {
  static String age(CodeCleanupAge age) => switch (age) {
    CodeCleanupAge.off => 'Off',
    CodeCleanupAge.day => 'After a day',
    CodeCleanupAge.week => 'After a week',
  };

  static String action(CodeCleanupAction action) => switch (action) {
    CodeCleanupAction.archive => 'Archive',
    CodeCleanupAction.trash => 'Move to Trash',
  };

  static const explanation =
      'Verification codes, sign-in links and password-reset emails, once '
      'they\'re older than this. Pinned ones are kept.';

  /// What would happen, for the question in the Verification section.
  static String proposal(CodeCleanupSettings settings) {
    final older = switch (settings.age) {
      CodeCleanupAge.week => 'a week',
      _ => 'a day',
    };
    final where = switch (settings.action) {
      CodeCleanupAction.archive => 'go to Archive',
      CodeCleanupAction.trash => 'go to Trash',
    };
    return 'Verification codes, sign-in links and password-reset emails '
        'older than $older $where. Pinned ones are kept. You can change '
        'this in Settings.';
  }
}

/// Asks once, in the Verification section, before old codes are moved
/// automatically: "Turn on" or "Not now".
final class CodeCleanupBanner extends StatelessWidget {
  const CodeCleanupBanner({super.key, required this.controller});

  final MailController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      container: true,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(CitusmailTheme.radius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.auto_delete_outlined, color: colors.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Tidy up old codes automatically?',
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        CodeCleanupText.proposal(
                          controller.codeCleaner.settings,
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Wrap(
              alignment: WrapAlignment.end,
              children: [
                TextButton(
                  onPressed: controller.declineTidyCodes,
                  child: const Text('Not now'),
                ),
                TextButton(
                  onPressed: controller.agreeToTidyCodes,
                  child: const Text('Turn on'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
