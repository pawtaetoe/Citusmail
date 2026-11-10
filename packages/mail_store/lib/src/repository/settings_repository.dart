// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../database/mail_database.dart';
import 'synced_preferences.dart';

/// Small app-wide values by name, stored encrypted with everything else.
/// Never put secrets here: those belong in the system keychain.
///
/// A change to one of the preferences that sync between the user's
/// devices ([SyncedPreferences.all]) notes when it happened; every other
/// setting stays on its device.
final class SettingsRepository {
  SettingsRepository(this._db);

  final MailDatabase _db;

  String? read(String key) {
    final rows = _db.select('SELECT value FROM settings WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first.columnAt(0) as String;
  }

  /// [at] and [device]: when applying another device's change.
  void write(String key, String value, {DateTime? at, String? device}) =>
      _change(key, value, at, device);

  void delete(String key, {DateTime? at, String? device}) =>
      _change(key, null, at, device);

  void _change(String key, String? value, DateTime? at, String? device) {
    void set() => value == null
        ? _db.execute('DELETE FROM settings WHERE key = ?', [key])
        : _db.execute(
            'INSERT INTO settings (key, value) VALUES (?, ?) '
            'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
            [key, value],
          );
    if (SyncedPreferences.preferenceOf(key) == null) return set();
    _db.transaction(() {
      final old = read(key);
      set();
      SyncedPreferences(_db)
          .settingChanged(key, old, value, at: at, device: device);
    });
  }
}
