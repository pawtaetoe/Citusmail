// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  void seed(String fixture, {required String subject, required int uid}) =>
      app.seedFixture(fixture, subject: subject, uid: uid);

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
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
  }

  Future<void> open(WidgetTester tester, String subject) async {
    await tester.tap(find.text(subject));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('a phishing message gets a red warning and guarded links', (
    tester,
  ) async {
    seed(
      'security/phishing-link-mismatch.eml',
      subject: 'Your account has been limited',
      uid: 70,
    );
    await show(tester);
    await open(tester, 'Your account has been limited');

    expect(find.text('This message may be a scam'), findsOneWidget);
    expect(
      find.textContaining('couldn\'t confirm this came from mailbox.example'),
      findsOneWidget,
    );
    expect(find.textContaining('calls itself PayPal'), findsOneWidget);

    final link = find
        .textContaining('https://www.paypal.com/signin', findRichText: true)
        .last;
    await tester.tapAt(tester.getTopLeft(link) + const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.text('Open this link anyway?'), findsOneWidget);
    expect(
      find.textContaining(
        'shows www.paypal.com but goes to paypa1-login.example',
      ),
      findsOneWidget,
    );
    expect(find.text('Open anyway'), findsOneWidget);
    await tester.tap(find.text('Don\'t open'));
    await tester.pumpAndSettle();
    expect(find.text('Open this link anyway?'), findsNothing);
  });

  testWidgets('a risky attachment asks before saving', (tester) async {
    seed('security/risky-attachments.eml', subject: 'Overdue invoice', uid: 71);
    await show(tester);
    await open(tester, 'Overdue invoice');

    expect(find.text('This message may be a scam'), findsOneWidget);
    await tester.tap(find.textContaining('invoice.pdf.exe ·'));
    await tester.pumpAndSettle();
    expect(find.text('Save this file anyway?'), findsOneWidget);
    expect(find.textContaining('Pretends to be a .pdf'), findsWidgets);
    await tester.tap(find.text('Don\'t save'));
    await tester.pumpAndSettle();
    expect(find.text('Save this file anyway?'), findsNothing);
    expect(find.textContaining('Saved to'), findsNothing);
  });

  testWidgets('ordinary mail shows no warning', (tester) async {
    await show(tester);
    await open(tester, 'Hello there');
    expect(find.text('This message may be a scam'), findsNothing);
    expect(find.text('Be careful with this message'), findsNothing);
  });
}
