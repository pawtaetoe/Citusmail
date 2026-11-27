// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:sqlite3/sqlite3.dart';

import '../database/mail_database.dart';
import '../ids.dart';
import 'setting.dart';
import 'settings_repository.dart';

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

  /// When it was read: the receipt's date, or when it arrived.
  final DateTime at;

  /// Only this means the person saw the message; `deleted` and the
  /// others mean it was not read.
  bool get displayed => disposition == 'displayed';
}

/// Read receipts the user asked for, and the ones that came back.
final class ReceiptRepository {
  ReceiptRepository(this._db) : _settings = SettingsRepository(_db);

  final MailDatabase _db;

  /// Which report each receipt came in (see [linkReport]); kept in the
  /// settings, so the database needs no new table.
  final SettingsRepository _settings;

  /// At most this many links are kept per account (the oldest go).
  static const maxLinks = 500;

  /// Remembers that the message [messageId] (without brackets) asked for
  /// read receipts.
  void requested(AccountId accountId, String messageId, {DateTime? at}) =>
      _db.execute(
        'INSERT OR IGNORE INTO receipt_requests (account_id, message_id_header, requested_at) '
        'VALUES (?, ?, ?)',
        [
          accountId.value,
          messageId,
          (at ?? DateTime.now()).toUtc().millisecondsSinceEpoch,
        ],
      );

  bool wasRequested(AccountId accountId, String messageId) => _db.select(
    'SELECT 1 FROM receipt_requests WHERE account_id = ? AND message_id_header = ?',
    [accountId.value, messageId],
  ).isNotEmpty;

  /// Records a receipt for a message that asked for one; a later receipt
  /// from the same person replaces an earlier one (an older one, read
  /// after it, does not). Returns false (and stores nothing) when the
  /// message never asked.
  bool record(
    AccountId accountId,
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
      'disposition = excluded.disposition, at = excluded.at '
      'WHERE excluded.at >= read_receipts.at',
      [
        accountId.value,
        messageId,
        recipient.toLowerCase(),
        disposition,
        (at ?? DateTime.now()).toUtc().millisecondsSinceEpoch,
      ],
    );
    return true;
  }

  /// The receipts for one sent message, oldest first.
  List<ReadReceipt> forMessage(AccountId accountId, String messageId) => [
    for (final row in _db.select(
      'SELECT recipient, disposition, at FROM read_receipts '
      'WHERE account_id = ? AND message_id_header = ? ORDER BY at, recipient',
      [accountId.value, messageId],
    ))
      _fromRow(row),
  ];

  /// Ids of stored messages in [mailboxId] that look like read receipts
  /// (from their Content-Type) and haven't been read for one yet.
  List<MessageId> unreadReports(MailboxId mailboxId, {int limit = 50}) => [
    for (final row in _db.select(
      'SELECT m.id FROM messages m JOIN message_headers h ON h.message_id = m.id '
      "WHERE m.mailbox_id = ? AND h.name = 'content-type' "
      "AND lower(h.value) LIKE '%multipart/report%' "
      "AND lower(h.value) LIKE '%disposition-notification%' "
      'AND NOT EXISTS (SELECT 1 FROM processed_reports p WHERE p.message_id = m.id) '
      'ORDER BY m.received_at DESC LIMIT ?',
      [mailboxId.value, limit.clamp(1, 500)],
    ))
      MessageId(row['id'] as int),
  ];

  void markReportRead(MessageId messageId) => _db.execute(
    'INSERT OR IGNORE INTO processed_reports (message_id) VALUES (?)',
    [messageId.value],
  );

  /// Reads every report of [mailboxId] again on the next pass (after the
  /// way they are matched improved).
  void rereadReports(MailboxId mailboxId) => _db.execute(
    'DELETE FROM processed_reports WHERE message_id IN '
    '(SELECT id FROM messages WHERE mailbox_id = ?)',
    [mailboxId.value],
  );

  /// Remembers that [recipient]'s receipt for [messageId] is the stored
  /// message [reportId], so it can be opened from the sent message.
  void linkReport(
    AccountId accountId,
    String messageId, {
    required String recipient,
    required MessageId reportId,
  }) {
    final links = _links(accountId)
      ..remove(_linkKey(messageId, recipient))
      ..[_linkKey(messageId, recipient)] = reportId.value;
    while (links.length > maxLinks) {
      links.remove(links.keys.first);
    }
    _linksFor(accountId).write(_settings, links);
  }

  /// The stored id of [recipient]'s receipt for [messageId], if known.
  MessageId? reportFor(
    AccountId accountId,
    String messageId,
    String recipient,
  ) =>
      switch (_links(accountId)[_linkKey(messageId, recipient.toLowerCase())]) {
        final id? => MessageId(id),
        null => null,
      };

  /// One account's links, as a JSON object: [_linkKey] to report id.
  static JsonSetting<Map<String, int>> _linksFor(AccountId accountId) =>
      JsonSetting(
        'receipts.reports.${accountId.value}',
        fallback: const {},
        fromJson: _linksFromJson,
        toJson: _linksToJson,
      );

  static Map<String, int>? _linksFromJson(Object? json) =>
      json is Map<String, Object?>
      ? {
          for (final MapEntry(:key, :value) in json.entries)
            if (value is int) key: value,
        }
      : null;

  static Object? _linksToJson(Map<String, int> links) => links;

  static String _linkKey(String messageId, String recipient) =>
      '$messageId ${recipient.toLowerCase()}';

  Map<String, int> _links(AccountId accountId) => {
    ..._linksFor(accountId).read(_settings),
  };

  static ReadReceipt _fromRow(Row row) => ReadReceipt(
    recipient: row['recipient'] as String,
    disposition: row['disposition'] as String,
    at: DateTime.fromMillisecondsSinceEpoch(row['at'] as int, isUtc: true),
  );
}
