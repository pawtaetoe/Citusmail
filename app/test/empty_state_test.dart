// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/empty_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG contrast of [fg] drawn with its alpha over the opaque [bg].
double contrast(Color fg, Color bg) {
  final over = Color.alphaBlend(fg, bg);
  final la = over.computeLuminance();
  final lb = bg.computeLuminance();
  final (hi, lo) = la > lb ? (la, lb) : (lb, la);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  for (final (name, theme) in [
    ('light', CitusmailTheme.light()),
    ('dark', CitusmailTheme.dark()),
  ]) {
    testWidgets('$name: the icon is muted but still 3:1 on the list', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(
            body: EmptyState(icon: Icons.mail_outline, text: 'Nothing here.'),
          ),
        ),
      );
      final icon = tester.widget<Icon>(find.byIcon(Icons.mail_outline));
      final colors = theme.colorScheme;
      expect(icon.color!.a, closeTo(EmptyState.iconAlpha, 0.001));
      expect(icon.size, 48);
      final list = theme.extension<ListColors>()!.background;
      expect(contrast(icon.color!, list), greaterThan(3));
      expect(contrast(icon.color!, colors.surface), greaterThan(3));
      expect(find.text('Nothing here.'), findsOneWidget);
    });
  }

  testWidgets('a hint and an action, when given', (tester) async {
    var checked = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: Scaffold(
          body: EmptyState(
            icon: Icons.inbox_outlined,
            text: 'Your inbox is empty.',
            hint: 'Nothing new has arrived.',
            action: 'Check for new mail',
            onAction: () => checked++,
          ),
        ),
      ),
    );
    expect(find.text('Nothing new has arrived.'), findsOneWidget);
    await tester.tap(find.text('Check for new mail'));
    expect(checked, 1);
  });
}
