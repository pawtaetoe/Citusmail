// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens links from mail only after showing where they really go: the
/// text of a link can say one thing and point somewhere else.
abstract final class LinkOpener {
  static Future<void> open(BuildContext context, Uri link) async {
    if (link.scheme == 'mailto') return _copyAddress(context, link);
    final unusual = link.host.runes.any((r) => r > 0x7E);
    final open = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Open this link?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              link.host,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            SelectableText(
              link.toString(),
              maxLines: 6,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (link.scheme == 'http') ...[
              const SizedBox(height: 12),
              const Text('This link is not encrypted.'),
            ],
            if (unusual) ...[
              const SizedBox(height: 12),
              Text(
                'The address uses unusual characters that can imitate a familiar site. '
                'Check it carefully.',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Open in browser'),
          ),
        ],
      ),
    );
    if (open != true) return;
    final launched = await launchUrl(
      link,
      mode: LaunchMode.externalApplication,
    );
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No app could open this link.')),
      );
    }
  }

  /// Writing mail arrives with the compose screen; until then, copy.
  static Future<void> _copyAddress(BuildContext context, Uri link) async {
    await Clipboard.setData(ClipboardData(text: link.path));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Copied ${link.path}')));
  }
}
