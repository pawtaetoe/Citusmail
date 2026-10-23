// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:sqlite3/sqlite3.dart';

import '../database/mail_database.dart';

/// A read receipt someone's mail app sent for the user's message.
final class ReadReceipt {
  const ReadReceipt({
    required this.recipient,
    required this.disposition,
    required this.at,
  });

  /// Who read it (lower case).
  final String recipient;

  /// `displayed`, `deleted`, `dispatched` or `processed`.
  final String disposition;

  /// When the receipt arrived.
  final DateTime at;
}

/// Read receipts the user asked for, and the ones that came back.
final class ReceiptRepository {
  ReceiptRepository(this._db);

  final MailDatabase _db;

  /// Remembers that the message [messageId] (without brackets) asked for
  /// read receipts.
  void requested(int accountId, String messageId, {DateTime? at}) =>
      _db.execute(
        'INSERT OR IGNORE INTO receipt_requests (account_id, message_id_header, requested_at) '
        'VALUES (?, ?, ?)',
        [
          accountId,
          messageId,
          (at ?? DateTime.now()).toUtc().millisecondsSinceEpoch,
        ],
      );

  bool wasRequested(int accountId, String messageId) => _db.select(
    'SELECT 1 FROM receipt_requests WHERE account_id = ? AND message_id_header = ?',
    [accountId, messageId],
  ).isNotEmpty;

  /// Records a receipt for a message that asked for one; a later receipt
  /// from the same person replaces an earlier one. Returns false (and
  /// stores nothing) when the message never asked.
  bool record(
    int accountId,
    String messageId, {
    required String recipient,
    required String disposition,
    DateTime? at,
  }) {
    if (!wasRequested(accountId, messageId)) return false;
    _db.execute(
      'INSERT INTO read_receipts (account_id, message_id_header, recipient, disposition, at) '
      'VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT (account_id, message_id_header, recipient) DO UPDATE SET '
      'disposition = excluded.disposition, at = excluded.at',
      [
        accountId,
        messageId,
        recipient.toLowerCase(),
        disposition,
        (at ?? DateTime.now()).toUtc().millisecondsSinceEpoch,
      ],
    );
    return true;
  }

  /// The receipts for one sent message, oldest first.
  List<ReadReceipt> forMessage(int accountId, String messageId) => [
    for (final row in _db.select(
      'SELECT recipient, disposition, at FROM read_receipts '
      'WHERE account_id = ? AND message_id_header = ? ORDER BY at, recipient',
      [accountId, messageId],
    ))
      _fromRow(row),
  ];

  /// Ids of stored messages in [mailboxId] that look like read receipts
  /// (from their Content-Type) and haven't been read for one yet.
  List<int> unreadReports(int mailboxId, {int limit = 50}) => [
    for (final row in _db.select(
      'SELECT m.id FROM messages m JOIN message_headers h ON h.message_id = m.id '
      "WHERE m.mailbox_id = ? AND h.name = 'content-type' "
      "AND lower(h.value) LIKE '%multipart/report%' "
      "AND lower(h.value) LIKE '%disposition-notification%' "
      'AND NOT EXISTS (SELECT 1 FROM processed_reports p WHERE p.message_id = m.id) '
      'ORDER BY m.received_at DESC LIMIT ?',
      [mailboxId, limit.clamp(1, 500)],
    ))
      row['id'] as int,
  ];

  void markReportRead(int messageId) => _db.execute(
    'INSERT OR IGNORE INTO processed_reports (message_id) VALUES (?)',
    [messageId],
  );

  static ReadReceipt _fromRow(Row row) => ReadReceipt(
    recipient: row['recipient'] as String,
    disposition: row['disposition'] as String,
    at: DateTime.fromMillisecondsSinceEpoch(row['at'] as int, isUtc: true),
  );
}
