// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';

import '../database/mail_database.dart';

/// What the stored mail says about writing to one address: when that
/// person's mail was dated, how quickly they answered, whether the user
/// knows the address at all. For the hints in the compose window. Every
/// query starts from an index on the address, so each costs about as
/// much as that person's mail, not the whole mailbox.
final class CorrespondenceRepository {
  CorrespondenceRepository(this._db);

  final MailDatabase _db;

  /// How much of a downloaded message is read for its Date header: the
  /// header section of most mail fits.
  static const _headBytes = 16 * 1024;

  /// Folders whose mail was not sent to the user by someone else.
  static const _notTheirs =
      "(b.special_use IS NULL OR b.special_use NOT IN ('sent', 'drafts'))";

  /// The dates of the newest [limit] messages [address] (any case) sent
  /// the user, each message once, newest first: from the kept `date`
  /// header, else from the downloaded message. A message whose Date is
  /// on neither is left out.
  List<MailDate> recentDates(String address, {int limit = 10}) {
    final rows = _db.select(
      'SELECT m.message_id_header AS mid, '
      "(SELECT value FROM message_headers h WHERE h.message_id = m.id AND h.name = 'date' "
      'ORDER BY position LIMIT 1) AS date, '
      'm.id AS id '
      'FROM messages m JOIN mailboxes b ON b.id = m.mailbox_id '
      'WHERE m.from_address = ? COLLATE NOCASE AND $_notTheirs '
      'ORDER BY coalesce(m.sent_at, m.received_at) DESC, m.id DESC LIMIT ?',
      [address, (limit * 3).clamp(1, 300)],
    );
    final seen = <String>{};
    final dates = <MailDate>[];
    for (final row in rows) {
      final mid = row['mid'] as String?;
      if (mid != null && !seen.add(mid)) continue;
      final value = row['date'] as String? ?? _dateInBody(row['id'] as int);
      final date = value == null ? null : const MailDateParser().parse(value);
      if (date != null) dates.add(date);
      if (dates.length == limit) break;
    }
    return dates;
  }

  /// The Date header of a downloaded message, read from its start.
  String? _dateInBody(int messageId) {
    final rows = _db.select(
      'SELECT substr(raw, 1, ?) FROM message_bodies WHERE message_id = ?',
      [_headBytes, messageId],
    );
    if (rows.isEmpty) return null;
    final head = rows.first.columnAt(0);
    if (head is! Uint8List) return null;
    return const HeaderParser().parse(head).headers.value('date');
  }

  /// How long [address] (any case) took to answer the user: for each of
  /// their newest [limit] replies to a message in a Sent folder (its
  /// In-Reply-To, or without one its References), the time from the
  /// user's message to theirs. Each reply once; newest first.
  List<Duration> replyDelays(String address, {int limit = 20}) {
    final rows = _db.select(
      'SELECT r.message_id_header AS mid, '
      'coalesce(r.sent_at, r.received_at) AS answered, '
      'coalesce(s.sent_at, s.received_at) AS asked '
      'FROM messages r JOIN mailboxes b ON b.id = r.mailbox_id '
      'JOIN messages s ON s.message_id_header = r.in_reply_to '
      "JOIN mailboxes sb ON sb.id = s.mailbox_id AND sb.special_use = 'sent' "
      'WHERE r.from_address = ? COLLATE NOCASE AND $_notTheirs '
      'UNION ALL '
      'SELECT r.message_id_header, coalesce(r.sent_at, r.received_at), '
      'coalesce(s.sent_at, s.received_at) '
      'FROM messages r JOIN mailboxes b ON b.id = r.mailbox_id '
      'JOIN message_references x ON x.message_id = r.id '
      'JOIN messages s ON s.message_id_header = x.ref '
      "JOIN mailboxes sb ON sb.id = s.mailbox_id AND sb.special_use = 'sent' "
      'WHERE r.from_address = ? COLLATE NOCASE AND r.in_reply_to IS NULL '
      'AND $_notTheirs '
      'ORDER BY 2 DESC LIMIT ?',
      [address, address, (limit * 10).clamp(1, 2000)],
    );
    // A reply answers the newest of the user's messages before it.
    final asked = <String, int>{};
    final answered = <String, int>{};
    for (final row in rows) {
      final mid = row['mid'] as String?;
      final at = row['answered'] as int, from = row['asked'] as int;
      if (mid == null || from >= at) continue;
      if (!answered.containsKey(mid) && answered.length == limit) break;
      answered[mid] = at;
      final before = asked[mid];
      if (before == null || from > before) asked[mid] = from;
    }
    return [
      for (final MapEntry(:key, :value) in answered.entries)
        Duration(milliseconds: value - asked[key]!),
    ];
  }

  /// Whether [address] (any case) is in any stored message: as its
  /// sender or one of its recipients, in any folder but Drafts (where the
  /// message being written may be).
  bool knows(String address) => _db.select(
    'SELECT 1 FROM message_addresses a '
    'JOIN messages m ON m.id = a.message_id '
    'JOIN mailboxes b ON b.id = m.mailbox_id '
    'WHERE a.address = ? COLLATE NOCASE '
    "AND (b.special_use IS NULL OR b.special_use != 'drafts') LIMIT 1",
    [address],
  ).isNotEmpty;

  /// Whether [address] is a mailing list: mail sent to it, or from it,
  /// came with a List-Id naming it (`dev@lists.example` is
  /// `dev.lists.example`).
  bool isList(String address) {
    final id = address.toLowerCase().replaceFirst('@', '.');
    return _db.select(
      'SELECT 1 FROM message_addresses a '
      'JOIN messages m ON m.id = a.message_id '
      "WHERE a.address = ? COLLATE NOCASE AND a.kind IN ('from', 'to', 'cc') "
      'AND m.list_id = ? LIMIT 1',
      [address, id],
    ).isNotEmpty;
  }

  /// The name [address] (any case) signs their mail with: the newest
  /// message from them that has one. Null if none does.
  String? nameOf(String address) {
    final rows = _db.select(
      'SELECT from_name FROM messages '
      "WHERE from_address = ? COLLATE NOCASE AND coalesce(from_name, '') != '' "
      'ORDER BY received_at DESC LIMIT 1',
      [address],
    );
    return rows.isEmpty ? null : rows.first.columnAt(0) as String;
  }
}
