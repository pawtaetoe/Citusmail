// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

import '../services/ai_assistant.dart';
import 'app_icons.dart';

/// Pieces the reader's AI helpers share: the one-time "send this to ..."
/// question, and the note under a result saying what was sent where.
abstract final class AiConfirm {
  /// Asks, once per feature and provider, whether the feature may send
  /// mail to [provider]'s company. True if the user agreed.
  static Future<bool> ask(
    BuildContext context,
    AiFeatureProvider provider,
  ) async {
    final feature = provider.feature;
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Send this email to ${provider.recipient}?'),
        content: Text(
          '${feature.title} sends ${feature.sends} to ${provider.recipient}, '
          'with your key, each time you ask. Nothing else from your mailbox '
          'is sent.',
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
    return agreed ?? false;
  }
}

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
