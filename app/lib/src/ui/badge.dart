// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

import 'citusmail_theme.dart';

/// What a badge says by its colour.
enum BadgeTone {
  /// A plain label: "Newsletter", "Paid".
  neutral,

  /// Time-sensitive, in citrus: "today", "in 2 days".
  accent,

  /// Something changed: "Moved", "Changed".
  warning,

  /// Something is off: "Cancelled", "Overdue".
  danger,
}

/// A small label on a card or a row: one shape (6dp corners, 2x8dp
/// padding, small semibold text) everywhere, coloured by [tone].
final class AppBadge extends StatelessWidget {
  const AppBadge(
    this.label, {
    super.key,
    this.tone = BadgeTone.neutral,
    this.icon,
    this.tint,
  });

  final String label;
  final BadgeTone tone;

  /// A small icon before the label.
  final IconData? icon;

  /// A colour of its own instead of a [tone] (the snooze colour): the
  /// text in it, the fill a light wash of it.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final (Color background, Color foreground) = switch (tint) {
      final tint? => (tint.withValues(alpha: 0.14), tint),
      null => switch (tone) {
        BadgeTone.neutral => (
          colors.surfaceContainerHighest,
          colors.onSurfaceVariant,
        ),
        BadgeTone.accent => (CitusPalette.citrus, CitusPalette.onCitrus),
        BadgeTone.warning => (
          CitusPalette.citrus.withValues(alpha: 0.24),
          colors.onSurface,
        ),
        BadgeTone.danger => (colors.errorContainer, colors.onErrorContainer),
      },
    };
    final style = theme.textTheme.labelSmall?.copyWith(
      color: foreground,
      fontWeight: FontWeight.w600,
      height: 1.3,
    );
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: CitusSpace.s,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(CitusmailTheme.radiusBadge),
      ),
      child: icon == null
          ? Text(label, style: style)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 12, color: foreground),
                const SizedBox(width: 3),
                Text(label, style: style),
              ],
            ),
    );
  }
}
