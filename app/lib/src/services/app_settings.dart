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

  /// New-mail notifications (on by default).
  bool get notifications => _store.settings.read(_notifications) != 'off';
  set notifications(bool on) =>
      _store.settings.write(_notifications, on ? 'on' : 'off');

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
