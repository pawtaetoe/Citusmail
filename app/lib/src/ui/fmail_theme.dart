// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

/// The app's look: a dark navy sidebar next to light (or dark) panes, with
/// a blue accent, in the spirit of Spark.
abstract final class FmailTheme {
  static const accent = Color(0xFF2F80ED);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final colors = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
      primary: brightness == Brightness.light
          ? accent
          : const Color(0xFF7FB2F5),
    );
    return ThemeData(
      colorScheme: colors,
      brightness: brightness,
      visualDensity: VisualDensity.standard,
      dividerTheme: DividerThemeData(
        color: colors.outlineVariant.withValues(alpha: 0.6),
        space: 1,
        thickness: 1,
      ),
      extensions: [
        SidebarColors(
          background: brightness == Brightness.light
              ? const Color(0xFF243044)
              : const Color(0xFF161D2A),
          selected: Colors.white.withValues(alpha: 0.10),
          text: Colors.white.withValues(alpha: 0.88),
          muted: Colors.white.withValues(alpha: 0.55),
          badge: accent,
        ),
        ListColors(
          selected: brightness == Brightness.light
              ? const Color(0xFFE6F0FD)
              : const Color(0xFF1E2C42),
          sectionBackground: brightness == Brightness.light
              ? const Color(0xFFF6F7F9)
              : const Color(0xFF1A1D22),
          unreadDot: accent,
        ),
      ],
    );
  }
}

/// Colors of the dark sidebar (the same in light and dark mode).
final class SidebarColors extends ThemeExtension<SidebarColors> {
  const SidebarColors({
    required this.background,
    required this.selected,
    required this.text,
    required this.muted,
    required this.badge,
  });

  final Color background;
  final Color selected;
  final Color text;
  final Color muted;
  final Color badge;

  static SidebarColors of(BuildContext context) =>
      Theme.of(context).extension<SidebarColors>()!;

  @override
  SidebarColors copyWith() => this;

  @override
  SidebarColors lerp(SidebarColors? other, double t) => other ?? this;
}

/// Colors of the message list.
final class ListColors extends ThemeExtension<ListColors> {
  const ListColors({
    required this.selected,
    required this.sectionBackground,
    required this.unreadDot,
  });

  final Color selected;
  final Color sectionBackground;
  final Color unreadDot;

  static ListColors of(BuildContext context) =>
      Theme.of(context).extension<ListColors>()!;

  @override
  ListColors copyWith() => this;

  @override
  ListColors lerp(ListColors? other, double t) => other ?? this;
}
