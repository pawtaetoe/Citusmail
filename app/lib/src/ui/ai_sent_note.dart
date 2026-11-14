// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

import 'app_icons.dart';

/// "Sent this email's sender, subject and text to Anthropic." in small
/// print under what came back.
final class AiSentNote extends StatelessWidget {
  const AiSentNote({super.key, required this.recipient});

  final String recipient;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(AppIcons.assistant, size: 14, color: muted),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Sent this email\'s sender, subject and text to $recipient, '
            'with your key.',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}
