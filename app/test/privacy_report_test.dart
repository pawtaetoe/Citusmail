// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/mail/privacy_report_model.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/privacy_report_page.dart';
import 'package:citusmail/src/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/privacy_mail.dart';
import 'support/test_app.dart';

void main() {
  final now = DateTime.utc(2026, 11, 4, 12);
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  /// Lets isolates (counting) finish.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  test('counts stored mail per period; nothing is downloaded', () async {
    seedPrivacyMail(app, now);
    final model = PrivacyReportModel(app.services, now: () => now);
    await model.load();

    final week = model.report;
    expect(model.period, PrivacyPeriod.week);
    // Shop twice, Market, the boss, Carol, the scam.
    expect(week.messages, 6);
    expect(model.received, 7, reason: 'with the sale not downloaded');
    expect(week.trackers, 2 + 2 + 3);
    expect(week.remoteImages, 2);
    expect(week.trackingLinks, 4);
    expect(week.readReceipts, 1);
    expect(week.warned, 1);
    expect(week.topTrackers.map((s) => s.address), [
      'deals@market.example',
      'news@shop.example',
    ]);
    expect(model.capped, isFalse);

    model.select(PrivacyPeriod.month);
    final month = model.report;
    // And "Summer leftovers" and the test inbox's "Hello there" (a pixel).
    expect(month.messages, 8);
    expect(month.trackers, 2 + 2 + 2 + 3 + 1);
    expect(month.topTrackers.first.address, 'deals@market.example');
    expect(month.topTrackers[1].emails, 3);
    model.dispose();
  });

  testWidgets('the page: numbers, periods and the senders that track', (
    tester,
  ) async {
    seedPrivacyMail(app, now);
    final shown = <String>[];
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: PrivacyReportPage(
          services: app.services,
          onShowMail: shown.add,
          now: () => now,
        ),
      ),
    );
    await settle(tester);

    expect(
      find.text('Citusmail blocked 7 trackers in the last 7 days'),
      findsOneWidget,
    );
    expect(find.text('In 6 emails on this device.'), findsOneWidget);
    expect(find.text('Trackers blocked'), findsOneWidget);
    expect(
      find.textContaining('Tracking pixels tell a sender when and where'),
      findsOneWidget,
    );
    expect(find.text('Remote images held back'), findsOneWidget);
    expect(find.text('Links with tracking tags'), findsOneWidget);
    expect(find.text('Read receipt not sent'), findsOneWidget);
    expect(find.text('Email warned about'), findsOneWidget);
    expect(find.text('Senders that track you most'), findsOneWidget);
    expect(find.text('3 trackers per email · 3 in 1 email'), findsOneWidget);
    expect(find.text('2 trackers per email · 4 in 2 emails'), findsOneWidget);
    expect(
      find.text(
        'Everything here is counted on this device. Nothing is sent anywhere.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Counted from the 6 of 7 emails received in the '
        'last 7 days whose content is on this device',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Last 30 days'));
    await tester.pumpAndSettle();
    expect(
      find.text('Citusmail blocked 10 trackers in the last 30 days'),
      findsOneWidget,
    );
    expect(find.text('2 trackers per email · 6 in 3 emails'), findsOneWidget);

    await tester.tap(find.text('Shop'));
    await tester.pumpAndSettle();
    expect(shown, ['news@shop.example']);
  });

  testWidgets('nothing on the device yet: says so, no zeros', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: PrivacyReportPage(services: app.services, now: () => now),
      ),
    );
    await settle(tester);
    expect(find.text('Nothing to count yet'), findsOneWidget);
    expect(find.text('Trackers blocked'), findsNothing);
    expect(find.textContaining('Nothing is sent anywhere'), findsOneWidget);
  });

  testWidgets('from the sidebar\'s Tools; a sender opens their mail', (
    tester,
  ) async {
    seedPrivacyMail(app, DateTime.now().toUtc());
    tester.view.physicalSize = const Size(1400, 1600);
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
    // In Tools, folded at first.
    expect(find.text('Privacy report'), findsNothing);
    await tester.tap(find.text('Tools'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Privacy report'));
    await tester.pump();
    await settle(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('Citusmail blocked'), findsOneWidget);

    // Back to the mail.
    await tester.tap(find.text('Market'));
    await settle(tester);
    expect(find.byType(PrivacyReportPage), findsNothing);
    expect(find.text('Deals of the day'), findsOneWidget);
    expect(find.text('Lunch?'), findsNothing);
  });

  testWidgets('from Settings, About, Privacy', (tester) async {
    tester.view.physicalSize = const Size(400, 2800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: SettingsPage(services: app.services, isAndroid: false),
      ),
    );
    await tester.pumpAndSettle();
    // A phone: the groups first, then Help & about.
    await tester.tap(find.text('Help & about'));
    await settle(tester);
    await tester.ensureVisible(find.text('Privacy'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Privacy'));
    await settle(tester);
    expect(find.text('Privacy report'), findsOneWidget);
    expect(find.textContaining('Nothing is sent anywhere'), findsOneWidget);
  });
}
