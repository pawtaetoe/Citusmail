// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../database/mail_database.dart';
import '../model/outbox.dart';

/// The queue of actions waiting to reach the server, replayed in order.
final class OutboxRepository {
  OutboxRepository(this._db);

  final MailDatabase _db;

  static const _columns =
      'id, account_id, action, data, state, attempts, last_error, created_at, not_before';

  /// Longest stored error text.
  static const _maxErrorLength = 500;

  OutboxEntry enqueue(int accountId, OutboxAction action, {Uint8List? data}) {
    final needsData = action is AppendAction || action is SendAction;
    if (needsData != (data != null)) {
      throw ArgumentError(
        needsData
            ? 'this action needs message data'
            : 'this action takes no data',
      );
    }
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    _db.execute(
      'INSERT INTO outbox (account_id, action, data, created_at, not_before) VALUES (?, ?, ?, ?, ?)',
      [accountId, action.encode(), data, now, 0],
    );
    return _byId(_db.lastInsertRowId)!;
  }

  /// Pending entries of an account whose retry time has come, oldest
  /// first. An entry that cannot be read is marked failed and skipped, so
  /// one corrupted entry never blocks the queue.
  List<OutboxEntry> due(int accountId, {DateTime? now}) {
    final at = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
    final rows = _db.select(
      "SELECT $_columns FROM outbox WHERE account_id = ? AND state = 'pending' AND not_before <= ? ORDER BY id",
      [accountId, at],
    );
    final result = <OutboxEntry>[];
    for (final row in rows) {
      final entry = _tryFromRow(row);
      if (entry == null) {
        markFailed(row['id'] as int, 'unreadable action');
      } else {
        result.add(entry);
      }
    }
    return result;
  }

  /// Every entry of an account (pending and failed), oldest first.
  List<OutboxEntry> all(int accountId) => _db
      .select('SELECT $_columns FROM outbox WHERE account_id = ? ORDER BY id', [
        accountId,
      ])
      .map(_tryFromRow)
      .whereType<OutboxEntry>()
      .toList(growable: false);

  /// The server has the change: remove the entry.
  void complete(int id) => _db.execute('DELETE FROM outbox WHERE id = ?', [id]);

  /// A temporary problem (offline, timeout): try again after [retryAt].
  void retryLater(int id, String error, DateTime retryAt) => _db.execute(
    'UPDATE outbox SET attempts = attempts + 1, last_error = ?, not_before = ? WHERE id = ?',
    [_shorten(error), retryAt.toUtc().millisecondsSinceEpoch, id],
  );

  /// A permanent problem: stop retrying and show it to the user.
  void markFailed(int id, String error) => _db.execute(
    "UPDATE outbox SET state = 'failed', attempts = attempts + 1, last_error = ? WHERE id = ?",
    [_shorten(error), id],
  );

  /// Put a failed entry back in the queue (the user chose "retry").
  void retryFailed(int id) => _db.execute(
    "UPDATE outbox SET state = 'pending', not_before = 0 WHERE id = ? AND state = 'failed'",
    [id],
  );

  int pendingCount(int accountId) =>
      _db
              .select(
                "SELECT count(*) FROM outbox WHERE account_id = ? AND state = 'pending'",
                [accountId],
              )
              .first
              .columnAt(0)
          as int;

  OutboxEntry? _byId(int id) {
    final rows = _db.select('SELECT $_columns FROM outbox WHERE id = ?', [id]);
    return rows.isEmpty ? null : _tryFromRow(rows.first);
  }

  static String _shorten(String text) =>
      text.length > _maxErrorLength ? text.substring(0, _maxErrorLength) : text;

  static OutboxEntry? _tryFromRow(Row row) {
    final OutboxAction action;
    try {
      action = OutboxAction.decode(row['action'] as String);
    } on FormatException {
      return null;
    }
    return OutboxEntry(
      id: row['id'] as int,
      accountId: row['account_id'] as int,
      action: action,
      data: row['data'] as Uint8List?,
      state: OutboxState.values.byName(row['state'] as String),
      attempts: row['attempts'] as int,
      lastError: row['last_error'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row['created_at'] as int,
        isUtc: true,
      ),
      notBefore: DateTime.fromMillisecondsSinceEpoch(
        row['not_before'] as int,
        isUtc: true,
      ),
    );
  }
}
