// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

/// The compose toolbar's toggles say what they are where there is room.
void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  Future<void> compose(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
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
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byTooltip('New message (C)'));
    await tester.pumpAndSettle();
  }

  testWidgets('desktop: "Receipt" and "Remind me" are labelled, and fill in '
      'when on', (tester) async {
    await compose(tester, const Size(1400, 900));
    expect(find.text('Receipt'), findsOneWidget);
    expect(find.text('Remind me'), findsOneWidget);
    expect(find.text('Cc · Bcc'), findsOneWidget);
    await tester.tap(find.text('Receipt'));
    await tester.pump();
    expect(find.byIcon(Icons.mark_email_read), findsOneWidget);
    expect(
      find.byTooltip('Read receipt requested (tap to cancel)'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Close (keeps the draft)'));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('phone: the toggles stay icons', (tester) async {
    await compose(tester, const Size(400, 860));
    expect(find.text('Receipt'), findsNothing);
    expect(find.text('Remind me'), findsNothing);
    expect(find.byTooltip('Ask for a read receipt'), findsOneWidget);
    expect(find.byKey(const ValueKey('compose-follow-up')), findsOneWidget);
    await tester.tap(find.byTooltip('Close (keeps the draft)'));
    await tester.pump(const Duration(seconds: 1));
  });
}
