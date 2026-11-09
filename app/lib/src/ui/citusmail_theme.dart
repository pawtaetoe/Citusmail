// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:flutter/material.dart';

/// The app's colours, in one place: "paper and lagoon". Warm, paper-like
/// neutrals for everything you read, a deep spruce sidebar as the one cool
/// dark element, lagoon green strictly for what you can act on (buttons,
/// links, the open row) and one citrus accent strictly for what is
/// time-sensitive (new mail counts, "today", "in 2 days", the "New
/// message" button).
///
/// Text colours meet WCAG AA (4.5:1) on the backgrounds they are used on.
abstract final class CitusPalette {
  static const spruce = Color(0xFF15332E);
  static const spruceDark = Color(0xFF111917);
  static const citrus = Color(0xFFF4B740);
  static const onCitrus = Color(0xFF2B1D00);
  static const lagoon = Color(0xFF0F7A69);
  static const lagoonLight = Color(0xFF5DCAB4);

  /// The message list's background: a warm off-white.
  static const paper = Color(0xFFF4F2EC);

  /// Text on paper: a warm near-black.
  static const ink = Color(0xFF1B1A17);
}

/// The spacing scale: every gap and padding is one of these, so screens
/// share a rhythm.
abstract final class CitusSpace {
  static const xs = 4.0;
  static const s = 8.0;
  static const m = 12.0;
  static const l = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

/// The app's look: Material 3, set in IBM Plex Sans (bundled, so it looks
/// the same on every platform and nothing is fetched from the network).
abstract final class CitusmailTheme {
  /// The bundled typeface (see assets/fonts).
  static const fontFamily = 'IBMPlexSans';

  /// Kept for callers that want "the brand colour".
  static const accent = CitusPalette.lagoon;

  /// Corner radii, from small to large: badges, chips and text buttons,
  /// controls (buttons, fields, list rows), cards, dialogs and sheets.
  static const radiusBadge = 6.0;
  static const radiusSmall = 8.0;
  static const radius = 10.0;
  static const radiusCard = 12.0;
  static const radiusLarge = 20.0;

  /// The widest a column of text gets, so lines stay readable on wide
  /// windows: a message being read, a message being written.
  static const readingWidth = 720.0;
  static const writingWidth = 760.0;

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
              ? const Color(0xFFD6EFE7)
              : const Color(0xFF1C3E37),
          onPrimaryContainer: light
              ? const Color(0xFF06322B)
              : const Color(0xFFC6EDE4),
          secondaryContainer: light
              ? const Color(0xFFDDEAE6)
              : const Color(0xFF243532),
          // Surfaces: warm neutrals in light mode (paper, not clinic
          // white); in dark mode they get lighter as they rise, so cards
          // sit on top of the page rather than sinking into it.
          surface: light ? const Color(0xFFFCFBF8) : const Color(0xFF171C1B),
          onSurface: light ? CitusPalette.ink : const Color(0xFFECEAE4),
          onSurfaceVariant: light
              ? const Color(0xFF5C5A53)
              : const Color(0xFFA9A79F),
          surfaceContainerLowest: light
              ? Colors.white
              : const Color(0xFF121615),
          surfaceContainerLow: light
              ? CitusPalette.paper
              : const Color(0xFF1D2321),
          surfaceContainer: light
              ? const Color(0xFFECE9E1)
              : const Color(0xFF242A28),
          surfaceContainerHigh: light
              ? const Color(0xFFE6E2D9)
              : const Color(0xFF2A312E),
          surfaceContainerHighest: light
              ? const Color(0xFFDFDBD1)
              : const Color(0xFF333A37),
          outline: light ? const Color(0xFF7D7B73) : const Color(0xFF83857F),
          outlineVariant: light
              ? const Color(0xFFE3DFD5)
              : const Color(0xFF343B38),
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
      hoverColor: colors.onSurface.withValues(alpha: 0.06),
      // Desktop: pages fade forward into place rather than zooming in
      // like a phone app. Android and iOS keep their own transitions.
      pageTransitionsTheme: PageTransitionsTheme(
        builders: {
          ...const PageTransitionsTheme().builders,
          TargetPlatform.linux: const FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.windows: const FadeForwardsPageTransitionsBuilder(),
        },
      ),
      // Flat cards: a white (or, in the dark, a lighter) surface with a
      // hairline, no shadow, so they read the same in a screenshot and on
      // screen.
      cardTheme: CardThemeData(
        elevation: 0,
        color: light ? colors.surfaceContainerLowest : colors.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusCard),
          side: BorderSide(color: colors.outlineVariant),
        ),
      ),
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
        // Every notice can be closed; it also closes by itself (see
        // SnackBar.persist: those with a button pass false).
        showCloseIcon: true,
        closeIconColor: light ? Colors.white70 : CitusPalette.ink,
        backgroundColor: light
            ? const Color(0xFF1E2B28)
            : const Color(0xFFDDE7E4),
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
          selected: colors.primaryContainer,
          indicator: colors.primary,
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
    required this.indicator,
    required this.checked,
    required this.unreadDot,
  });

  /// The list pane, a shade off the reader's white.
  final Color background;

  /// The row open in the reader.
  final Color selected;

  /// The bar at the left of the open row (as in the sidebar), so the row
  /// is marked by more than its tint.
  final Color indicator;

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

/// The app's mark, as in the app icon (assets/icon/icon.svg): a
/// forward-leaning envelope with citrus speed lines ("citus" is Latin for
/// fast) on a lagoon tile. Drawn, so there is no image asset to load.
final class CitusMark extends StatelessWidget {
  const CitusMark({super.key, this.size = 24});

  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(size: Size.square(size), painter: const _MarkPainter()),
  );
}

final class _MarkPainter extends CustomPainter {
  const _MarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    // The icon's own 512-unit drawing, scaled to fit.
    final scale = size.shortestSide / 512;
    canvas.save();
    canvas.scale(scale);

    // The tile (the icon's 16-unit margin dropped, so it fills the space).
    const tile = Rect.fromLTWH(0, 0, 512, 512);
    canvas.drawRRect(
      RRect.fromRectAndRadius(tile, const Radius.circular(120)),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF14917C), Color(0xFF0B4A40)],
        ).createShader(tile),
    );

    // The envelope, leaning forward (skewX -14 degrees, moved right).
    canvas.save();
    canvas.transform(
      Float64List.fromList([
        1, 0, 0, 0, //
        -0.2493, 1, 0, 0, //
        0, 0, 1, 0, //
        96, 0, 0, 1, //
      ]),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(150, 160, 252, 184),
        const Radius.circular(26),
      ),
      Paint()..color = Colors.white,
    );
    canvas.drawPath(
      Path()
        ..moveTo(166, 180)
        ..lineTo(276, 262)
        ..lineTo(386, 180),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 22
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = CitusPalette.lagoon,
    );
    canvas.restore();

    // Citrus speed lines.
    final speed = Paint()
      ..strokeWidth = 22
      ..strokeCap = StrokeCap.round
      ..color = CitusPalette.citrus;
    canvas.drawLine(const Offset(104, 206), const Offset(168, 206), speed);
    canvas.drawLine(const Offset(84, 252), const Offset(160, 252), speed);
    canvas.drawLine(const Offset(104, 298), const Offset(148, 298), speed);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MarkPainter oldDelegate) => false;
}
