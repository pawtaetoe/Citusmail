// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../database/mail_database.dart';
import '../model/mailbox.dart';
import 'section_sql.dart';

/// Folders and their sync state.
final class MailboxRepository {
  MailboxRepository(this._db);

  final MailDatabase _db;

  static const _columns =
      'id, account_id, encoded_name, name, delimiter, special_use, selectable, '
      'uid_validity, uid_next, highest_mod_seq, last_sync_at';

  List<StoredMailbox> forAccount(int accountId) => _db
      .select(
        'SELECT $_columns FROM mailboxes WHERE account_id = ? ORDER BY name',
        [accountId],
      )
      .map(_fromRow)
      .toList(growable: false);

  StoredMailbox? byId(int id) {
    final rows = _db.select('SELECT $_columns FROM mailboxes WHERE id = ?', [
      id,
    ]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  StoredMailbox? inbox(int accountId) {
    final rows = _db.select(
      "SELECT $_columns FROM mailboxes WHERE account_id = ? AND upper(encoded_name) = 'INBOX'",
      [accountId],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// The folder with a special use (Sent, Trash, Junk...). Chosen by the
  /// server's flag, never by name.
  StoredMailbox? bySpecialUse(int accountId, SpecialUse use) {
    final rows = _db.select(
      'SELECT $_columns FROM mailboxes WHERE account_id = ? AND special_use = ? ORDER BY id LIMIT 1',
      [accountId, use.name],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Makes the stored folders match the server's list: new folders are
  /// added, existing ones updated (sync state kept), and folders gone from
  /// the server are removed together with their cached messages.
  List<StoredMailbox> replaceAll(
    int accountId,
    List<ImapMailboxInfo> serverFolders,
  ) => _db.transaction(() {
    String uses() => _db
        .select(
          'SELECT encoded_name, special_use FROM mailboxes WHERE account_id = ? ORDER BY encoded_name',
          [accountId],
        )
        .map((r) => '${r['encoded_name']}=${r['special_use']}')
        .join(';');
    final before = uses();
    final seen = <String>{};
    for (final folder in serverFolders) {
      if (!seen.add(folder.encodedName)) continue; // ignore duplicates
      _db.execute(
        'INSERT INTO mailboxes (account_id, encoded_name, name, delimiter, special_use, selectable) '
        'VALUES (?, ?, ?, ?, ?, ?) '
        'ON CONFLICT (account_id, encoded_name) DO UPDATE SET '
        'name = excluded.name, delimiter = excluded.delimiter, '
        'special_use = excluded.special_use, selectable = excluded.selectable',
        [
          accountId,
          folder.encodedName,
          folder.name,
          folder.delimiter,
          folder.specialUse?.name,
          folder.isSelectable ? 1 : 0,
        ],
      );
    }
    final existing = _db.select(
      'SELECT id, encoded_name FROM mailboxes WHERE account_id = ?',
      [accountId],
    );
    for (final row in existing) {
      if (!seen.contains(row['encoded_name'])) {
        _db.execute('DELETE FROM mailboxes WHERE id = ?', [row['id']]);
      }
    }
    // A Sent or Important folder appearing or going changes what counts
    // as Important (rare: only when folders change).
    if (uses() != before) SectionSql.refreshAccount(_db, accountId);
    return forAccount(accountId);
  });

  void saveSyncState(int mailboxId, MailboxSyncState state) {
    _db.execute(
      'UPDATE mailboxes SET uid_validity = ?, uid_next = ?, highest_mod_seq = ?, last_sync_at = ? WHERE id = ?',
      [
        state.uidValidity,
        state.uidNext,
        state.highestModSeq,
        state.lastSyncAt?.toUtc().millisecondsSinceEpoch,
        mailboxId,
      ],
    );
  }

  /// The server's UIDVALIDITY changed, so every cached UID for this folder
  /// is meaningless (RFC 9051 2.3.1.1). Drops the folder's cached messages
  /// and starts its sync state over, atomically.
  void resetForUidValidity(int mailboxId, int uidValidity) =>
      _db.transaction(() {
        _db.execute('DELETE FROM messages WHERE mailbox_id = ?', [mailboxId]);
        _db.execute(
          'UPDATE mailboxes SET uid_validity = ?, uid_next = NULL, highest_mod_seq = NULL, last_sync_at = NULL '
          'WHERE id = ?',
          [uidValidity, mailboxId],
        );
      });

  static StoredMailbox _fromRow(Row row) {
    final lastSync = row['last_sync_at'] as int?;
    final use = row['special_use'] as String?;
    return StoredMailbox(
      id: row['id'] as int,
      accountId: row['account_id'] as int,
      encodedName: row['encoded_name'] as String,
      name: row['name'] as String,
      delimiter: row['delimiter'] as String?,
      specialUse: use == null ? null : SpecialUse.values.asNameMap()[use],
      selectable: row['selectable'] == 1,
      syncState: MailboxSyncState(
        uidValidity: row['uid_validity'] as int?,
        uidNext: row['uid_next'] as int?,
        highestModSeq: row['highest_mod_seq'] as int?,
        lastSyncAt: lastSync == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(lastSync, isUtc: true),
      ),
    );
  }
}
