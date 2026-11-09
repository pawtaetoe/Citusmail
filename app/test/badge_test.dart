// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/ui/badge.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// One badge shape everywhere; the tone picks the colours.
void main() {
  Future<Container> pump(WidgetTester tester, AppBadge badge) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: Scaffold(body: Center(child: badge)),
      ),
    );
    return tester.widget<Container>(
      find.ancestor(of: find.byType(Text), matching: find.byType(Container)),
    );
  }

  testWidgets('6dp corners, 2x8 padding, small semibold text', (tester) async {
    final box = await pump(tester, const AppBadge('today'));
    final decoration = box.decoration! as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(6));
    expect(box.padding, const EdgeInsets.symmetric(horizontal: 8, vertical: 2));
    final text = tester.widget<Text>(find.text('today'));
    expect(text.style?.fontWeight, FontWeight.w600);
    expect(
      text.style?.fontSize,
      CitusmailTheme.light().textTheme.labelSmall?.fontSize,
    );
  });

  testWidgets('tones', (tester) async {
    final colors = CitusmailTheme.light().colorScheme;
    final expected = {
      BadgeTone.neutral: (
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
      ),
      BadgeTone.accent: (CitusPalette.citrus, CitusPalette.onCitrus),
      BadgeTone.danger: (colors.errorContainer, colors.onErrorContainer),
    };
    for (final MapEntry(key: tone, value: (background, foreground))
        in expected.entries) {
      final box = await pump(tester, AppBadge('x', tone: tone));
      expect(
        (box.decoration! as BoxDecoration).color,
        background,
        reason: '$tone',
      );
      expect(
        tester.widget<Text>(find.text('x')).style?.color,
        foreground,
        reason: '$tone',
      );
    }
    // Warning: a wash of citrus under ink.
    final warn = await pump(
      tester,
      const AppBadge('x', tone: BadgeTone.warning),
    );
    expect((warn.decoration! as BoxDecoration).color?.a, lessThan(0.5));
    expect(tester.widget<Text>(find.text('x')).style?.color, colors.onSurface);
  });

  testWidgets('a tint of its own, with an icon', (tester) async {
    const pink = Color(0xFFD6409F);
    final box = await pump(
      tester,
      const AppBadge('Snoozed', icon: Icons.snooze, tint: pink),
    );
    expect(
      (box.decoration! as BoxDecoration).color,
      pink.withValues(alpha: 0.14),
    );
    expect(tester.widget<Text>(find.text('Snoozed')).style?.color, pink);
    expect(tester.widget<Icon>(find.byIcon(Icons.snooze)).color, pink);
  });
}
