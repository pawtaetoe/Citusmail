// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/mail/mail_controller.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/feature_settings.dart';
import 'package:citusmail/src/ui/image_senders_page.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/screener_page.dart';
import 'package:citusmail/src/ui/settings_page.dart';
import 'package:citusmail/src/ui/subscriptions_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

/// A feature's options where the feature is, not only in Settings.
void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  void size(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Widget shell() => MaterialApp(
    theme: CitusmailTheme.light(),
    home: MailShell(
      notifications: false,
      services: app.services,
      onAddAccount: () {},
      onAccountsChanged: () {},
    ),
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('the Screener page has its options', (tester) async {
    size(tester, const Size(1200, 900));
    app.store.screener.enable();
    final controller = MailController(app.services);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: ScreenerPage(controller: controller),
      ),
    );
    await tester.tap(find.byTooltip('Screener options'));
    await tester.pumpAndSettle();
    expect(find.text('Screen first-time senders'), findsOneWidget);
    await tester.tap(find.text('Newsletters'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive').last);
    await tester.pumpAndSettle();
    expect(app.store.screener.outPlace, ScreenOutPlace.archive);
    expect(find.text('Screened senders'), findsOneWidget);
  });

  testWidgets('the sync line: notifications and checking mail', (tester) async {
    size(tester, const Size(1400, 900));
    await tester.pumpWidget(shell());
    await tester.pump();
    await tester.tap(find.byTooltip('Notifications and checking mail'));
    await tester.pumpAndSettle();
    expect(find.byType(CheckingMailSheet), findsOneWidget);
    expect(find.text('Instant mail'), findsNothing, reason: 'Android only');
    await tester.tap(find.text('New mail notifications'));
    await tester.pump();
    expect(app.services.settings.notifications, isFalse);

    await tester.tap(find.text('All notification settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(
      find.descendant(
        of: find.byWidgetPredicate((w) => w is SettingHighlight && w.on),
        matching: find.text('New mail notifications'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Android: Instant mail from the sync line', (tester) async {
    final controller = MailController(app.services);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CheckingMailSheet(controller: controller, isAndroid: true),
        ),
      ),
    );
    expect(find.text('Instant mail'), findsOneWidget);
  });

  testWidgets('the image notice in the reader leads to image senders', (
    tester,
  ) async {
    size(tester, const Size(1400, 900));
    app.seedFixture(
      'newsletters/one-click-unsubscribe.eml',
      subject: 'Spring sale',
      uid: 70,
    );
    await tester.pumpWidget(shell());
    await tester.pump();
    await tester.tap(find.text('Spring sale').first);
    await settle(tester);
    expect(find.text('Load images'), findsOneWidget);
    await tester.tap(find.text('Image settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(ImageSendersPage), findsOneWidget);
  });

  testWidgets('a found-in-your-mail page can read emails by itself', (
    tester,
  ) async {
    size(tester, const Size(1200, 900));
    app.services.settings.autoRead = false;
    final controller = MailController(app.services);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: SubscriptionsPage(controller: controller),
      ),
    );
    await settle(tester);
    await tester.tap(find.byTooltip('How is this found?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read receipts and bookings automatically'));
    await tester.pump();
    expect(app.services.settings.autoRead, isTrue);
  });
}
