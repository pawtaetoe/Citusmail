// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_lookup/mail_lookup.dart';
import 'package:mail_trust/mail_trust.dart';
import 'package:url_launcher/url_launcher.dart';

import 'trust_banner.dart';

/// Opens links from mail only after showing where they really go: the
/// text of a link can say one thing and point somewhere else.
abstract final class LinkOpener {
  /// Opens [link] after confirmation; `mailto:` links go to [onMailto]
  /// (the compose window).
  ///
  /// [trust] is the message's check report. A link it flags, or any link
  /// in a message that looks like a scam, gets a warning, and "Don't open"
  /// becomes the main button.
  static Future<void> open(
    BuildContext context,
    Uri link, {
    required void Function(Uri mailto) onMailto,
    TrustReport? trust,
    Future<SafeBrowsingVerdict?> Function(Uri link)? safety,
  }) async {
    if (link.scheme == 'mailto') return onMailto(link);
    final reasons = <String>[...?trust?.link(link)?.reasons];
    var level = trust?.link(link)?.level ?? TrustLevel.ok;
    // Google Safe Browsing, when the user turned it on: checked on the
    // device, so this is quick unless a match must be confirmed.
    if (safety != null) {
      final verdict = await safety(link);
      if (!context.mounted) return;
      if (verdict?.threat case final threat?) {
        level = TrustLevel.danger;
        reasons.add(switch (threat) {
          ThreatType.socialEngineering =>
            'Google Safe Browsing lists this site as deceptive (phishing).',
          ThreatType.malware =>
            'Google Safe Browsing lists this site as spreading malware.',
          ThreatType.unwantedSoftware =>
            'Google Safe Browsing lists this site for unwanted software.',
        });
      }
    }
    if (trust?.level == TrustLevel.danger) {
      level = TrustLevel.danger;
      reasons.add('This message may be a scam.');
    }
    final unusual = link.host.runes.any((r) => r > 0x7E);
    if (unusual && reasons.isEmpty) {
      level = level.max(TrustLevel.caution);
      reasons.add(
        'The address uses unusual characters that can imitate a familiar '
        'site. Check it carefully.',
      );
    }
    if (link.scheme == 'http') reasons.add('This link is not encrypted.');
    final risky = level != TrustLevel.ok;
    // Opened without the parameters that only report the click.
    final (link: cleaned, :removed) = LinkCleaner.clean(link);

    final open = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(risky ? 'Open this link anyway?' : 'Open this link?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _host(link),
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            SelectableText(
              cleaned.toString(),
              maxLines: 6,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (removed.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Tracking removed from the link: ${removed.take(4).join(', ')}'
                '${removed.length > 4 ? ' and ${removed.length - 4} more' : ''}.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (reasons.isNotEmpty) ...[
              const SizedBox(height: 12),
              if (risky)
                TrustReasons(level: level, reasons: reasons)
              else
                for (final reason in reasons) Text(reason),
            ],
          ],
        ),
        // The safe choice is the prominent one when something is wrong.
        actions: risky
            ? [
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Open anyway'),
                ),
                FilledButton(
                  autofocus: true,
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Don\'t open'),
                ),
              ]
            : [
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
    if (open != true || !context.mounted) return;
    await launch(context, cleaned);
  }

  /// Opens [link] in the browser without asking (the caller already
  /// showed where it goes). Returns whether a browser took it.
  static Future<bool> launch(BuildContext context, Uri link) async {
    final messenger = ScaffoldMessenger.of(context);
    final launched = await launchUrl(
      link,
      mode: LaunchMode.externalApplication,
    );
    if (!launched) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No app could open this link.')),
      );
    }
    return launched;
  }

  /// The host as people read it: international names decoded, so a
  /// lookalike shows its true letters next to the punycode.
  static String _host(Uri link) {
    String host;
    try {
      host = Uri.decodeComponent(link.host);
    } on Object {
      host = link.host;
    }
    final readable = Domains.normalize(host);
    if (readable == null || readable == host) return host;
    return '$readable ($host)';
  }
}
