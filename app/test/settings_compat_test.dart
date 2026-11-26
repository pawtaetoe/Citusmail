// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:citusmail/src/background/background_mail.dart';
import 'package:citusmail/src/core/theme/appearance.dart';
import 'package:citusmail/src/features/accounts/state/accounts_model.dart';
import 'package:citusmail/src/features/discover/ui/tips.dart';
import 'package:citusmail/src/features/discover/ui/whats_new.dart';
import 'package:citusmail/src/features/found/state/appointments_model.dart';
import 'package:citusmail/src/features/found/state/attachments_model.dart';
import 'package:citusmail/src/features/found/state/deliveries_model.dart';
import 'package:citusmail/src/features/found/state/subscriptions_model.dart';
import 'package:citusmail/src/features/found/state/trips_model.dart';
import 'package:citusmail/src/features/inbox/state/commands.dart';
import 'package:citusmail/src/features/inbox/state/corrections.dart';
import 'package:citusmail/src/features/inbox/state/message_list_model.dart';
import 'package:citusmail/src/features/inbox/state/new_since_away.dart';
import 'package:citusmail/src/features/organise/state/sender_cleanup_model.dart';
import 'package:citusmail/src/features/reader/state/invitation_answers.dart';
import 'package:citusmail/src/features/reader/state/summaries.dart';
import 'package:citusmail/src/features/security/state/app_lock.dart';
import 'package:citusmail/src/services/ai_sorter.dart';
import 'package:citusmail/src/services/app_settings.dart';
import 'package:citusmail/src/services/auto_reader.dart';
import 'package:citusmail/src/services/link_safety.dart';
import 'package:citusmail/src/services/reminders.dart';
import 'package:citusmail/src/services/virus_total_checks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_store/mail_store.dart';

/// Values written as the code before typed settings wrote them, read
/// through the typed settings: the same keys, stored text and defaults.
void main() {
  late Directory directory;
  late MailStore store;
  SettingsRepository settings() => store.settings;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('settings_compat');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
  });
  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  test('every key is as before', () {
    final keys = {
      for (final s in AppSettings.all) s.key,
      AppLock.enabledSetting.key,
      AppLock.timeoutSetting.key,
      AppLock.biometricsSetting.key,
      AppLock.failuresSetting.key,
      AppLock.untilSetting.key,
      AppLock.untilElapsedSetting.key,
      AppLock.elapsedAtSetting.key,
      AppLock.waitSetting.key,
      Appearance.setting.key,
      Tips.offSetting.key,
      Tips.seenSetting.key,
      Tips.dismissedSetting.key,
      WhatsNew.seenSetting.key,
      CommandHistory.setting.key,
      ReminderState.dismissedSetting.key,
      ReminderState.notifiedSetting.key,
      ReminderState.lastCheckSetting.key,
      NewSinceAway.awaySetting.key,
      Corrections.modelSetting.key,
      Corrections.keptSetting.key,
      Corrections.openedSetting.key,
      MessageListModel.collapsedSetting.key,
      SenderCleanupModel.keptSetting.key,
      InvitationAnswers.setting.key,
      MessageSummaries.indexSetting.key,
      AccountsModel.hiddenSetting.key,
      AppointmentsModel.hiddenSetting.key,
      SubscriptionsModel.hiddenSetting.key,
      TripsModel.hiddenSetting.key,
      AttachmentsModel.hiddenSetting.key,
      DeliveriesModel.hiddenSetting.key,
      DeliveriesModel.deliveredSetting.key,
      DeliveriesModel.returnedSetting.key,
      DeliveriesModel.keptSetting.key,
      BackgroundMail.lastCheckSetting.key,
      BackgroundMail.askedSetting.key,
      BackgroundMail.readAheadSetting.key,
      AiSorter.perSyncSetting.key,
      LinkSafety.setting.key,
      LinkSafety.statusSetting.key,
      VirusTotalChecks.setting.key,
      ReadFailures.setting.key,
    };
    expect(keys, {
      'app.notifications',
      'app.instantMail',
      'app.notificationPreviews',
      'reminders.on',
      'reminders.monthly',
      'followUps.notify',
      'learning.on',
      'autoRead.on',
      'inbox.newSinceAway',
      'inbox.summaryLine',
      'writing.hints',
      'notify.notificationsSection',
      'mail.serverRules',
      'lock.enabled',
      'lock.timeout',
      'lock.biometrics',
      'lock.failures',
      'lock.until',
      'lock.untilElapsed',
      'lock.elapsedAt',
      'lock.wait',
      'app.theme',
      'tips.off',
      'tips.seen',
      'tips.seen.dismissed',
      'whatsNew.seen',
      'commandBar.recent',
      'reminders.dismissed',
      'reminders.notified',
      'reminders.lastCheck',
      'inbox.awaySince',
      'learning.model',
      'learning.kept',
      'learning.opened',
      'ui.collapsedSections',
      'cleanup.kept',
      'invitations.answers',
      'ai.summaries',
      'accounts.hidden',
      'appointments.hidden',
      'subscriptions.hidden',
      'trips.hidden',
      'attachments.hidden',
      'deliveries.hidden',
      'deliveries.delivered',
      'returns.returned',
      'returns.kept',
      'background.lastCheck',
      'instant.askedBackground',
      'autoRead.background',
      'ai.sorting.perSync',
      'app.safeBrowsing',
      'app.safeBrowsing.status',
      'app.virusTotal',
      'autoRead.failed',
    });
  });

  test('app settings: on and off as before, with the same defaults', () {
    final app = AppSettings(store);
    const onByDefault = {
      'app.notifications',
      'app.instantMail',
      'app.notificationPreviews',
      'reminders.on',
      'followUps.notify',
      'learning.on',
      'autoRead.on',
      'inbox.newSinceAway',
      'inbox.summaryLine',
      'writing.hints',
      'notify.notificationsSection',
    };
    bool values(String key) => switch (key) {
      'app.notifications' => app.notifications,
      'app.instantMail' => app.instantMail,
      'app.notificationPreviews' => app.notificationPreviews,
      'reminders.on' => app.reminders,
      'reminders.monthly' => app.monthlyRenewals,
      'followUps.notify' => app.followUpNotifications,
      'learning.on' => app.learnFromCorrections,
      'autoRead.on' => app.autoRead,
      'inbox.newSinceAway' => app.newSinceAway,
      'inbox.summaryLine' => app.summaryLine,
      'writing.hints' => app.writingHints,
      'notify.notificationsSection' => app.notifyNotificationsSection,
      'mail.serverRules' => app.serverRules,
      _ => throw ArgumentError(key),
    };
    for (final setting in AppSettings.all) {
      final key = setting.key;
      final onDefault = onByDefault.contains(key);
      expect(values(key), onDefault, reason: '$key default');
      settings().write(key, 'off');
      expect(values(key), isFalse, reason: key);
      settings().write(key, 'on');
      expect(values(key), isTrue, reason: key);
      // Anything else read as the default before: `!= 'off'` or `== 'on'`.
      settings().write(key, 'maybe');
      expect(values(key), onDefault, reason: '$key unreadable');
    }
    app.notifications = false;
    expect(settings().read('app.notifications'), 'off');
    app.serverRules = true;
    expect(settings().read('mail.serverRules'), 'on');
  });

  test('the app lock', () {
    expect(AppLock.isEnabledIn(store), isFalse);
    settings().write('lock.enabled', 'on');
    expect(AppLock.isEnabledIn(store), isTrue);
    expect(AppLock.timeoutSetting.read(settings()), LockTimeout.oneMinute);
    settings().write('lock.timeout', 'fiveMinutes');
    expect(AppLock.timeoutSetting.read(settings()), LockTimeout.fiveMinutes);
    settings().write('lock.timeout', 'never');
    expect(AppLock.timeoutSetting.read(settings()), LockTimeout.oneMinute);
    settings().write('lock.failures', '3');
    expect(AppLock.failuresSetting.read(settings()), 3);
    final until = DateTime.utc(2026, 11, 9, 9);
    settings().write('lock.until', '${until.millisecondsSinceEpoch}');
    expect(AppLock.untilSetting.read(settings()), until);
    settings().write('lock.untilElapsed', '120000');
    settings().write('lock.elapsedAt', '90000');
    settings().write('lock.wait', '30000');
    expect(AppLock.untilElapsedSetting.readOrNull(settings()), 120000);
    expect(AppLock.elapsedAtSetting.readOrNull(settings()), 90000);
    expect(AppLock.waitSetting.read(settings()), 30000);
  });

  test('appearance', () {
    expect(Appearance.read(store), ThemeMode.system);
    settings().write('app.theme', 'dark');
    expect(Appearance.read(store), ThemeMode.dark);
    settings().write('app.theme', 'light');
    expect(Appearance.read(store), ThemeMode.light);
    settings().write('app.theme', 'sepia');
    expect(Appearance.read(store), ThemeMode.system);
  });

  test('tips, What\'s new and the command bar', () {
    final tips = Tips(store);
    expect(tips.enabled, isTrue);
    settings().write('tips.off', 'on');
    expect(tips.enabled, isFalse);
    tips.enabled = true;
    expect(settings().read('tips.off'), 'off');
    settings().write('tips.seen', 'unsubscribe,snooze');
    expect(tips.seen, {'unsubscribe', 'snooze'});
    settings().write('tips.seen.dismissed', 'snooze');
    expect(tips.dismissed('snooze'), isTrue);

    expect(WhatsNew(store).seenVersion, isNull);
    settings().write('whatsNew.seen', '0.6.1');
    expect(WhatsNew(store).seenVersion, '0.6.1');

    settings().write('commandBar.recent', 'go.inbox,action.archive');
    expect(CommandHistory(store).ids, ['go.inbox', 'action.archive']);
  });

  test('reminders and "New since you were away"', () {
    final state = ReminderState(store);
    settings().write('reminders.dismissed', 'billDue:x.com:2099-01-01');
    expect(state.dismissed, {'billDue:x.com:2099-01-01'});
    settings().write('reminders.notified', 'a@soon,b@due');
    expect(state.notified, {'a@soon', 'b@due'});
    final at = DateTime.utc(2026, 11, 9, 9);
    settings().write('reminders.lastCheck', '${at.millisecondsSinceEpoch}');
    expect(state.lastCheck!.isAtSameMomentAs(at), isTrue);
    expect(state.lastCheck!.isUtc, isFalse, reason: 'local, as before');
    settings().write('reminders.lastCheck', '');
    expect(state.lastCheck, isNull);
    state.lastCheck = at;
    expect(
      settings().read('reminders.lastCheck'),
      '${at.millisecondsSinceEpoch}',
    );
    state.lastCheck = null;
    expect(settings().read('reminders.lastCheck'), '');

    settings().write('inbox.awaySince', '${at.millisecondsSinceEpoch}');
    expect(NewSinceAway.awaySetting.read(settings()), at);
  });

  test('learning, kept senders and folded sections', () {
    settings().write('learning.kept', 'd/x\ns/y');
    expect(Corrections.keptSetting.read(settings()), ['d/x', 's/y']);
    settings().write('learning.opened', 'd/x');
    expect(Corrections.openedSetting.read(settings()), ['d/x']);
    settings().write('learning.model', 'v1 text');
    expect(Corrections.modelSetting.readOrNull(settings()), 'v1 text');
    settings().write('cleanup.kept', 'a@example.com,b@example.com');
    expect(SenderCleanupModel.keptSetting.read(settings()), [
      'a@example.com',
      'b@example.com',
    ]);
    settings().write('ui.collapsedSections', 'newsletters,notifications');
    expect(MessageListModel.collapsedSetting.read(settings()), [
      'newsletters',
      'notifications',
    ]);
  });

  test('hidden items, deliveries and returns', () {
    for (final setting in [
      AccountsModel.hiddenSetting,
      AppointmentsModel.hiddenSetting,
      SubscriptionsModel.hiddenSetting,
      TripsModel.hiddenSetting,
      DeliveriesModel.hiddenSetting,
      DeliveriesModel.deliveredSetting,
      DeliveriesModel.returnedSetting,
      DeliveriesModel.keptSetting,
    ]) {
      expect(setting.read(settings()), isEmpty);
      settings().write(setting.key, 'one,two');
      expect(setting.read(settings()), ['one', 'two'], reason: setting.key);
      setting.write(settings(), ['three', 'four']);
      expect(settings().read(setting.key), 'three,four');
    }
    // Attachments: one per line (their keys may hold commas).
    settings().write('attachments.hidden', '1:a,b.pdf\n2:c.pdf');
    expect(AttachmentsModel.hiddenSetting.read(settings()), [
      '1:a,b.pdf',
      '2:c.pdf',
    ]);
  });

  test('invitations and summaries', () {
    settings().write('invitations.answers', '{"uid:1":"accepted","x":2}');
    expect(InvitationAnswers.setting.read(settings()), {'uid:1': 'accepted'});
    settings().write('invitations.answers', 'not json');
    expect(InvitationAnswers.setting.read(settings()), isEmpty);
    settings().write('ai.summaries', '["ai.summary.m.1",7,"ai.summary.c.2"]');
    expect(MessageSummaries.indexSetting.read(settings()), [
      'ai.summary.m.1',
      'ai.summary.c.2',
    ]);
    MessageSummaries.indexSetting.write(settings(), ['ai.summary.m.1']);
    expect(settings().read('ai.summaries'), '["ai.summary.m.1"]');
  });

  test('the background check', () {
    expect(BackgroundMail.lastCheck(store), isNull);
    settings().write('background.lastCheck', 'ok 2026-11-09T09:00:00.000Z');
    final last = BackgroundMail.lastCheck(store)!;
    expect(last.ok, isTrue);
    expect(last.at.isAtSameMomentAs(DateTime.utc(2026, 11, 9, 9)), isTrue);
    expect(last.at.isUtc, isFalse);
    BackgroundMail.recordCheck(store, ok: false, at: DateTime.utc(2026, 11, 9));
    expect(
      settings().read('background.lastCheck'),
      'failed 2026-11-09T00:00:00.000Z',
    );
    settings().write('background.lastCheck', 'garbage');
    expect(BackgroundMail.lastCheck(store), isNull);

    expect(BackgroundMail.askedSetting.isSetIn(settings()), isFalse);
    BackgroundMail.askedSetting.write(settings(), true);
    expect(settings().read('instant.askedBackground'), 'yes');
    final at = DateTime.utc(2026, 11, 9, 9);
    settings().write('autoRead.background', '${at.millisecondsSinceEpoch}');
    expect(BackgroundMail.readAheadSetting.read(settings()), at);
  });

  test('AI sorting per sync, link and file checks, failed reads', () {
    expect(AiSorter.perSyncSetting.read(settings()), AiSorter.defaultPerSync);
    settings().write('ai.sorting.perSync', '50');
    expect(AiSorter.perSyncSetting.read(settings()), 50);
    for (final bad in ['0', '-4', 'many']) {
      settings().write('ai.sorting.perSync', bad);
      expect(AiSorter.perSyncSetting.read(settings()), AiSorter.defaultPerSync);
    }

    expect(LinkSafety.setting.read(settings()), isFalse);
    settings().write('app.safeBrowsing', 'on');
    expect(LinkSafety.setting.read(settings()), isTrue);
    settings().write('app.safeBrowsing.status', 'Lists updated x');
    expect(LinkSafety.statusSetting.readOrNull(settings()), 'Lists updated x');
    expect(VirusTotalChecks.setting.read(settings()), isFalse);
    settings().write('app.virusTotal', 'on');
    expect(VirusTotalChecks.setting.read(settings()), isTrue);

    settings().write('autoRead.failed', '12:1,13:3');
    final failures = ReadFailures(store);
    expect(failures.times(12), 1);
    expect(failures.givenUp, {13});
    failures.failed(12);
    expect(settings().read('autoRead.failed'), '13:3,12:2');
  });
}
