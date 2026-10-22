// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_trust/mail_trust.dart';

/// Colours and icons for warnings: red for danger, amber for caution.
final class TrustStyle {
  const TrustStyle._(this.background, this.foreground, this.icon);

  factory TrustStyle.of(BuildContext context, TrustLevel level) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return switch (level) {
      TrustLevel.danger => TrustStyle._(
        theme.colorScheme.errorContainer,
        theme.colorScheme.onErrorContainer,
        Icons.gpp_bad_outlined,
      ),
      TrustLevel.caution || TrustLevel.ok => TrustStyle._(
        dark ? const Color(0xFF3D2E0A) : const Color(0xFFFFF1CC),
        dark ? const Color(0xFFFFDFA0) : const Color(0xFF5C3B00),
        Icons.warning_amber_rounded,
      ),
    };
  }

  final Color background;
  final Color foreground;
  final IconData icon;
}

/// The warning at the top of a suspicious message: a plain headline, the
/// reasons, and what the app does about it.
final class TrustBanner extends StatelessWidget {
  const TrustBanner({super.key, required this.report});

  final TrustReport report;

  @override
  Widget build(BuildContext context) {
    final level = report.level;
    if (level == TrustLevel.ok) return const SizedBox.shrink();
    final style = TrustStyle.of(context, level);
    final text = Theme.of(context).textTheme;
    final danger = level == TrustLevel.danger;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: style.background,
          borderRadius: BorderRadius.circular(10),
        ),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: style.foreground),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(style.icon, color: style.foreground),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      danger
                          ? 'This message may be a scam'
                          : 'Be careful with this message',
                      style: text.titleSmall?.copyWith(
                        color: style.foreground,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    for (final finding in report.findings)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('•  '),
                            Expanded(child: Text(finding.message)),
                          ],
                        ),
                      ),
                    if (danger) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Don\'t reply with personal details, sign in from its links, '
                        'or open its attachments. Links and files ask before opening.',
                        style: text.bodySmall?.copyWith(
                          color: style.foreground,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The reasons part of a confirmation dialog.
final class TrustReasons extends StatelessWidget {
  const TrustReasons({super.key, required this.level, required this.reasons});

  final TrustLevel level;
  final List<String> reasons;

  @override
  Widget build(BuildContext context) {
    final style = TrustStyle.of(context, level);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: style.background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(style.icon, size: 20, color: style.foreground),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final reason in reasons)
                  Text(reason, style: TextStyle(color: style.foreground)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
