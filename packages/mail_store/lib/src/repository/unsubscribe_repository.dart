// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:sqlite3/sqlite3.dart';

import '../database/mail_database.dart';
import '../model/unsubscription.dart';
import 'app_data_sync_repository.dart';

/// Lists the user unsubscribed from, so the app can say so on later mail
/// from them (and notice lists that keep sending).
final class UnsubscribeRepository {
  UnsubscribeRepository(this._db);

  final MailDatabase _db;

  static const _columns = 'id, account_id, list_key, list_name, kind, at';

  /// Remembers an unsubscribe; a later one for the same list replaces it.
  Unsubscription record({
    required int accountId,
    required String listKey,
    required String listName,
    required UnsubscribeKind kind,
    DateTime? now,
  }) => _db.transaction(() {
    final at = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
    final name = listName.length > 200 ? listName.substring(0, 200) : listName;
    _db.execute(
      'INSERT INTO unsubscriptions (account_id, list_key, list_name, kind, at) '
      'VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT (account_id, list_key) DO UPDATE SET '
      'list_name = excluded.list_name, kind = excluded.kind, at = excluded.at',
      [accountId, listKey, name, kind.name, at],
    );
    return find(accountId, listKey)!;
  });

  Unsubscription? find(int accountId, String listKey) {
    final rows = _db.select(
      'SELECT $_columns FROM unsubscriptions WHERE account_id = ? AND list_key = ?',
      [accountId, listKey],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// An account's unsubscribes, newest first.
  List<Unsubscription> forAccount(int accountId) => _db
      .select(
        'SELECT $_columns FROM unsubscriptions WHERE account_id = ? ORDER BY at DESC, id DESC',
        [accountId],
      )
      .map(_fromRow)
      .toList(growable: false);

  /// Removes the record, remembering the removal for the user's other
  /// devices.
  void remove(int id, {DateTime? at, String? device}) => _db.transaction(() {
    final rows = _db.select(
      'SELECT a.email, u.list_key FROM unsubscriptions u '
      'JOIN accounts a ON a.id = u.account_id WHERE u.id = ?',
      [id],
    );
    if (rows.isEmpty) return;
    _db.execute('DELETE FROM unsubscriptions WHERE id = ?', [id]);
    AppDataSyncRepository(_db).recordRemoval(
      AppDataKeys.unsubscribe(
        rows.first.columnAt(0) as String,
        rows.first.columnAt(1) as String,
      ),
      'unsubscribe',
      at: at,
      device: device,
    );
  });

  static Unsubscription _fromRow(Row row) => Unsubscription(
    id: row['id'] as int,
    accountId: row['account_id'] as int,
    listKey: row['list_key'] as String,
    listName: row['list_name'] as String,
    kind: UnsubscribeKind.values.byName(row['kind'] as String),
    at: DateTime.fromMillisecondsSinceEpoch(row['at'] as int, isUtc: true),
  );
}
