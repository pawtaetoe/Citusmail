// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../database/mail_database.dart';

/// Small app-wide values by name, stored encrypted with everything else.
/// Never put secrets here: those belong in the system keychain.
final class SettingsRepository {
  SettingsRepository(this._db);

  final MailDatabase _db;

  String? read(String key) {
    final rows = _db.select('SELECT value FROM settings WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first.columnAt(0) as String;
  }

  void write(String key, String value) => _db.execute(
    'INSERT INTO settings (key, value) VALUES (?, ?) '
    'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
    [key, value],
  );

  void delete(String key) =>
      _db.execute('DELETE FROM settings WHERE key = ?', [key]);
}
