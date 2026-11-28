// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

import '../theme/citusmail_theme.dart';

/// Grey stand-ins for rows that are on their way: a circle where the
/// picture goes and two bars where the text goes. Shown while a list
/// loads (the first check for mail, a page reading what was found), so
/// the screen already has the shape it is about to have instead of a
/// lone spinner.
///
/// A soft light sweeps across them, again and again, so waiting reads as
/// loading rather than the app being stuck. It runs only while the rows
/// are shown (they go once loaded), repaints only them, and stays still
/// when the system asks for less motion.
final class SkeletonRows extends StatefulWidget {
  const SkeletonRows({
    super.key,
    this.count = 6,
    this.label = 'Loading…',
    this.avatar = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.maxWidth,
  });

  final int count;

  /// What a screen reader says instead of the grey shapes.
  final String label;

  /// A circle at the start of each row, as in the message list.
  final bool avatar;

  final EdgeInsets padding;

  /// Keeps the rows in a page's centred content column.
  final double? maxWidth;

  @override
  State<SkeletonRows> createState() => _SkeletonRowsState();
}

final class _SkeletonRowsState extends State<SkeletonRows>
    with SingleTickerProviderStateMixin {
  /// Where the light is: 0 before the rows' start, 1 past their end.
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: CitusMotion.shimmer,
  );
  late final _curve = CurvedAnimation(
    parent: _sweep,
    curve: CitusMotion.standard,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (CitusMotion.reduced(context)) {
      _sweep.value = 0;
    } else if (!_sweep.isAnimating) {
      _sweep.repeat();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final fill = colors.surfaceContainerHigh;
    // A little lighter than the grey, in either theme.
    final light = theme.brightness == Brightness.light
        ? Color.lerp(fill, colors.surfaceContainerLowest, 0.7)!
        : colors.surfaceContainerHighest;
    Widget bar(double widthFactor, double height) => FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthFactor,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(CitusmailTheme.radiusBadge),
        ),
      ),
    );
    final list = ListView(
      key: const ValueKey('skeleton-rows'),
      physics: const NeverScrollableScrollPhysics(),
      padding: widget.padding.copyWith(top: CitusSpace.s),
      children: [
        for (var i = 0; i < widget.count; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: CitusSpace.m),
            child: Row(
              children: [
                if (widget.avatar) ...[
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: fill,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: CitusSpace.m),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Varied, so it reads as rows of text.
                      bar(const [0.45, 0.6, 0.35, 0.5, 0.4][i % 5], 12),
                      const SizedBox(height: CitusSpace.s),
                      bar(const [0.85, 0.7, 0.9, 0.75, 0.8][i % 5], 10),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    final rows = Semantics(
      label: widget.label,
      liveRegion: true,
      child: ExcludeSemantics(
        // Only the grey shapes repaint as the light moves.
        child: RepaintBoundary(
          child: CitusMotion.reduced(context)
              ? list
              : AnimatedBuilder(
                  animation: _curve,
                  child: list,
                  builder: (context, list) => ShaderMask(
                    key: const ValueKey('skeleton-shimmer'),
                    blendMode: BlendMode.srcATop,
                    shaderCallback: (bounds) =>
                        LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [fill, light, fill],
                          stops: const [0.35, 0.5, 0.65],
                          transform: _Slide(_curve.value),
                        ).createShader(
                          bounds,
                          textDirection: Directionality.of(context),
                        ),
                    child: list,
                  ),
                ),
        ),
      ),
    );
    if (widget.maxWidth case final max?) {
      return Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: max),
          child: rows,
        ),
      );
    }
    return rows;
  }
}

/// Moves the gradient's light band from just before the rows (at 0) to
/// just past them (at 1).
final class _Slide extends GradientTransform {
  const _Slide(this.t);

  final double t;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    // The band sits at 35–65% of the width; ±70% takes it out of sight.
    final dx = (t * 1.4 - 0.7) * bounds.width;
    final rtl = textDirection == TextDirection.rtl;
    return Matrix4.translationValues(rtl ? -dx : dx, 0, 0);
  }
}
