// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

import '../app.dart' show appName;
import '../services/ai_assistant.dart';

/// The first time a feature would send mail to a provider: names the
/// provider and what is sent, and sends only if the user agrees (asked
/// once per feature and provider). Every AI feature calls this before
/// its first request.
Future<bool> confirmAiSend(
  BuildContext context,
  AiFeatureProvider provider,
) async {
  if (!provider.needsConfirmation) return true;
  final yes = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('ai-confirm'),
      title: Text('Send to ${provider.recipient}?'),
      content: Text(
        '${provider.feature.title}: to do this, $appName sends '
        '${provider.feature.sends} to ${provider.recipient}, straight from '
        'this device with your key, and only when you ask.\n\n'
        '${provider.recipient}\'s terms and privacy policy apply to what it '
        'receives. $appName itself receives nothing.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Not now'),
        ),
        FilledButton(
          key: const ValueKey('ai-confirm-send'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Send'),
        ),
      ],
    ),
  );
  if (yes != true) return false;
  provider.confirm();
  return true;
}
