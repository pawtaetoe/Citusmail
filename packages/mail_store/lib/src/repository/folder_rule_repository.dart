// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:sqlite3/sqlite3.dart';

import '../database/mail_database.dart';
import '../model/folder_rule.dart';
import 'app_data_sync_repository.dart';

/// The user's custom-folder rules, and which messages they already moved.
final class FolderRuleRepository {
  FolderRuleRepository(this._db);

  final MailDatabase _db;

  static const _columns =
      'id, account_id, mailbox_id, field, value, applies_from, created_at';

  /// Adds a rule moving matching mail into [mailboxId] (a folder of
  /// [accountId]). With [includeExisting], mail already in the inbox moves
  /// too; otherwise only mail arriving from now on.
  FolderRule add({
    required int accountId,
    required int mailboxId,
    required RuleField field,
    required String value,
    bool includeExisting = false,
    DateTime? now,
    DateTime? appliesFrom,
  }) => _db.transaction(() {
    final owner = _db.select('SELECT account_id FROM mailboxes WHERE id = ?', [
      mailboxId,
    ]);
    if (owner.isEmpty || owner.first.columnAt(0) != accountId) {
      throw ArgumentError.value(
        mailboxId,
        'mailboxId',
        'not a folder of this account',
      );
    }
    final at = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
    _db.execute(
      'INSERT INTO folder_rules (account_id, mailbox_id, field, value, applies_from, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [
        accountId,
        mailboxId,
        field.name,
        FolderRule.normalize(field, value),
        appliesFrom?.toUtc().millisecondsSinceEpoch ??
            (includeExisting ? 0 : at),
        at,
      ],
    );
    return _byId(_db.lastInsertRowId)!;
  });

  /// Removes a rule the user deleted, remembering the removal for their
  /// other devices.
  void remove(int id, {DateTime? at, String? device}) => _db.transaction(() {
    final rows = _db.select(
      'SELECT a.email, m.encoded_name, r.field, r.value FROM folder_rules r '
      'JOIN accounts a ON a.id = r.account_id '
      'JOIN mailboxes m ON m.id = r.mailbox_id WHERE r.id = ?',
      [id],
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    _db.execute('DELETE FROM folder_rules WHERE id = ?', [id]);
    AppDataSyncRepository(_db).recordRemoval(
      AppDataKeys.folderRule(
        row['email'] as String,
        row['encoded_name'] as String,
        RuleField.values.byName(row['field'] as String),
        row['value'] as String,
      ),
      'folderRule',
      at: at,
      device: device,
    );
  });

  /// An account's rules, oldest first (the first match wins).
  List<FolderRule> forAccount(int accountId) => _db
      .select(
        'SELECT $_columns FROM folder_rules WHERE account_id = ? ORDER BY id',
        [accountId],
      )
      .map(_fromRow)
      .toList(growable: false);

  /// The rules moving mail into one folder.
  List<FolderRule> forMailbox(int mailboxId) => _db
      .select(
        'SELECT $_columns FROM folder_rules WHERE mailbox_id = ? ORDER BY id',
        [mailboxId],
      )
      .map(_fromRow)
      .toList(growable: false);

  /// Whether a rule already moved the message [messageId].
  bool wasMoved(int accountId, String messageId) => _db.select(
    'SELECT 1 FROM rule_moves WHERE account_id = ? AND message_id_header = ?',
    [accountId, messageId],
  ).isNotEmpty;

  void recordMoved(int accountId, String messageId) => _db.execute(
    'INSERT OR IGNORE INTO rule_moves (account_id, message_id_header, moved_at) VALUES (?, ?, ?)',
    [accountId, messageId, DateTime.now().toUtc().millisecondsSinceEpoch],
  );

  FolderRule? _byId(int id) {
    final rows = _db.select('SELECT $_columns FROM folder_rules WHERE id = ?', [
      id,
    ]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  static FolderRule _fromRow(Row row) => FolderRule(
    id: row['id'] as int,
    accountId: row['account_id'] as int,
    mailboxId: row['mailbox_id'] as int,
    field: RuleField.values.byName(row['field'] as String),
    value: row['value'] as String,
    appliesFrom: DateTime.fromMillisecondsSinceEpoch(
      row['applies_from'] as int,
      isUtc: true,
    ),
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      row['created_at'] as int,
      isUtc: true,
    ),
  );
}
