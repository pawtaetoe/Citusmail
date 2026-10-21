// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../database/mail_database.dart';
import '../database/store_exception.dart';
import '../model/account.dart';

/// Accounts. Removing an account removes all of its folders, messages and
/// queued actions (foreign keys cascade, and secure_delete overwrites them).
final class AccountRepository {
  AccountRepository(this._db);

  final MailDatabase _db;

  static const _columns =
      'id, email, display_name, username, imap_host, imap_port, imap_security, '
      'smtp_host, smtp_port, smtp_security, sort_order, created_at';

  Account add(NewAccount account) => _db.transaction(() {
    final next =
        _db
                .select(
                  'SELECT coalesce(max(sort_order), -1) + 1 FROM accounts',
                )
                .first
                .columnAt(0)
            as int;
    try {
      _db.execute(
        'INSERT INTO accounts (email, display_name, username, imap_host, imap_port, imap_security, '
        'smtp_host, smtp_port, smtp_security, sort_order, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          account.email,
          account.displayName,
          account.username,
          account.imap.host,
          account.imap.port,
          account.imap.security.name,
          account.smtp.host,
          account.smtp.port,
          account.smtp.security.name,
          next,
          DateTime.now().toUtc().millisecondsSinceEpoch,
        ],
      );
    } on SqliteException catch (e) {
      if (e.extendedResultCode == 2067) {
        throw DuplicateAccountException(account.email); // UNIQUE
      }
      rethrow;
    }
    return byId(_db.lastInsertRowId)!;
  });

  List<Account> all() => _db
      .select('SELECT $_columns FROM accounts ORDER BY sort_order, id')
      .map(_fromRow)
      .toList(growable: false);

  Account? byId(int id) {
    final rows = _db.select('SELECT $_columns FROM accounts WHERE id = ?', [
      id,
    ]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Changes name, login or servers (the email address is the identity).
  void update(Account account) {
    _db.execute(
      'UPDATE accounts SET display_name = ?, username = ?, imap_host = ?, imap_port = ?, imap_security = ?, '
      'smtp_host = ?, smtp_port = ?, smtp_security = ?, sort_order = ? WHERE id = ?',
      [
        account.displayName,
        account.username,
        account.imap.host,
        account.imap.port,
        account.imap.security.name,
        account.smtp.host,
        account.smtp.port,
        account.smtp.security.name,
        account.sortOrder,
        account.id,
      ],
    );
  }

  /// Removes the account and everything stored for it. The caller also
  /// removes its keychain entry.
  void remove(int id) => _db.execute('DELETE FROM accounts WHERE id = ?', [id]);

  static Account _fromRow(Row row) => Account(
    id: row['id'] as int,
    email: row['email'] as String,
    displayName: row['display_name'] as String?,
    username: row['username'] as String,
    imap: ServerSettings(
      host: row['imap_host'] as String,
      port: row['imap_port'] as int,
      security: ConnectionSecurity.values.byName(
        row['imap_security'] as String,
      ),
    ),
    smtp: ServerSettings(
      host: row['smtp_host'] as String,
      port: row['smtp_port'] as int,
      security: ConnectionSecurity.values.byName(
        row['smtp_security'] as String,
      ),
    ),
    sortOrder: row['sort_order'] as int,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      row['created_at'] as int,
      isUtc: true,
    ),
  );
}
