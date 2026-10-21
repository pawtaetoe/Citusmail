// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../database/mail_database.dart';
import '../model/message.dart';
import 'category_refresh.dart';
import 'search_query.dart';

/// Which messages to list. Results are newest first; page with [before].
final class MessageQuery {
  const MessageQuery({
    this.mailboxIds,
    this.accountIds,
    this.inboxesOnly = false,
    this.category,
    this.unreadOnly = false,
    this.before,
    this.limit = 50,
  });

  /// The unified inbox of one category across all accounts.
  const MessageQuery.unified(
    MessageCategory this.category, {
    this.before,
    this.limit = 50,
  }) : mailboxIds = null,
       accountIds = null,
       inboxesOnly = true,
       unreadOnly = false;

  final List<int>? mailboxIds;
  final List<int>? accountIds;

  /// Only messages in each account's INBOX.
  final bool inboxesOnly;
  final MessageCategory? category;
  final bool unreadOnly;

  /// Keyset paging: only messages older than this one.
  final StoredMessage? before;
  final int limit;
}

/// Messages, their addresses, selected headers, bodies and search index.
final class MessageRepository {
  MessageRepository(this._db);

  final MailDatabase _db;

  static const _columns =
      'm.id, m.mailbox_id, b.account_id, m.uid, m.message_id_header, m.in_reply_to, '
      'm.thread_references, m.subject, m.from_name, m.from_address, m.sent_at, m.received_at, m.size, '
      'm.flags, m.keywords, m.mod_seq, m.has_attachments, m.category, m.category_source, m.snippet, m.list_id';
  static const _from =
      'FROM messages m JOIN mailboxes b ON b.id = m.mailbox_id';

  /// Inserts or updates summaries by UID, in one transaction. The summary
  /// carries the automatic category; the category shown also follows the
  /// user's choices (see [CategoryRefresh]), which rules never overwrite.
  void upsertSummaries(int mailboxId, List<MessageSummary> summaries) =>
      _db.transaction(() {
        for (final s in summaries) {
          final id =
              _db
                      .select(
                        'INSERT INTO messages (mailbox_id, uid, message_id_header, in_reply_to, thread_references, '
                        'subject, from_name, from_address, sent_at, received_at, size, flags, keywords, mod_seq, '
                        'has_attachments, auto_category, auto_source, category, category_source, list_id, snippet) '
                        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
                        'ON CONFLICT (mailbox_id, uid) DO UPDATE SET '
                        'message_id_header = excluded.message_id_header, in_reply_to = excluded.in_reply_to, '
                        'thread_references = excluded.thread_references, subject = excluded.subject, '
                        'from_name = excluded.from_name, from_address = excluded.from_address, '
                        'sent_at = excluded.sent_at, received_at = excluded.received_at, size = excluded.size, '
                        'flags = excluded.flags, keywords = excluded.keywords, mod_seq = excluded.mod_seq, '
                        'has_attachments = excluded.has_attachments, snippet = excluded.snippet, '
                        'auto_category = excluded.auto_category, auto_source = excluded.auto_source, '
                        'list_id = excluded.list_id '
                        'RETURNING id',
                        [
                          mailboxId,
                          s.uid,
                          s.messageId,
                          s.inReplyTo,
                          s.references.join(' '),
                          s.subject,
                          s.from?.displayName,
                          s.from?.address,
                          s.sentAt?.toUtc().millisecondsSinceEpoch,
                          s.receivedAt.toUtc().millisecondsSinceEpoch,
                          s.size,
                          s.flags.bits,
                          s.flags.keywords.join(' '),
                          s.modSeq,
                          s.hasAttachments ? 1 : 0,
                          s.category.name,
                          s.categorySource.name,
                          s.category.name,
                          s.categorySource.name,
                          s.listId,
                          s.snippet,
                        ],
                      )
                      .first
                      .columnAt(0)
                  as int;
          CategoryRefresh.byId(_db, id);
          _replaceAddresses(id, s);
          _replaceHeaders(id, s.headers);
          _indexSummary(id, s);
        }
      });

  /// Updates flags (and mod-sequences) of messages by UID.
  void updateFlags(
    int mailboxId,
    List<({int uid, MessageFlags flags, int? modSeq})> changes,
  ) => _db.transaction(
    () => _db.executeMany(
      'UPDATE messages SET flags = ?, keywords = ?, mod_seq = coalesce(?, mod_seq) '
      'WHERE mailbox_id = ? AND uid = ?',
      [
        for (final c in changes)
          [
            c.flags.bits,
            c.flags.keywords.join(' '),
            c.modSeq,
            mailboxId,
            c.uid,
          ],
      ],
    ),
  );

  /// Removes messages by UID (with addresses, headers, body and index).
  void removeUids(int mailboxId, Iterable<int> uids) => _db.transaction(
    () => _db.executeMany(
      'DELETE FROM messages WHERE mailbox_id = ? AND uid = ?',
      [
        for (final uid in uids) [mailboxId, uid],
      ],
    ),
  );

  /// All cached UIDs of a folder, ascending.
  List<int> uids(int mailboxId) => _db
      .select('SELECT uid FROM messages WHERE mailbox_id = ? ORDER BY uid', [
        mailboxId,
      ])
      .map((r) => r.columnAt(0) as int)
      .toList(growable: false);

  /// Cached flags of every message in a folder, by UID.
  Map<int, MessageFlags> flagsByUid(int mailboxId) => {
    for (final row in _db.select(
      'SELECT uid, flags, keywords FROM messages WHERE mailbox_id = ?',
      [mailboxId],
    ))
      row['uid'] as int: MessageFlags(
        row['flags'] as int,
        Set.unmodifiable(
          (row['keywords'] as String).split(' ').where((k) => k.isNotEmpty),
        ),
      ),
  };

  int? lowestUid(int mailboxId) =>
      _db
              .select('SELECT min(uid) FROM messages WHERE mailbox_id = ?', [
                mailboxId,
              ])
              .first
              .columnAt(0)
          as int?;

  int? highestUid(int mailboxId) =>
      _db
              .select('SELECT max(uid) FROM messages WHERE mailbox_id = ?', [
                mailboxId,
              ])
              .first
              .columnAt(0)
          as int?;

  StoredMessage? byId(int id) {
    final rows = _db.select('SELECT $_columns $_from WHERE m.id = ?', [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  StoredMessage? byUid(int mailboxId, int uid) {
    final rows = _db.select(
      'SELECT $_columns $_from WHERE m.mailbox_id = ? AND m.uid = ?',
      [mailboxId, uid],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Messages matching [query], newest first.
  List<StoredMessage> list(MessageQuery query) {
    final where = <String>[];
    final args = <Object?>[];
    if (query.mailboxIds case final ids?) {
      where.add('m.mailbox_id IN (${List.filled(ids.length, '?').join(', ')})');
      args.addAll(ids);
    }
    if (query.accountIds case final ids?) {
      where.add('b.account_id IN (${List.filled(ids.length, '?').join(', ')})');
      args.addAll(ids);
    }
    if (query.inboxesOnly) where.add("upper(b.encoded_name) = 'INBOX'");
    if (query.category case final category?) {
      where.add('m.category = ?');
      args.add(category.name);
    }
    if (query.unreadOnly) where.add('(m.flags & ${MessageFlags.seenBit}) = 0');
    if (query.before case final before?) {
      where.add('(m.received_at < ? OR (m.received_at = ? AND m.id < ?))');
      final at = before.receivedAt.millisecondsSinceEpoch;
      args.addAll([at, at, before.id]);
    }
    final sql = StringBuffer('SELECT $_columns $_from');
    if (where.isNotEmpty) sql.write(' WHERE ${where.join(' AND ')}');
    sql.write(' ORDER BY m.received_at DESC, m.id DESC LIMIT ?');
    args.add(query.limit.clamp(1, 500));
    return _db
        .select(sql.toString(), args)
        .map(_fromRow)
        .toList(growable: false);
  }

  /// Unread messages in a folder.
  int unreadCount(int mailboxId) =>
      _db
              .select(
                'SELECT count(*) FROM messages WHERE mailbox_id = ? AND (flags & ${MessageFlags.seenBit}) = 0',
                [mailboxId],
              )
              .first
              .columnAt(0)
          as int;

  /// Searches subject, participants and downloaded bodies. Typed text is
  /// always literal (see [SearchQuery]).
  List<StoredMessage> search(String text, {int limit = 100}) {
    final query = SearchQuery.parse(text);
    if (query == null) return const [];
    final capped = limit.clamp(1, 500);
    if (query.usesIndex) {
      return _db
          .select(
            'SELECT $_columns $_from JOIN message_search s ON s.rowid = m.id '
            'WHERE message_search MATCH ? ORDER BY m.received_at DESC, m.id DESC LIMIT ?',
            [query.toFtsMatch(), capped],
          )
          .map(_fromRow)
          .toList(growable: false);
    }
    // Short terms: substring match on subject and sender (no index).
    final patterns = query.toLikePatterns();
    final conditions = patterns
        .map(
          (_) => r"(m.subject LIKE ? ESCAPE '\' OR m.from_name LIKE ? ESCAPE '\' OR m.from_address LIKE ? ESCAPE '\')",
        )
        .join(' AND ');
    return _db
        .select(
          'SELECT $_columns $_from WHERE $conditions ORDER BY m.received_at DESC, m.id DESC LIMIT ?',
          [
            for (final p in patterns) ...[p, p, p],
            capped,
          ],
        )
        .map(_fromRow)
        .toList(growable: false);
  }

  /// Addresses of one kind (from, to, cc...), in order.
  List<MailAddress> addresses(int messageId, String kind) => _db
      .select(
        'SELECT name, address FROM message_addresses WHERE message_id = ? AND kind = ? ORDER BY position',
        [messageId, kind],
      )
      .map((r) => _address(r['name'] as String?, r['address'] as String)!)
      .toList(growable: false);

  /// Stored headers of a message: lower-case name -> values.
  Map<String, List<String>> headers(int messageId) {
    final result = <String, List<String>>{};
    for (final row in _db.select(
      'SELECT name, value FROM message_headers WHERE message_id = ? ORDER BY name, position',
      [messageId],
    )) {
      result
          .putIfAbsent(row['name'] as String, () => [])
          .add(row['value'] as String);
    }
    return result;
  }

  /// Stores the full raw message and indexes its text for search.
  void saveBody(
    int messageId,
    Uint8List raw, {
    required String searchableText,
  }) => _db.transaction(() {
    _db.execute(
      'INSERT INTO message_bodies (message_id, raw, fetched_at) VALUES (?, ?, ?) '
      'ON CONFLICT (message_id) DO UPDATE SET raw = excluded.raw, fetched_at = excluded.fetched_at',
      [messageId, raw, DateTime.now().toUtc().millisecondsSinceEpoch],
    );
    final existing = _db.select(
      'SELECT subject, participants FROM message_search WHERE rowid = ?',
      [messageId],
    );
    final subject = existing.isEmpty
        ? ''
        : existing.first['subject'] as String? ?? '';
    final participants = existing.isEmpty
        ? ''
        : existing.first['participants'] as String? ?? '';
    _db.execute('DELETE FROM message_search WHERE rowid = ?', [messageId]);
    _db.execute(
      'INSERT INTO message_search (rowid, subject, participants, body) VALUES (?, ?, ?, ?)',
      [messageId, subject, participants, searchableText],
    );
  });

  /// The full raw message, if downloaded.
  Uint8List? body(int messageId) {
    final rows = _db.select(
      'SELECT raw FROM message_bodies WHERE message_id = ?',
      [messageId],
    );
    return rows.isEmpty ? null : rows.first.columnAt(0) as Uint8List;
  }

  /// Up to [limit] messages with an id above [afterId], in id order, with
  /// what sorting needs. For re-sorting stored mail without downloading.
  List<SortableMessage> sortable({int afterId = 0, int limit = 500}) {
    final rows = _db.select(
      'SELECT m.id, m.from_name, m.from_address, b.special_use '
      'FROM messages m JOIN mailboxes b ON b.id = m.mailbox_id '
      'WHERE m.id > ? ORDER BY m.id LIMIT ?',
      [afterId, limit.clamp(1, 5000)],
    );
    if (rows.isEmpty) return const [];
    final ids = [for (final r in rows) r['id'] as int];
    final headers = <int, Map<String, List<String>>>{};
    for (final row in _db.select(
      'SELECT message_id, name, value FROM message_headers '
      'WHERE message_id BETWEEN ? AND ? ORDER BY message_id, name, position',
      [ids.first, ids.last],
    )) {
      headers
          .putIfAbsent(row['message_id'] as int, () => {})
          .putIfAbsent(row['name'] as String, () => [])
          .add(row['value'] as String);
    }
    return [
      for (final row in rows)
        SortableMessage(
          id: row['id'] as int,
          from: _address(
            row['from_name'] as String?,
            row['from_address'] as String?,
          ),
          headers: headers[row['id'] as int] ?? const {},
          mailboxUse: switch (row['special_use'] as String?) {
            final use? => SpecialUse.values.asNameMap()[use],
            null => null,
          },
        ),
    ];
  }

  /// Stores new automatic decisions (e.g. after the rules changed). The
  /// user's choices still take precedence.
  void updateAutomaticCategories(List<AutomaticCategory> decisions) =>
      _db.transaction(() {
        for (final d in decisions) {
          _db.execute(
            'UPDATE messages SET auto_category = ?, auto_source = ?, list_id = ? WHERE id = ?',
            [d.category.name, d.source.name, d.listId, d.messageId],
          );
          CategoryRefresh.byId(_db, d.messageId);
        }
      });

  // ---------------------------------------------------------------------

  void _replaceAddresses(int messageId, MessageSummary s) {
    _db.execute('DELETE FROM message_addresses WHERE message_id = ?', [
      messageId,
    ]);
    final rows = <List<Object?>>[];
    void add(String kind, List<MailAddress> list) {
      for (var i = 0; i < list.length; i++) {
        rows.add([messageId, kind, i, list[i].displayName, list[i].address]);
      }
    }

    add('from', [?s.from]);
    add('sender', s.sender);
    add('reply_to', s.replyTo);
    add('to', s.to);
    add('cc', s.cc);
    add('bcc', s.bcc);
    _db.executeMany(
      'INSERT INTO message_addresses (message_id, kind, position, name, address) VALUES (?, ?, ?, ?, ?)',
      rows,
    );
  }

  void _replaceHeaders(int messageId, Map<String, List<String>> headers) {
    _db.execute('DELETE FROM message_headers WHERE message_id = ?', [
      messageId,
    ]);
    _db.executeMany(
      'INSERT INTO message_headers (message_id, name, position, value) VALUES (?, ?, ?, ?)',
      [
        for (final MapEntry(key: name, value: values) in headers.entries)
          for (var i = 0; i < values.length; i++)
            [messageId, name.toLowerCase(), i, values[i]],
      ],
    );
  }

  /// Indexes subject and participants, keeping any body text already
  /// indexed for this message.
  void _indexSummary(int messageId, MessageSummary s) {
    final existing = _db.select(
      'SELECT body FROM message_search WHERE rowid = ?',
      [messageId],
    );
    final body = existing.isEmpty
        ? ''
        : existing.first['body'] as String? ?? '';
    final participants = [
      ?s.from,
      ...s.to,
      ...s.cc,
    ].map((a) => '${a.displayName ?? ''} ${a.address}').join(' ');
    _db.execute('DELETE FROM message_search WHERE rowid = ?', [messageId]);
    _db.execute(
      'INSERT INTO message_search (rowid, subject, participants, body) VALUES (?, ?, ?, ?)',
      [messageId, s.subject ?? '', participants, body],
    );
  }

  /// Splits a stored `MailAddress.address` back into its parts, undoing
  /// the quoting of a local part such as `"john doe"`, so that `.address`
  /// gives back exactly the stored text.
  static MailAddress? _address(String? name, String? address) {
    if (address == null) return null;
    final at = address.lastIndexOf('@');
    var local = at > 0 ? address.substring(0, at) : address;
    if (local.length >= 2 && local.startsWith('"') && local.endsWith('"')) {
      local = local
          .substring(1, local.length - 1)
          .replaceAllMapped(RegExp(r'\\(.)'), (m) => m.group(1)!);
    }
    return MailAddress(
      displayName: name,
      localPart: local,
      domain: at > 0 ? address.substring(at + 1) : '',
    );
  }

  static StoredMessage _fromRow(Row row) {
    final from = _address(
      row['from_name'] as String?,
      row['from_address'] as String?,
    );
    final sentAt = row['sent_at'] as int?;
    final references = (row['thread_references'] as String?) ?? '';
    final keywords = (row['keywords'] as String)
        .split(' ')
        .where((k) => k.isNotEmpty)
        .toSet();
    return StoredMessage(
      id: row['id'] as int,
      mailboxId: row['mailbox_id'] as int,
      accountId: row['account_id'] as int,
      uid: row['uid'] as int,
      messageId: row['message_id_header'] as String?,
      inReplyTo: row['in_reply_to'] as String?,
      references: references.isEmpty ? const [] : references.split(' '),
      subject: row['subject'] as String?,
      from: from,
      sentAt: sentAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(sentAt, isUtc: true),
      receivedAt: DateTime.fromMillisecondsSinceEpoch(
        row['received_at'] as int,
        isUtc: true,
      ),
      size: row['size'] as int,
      flags: MessageFlags(row['flags'] as int, Set.unmodifiable(keywords)),
      modSeq: row['mod_seq'] as int?,
      hasAttachments: row['has_attachments'] == 1,
      category: MessageCategory.values.byName(row['category'] as String),
      categorySource: CategorySource.values.byName(
        row['category_source'] as String,
      ),
      snippet: row['snippet'] as String?,
      listId: row['list_id'] as String?,
    );
  }
}
