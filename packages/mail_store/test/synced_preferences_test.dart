// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

import 'support/temp_store.dart';

void main() {
  late TempStore temp;
  MailStore store() => temp.store;
  SyncedPreferences prefs() => SyncedPreferences(temp.store.database);

  setUp(() => temp = TempStore.create());
  tearDown(() => temp.dispose());

  final monday = DateTime.utc(2026, 11, 9, 9);

  test('an allowlisted setting notes when it changed; others never', () {
    store().settings.write('reminders.on', 'off', at: monday);
    expect(prefs().changedAt('reminders.on'), monday);

    // Writing the same value again is no change.
    store().settings.write('reminders.on', 'off');
    expect(prefs().changedAt('reminders.on'), monday);

    for (final key in [
      'app.theme',
      'app.notifications',
      'app.safeBrowsing',
      'app.virusTotal',
      'ui.sidebar.folded',
      'reminders.lastCheck',
    ]) {
      store().settings.write(key, 'x');
      expect(prefs().changedAt(key), isNull, reason: key);
      expect(SyncedPreferences.preferenceOf(key), isNull, reason: key);
    }
    expect(prefs().entries().map((e) => e.key), [
      AppDataKeys.preference('reminders.on'),
    ]);
  });

  test('turning the Screener on or off notes the time', () {
    store().screener.enable(now: monday);
    expect(prefs().changedAt(SyncedPreferences.screener), monday);
    final entry = prefs().entries().single;
    expect(entry.data, {'key': 'screener.since', 'value': 'on'});

    final later = monday.add(const Duration(hours: 1));
    store().screener.disable(now: later);
    expect(prefs().changedAt(SyncedPreferences.screener), later);
    expect(prefs().entries().single.data['value'], isNull);
  });

  test('code clean-up travels as one; "Not now" stays here', () {
    store().settings.write(
      SyncedPreferences.codeCleanupConsent,
      'no:1',
      at: monday,
    );
    expect(prefs().changedAt(SyncedPreferences.codeCleanup), isNull);

    store().settings.write(
      SyncedPreferences.codeCleanupAge,
      'week',
      at: monday,
    );
    store().settings.write(SyncedPreferences.codeCleanupConsent, 'yes');
    final entry = prefs().entries().single;
    expect(entry.key, AppDataKeys.preference('codes.cleanup'));
    expect(entry.data, {
      'key': 'codes.cleanup',
      'age': 'week',
      'action': null,
      'agreed': true,
    });
  });

  test('the Keep list notes each sender, and removals', () {
    store().settings.write(
      SyncedPreferences.keptSenders.key,
      'mum@family.example,news@shop.example',
      at: monday,
    );
    expect(prefs().entries().map((e) => e.data['item']), [
      'mum@family.example',
      'news@shop.example',
    ]);
    store().settings.write(
      SyncedPreferences.keptSenders.key,
      'mum@family.example',
      at: monday.add(const Duration(minutes: 5)),
    );
    final removal = store().appDataSync.tombstones().single;
    expect(
      removal.key,
      AppDataKeys.preference('cleanup.kept', 'news@shop.example'),
    );
    expect(removal.kind, 'preference');
    expect(removal.deletedAt, monday.add(const Duration(minutes: 5)));
  });

  test('another device\'s change applies; an older one does not', () {
    final tuesday = monday.add(const Duration(days: 1));
    store().settings.write('tips.off', 'on', at: tuesday);
    // Older than the change here.
    expect(
      prefs().apply(
        AppDataKeys.preference('tips.off'),
        {'key': 'tips.off', 'value': 'off'},
        deleted: false,
        at: monday,
        device: 'phone',
      ),
      isFalse,
    );
    expect(store().settings.read('tips.off'), 'on');

    final wednesday = tuesday.add(const Duration(days: 1));
    expect(
      prefs().apply(
        AppDataKeys.preference('tips.off'),
        {'key': 'tips.off', 'value': 'off'},
        deleted: false,
        at: wednesday,
        device: 'phone',
      ),
      isTrue,
    );
    expect(store().settings.read('tips.off'), 'off');
    // Never newer than the change it came from.
    expect(prefs().changedAt('tips.off'), wednesday);
  });

  test('the synced keys, pinned: renaming one stops it syncing', () {
    expect(SyncedPreferences.all.toList(), [
      'screener.since',
      'inbox.newSinceAway',
      'inbox.summaryLine',
      'autoRead.on',
      'learning.on',
      'reminders.on',
      'reminders.monthly',
      'followUps.notify',
      'codes.cleanup',
      'cleanup.kept',
      'writing.hints',
      'tips.off',
    ]);
    for (final key in [
      'codes.cleanup.age',
      'codes.cleanup.action',
      'codes.cleanup.consent',
    ]) {
      expect(SyncedPreferences.preferenceOf(key), 'codes.cleanup');
    }
    expect(SyncedPreferences.preferenceOf('codes.cleanup'), isNull);
    expect(SyncedPreferences.preferenceOf('codes.cleanup.lastRun'), isNull);
  });

  test('the typed synced settings keep their old defaults', () {
    final s = store().settings;
    const onByDefault = [
      SyncedPreferences.newSinceAway,
      SyncedPreferences.summaryLine,
      SyncedPreferences.autoRead,
      SyncedPreferences.learnFromCorrections,
      SyncedPreferences.reminders,
      SyncedPreferences.followUpNotifications,
      SyncedPreferences.writingHints,
    ];
    for (final setting in onByDefault) {
      expect(setting.read(s), isTrue, reason: setting.key);
      s.write(setting.key, 'off'); // as the old code wrote it
      expect(setting.read(s), isFalse, reason: setting.key);
      s.write(setting.key, 'on');
      expect(setting.read(s), isTrue, reason: setting.key);
    }
    for (final setting in [
      SyncedPreferences.monthlyRenewals,
      SyncedPreferences.tipsOff,
    ]) {
      expect(setting.read(s), isFalse, reason: setting.key);
      s.write(setting.key, 'on');
      expect(setting.read(s), isTrue, reason: setting.key);
    }
    s.write('cleanup.kept', 'a@example.com,b@example.com');
    expect(SyncedPreferences.keptSenders.read(s), [
      'a@example.com',
      'b@example.com',
    ]);
  });

  test('a preference this device does not sync is never applied', () {
    expect(
      () => prefs().apply(
        AppDataKeys.preference('app.safeBrowsing'),
        {'key': 'app.safeBrowsing', 'value': 'on'},
        deleted: false,
        at: monday,
        device: 'phone',
      ),
      throwsArgumentError,
    );
    expect(store().settings.read('app.safeBrowsing'), isNull);
  });
}
