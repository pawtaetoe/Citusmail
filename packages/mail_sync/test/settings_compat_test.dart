// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

/// Values as the code before typed settings wrote them, read through the
/// typed settings: the keys, the stored text and the defaults are the
/// same.
void main() {
  late Directory directory;
  late MailStore store;
  SettingsRepository settings() => store.settings;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('settings_compat_test');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
  });
  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  test('the keys are unchanged', () {
    expect(KeepMail.setting.key, 'sync.keepMail');
    expect(ServerRules.setting.key, 'mail.serverRules');
    expect(
      NewMailTracker.notificationsSection.key,
      'notify.notificationsSection',
    );
    expect(CodeCleanupSettings.ageSetting.key, 'codes.cleanup.age');
    expect(CodeCleanupSettings.actionSetting.key, 'codes.cleanup.action');
    expect(CodeCleanupSettings.consentSetting.key, 'codes.cleanup.consent');
    expect(CodeCleanupSettings.lastRunSetting.key, 'codes.cleanup.lastRun');
    expect(CodeCleanupSettings.undoneSetting.key, 'codes.cleanup.undone');
    expect(AppDataSync.accountSetting.key, 'sync.account');
    expect(AppDataSync.publishedSetting.key, 'sync.published');
    expect(AppDataSync.statusSetting.key, 'sync.status');
    expect(AppDataSync.exchangedSetting.key, 'sync.exchanged');
  });

  test('keep mail: stored names, two years by default', () {
    expect(KeepMail.read(store), KeepMail.twoYears);
    for (final (stored, keep) in [
      ('3m', KeepMail.threeMonths),
      ('1y', KeepMail.year),
      ('2y', KeepMail.twoYears),
      ('all', KeepMail.everything),
    ]) {
      settings().write('sync.keepMail', stored);
      expect(KeepMail.read(store), keep);
      KeepMail.setting.write(settings(), keep);
      expect(settings().read('sync.keepMail'), stored);
    }
    settings().write('sync.keepMail', 'everything');
    expect(KeepMail.read(store), KeepMail.twoYears);
  });

  test('server rules and the Notifications section', () {
    expect(ServerRules.setting.read(settings()), isFalse);
    settings().write('mail.serverRules', 'on');
    expect(ServerRules.setting.read(settings()), isTrue);
    expect(NewMailTracker.notificationsSection.read(settings()), isTrue);
    settings().write('notify.notificationsSection', 'off');
    expect(NewMailTracker.notificationsSection.read(settings()), isFalse);
  });

  test('code clean-up', () {
    final cleanup = CodeCleanupSettings(store);
    expect(cleanup.age, CodeCleanupAge.day);
    expect(cleanup.action, CodeCleanupAction.archive);
    expect(cleanup.consent, isA<ConsentUnasked>());
    settings().write('codes.cleanup.age', 'week');
    settings().write('codes.cleanup.action', 'trash');
    settings().write('codes.cleanup.consent', 'no:1700000000000');
    settings().write('codes.cleanup.undone', 'a\nb');
    expect(cleanup.age, CodeCleanupAge.week);
    expect(cleanup.action, CodeCleanupAction.trash);
    expect(
      (cleanup.consent as ConsentDeclined).at,
      DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
    );
    expect(cleanup.undone, {'a', 'b'});
    settings().write('codes.cleanup.age', 'off');
    expect(cleanup.age, CodeCleanupAge.off);
    settings().write('codes.cleanup.age', 'month');
    expect(cleanup.age, CodeCleanupAge.day);
    settings().write('codes.cleanup.consent', 'no:soon');
    expect(cleanup.consent, isA<ConsentUnasked>());

    cleanup.agree();
    expect(settings().read('codes.cleanup.consent'), 'yes');
    cleanup.decline(DateTime.utc(2026, 11, 9));
    expect(
      settings().read('codes.cleanup.consent'),
      'no:${DateTime.utc(2026, 11, 9).millisecondsSinceEpoch}',
    );
    cleanup.remember(['c']);
    expect(settings().read('codes.cleanup.undone'), 'a\nb\nc');
  });

  test('device sync status', () {
    expect(AppDataSync.statusIn(store), isNull);
    settings().write(
      'sync.status',
      '{"at":1700000000000,"devices":2,"unreadable":1,"problem":"x"}',
    );
    final status = AppDataSync.statusIn(store)!;
    expect(status.at.millisecondsSinceEpoch, 1700000000000);
    expect(status.devices, 2);
    expect(status.unreadable, 1);
    expect(status.problem, 'x');
    AppDataSync.statusSetting.write(settings(), status);
    expect(
      settings().read('sync.status'),
      '{"at":1700000000000,"devices":2,"unreadable":1,"problem":"x"}',
    );
    settings().write('sync.status', '{"devices":2}');
    expect(AppDataSync.statusIn(store), isNull);
    settings().write('sync.account', '7');
    expect(AppDataSync.accountSetting.readOrNull(settings()), 7);
  });
}
