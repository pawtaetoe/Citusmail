// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

import 'citusmail_theme.dart';

/// Grey stand-ins for rows that are on their way: a circle where the
/// picture goes and two bars where the text goes. Shown while a list
/// loads (the first check for mail, a page reading what was found), so
/// the screen already has the shape it is about to have instead of a
/// lone spinner.
///
/// Still, not animated: nothing moves on screen while waiting, and it
/// never keeps a test or the battery busy.
final class SkeletonRows extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final fill = Theme.of(context).colorScheme.surfaceContainerHigh;
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
    final rows = Semantics(
      label: label,
      liveRegion: true,
      child: ExcludeSemantics(
        child: ListView(
          key: const ValueKey('skeleton-rows'),
          physics: const NeverScrollableScrollPhysics(),
          padding: padding.copyWith(top: CitusSpace.s),
          children: [
            for (var i = 0; i < count; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: CitusSpace.m),
                child: Row(
                  children: [
                    if (avatar) ...[
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
        ),
      ),
    );
    if (maxWidth case final max?) {
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
