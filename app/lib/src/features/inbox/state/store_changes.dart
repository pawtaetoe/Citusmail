// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_store/mail_store.dart';

/// Tells whether anything in the store changed since an earlier look: a
/// write on this connection (the UI's own), or a commit by another one
/// (the sync worker, the background check). Two tiny queries, so the
/// mail screen can keep counts it read before instead of counting again
/// when nothing changed.
final class StoreChanges {
  StoreChanges(this._store);

  final MailStore _store;

  /// Equal to an earlier one exactly when nothing was written since.
  (int, int) get stamp {
    final db = _store.database;
    return (
      db.select('SELECT total_changes()').first.columnAt(0) as int,
      db.select('PRAGMA data_version').first.columnAt(0) as int,
    );
  }
}
