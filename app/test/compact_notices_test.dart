// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/core/theme/citusmail_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Notices are a compact card in the corner on a wide window, and keep the
/// phone's width on a phone.
void main() {
  Future<Rect> notice(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        builder: (context, child) => CompactNotices(child: child!),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Archived 3 emails')),
              ),
              child: const Text('Show'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle();
    // The card itself (the snack bar's own box spans the window).
    return tester.getRect(
      find
          .ancestor(
            of: find.text('Archived 3 emails'),
            matching: find.byType(Material),
          )
          .first,
    );
  }

  testWidgets('desktop: compact, in the bottom-right corner', (tester) async {
    final rect = await notice(tester, const Size(1400, 900));
    expect(rect.width, lessThanOrEqualTo(CompactNotices.maxWidth + 1));
    expect(rect.right, closeTo(1400 - CitusSpace.xl, 2));
    expect(rect.bottom, closeTo(900 - CitusSpace.xl, 2));
  });

  testWidgets('phone: across the screen, as before', (tester) async {
    final rect = await notice(tester, const Size(390, 844));
    expect(rect.width, greaterThan(300));
  });
}
