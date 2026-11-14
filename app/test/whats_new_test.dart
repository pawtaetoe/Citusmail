// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/features.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/settings_page.dart';
import 'package:citusmail/src/ui/whats_new.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

/// After an update, once: what is new, each with "Show me".
void main() {
  late TestApp app;
  setUp(() async {
    app = await TestApp.create();
    // The first start after updating to this version.
    app.store.settings.delete(WhatsNew.seenKey);
  });
  tearDown(() => app.dispose());

  test('the version is the one in pubspec.yaml', () {
    final line = File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('version:'));
    expect(line.split(':').last.trim().split('+').first, appVersion);
  });

  test('every note names a feature that exists', () {
    for (final r in releaseNotes) {
      for (final id in r.features) {
        expect(Features.byId(id), isNotNull, reason: '${r.version}: $id');
      }
    }
    // Newest first, and never ahead of the app (a release with only
    // fixes has no note of its own).
    List<int> parts(String v) => [for (final p in v.split('.')) int.parse(p)];
    int compare(String a, String b) {
      final x = parts(a), y = parts(b);
      for (var i = 0; i < 3; i++) {
        if (x[i] != y[i]) return x[i].compareTo(y[i]);
      }
      return 0;
    }

    expect(compare(releaseNotes.first.version, appVersion), lessThan(1));
    for (var i = 1; i < releaseNotes.length; i++) {
      expect(
        compare(releaseNotes[i - 1].version, releaseNotes[i].version),
        1,
        reason: 'newest first',
      );
    }
  });

  test('what is new since the version last seen', () {
    final whatsNew = WhatsNew(app.store);
    // First start after this update: this version and the 0.5 highlights.
    final first = [for (final f in whatsNew.pending) f.id];
    expect(first.first, releaseNotes.first.features.first);
    expect(first, containsAll(['screener', 'snooze', 'appointments']));

    // Coming from the version before: only what this one brought.
    app.store.settings.write(WhatsNew.seenKey, releaseNotes[1].version);
    expect([
      for (final f in whatsNew.pending) f.id,
    ], releaseNotes.first.features);

    whatsNew.markSeen();
    expect(whatsNew.pending, isEmpty);
    expect(whatsNew.seenVersion, appVersion);
  });

  group('the card', () {
    Future<void> showShell(WidgetTester tester) async {
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

    testWidgets('"Show me" opens the feature; then it is gone', (tester) async {
      await showShell(tester);
      expect(find.text('New in Citusmail'), findsOneWidget);
      expect(find.text('Add accounts from your phone'), findsOneWidget);
      expect(find.textContaining('more'), findsOneWidget, reason: 'And N more');

      await tester.tap(
        find.bySemanticsLabel('Show Add accounts from your phone'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(
        find.descendant(
          of: find.byWidgetPredicate((w) => w is SettingHighlight && w.on),
          matching: find.text('Add accounts from your phone'),
        ),
        findsOneWidget,
      );
      expect(WhatsNew(app.store).seenVersion, appVersion);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('New in Citusmail'), findsNothing);

      // Not again at the next start.
      await tester.pumpWidget(const SizedBox());
      await showShell(tester);
      expect(find.text('New in Citusmail'), findsNothing);
    });

    testWidgets('closing it puts it away for this version', (tester) async {
      await showShell(tester);
      await tester.tap(find.byTooltip('Close What\'s new'));
      await tester.pump();
      expect(find.text('New in Citusmail'), findsNothing);
      expect(WhatsNew(app.store).pending, isEmpty);
    });

    testWidgets('"And N more" lists every one, with "Show me"', (tester) async {
      await showShell(tester);
      await tester.tap(find.textContaining('more'));
      await tester.pumpAndSettle();
      expect(find.text('What\'s new'), findsOneWidget);
      // The list grows with each version: Snooze may be further down.
      await tester.scrollUntilVisible(
        find.widgetWithText(ListTile, 'Snooze'),
        120,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.widgetWithText(ListTile, 'Snooze'), findsOneWidget);
      final showSnooze = find.descendant(
        of: find.widgetWithText(ListTile, 'Snooze'),
        matching: find.text('Show me'),
      );
      await tester.ensureVisible(showSnooze);
      await tester.pumpAndSettle();
      await tester.tap(showSnooze);
      await tester.pumpAndSettle();
      expect(find.text('Nothing is snoozed.'), findsOneWidget);
      expect(find.text('New in Citusmail'), findsNothing);
    });
  });
}
