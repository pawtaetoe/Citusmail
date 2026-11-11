// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/mail/mail_controller.dart';
import 'package:citusmail/src/services/app_settings.dart';
import 'package:citusmail/src/ui/appearance.dart';
import 'package:citusmail/src/ui/device_sync_page.dart';
import 'package:citusmail/src/ui/settings_page.dart';
import 'package:citusmail/src/ui/tips.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_appsync/mail_appsync.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  SyncedPreferences prefs() => SyncedPreferences(app.store.database);

  /// Another device's change of [key] to [value], as an exchange applies
  /// it (and as the app hears of it).
  AppliedChanges fromOtherDevice(String key, String value, DateTime at) {
    final record = SyncRecord(
      key: AppDataKeys.preference(key),
      kind: RecordKind.preference,
      changedAt: at.millisecondsSinceEpoch,
      device: 'other-device',
      data: {'key': key, 'value': value},
    );
    final changes = AppDataSnapshotter(app.store).apply({record.key: record});
    app.services.settings.syncApplied(changes);
    return changes;
  }

  test('changing a synced setting notes when; a per-device one never', () {
    final settings = AppSettings(app.store);
    expect(prefs().changedAt('reminders.on'), isNull);
    settings.reminders = false;
    settings.learnFromCorrections = false;
    Tips(app.store).enabled = false;
    for (final key in ['reminders.on', 'learning.on', 'tips.off']) {
      expect(prefs().changedAt(key), isNotNull, reason: key);
    }

    settings.notifications = false;
    settings.notificationPreviews = false;
    settings.notifyNotificationsSection = false;
    settings.instantMail = false;
    Appearance.choose(app.store, ThemeMode.dark);
    for (final key in [
      'app.notifications',
      'app.notificationPreviews',
      'notify.notificationsSection',
      'app.instantMail',
      'app.theme',
    ]) {
      expect(prefs().changedAt(key), isNull, reason: key);
    }
    expect(prefs().entries().map((e) => e.data['key']).toSet(), {
      'reminders.on',
      'learning.on',
      'tips.off',
    });
  });

  test('a change from another device updates the setting and tells the '
      'listeners', () {
    var heard = 0;
    app.services.settings.syncedChanges.addListener(() => heard++);
    fromOtherDevice('autoRead.on', 'off', DateTime.utc(2026, 11, 9));
    expect(app.services.settings.autoRead, isFalse);
    expect(heard, 1);

    // An older change than the one made here doesn't apply.
    app.services.settings.autoRead = true;
    final changes = fromOtherDevice(
      'autoRead.on',
      'off',
      DateTime.utc(2026, 11, 8),
    );
    expect(changes.preferences, isEmpty);
    expect(app.services.settings.autoRead, isTrue);
    expect(heard, 1);
  });

  testWidgets('Settings shows a change from another device at once', (
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
    bool remindersOn() => tester
        .widget<SwitchListTile>(
          find.widgetWithText(SwitchListTile, 'Bill and trial reminders'),
        )
        .value;
    // Settled: nothing else rebuilds the page.
    await tester.pumpAndSettle();
    expect(remindersOn(), isTrue);

    fromOtherDevice('reminders.on', 'off', DateTime.now());
    await tester.pump();
    expect(remindersOn(), isFalse);
  });

  testWidgets('Sync between devices says what syncs and what stays', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: DeviceSyncPage(services: app.services)),
    );
    for (var i = 0; i < 20 && find.text('Turn on').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(find.text('What syncs'), findsOneWidget);
    expect(find.text('What stays on each device'), findsOneWidget);
    expect(find.textContaining('Bill and trial reminders'), findsOneWidget);
    expect(find.textContaining('The app lock'), findsOneWidget);
    expect(find.textContaining('Safe Browsing'), findsOneWidget);
  });
}
