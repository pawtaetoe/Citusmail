// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

/// The user's app settings, stored encrypted with everything else (so the
/// background job on Android reads the same values).
final class AppSettings {
  AppSettings(this._store);

  final MailStore _store;

  static const _notifications = 'app.notifications';
  static const _instantMail = 'app.instantMail';
  static const _previews = 'app.notificationPreviews';
  static const _reminders = 'reminders.on';
  static const _monthlyRenewals = 'reminders.monthly';
  static const _followUps = 'followUps.notify';
  static const _learn = 'learning.on';
  static const _autoRead = 'autoRead.on';

  /// New-mail notifications (on by default).
  bool get notifications => _store.settings.read(_notifications) != 'off';
  set notifications(bool on) =>
      _store.settings.write(_notifications, on ? 'on' : 'off');

  /// New-mail notifications show a short preview of the text (on by
  /// default); off, sender and subject only.
  bool get notificationPreviews => _store.settings.read(_previews) != 'off';
  set notificationPreviews(bool on) =>
      _store.settings.write(_previews, on ? 'on' : 'off');

  /// Notifications before a bill is due, a free trial ends or a yearly
  /// subscription renews (on by default; only with [notifications]).
  bool get reminders => _store.settings.read(_reminders) != 'off';
  set reminders(bool on) =>
      _store.settings.write(_reminders, on ? 'on' : 'off');

  /// A notification when an email the user is waiting on got no reply in
  /// time ("Remind me if no reply"; on by default; only with
  /// [notifications]). The email comes back to the inbox either way.
  bool get followUpNotifications => _store.settings.read(_followUps) != 'off';
  set followUpNotifications(bool on) =>
      _store.settings.write(_followUps, on ? 'on' : 'off');

  /// "Learn from my corrections" (on by default): items that look like
  /// ones the user said are not a subscription, delivery, booking or
  /// account are left out too. Off, the pages show what the rules find.
  bool get learnFromCorrections => _store.settings.read(_learn) != 'off';
  set learnFromCorrections(bool on) =>
      _store.settings.write(_learn, on ? 'on' : 'off');

  /// "Read receipts and bookings automatically" (on by default): the
  /// emails Subscriptions, Deliveries, Trips and Your accounts would read
  /// are downloaded ahead of time (they stay unread). Off, each page
  /// offers to read them, as a button.
  bool get autoRead => _store.settings.read(_autoRead) != 'off';
  set autoRead(bool on) => _store.settings.write(_autoRead, on ? 'on' : 'off');

  /// Monthly (and weekly) renewals are reminded of too (off by default:
  /// they come every month).
  bool get monthlyRenewals => _store.settings.read(_monthlyRenewals) == 'on';
  set monthlyRenewals(bool on) =>
      _store.settings.write(_monthlyRenewals, on ? 'on' : 'off');

  /// Android: keep a live connection for instant mail (off by default; it
  /// needs a permanent notification).
  bool get instantMail => _store.settings.read(_instantMail) == 'on';
  set instantMail(bool on) =>
      _store.settings.write(_instantMail, on ? 'on' : 'off');

  /// Blocked senders and folder rules also run on the mail server, where
  /// it supports Sieve (off by default: it changes the server's setup).
  bool get serverRules => _store.settings.read(ServerRules.settingKey) == 'on';
  set serverRules(bool on) =>
      _store.settings.write(ServerRules.settingKey, on ? 'on' : 'off');
}
