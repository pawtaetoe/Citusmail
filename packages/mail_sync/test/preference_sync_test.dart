// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:mail_appsync/mail_appsync.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

/// A device: its own store with the same account.
final class _Device {
  _Device(String name) {
    directory = Directory.systemTemp.createTempSync('prefs_$name');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
    store.accounts.add(
      NewAccount(
        email: 'carol@citusmail.test',
        username: 'carol',
        imap: ServerSettings(
          host: 'h.example',
          port: 993,
          security: ConnectionSecurity.implicitTls,
        ),
        smtp: ServerSettings(
          host: 'h.example',
          port: 465,
          security: ConnectionSecurity.implicitTls,
        ),
      ),
    );
    snapshotter = AppDataSnapshotter(store);
  }

  late final Directory directory;
  late final MailStore store;
  late final AppDataSnapshotter snapshotter;

  String? read(String key) => store.settings.read(key);

  Iterable<SyncRecord> get preferenceRecords => snapshotter
      .localRecords()
      .values
      .where((r) => r.kind == RecordKind.preference);

  void close() {
    store.close();
    directory.deleteSync(recursive: true);
  }
}

/// What a real exchange does, without the server (and through the
/// sealed form, as stored): merge all devices' records and apply the
/// result to each. Returns what changed on each.
List<AppliedChanges> _exchange(List<_Device> devices) {
  final keys = SyncCode.generate().keys;
  final sealer = SnapshotSealer(keys);
  final snapshots = [
    for (final d in devices)
      sealer.open(
        sealer.seal(
          SyncSnapshot(
            device: d.snapshotter.device,
            createdAt: 0,
            records: d.snapshotter.localRecords().values.toList(),
          ),
        ),
        device: d.snapshotter.device,
      ),
  ];
  final merged = SyncSnapshot.merge(snapshots);
  return [for (final d in devices) d.snapshotter.apply(merged)];
}

void main() {
  late _Device phone;
  late _Device laptop;
  setUp(() {
    phone = _Device('phone');
    laptop = _Device('laptop');
  });
  tearDown(() {
    phone.close();
    laptop.close();
  });

  final monday = DateTime.utc(2026, 11, 9, 9);
  final tuesday = monday.add(const Duration(days: 1));

  test('a preference changed on one device reaches the other', () {
    phone.store.settings.write('reminders.on', 'off', at: monday);
    phone.store.settings.write('autoRead.on', 'off', at: monday);

    final [_, onLaptop] = _exchange([phone, laptop]);

    // The laptop never touched them: it takes the phone's values.
    expect(laptop.read('reminders.on'), 'off');
    expect(laptop.read('autoRead.on'), 'off');
    expect(onLaptop.preferences, {'reminders.on', 'autoRead.on'});
    expect(
      SyncedPreferences(laptop.store.database).changedAt('reminders.on'),
      monday,
      reason: 'the change\'s own time, not when it arrived',
    );
  });

  test('the later change wins, whichever device made it', () {
    phone.store.settings.write('learning.on', 'off', at: monday);
    _exchange([phone, laptop]);
    expect(laptop.read('learning.on'), 'off');

    // Back on, later, on the laptop; meanwhile an older change on the
    // phone that it hadn't sent yet.
    laptop.store.settings.write('learning.on', 'on', at: tuesday);
    phone.store.settings.write(
      'learning.on',
      'off',
      at: monday.add(const Duration(hours: 1)),
    );
    _exchange([phone, laptop]);
    expect(phone.read('learning.on'), 'on');
    expect(laptop.read('learning.on'), 'on');

    // And again: settles, nothing changes twice.
    final again = _exchange([phone, laptop]);
    expect(again.every((c) => c.preferences.isEmpty), isTrue);
  });

  test('a value set before this version reaches a device that never '
      'touched it, without overriding one that did', () {
    // As stored by an older version: a value, no time.
    phone.store.database.execute(
      "INSERT INTO settings (key, value) VALUES ('followUps.notify', 'off')",
    );
    phone.store.database.execute(
      "INSERT INTO settings (key, value) VALUES ('tips.off', 'on')",
    );
    laptop.store.database.execute(
      "INSERT INTO settings (key, value) VALUES ('tips.off', 'off')",
    );

    _exchange([phone, laptop]);

    expect(laptop.read('followUps.notify'), 'off');
    // Both had their own: each keeps it until the user changes it.
    expect(phone.read('tips.off'), 'on');
    expect(laptop.read('tips.off'), 'off');

    // A real change wins over both.
    phone.store.settings.write('tips.off', 'off', at: monday);
    laptop.store.settings.write('tips.off', 'on', at: tuesday);
    _exchange([phone, laptop]);
    expect(phone.read('tips.off'), 'on');
    expect(laptop.read('tips.off'), 'on');
  });

  test('settings that stay on each device never go into a snapshot', () {
    for (final key in [
      'app.theme',
      'app.notifications',
      'app.notificationPreviews',
      'app.instantMail',
      'app.safeBrowsing',
      'app.virusTotal',
      'notify.notificationsSection',
      'ui.sidebar.folded',
      'tips.seen',
      'reminders.lastCheck',
      'codes.cleanup.lastRun',
      'inbox.awaySince',
    ]) {
      phone.store.settings.write(key, 'changed', at: monday);
    }
    expect(phone.preferenceRecords, isEmpty);

    _exchange([phone, laptop]);
    expect(laptop.read('app.theme'), isNull);
    expect(laptop.read('app.safeBrowsing'), isNull);
  });

  test('a preference from a newer version is passed on, never applied', () {
    final foreign = SyncRecord(
      key: AppDataKeys.preference('app.safeBrowsing'),
      kind: RecordKind.preference,
      changedAt: monday.millisecondsSinceEpoch,
      device: 'tablet',
      data: {'key': 'app.safeBrowsing', 'value': 'on'},
    );
    final changes = laptop.snapshotter.apply({foreign.key: foreign});
    expect(changes.skipped, 1);
    expect(laptop.read('app.safeBrowsing'), isNull);
    expect(laptop.snapshotter.localRecords(), contains(foreign.key));
  });

  test('the Screener turned on on one device is on on the other', () {
    phone.store.screener.enable(now: monday);
    _exchange([phone, laptop]);
    expect(laptop.store.screener.enabled, isTrue);

    laptop.store.screener.disable(now: tuesday);
    _exchange([phone, laptop]);
    expect(phone.store.screener.enabled, isFalse);
  });

  test('code clean-up: the agreement travels only with its rule', () {
    final phoneCleanup = CodeCleanupSettings(phone.store);
    expect(SyncedPreferences.codeCleanupAge, CodeCleanupSettings.ageKey);
    expect(SyncedPreferences.codeCleanupAction, CodeCleanupSettings.actionKey);
    expect(
      SyncedPreferences.codeCleanupConsent,
      CodeCleanupSettings.consentKey,
    );

    phoneCleanup.action = CodeCleanupAction.trash;
    phoneCleanup.agree();
    _exchange([phone, laptop]);
    final laptopCleanup = CodeCleanupSettings(laptop.store);
    expect(laptopCleanup.action, CodeCleanupAction.trash);
    expect(laptopCleanup.agreed, isTrue);

    // "Not now" on a third device stays there.
    final tablet = _Device('tablet');
    addTearDown(tablet.close);
    CodeCleanupSettings(tablet.store).decline(DateTime.now());
    expect(tablet.preferenceRecords, isEmpty);

    // A rule changed later where the user never agreed: the others ask
    // again rather than move mail on an agreement to another rule.
    tablet.store.settings.write(
      CodeCleanupSettings.ageKey,
      CodeCleanupAge.week.storageName,
      at: DateTime.now().add(const Duration(minutes: 1)),
    );
    _exchange([phone, laptop, tablet]);
    expect(phoneCleanup.age, CodeCleanupAge.week);
    expect(phoneCleanup.action, CodeCleanupAction.archive);
    expect(phoneCleanup.agreed, isFalse);
    expect(CodeCleanupSettings(tablet.store).consent, isA<ConsentDeclined>());
  });

  test('the Keep list merges additions and removals per sender', () {
    const kept = SyncedPreferences.keptSenders;
    phone.store.settings.write(
      kept,
      'mum@family.example,news@shop.example',
      at: monday,
    );
    laptop.store.settings.write(kept, 'club@tennis.example', at: monday);
    _exchange([phone, laptop]);
    Set<String> keptOn(_Device d) => d.read(kept)!.split(',').toSet();
    const all = {
      'mum@family.example',
      'news@shop.example',
      'club@tennis.example',
    };
    expect(keptOn(phone), all);
    expect(keptOn(laptop), all);

    // Removed on the phone, another added on the laptop: both count.
    phone.store.settings.write(
      kept,
      'mum@family.example,club@tennis.example',
      at: tuesday,
    );
    laptop.store.settings.write(
      kept,
      '${laptop.read(kept)},shoes@store.example',
      at: tuesday,
    );
    _exchange([phone, laptop]);
    const after = {
      'mum@family.example',
      'club@tennis.example',
      'shoes@store.example',
    };
    expect(keptOn(phone), after);
    expect(keptOn(laptop), after);

    // Kept again later on the laptop: the later choice wins.
    laptop.store.settings.write(
      kept,
      '${laptop.read(kept)},news@shop.example',
      at: tuesday.add(const Duration(hours: 1)),
    );
    _exchange([phone, laptop]);
    expect(keptOn(phone), contains('news@shop.example'));
  });
}
