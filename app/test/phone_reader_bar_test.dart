// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

/// On a phone, an open message has one bar at the bottom: Back, Reply and
/// the actions, with Reply all and Forward under "More".
void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  Future<void> openOnPhone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: MailShell(
          notifications: false,
          services: app.services,
          onAddAccount: () {},
          onAccountsChanged: () {},
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Hello there'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('one bar: Back, Reply, actions, More', (tester) async {
    await openOnPhone(tester);

    final back = tester.getRect(find.byTooltip('Back (Esc)'));
    final reply = tester.getRect(find.byKey(const ValueKey('reply')));
    final archive = tester.getRect(find.byTooltip('Archive (E)'));
    // All in one row at the bottom.
    expect(reply.center.dy, closeTo(back.center.dy, 1));
    expect(archive.center.dy, closeTo(back.center.dy, 1));
    expect(back.bottom, greaterThan(844 - 80));
    // Room for the everyday actions beside Reply.
    expect(find.byTooltip('Move to Trash (#)'), findsOneWidget);
    expect(reply.width, lessThanOrEqualTo(132));
    // No second bar of reply buttons above it.
    expect(find.widgetWithText(OutlinedButton, 'Reply all'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'Forward'), findsNothing);
    expect(find.text('Reply'), findsOneWidget);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Reply all (A)'), findsOneWidget);
    expect(find.text('Forward (F)'), findsOneWidget);
  });

  testWidgets('Reply opens a reply', (tester) async {
    await openOnPhone(tester);
    await tester.tap(find.byKey(const ValueKey('reply')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Re: Hello there'), findsWidgets);
  });
}
