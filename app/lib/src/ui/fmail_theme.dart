// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math';

import 'package:flutter/material.dart';

/// The app's colours, in one place. A deep spruce sidebar, a calm lagoon
/// green for actions and selection, and one citrus accent kept for what
/// asks for attention first (new mail counts, the "New message" button).
///
/// Text colours meet WCAG AA (4.5:1) on the backgrounds they are used on.
abstract final class CitusPalette {
  static const spruce = Color(0xFF15332E);
  static const spruceDark = Color(0xFF0E1A18);
  static const citrus = Color(0xFFF4B740);
  static const onCitrus = Color(0xFF2B1D00);
  static const lagoon = Color(0xFF0F7A69);
  static const lagoonLight = Color(0xFF5DCAB4);
  static const paper = Color(0xFFF3F6F5);
  static const ink = Color(0xFF17201E);
}

/// The app's look: Material 3, set in IBM Plex Sans (bundled, so it looks
/// the same on every platform and nothing is fetched from the network).
abstract final class FmailTheme {
  /// The bundled typeface (see assets/fonts).
  static const fontFamily = 'IBMPlexSans';

  /// Kept for callers that want "the brand colour".
  static const accent = CitusPalette.lagoon;

  /// Corner radii: small controls, list rows and fields, dialogs.
  static const radiusSmall = 8.0;
  static const radius = 10.0;
  static const radiusLarge = 20.0;

  /// A field without a box, for writing mail: the lines between fields
  /// do the separating.
  static InputDecoration bareField({
    String? hintText,
    String? errorText,
    bool isDense = false,
  }) => InputDecoration(
    hintText: hintText,
    errorText: errorText,
    isDense: isDense,
    filled: false,
    contentPadding: EdgeInsets.symmetric(vertical: isDense ? 8 : 12),
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    errorBorder: InputBorder.none,
    focusedErrorBorder: InputBorder.none,
  );

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final light = brightness == Brightness.light;
    final colors =
        ColorScheme.fromSeed(
          seedColor: CitusPalette.lagoon,
          brightness: brightness,
        ).copyWith(
          primary: light ? CitusPalette.lagoon : CitusPalette.lagoonLight,
          onPrimary: light ? Colors.white : const Color(0xFF00201A),
          primaryContainer: light
              ? const Color(0xFFD3EDE6)
              : const Color(0xFF1C3E37),
          onPrimaryContainer: light
              ? const Color(0xFF06322B)
              : const Color(0xFFC6EDE4),
          secondaryContainer: light
              ? const Color(0xFFDDEAE6)
              : const Color(0xFF243532),
          surface: light ? Colors.white : const Color(0xFF161E1D),
          onSurface: light ? CitusPalette.ink : const Color(0xFFE4ECEA),
          onSurfaceVariant: light
              ? const Color(0xFF55635F)
              : const Color(0xFFA3B2AE),
          surfaceContainerLowest: light
              ? Colors.white
              : const Color(0xFF101716),
          surfaceContainerLow: light
              ? CitusPalette.paper
              : const Color(0xFF121918),
          surfaceContainer: light
              ? const Color(0xFFECF1EF)
              : const Color(0xFF1B2422),
          surfaceContainerHigh: light
              ? const Color(0xFFE5ECE9)
              : const Color(0xFF212B29),
          surfaceContainerHighest: light
              ? const Color(0xFFDEE6E3)
              : const Color(0xFF28332F),
          outline: light ? const Color(0xFF7A8985) : const Color(0xFF7F8F8B),
          outlineVariant: light
              ? const Color(0xFFD9E1DE)
              : const Color(0xFF2D3936),
          surfaceTint: Colors.transparent,
        );

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      brightness: brightness,
      fontFamily: fontFamily,
      visualDensity: VisualDensity.standard,
    );
    final text = _text(base.textTheme, colors);
    final rounded = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
    );

    return base.copyWith(
      textTheme: text,
      scaffoldBackgroundColor: colors.surface,
      focusColor: colors.primary.withValues(alpha: 0.14),
      hoverColor: colors.onSurface.withValues(alpha: 0.04),
      dividerTheme: DividerThemeData(
        color: colors.outlineVariant,
        space: 1,
        thickness: 1,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: colors.surface,
        foregroundColor: colors.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: rounded,
          minimumSize: const Size(64, 44),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          textStyle: text.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: rounded,
          minimumSize: const Size(64, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          side: BorderSide(color: colors.outlineVariant),
          foregroundColor: colors.onSurface,
          textStyle: text.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSmall),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          shape: rounded,
          side: BorderSide(color: colors.outlineVariant),
          selectedBackgroundColor: colors.primaryContainer,
          selectedForegroundColor: colors.onPrimaryContainer,
          foregroundColor: colors.onSurfaceVariant,
          textStyle: text.labelLarge,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceContainer,
        hoverColor: Colors.transparent,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: colors.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: colors.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: colors.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: colors.error, width: 2),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
        ),
        side: BorderSide(color: colors.outlineVariant),
        labelStyle: text.labelLarge,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLarge),
        ),
        titleTextStyle: text.titleLarge,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: colors.surface,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: colors.outlineVariant),
        ),
        textStyle: text.bodyMedium,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: light ? const Color(0xFF1E2B28) : const Color(0xFFDDE7E4),
        contentTextStyle: text.bodyMedium?.copyWith(
          color: light ? Colors.white : CitusPalette.ink,
        ),
        actionTextColor: light ? CitusPalette.citrus : CitusPalette.lagoon,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        decoration: BoxDecoration(
          color: light ? const Color(0xF01E2B28) : const Color(0xF0DDE7E4),
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: text.bodySmall?.copyWith(
          color: light ? Colors.white : CitusPalette.ink,
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        radius: const Radius.circular(4),
        thickness: const WidgetStatePropertyAll(6),
        thumbColor: WidgetStatePropertyAll(
          colors.onSurface.withValues(alpha: 0.22),
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
        ),
        titleTextStyle: text.bodyLarge?.copyWith(
          color: colors.onSurface,
          fontWeight: FontWeight.w500,
          height: 1.35,
        ),
        subtitleTextStyle: text.bodyMedium?.copyWith(
          color: colors.onSurfaceVariant,
        ),
      ),
      drawerTheme: const DrawerThemeData(
        shape: RoundedRectangleBorder(),
        backgroundColor: CitusPalette.spruce,
      ),
      extensions: [
        SidebarColors(
          background: light ? CitusPalette.spruce : CitusPalette.spruceDark,
          selected: Colors.white.withValues(alpha: 0.09),
          hover: Colors.white.withValues(alpha: 0.05),
          text: Colors.white.withValues(alpha: 0.92),
          muted: Colors.white.withValues(alpha: 0.62),
          badge: CitusPalette.citrus,
          onBadge: CitusPalette.onCitrus,
          indicator: CitusPalette.citrus,
          problem: const Color(0xFFFFB4A8),
        ),
        ListColors(
          background: colors.surfaceContainerLow,
          selected: light ? const Color(0xFFDCECE7) : const Color(0xFF1D3531),
          checked: colors.primaryContainer,
          unreadDot: colors.primary,
        ),
      ],
    );
  }

  /// IBM Plex Sans at a scale for a dense, scannable mail app: body 14,
  /// headers in semibold with slightly tighter tracking.
  static TextTheme _text(TextTheme base, ColorScheme colors) {
    TextStyle? tune(
      TextStyle? s, {
      double? size,
      FontWeight? weight,
      double? height,
      double? spacing,
    }) => s?.copyWith(
      fontFamily: fontFamily,
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: spacing,
    );

    return base.copyWith(
      headlineMedium: tune(
        base.headlineMedium,
        size: 28,
        weight: FontWeight.w600,
        height: 1.2,
        spacing: -0.4,
      ),
      headlineSmall: tune(
        base.headlineSmall,
        size: 24,
        weight: FontWeight.w600,
        height: 1.25,
        spacing: -0.3,
      ),
      titleLarge: tune(
        base.titleLarge,
        size: 20,
        weight: FontWeight.w600,
        spacing: -0.2,
      ),
      titleMedium: tune(
        base.titleMedium,
        size: 16,
        weight: FontWeight.w600,
        spacing: 0,
      ),
      titleSmall: tune(
        base.titleSmall,
        size: 14,
        weight: FontWeight.w600,
        spacing: 0,
      ),
      bodyLarge: tune(base.bodyLarge, size: 15, height: 1.5, spacing: 0),
      bodyMedium: tune(base.bodyMedium, size: 14, height: 1.45, spacing: 0),
      bodySmall: tune(base.bodySmall, size: 12.5, height: 1.4, spacing: 0.1),
      labelLarge: tune(
        base.labelLarge,
        size: 14,
        weight: FontWeight.w600,
        spacing: 0.1,
      ),
      labelMedium: tune(base.labelMedium, size: 12.5, spacing: 0.2),
      labelSmall: tune(base.labelSmall, size: 11.5, spacing: 0.3),
    );
  }
}

/// Colors of the dark sidebar (the same in light and dark mode).
final class SidebarColors extends ThemeExtension<SidebarColors> {
  const SidebarColors({
    required this.background,
    required this.selected,
    required this.hover,
    required this.text,
    required this.muted,
    required this.badge,
    required this.onBadge,
    required this.indicator,
    required this.problem,
  });

  final Color background;
  final Color selected;
  final Color hover;
  final Color text;
  final Color muted;
  final Color badge;
  final Color onBadge;

  /// The bar beside the place shown.
  final Color indicator;

  /// Sync problems (readable on [background]).
  final Color problem;

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
    required this.background,
    required this.selected,
    required this.checked,
    required this.unreadDot,
  });

  /// The list pane, a shade off the reader's white.
  final Color background;

  /// The row open in the reader.
  final Color selected;

  /// Rows picked for a bulk action.
  final Color checked;
  final Color unreadDot;

  static ListColors of(BuildContext context) =>
      Theme.of(context).extension<ListColors>()!;

  @override
  ListColors copyWith() => this;

  @override
  ListColors lerp(ListColors? other, double t) => other ?? this;
}

/// The app's mark: a citrus slice, drawn (no image asset to load).
final class CitusMark extends StatelessWidget {
  const CitusMark({super.key, this.size = 24});

  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(size: Size.square(size), painter: const _SlicePainter()),
  );
}

final class _SlicePainter extends CustomPainter {
  const _SlicePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    canvas.drawCircle(c, r, Paint()..color = CitusPalette.citrus);
    final pith = Paint()
      ..color = CitusPalette.onCitrus.withValues(alpha: 0.55)
      ..strokeWidth = max(1, r * 0.11)
      ..strokeCap = StrokeCap.round;
    // Six segments, like a cut lemon.
    for (var i = 0; i < 6; i++) {
      final a = i * pi / 3 + pi / 6;
      canvas.drawLine(
        c + Offset(cos(a), sin(a)) * r * 0.16,
        c + Offset(cos(a), sin(a)) * r * 0.68,
        pith,
      );
    }
    canvas.drawCircle(
      c,
      r * 0.82,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = max(1, r * 0.09)
        ..color = CitusPalette.onCitrus.withValues(alpha: 0.35),
    );
  }

  @override
  bool shouldRepaint(_SlicePainter oldDelegate) => false;
}
