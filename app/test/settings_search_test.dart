// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/mail/mail_controller.dart';
import 'package:citusmail/src/ui/appearance.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/discover_page.dart';
import 'package:citusmail/src/ui/settings_catalog.dart';
import 'package:citusmail/src/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

/// Settings, grouped by what people want to do, with a search that knows
/// their words for things.
void main() {
  group('the search', () {
    List<String> ids(String query, {bool android = false}) => [
      for (final e in SettingsCatalog.search(query, android: android)) e.id,
    ];

    test('finds settings by other names', () {
      expect(ids('dark mode').first, 'theme');
      expect(ids('signature').first, 'writing');
      expect(ids('PIN'), containsAll(['appLock', 'changePin']));
      expect(ids('spam'), containsAll(['screener', 'blockedSenders']));
      expect(ids('push').first, 'notifications');
      expect(ids('push', android: true), contains('instantMail'));
      expect(ids('otp'), ['codeCleanup']);
      expect(ids('safe browsing'), ['safeBrowsing']);
    });

    test('names first, then other words', () {
      expect(ids('notifications').first, 'notifications');
      expect(ids('blocked').first, 'blockedSenders');
    });

    test('only what this device has', () {
      expect(ids('instant'), isEmpty, reason: 'Android only');
      expect(ids('qr'), ['pairing']);
      expect(
        SettingsCatalog.search('qr', android: true).single.title,
        'Send accounts to a computer',
      );
    });

    test('nothing for nothing, or for nonsense', () {
      expect(ids(''), isEmpty);
      expect(ids('   '), isEmpty);
      expect(ids('zzqx'), isEmpty);
    });

    test('every setting is in a group that exists', () {
      final groups = {for (final s in SettingsCatalog.sections) s.id};
      for (final e in SettingsCatalog.entries) {
        expect(groups, contains(e.section), reason: e.id);
      }
    });
  });

  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() async {
    Appearance.theme.value = ThemeMode.system;
    await app.dispose();
  });

  void size(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> show(WidgetTester tester, {MailController? controller}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: SettingsPage(
          services: app.services,
          controller: controller,
          isAndroid: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester, String words) async {
    await tester.tap(find.byKey(const ValueKey('settings-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), words);
    await tester.pumpAndSettle();
  }

  bool marked(WidgetTester tester, String title) => tester
      .widget<SettingHighlight>(
        find
            .ancestor(
              of: find.text(title),
              matching: find.byType(SettingHighlight),
            )
            .first,
      )
      .on;

  group('wide screens', () {
    testWidgets('groups beside the settings; a group scrolls into view', (
      tester,
    ) async {
      size(tester, const Size(1200, 800));
      await show(tester);
      for (final s in SettingsCatalog.sections) {
        expect(
          find.byKey(ValueKey('settings-rail-${s.id}')),
          findsOneWidget,
          reason: s.title,
        );
      }
      // Every setting is on the page: notifications first.
      expect(find.text('New mail notifications'), findsOneWidget);
      final theme = find.text('Theme');
      expect(tester.getTopLeft(theme).dy, greaterThan(800));

      await tester.tap(find.byKey(const ValueKey('settings-rail-appearance')));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(theme).dy, inInclusiveRange(0, 800));
      // The group chosen is marked.
      final chosen = tester.widget<Material>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('settings-rail-appearance')),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(chosen.color, isNot(Colors.transparent));
    });

    testWidgets('"dark mode" finds Theme, shows and marks it', (tester) async {
      size(tester, const Size(1200, 800));
      await show(tester);
      await search(tester, 'dark mode');
      expect(find.text('Theme'), findsWidgets);
      expect(find.text('Appearance'), findsWidgets, reason: 'its group');
      await tester.tap(find.widgetWithText(ListTile, 'Theme').last);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing, reason: 'search closed');
      final theme = find.text('Theme');
      expect(tester.getTopLeft(theme).dy, inInclusiveRange(0, 800));
      expect(marked(tester, 'Theme'), isTrue);
      expect(marked(tester, 'New mail notifications'), isFalse);

      // And it works: dark.
      await tester.tap(find.text('Automatic'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dark').last);
      await tester.pumpAndSettle();
      expect(Appearance.theme.value, ThemeMode.dark);
      expect(Appearance.read(app.store), ThemeMode.dark);
    });

    testWidgets('"PIN" finds the app lock', (tester) async {
      size(tester, const Size(1200, 800));
      await show(tester);
      await search(tester, 'PIN');
      await tester.tap(find.widgetWithText(ListTile, 'App lock').last);
      await tester.pumpAndSettle();
      expect(marked(tester, 'App lock'), isTrue);
    });

    testWidgets('an Advanced setting opens Advanced, marked', (tester) async {
      size(tester, const Size(1200, 800));
      await show(tester);
      await search(tester, 'sieve');
      expect(find.text('Help & about › Advanced'), findsOneWidget);
      await tester.tap(find.text('Rules on the mail server'));
      await tester.pumpAndSettle();
      expect(find.byType(AdvancedSettingsPage), findsOneWidget);
      expect(marked(tester, 'Rules on the mail server'), isTrue);
    });

    testWidgets('nothing found: a way to all features', (tester) async {
      size(tester, const Size(1200, 800));
      final controller = MailController(app.services);
      addTearDown(controller.dispose);
      await show(tester, controller: controller);
      await search(tester, 'zzqx');
      expect(find.textContaining('No setting matches'), findsOneWidget);
      await tester.tap(find.text('See all features'));
      await tester.pumpAndSettle();
      expect(find.byType(DiscoverPage), findsOneWidget);
    });

    testWidgets('a feature opens its own setting', (tester) async {
      size(tester, const Size(1200, 800));
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsPage(
            services: app.services,
            isAndroid: false,
            show: 'codeCleanup',
          ),
        ),
      );
      await tester.pumpAndSettle();
      final tile = find.text('Clean up old codes');
      expect(tester.getTopLeft(tile).dy, inInclusiveRange(0, 800));
      expect(marked(tester, 'Clean up old codes'), isTrue);
    });
  });

  group('phones', () {
    testWidgets('the groups, each on a page of its own', (tester) async {
      size(tester, const Size(390, 844));
      await show(tester);
      for (final s in SettingsCatalog.sections) {
        expect(find.text(s.title), findsOneWidget, reason: s.title);
        expect(find.text(s.description), findsOneWidget, reason: s.title);
      }
      expect(find.text('New mail notifications'), findsNothing);
      await tester.tap(find.text('Inbox & sorting'));
      await tester.pumpAndSettle();
      expect(find.text('Screen first-time senders'), findsOneWidget);
      expect(find.text('New mail notifications'), findsNothing);

      // A switch works on the group's page, and stays.
      await tester.tap(find.text('Screen first-time senders'));
      await tester.pumpAndSettle();
      expect(app.store.screener.enabled, isTrue);
      expect(find.text('Screened-out mail goes to'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Inbox & sorting'), findsOneWidget);
    });

    testWidgets('search opens the group, at the setting', (tester) async {
      size(tester, const Size(390, 844));
      await show(tester);
      await search(tester, 'trackers');
      await tester.tap(find.widgetWithText(ListTile, 'Images'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('page-title')), findsWidgets);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('page-title')).last).data,
        'Privacy & security',
      );
      expect(marked(tester, 'Images'), isTrue);
    });
  });
}
