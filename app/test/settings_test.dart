// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/background/background_mail.dart';
import 'package:citusmail/src/mail/corrections.dart';
import 'package:citusmail/src/mail/mail_controller.dart';
import 'package:citusmail/src/ui/privacy_report_page.dart';
import 'package:citusmail/src/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_sync/mail_sync.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  testWidgets('Clean up and the Privacy report are in the sidebar, not here', (
    tester,
  ) async {
    final controller = MailController(app.services);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          services: app.services,
          controller: controller,
          onShowMail: controller.search,
          isAndroid: false,
        ),
      ),
    );
    // Settings starts with settings (the sidebar's Tools has the pages).
    expect(find.text('Your mail'), findsNothing);
    expect(find.text('Clean up senders'), findsNothing);
    expect(find.text('Privacy report'), findsNothing);
    expect(
      tester.getTopLeft(find.text('Notifications')).dy <
          tester.getTopLeft(find.text('New mail notifications')).dy,
      isTrue,
    );

    // About, Privacy still opens the report.
    await tester.scrollUntilVisible(find.text('Privacy'), 200);
    await tester.tap(find.text('Privacy'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(PrivacyReportPage), findsOneWidget);
  });

  testWidgets('notifications can be turned off; it is remembered', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(services: app.services, isAndroid: false)),
    );
    expect(
      app.services.settings.notifications,
      isTrue,
      reason: 'on by default',
    );
    expect(find.text('Instant mail'), findsNothing, reason: 'Android only');
    await tester.tap(find.text('New mail notifications'));
    await tester.pump();
    expect(app.services.settings.notifications, isFalse);
  });

  testWidgets('bill and trial reminders: on by default, monthly ones off', (
    tester,
  ) async {
    // Tall enough for the notification settings.
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(services: app.services, isAndroid: false)),
    );
    final settings = app.services.settings;
    expect(settings.reminders, isTrue);
    expect(settings.monthlyRenewals, isFalse);
    await tester.tap(find.text('Also remind me of monthly renewals'));
    await tester.pump();
    expect(settings.monthlyRenewals, isTrue);
    await tester.tap(find.text('Bill and trial reminders'));
    await tester.pump();
    expect(settings.reminders, isFalse);
    // Only with notifications: off with them.
    await tester.tap(find.text('Bill and trial reminders'));
    await tester.tap(find.text('New mail notifications'));
    await tester.pump();
    expect(settings.reminders, isTrue);
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, 'Bill and trial reminders'),
          )
          .value,
      isFalse,
    );
  });

  testWidgets('reading receipts and bookings automatically: on by default', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(services: app.services, isAndroid: false)),
    );
    final settings = app.services.settings;
    expect(settings.autoRead, isTrue);
    expect(
      find.text(
        'Downloads receipts, bills and booking emails from your mail server '
        'so Subscriptions, Deliveries and Trips fill in by themselves. They '
        'stay unread.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Read receipts and bookings automatically'));
    await tester.pump();
    expect(settings.autoRead, isFalse);
    await tester.tap(find.text('Read receipts and bookings automatically'));
    await tester.pump();
    expect(settings.autoRead, isTrue);
  });

  testWidgets('follow-up reminders: on by default, only with notifications', (
    tester,
  ) async {
    // Tall enough for the notification settings.
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(services: app.services, isAndroid: false)),
    );
    final settings = app.services.settings;
    expect(settings.followUpNotifications, isTrue);
    await tester.tap(find.text('Follow-up reminders'));
    await tester.pump();
    expect(settings.followUpNotifications, isFalse);
    await tester.tap(find.text('Follow-up reminders'));
    await tester.tap(find.text('New mail notifications'));
    await tester.pump();
    expect(settings.followUpNotifications, isTrue);
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, 'Follow-up reminders'),
          )
          .value,
      isFalse,
    );
  });

  testWidgets('message previews: on by default, only with notifications', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(services: app.services, isAndroid: false)),
    );
    final settings = app.services.settings;
    expect(settings.notificationPreviews, isTrue);
    await tester.tap(find.text('Show message previews'));
    await tester.pump();
    expect(settings.notificationPreviews, isFalse);
    await tester.tap(find.text('Show message previews'));
    await tester.tap(find.text('New mail notifications'));
    await tester.pump();
    expect(settings.notificationPreviews, isTrue);
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, 'Show message previews'),
          )
          .onChanged,
      isNull,
    );
  });

  testWidgets('Notifications section: notified by default, can be turned off', (
    tester,
  ) async {
    expect(app.services.settings.notifyNotificationsSection, isTrue);
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(services: app.services)),
    );
    await tester.scrollUntilVisible(find.text('Also for Notifications'), 200);
    await tester.tap(find.text('Also for Notifications'));
    await tester.pump();
    expect(app.services.settings.notifyNotificationsSection, isFalse);
    expect(
      app.store.settings.read(NewMailTracker.notificationsKey),
      'off',
      reason: 'the new-mail tracker reads the same key',
    );
  });

  testWidgets('Android: instant mail is on by default; can be turned off', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('citusmail/background'),
      (call) async => null,
    );
    expect(app.services.settings.instantMail, isTrue, reason: 'the default');
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          services: app.services,
          isAndroid: true,
          batteryLimited: () async => false,
        ),
      ),
    );
    await tester.scrollUntilVisible(find.text('Instant mail'), 200);
    expect(find.text('Background checks'), findsNothing);
    await tester.tap(find.text('Instant mail'));
    await tester.pumpAndSettle();
    expect(app.services.settings.instantMail, isFalse);
    expect(find.text('Background checks'), findsOneWidget);
    await tester.tap(find.text('Instant mail'));
    await tester.pumpAndSettle();
    expect(app.services.settings.instantMail, isTrue);
  });

  test(
    'Android is asked once to let Instant mail run in the background',
    () async {
      var asked = 0;
      Future<void> ask() async => asked++;
      await BackgroundMail.askOnce(
        app.store,
        limited: () async => false,
        ask: ask,
      );
      expect(asked, 0, reason: 'already allowed: nothing to ask');
      await BackgroundMail.askOnce(
        app.store,
        limited: () async => true,
        ask: ask,
      );
      await BackgroundMail.askOnce(
        app.store,
        limited: () async => true,
        ask: ask,
      );
      expect(asked, 1, reason: 'never twice');
    },
  );

  testWidgets('Android: when the background check last ran', (tester) async {
    app.services.settings.instantMail = false;
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          services: app.services,
          isAndroid: true,
          batteryLimited: () async => false,
        ),
      ),
    );
    await tester.scrollUntilVisible(find.text('Background checks'), 200);
    expect(
      find.textContaining('No background check has run yet'),
      findsOneWidget,
    );
    expect(find.text('Allow in background'), findsNothing);

    BackgroundMail.recordCheck(
      app.store,
      ok: true,
      at: DateTime.now().subtract(const Duration(minutes: 12)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          services: app.services,
          isAndroid: true,
          batteryLimited: () async => false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Background checks'), 200);
    expect(find.text('Last background check: 12 min ago.'), findsOneWidget);
  });

  testWidgets('Android: held back to save battery, with one tap to allow it', (
    tester,
  ) async {
    app.services.settings.instantMail = false;
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('citusmail/background'),
      (call) async {
        calls.add(call);
        return null;
      },
    );
    BackgroundMail.recordCheck(
      app.store,
      ok: false,
      at: DateTime.now().subtract(const Duration(hours: 3)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          services: app.services,
          isAndroid: true,
          batteryLimited: () async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Allow in background'), 200);
    expect(find.textContaining('3 hours ago'), findsOneWidget);
    expect(find.textContaining('not every account'), findsOneWidget);
    // On a phone it opens the app's page in Android's settings; here
    // (not Android) nothing is called.
    await tester.ensureVisible(find.text('Allow in background'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Allow in background'));
    await tester.pump();
    expect(calls, isEmpty);
  });

  testWidgets('Android with Instant mail on: no background check row', (
    tester,
  ) async {
    app.services.settings.instantMail = true;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('citusmail/background'),
      (call) async => null,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          services: app.services,
          isAndroid: true,
          batteryLimited: () async => true,
        ),
      ),
    );
    await tester.scrollUntilVisible(find.text('Instant mail'), 200);
    expect(find.text('Background checks'), findsNothing);
  });

  testWidgets('desktop: no background mail settings', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(services: app.services, isAndroid: false)),
    );
    expect(find.text('Instant mail'), findsNothing);
    expect(find.text('Checking for new mail'), findsNothing);
  });

  testWidgets('About: privacy policy and terms open after asking', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(services: app.services, isAndroid: false)),
    );
    for (final (title, url) in [
      ('Privacy policy', 'https://citusmail.fluminaris.com/privacy-policy'),
      ('Terms of service', 'https://citusmail.fluminaris.com/terms-of-service'),
    ]) {
      await tester.scrollUntilVisible(find.text(title), 200);
      await tester.ensureVisible(find.text(title));
      await tester.pumpAndSettle();
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(find.text('Open this link?'), findsOneWidget, reason: title);
      expect(find.text(url), findsOneWidget, reason: title);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Open this link?'), findsNothing);
    }
  });

  testWidgets('rules on the mail server: off by default; status per account', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: AdvancedSettingsPage(services: app.services)),
    );
    expect(app.services.settings.serverRules, isFalse);
    expect(find.text('alice@citusmail.test'), findsNothing);
    await tester.tap(find.text('Rules on the mail server'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    expect(app.services.settings.serverRules, isTrue);
    expect(find.text('alice@citusmail.test'), findsOneWidget);
  });

  test('server rules status in words', () {
    final at = DateTime.utc(2026);
    expect(serverRulesText(null), contains('next check'));
    expect(
      serverRulesText(ServerRulesStatus(ServerRulesState.active, at)),
      'Running on the server.',
    );
    expect(
      serverRulesText(
        ServerRulesStatus(
          ServerRulesState.otherScriptActive,
          at,
          detail: 'roundcube',
        ),
      ),
      contains('"roundcube"'),
    );
    expect(
      serverRulesText(ServerRulesStatus(ServerRulesState.notSupported, at)),
      contains('doesn\'t support'),
    );
    expect(
      serverRulesText(
        ServerRulesStatus(ServerRulesState.failed, at, detail: 'quota'),
      ),
      contains('quota'),
    );
  });

  testWidgets('outside services and server rules are under Advanced', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(services: app.services, isAndroid: false)),
    );
    for (final hidden in [
      'Check links with Google Safe Browsing',
      'Ask VirusTotal about flagged files and links',
      'Rules on the mail server',
    ]) {
      expect(find.text(hidden), findsNothing, reason: hidden);
    }
    await tester.scrollUntilVisible(find.text('Advanced'), 200);
    await tester.ensureVisible(find.text('Advanced'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    for (final shown in [
      'Check links with Google Safe Browsing',
      'Ask VirusTotal about flagged files and links',
      'Rules on the mail server',
    ]) {
      expect(find.text(shown), findsOneWidget, reason: shown);
    }
  });

  testWidgets('how far back mail is kept: 2 years unless changed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(services: app.services, isAndroid: false)),
    );
    expect(KeepMail.read(app.store), KeepMail.twoYears);
    expect(find.textContaining('The last 2 years.'), findsOneWidget);
    await tester.tap(find.text('Keep mail from'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Everything'));
    await tester.pumpAndSettle();
    expect(KeepMail.read(app.store), KeepMail.everything);
    expect(find.textContaining('Everything.'), findsOneWidget);
  });

  testWidgets('Advanced: learning on by default; forget after asking', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final corrections = Corrections(app.store);
    corrections.rejected(MailKind.subscription, [
      const MailSample(subject: 'Re: [acme/web] Billing (#1)', text: 'Hi'),
    ]);
    await tester.pumpWidget(
      MaterialApp(home: AdvancedSettingsPage(services: app.services)),
    );
    expect(app.services.settings.learnFromCorrections, isTrue);
    await tester.tap(find.text('Learn from my corrections'));
    await tester.pump();
    expect(app.services.settings.learnFromCorrections, isFalse);
    await tester.tap(find.text('Learn from my corrections'));
    await tester.pump();
    expect(app.services.settings.learnFromCorrections, isTrue);

    await tester.tap(find.text('Forget what it learned'));
    await tester.pumpAndSettle();
    expect(find.text('Forget what it learned?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(corrections.learnedAnything, isTrue);

    await tester.tap(find.text('Forget what it learned'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forget'));
    await tester.pumpAndSettle();
    expect(corrections.learnedAnything, isFalse);
    expect(find.text('Forgot what it learned'), findsOneWidget);
    expect(
      tester
          .widget<ListTile>(
            find.widgetWithText(ListTile, 'Forget what it learned'),
          )
          .enabled,
      isFalse,
    );
  });
}
