// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

/// The user's app settings, stored encrypted with everything else (so the
/// background job on Android reads the same values).
///
/// Some of them (reminders, learning, reading ahead, "New since you were
/// away", the summary line) sync between the user's devices with sync
/// between devices on: which ones is decided in one place,
/// `SyncedPreferences` in mail_store, which also declares them.
/// The rest stay on this device.
final class AppSettings {
  AppSettings(this._store);

  final MailStore _store;

  SettingsRepository get _settings => _store.settings;

  /// Changes when preferences from the user's other devices were applied
  /// here, so what shows them reads them again.
  final syncedChanges = ValueNotifier<int>(0);

  /// After an exchange with the user's other devices.
  void syncApplied(AppliedChanges changes) {
    if (changes.preferences.isNotEmpty) syncedChanges.value++;
  }

  static const notificationsSetting = BoolSetting(
    'app.notifications',
    fallback: true,
  );
  static const instantMailSetting = BoolSetting(
    'app.instantMail',
    fallback: true,
  );
  static const previewsSetting = BoolSetting(
    'app.notificationPreviews',
    fallback: true,
  );
  static const remindersSetting = SyncedPreferences.reminders;
  static const monthlyRenewalsSetting = SyncedPreferences.monthlyRenewals;
  static const followUpsSetting = SyncedPreferences.followUpNotifications;
  static const learnSetting = SyncedPreferences.learnFromCorrections;
  static const autoReadSetting = SyncedPreferences.autoRead;
  static const newSinceAwaySetting = SyncedPreferences.newSinceAway;
  static const summaryLineSetting = SyncedPreferences.summaryLine;
  static const writingHintsSetting = SyncedPreferences.writingHints;
  static const notificationsSectionSetting =
      NewMailTracker.notificationsSection;
  static const serverRulesSetting = ServerRules.setting;

  /// Every setting above, for tests.
  static const all = <Setting<Object?>>[
    notificationsSetting,
    instantMailSetting,
    previewsSetting,
    remindersSetting,
    monthlyRenewalsSetting,
    followUpsSetting,
    learnSetting,
    autoReadSetting,
    newSinceAwaySetting,
    summaryLineSetting,
    writingHintsSetting,
    notificationsSectionSetting,
    serverRulesSetting,
  ];

  /// New-mail notifications (on by default).
  bool get notifications => notificationsSetting.read(_settings);
  set notifications(bool on) => notificationsSetting.write(_settings, on);

  /// New-mail notifications show a short preview of the text (on by
  /// default); off, sender and subject only.
  bool get notificationPreviews => previewsSetting.read(_settings);
  set notificationPreviews(bool on) => previewsSetting.write(_settings, on);

  /// Notifications before a bill is due, a free trial ends, a yearly
  /// subscription renews, a return window closes or an appointment (on by
  /// default; only with [notifications]).
  bool get reminders => remindersSetting.read(_settings);
  set reminders(bool on) => remindersSetting.write(_settings, on);

  /// A notification when an email the user is waiting on got no reply in
  /// time ("Remind me if no reply"; on by default; only with
  /// [notifications]). The email comes back to the inbox either way.
  bool get followUpNotifications => followUpsSetting.read(_settings);
  set followUpNotifications(bool on) => followUpsSetting.write(_settings, on);

  /// "Learn from my corrections" (on by default): items that look like
  /// ones the user said are not a subscription, delivery, booking or
  /// account are left out too. Off, the pages show what the rules find.
  bool get learnFromCorrections => learnSetting.read(_settings);
  set learnFromCorrections(bool on) => learnSetting.write(_settings, on);

  /// "Read receipts and bookings automatically" (on by default): the
  /// emails Subscriptions, Deliveries, Trips, Appointments and Online
  /// accounts would read are downloaded ahead of time (they stay unread). Off, each page
  /// offers to read them, as a button.
  bool get autoRead => autoReadSetting.read(_settings);
  set autoRead(bool on) => autoReadSetting.write(_settings, on);

  /// "New since you were away" at the top of the inbox (on by default).
  bool get newSinceAway => newSinceAwaySetting.read(_settings);
  set newSinceAway(bool on) => newSinceAwaySetting.write(_settings, on);

  /// The summary line at the top of the inbox: new mail, the latest
  /// code, today's deliveries, appointments and bills (on by default).
  bool get summaryLine => summaryLineSetting.read(_settings);
  set summaryLine(bool on) => summaryLineSetting.write(_settings, on);

  /// Writing hints under the recipients in the compose window (on by
  /// default): their local time, how quickly they reply, a likely typo.
  bool get writingHints => writingHintsSetting.read(_settings);
  set writingHints(bool on) => writingHintsSetting.write(_settings, on);

  /// Monthly (and weekly) renewals are reminded of too (off by default:
  /// they come every month).
  bool get monthlyRenewals => monthlyRenewalsSetting.read(_settings);
  set monthlyRenewals(bool on) => monthlyRenewalsSetting.write(_settings, on);

  /// New mail in the Notifications section (GitHub, a bank, deliveries)
  /// is announced too, unless turned off. Newsletters never are.
  bool get notifyNotificationsSection =>
      notificationsSectionSetting.read(_settings);
  set notifyNotificationsSection(bool on) =>
      notificationsSectionSetting.write(_settings, on);

  /// Android: keep a live connection for instant mail (on unless turned
  /// off; Android shows a quiet permanent notification while it runs).
  bool get instantMail => instantMailSetting.read(_settings);
  set instantMail(bool on) => instantMailSetting.write(_settings, on);

  /// Blocked senders and folder rules also run on the mail server, where
  /// it supports Sieve (off by default: it changes the server's setup).
  bool get serverRules => serverRulesSetting.read(_settings);
  set serverRules(bool on) => serverRulesSetting.write(_settings, on);
}
