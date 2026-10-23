// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../database/mail_database.dart';
import '../model/message.dart';
import 'search_query.dart';
import 'section_sql.dart';

/// Which messages to list. Results are newest first; page with [before].
final class MessageQuery {
  const MessageQuery({
    this.mailboxIds,
    this.accountIds,
    this.inboxesOnly = false,
    this.category,
    this.section,
    this.unreadOnly = false,
    this.flaggedOnly = false,
    this.before,
    this.limit = 50,
  });

  /// One Smart Inbox section, across the inboxes of [accountIds] (or all
  /// accounts).
  const MessageQuery.smart(
    SmartSection this.section, {
    this.accountIds,
    this.before,
    this.limit = 50,
  }) : mailboxIds = null,
       inboxesOnly = true,
       category = null,
       unreadOnly = false,
       flaggedOnly = false;

  /// The classic inbox: every inbox message, newest first.
  const MessageQuery.inbox({this.accountIds, this.before, this.limit = 50})
    : mailboxIds = null,
      inboxesOnly = true,
      category = null,
      section = null,
      unreadOnly = false,
      flaggedOnly = false;

  final List<int>? mailboxIds;
  final List<int>? accountIds;

  /// Only messages in each account's INBOX.
  final bool inboxesOnly;
  final MessageCategory? category;
  final SmartSection? section;
  final bool unreadOnly;

  /// Only pinned (flagged) messages.
  final bool flaggedOnly;

  /// Keyset paging: only messages older than this one.
  final StoredMessage? before;
  final int limit;

  /// The same query, continuing after [last].
  MessageQuery after(StoredMessage last) => MessageQuery(
    mailboxIds: mailboxIds,
    accountIds: accountIds,
    inboxesOnly: inboxesOnly,
    category: category,
    section: section,
    unreadOnly: unreadOnly,
    flaggedOnly: flaggedOnly,
    before: last,
    limit: limit,
  );
}

/// How many messages a Smart Inbox section has.
final class SectionCount {
  const SectionCount(this.total, this.unread);

  static const empty = SectionCount(0, 0);

  final int total;
  final int unread;
}

/// Messages, their addresses, selected headers, bodies and search index.
final class MessageRepository {
  MessageRepository(this._db);

  final MailDatabase _db;

  static const _columns =
      'm.id, m.mailbox_id, b.account_id, m.uid, m.message_id_header, m.in_reply_to, '
      'm.thread_references, m.subject, m.from_name, m.from_address, m.sent_at, m.received_at, m.size, '
      'm.flags, m.keywords, m.mod_seq, m.has_attachments, m.category, m.category_source, m.snippet, m.list_id, m.section';
  static const _from =
      'FROM messages m JOIN mailboxes b ON b.id = m.mailbox_id';

  static String _placeholders(int count) => List.filled(count, '?').join(', ');

  /// Inserts or updates summaries by UID, in one transaction.
  void upsertSummaries(int mailboxId, List<MessageSummary> summaries) =>
      _db.transaction(() {
        final ids = <int>[];
        for (final s in summaries) {
          final id =
              _db
                      .select(
                        'INSERT INTO messages (mailbox_id, uid, message_id_header, in_reply_to, thread_references, '
                        'subject, from_name, from_address, sent_at, received_at, size, flags, keywords, mod_seq, '
                        'has_attachments, category, category_source, list_id, snippet) '
                        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
                        'ON CONFLICT (mailbox_id, uid) DO UPDATE SET '
                        'message_id_header = excluded.message_id_header, in_reply_to = excluded.in_reply_to, '
                        'thread_references = excluded.thread_references, subject = excluded.subject, '
                        'from_name = excluded.from_name, from_address = excluded.from_address, '
                        'sent_at = excluded.sent_at, received_at = excluded.received_at, size = excluded.size, '
                        'flags = excluded.flags, keywords = excluded.keywords, mod_seq = excluded.mod_seq, '
                        'has_attachments = excluded.has_attachments, snippet = excluded.snippet, '
                        'category = excluded.category, category_source = excluded.category_source, '
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
                          s.category.storageName,
                          s.categorySource.name,
                          s.listId,
                          s.snippet,
                        ],
                      )
                      .first
                      .columnAt(0)
                  as int;
          _replaceAddresses(id, s);
          _replaceHeaders(id, s.headers);
          _indexSummary(id, s);
          ids.add(id);
        }
        SectionSql.refreshIds(_db, ids);
        _refreshRelated(mailboxId, summaries);
      });

  /// Mail in Sent or the Important folder changes the section of other
  /// messages: those from the people written to, replies to the sent
  /// messages, or the same message in the inbox.
  void _refreshRelated(int mailboxId, List<MessageSummary> summaries) {
    final use = _db.select('SELECT special_use FROM mailboxes WHERE id = ?', [
      mailboxId,
    ]).firstOrNull?['special_use'];
    if (use == 'sent') {
      final recipients = {
        for (final s in summaries)
          for (final a in [...s.to, ...s.cc, ...s.bcc]) a.address.toLowerCase(),
      };
      for (final address in recipients) {
        SectionSql.refresh(_db, 'from_address = ? COLLATE NOCASE', [address]);
      }
      for (final s in summaries) {
        if (s.messageId case final id?) {
          SectionSql.refresh(_db, 'in_reply_to = ?', [id]);
        }
      }
    } else if (use == 'important') {
      for (final s in summaries) {
        if (s.messageId case final id?) {
          SectionSql.refresh(_db, 'message_id_header = ?', [id]);
        }
      }
    }
  }

  /// Updates flags (and mod-sequences) of messages by UID.
  void updateFlags(
    int mailboxId,
    List<({int uid, MessageFlags flags, int? modSeq})> changes,
  ) => _db.transaction(() {
    _db.executeMany(
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
    );
    // Pinning (and the $Important keyword) changes the section.
    for (final c in changes) {
      SectionSql.refresh(_db, 'mailbox_id = ? AND uid = ?', [mailboxId, c.uid]);
    }
  });

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
  ///
  /// Each folder is read through an index in date order and only a page
  /// is read, so the cost depends on the page size, not on how much mail
  /// there is. Several folders (the unified inbox) are read one by one and
  /// merged.
  List<StoredMessage> list(MessageQuery query) {
    final limit = query.limit.clamp(1, 500);
    List<int>? folders = query.mailboxIds;
    if (query.inboxesOnly) {
      final inboxes = inboxIds(accountIds: query.accountIds);
      folders = folders == null
          ? inboxes
          : [
              for (final id in folders)
                if (inboxes.contains(id)) id,
            ];
    }
    if (folders == null) return _listPage(query, null, limit);
    if (folders.length == 1) return _listPage(query, folders.single, limit);
    final merged = [for (final id in folders) ..._listPage(query, id, limit)]
      ..sort(_newestFirst);
    return merged.length > limit ? merged.sublist(0, limit) : merged;
  }

  static int _newestFirst(StoredMessage a, StoredMessage b) {
    final byDate = b.receivedAt.compareTo(a.receivedAt);
    return byDate != 0 ? byDate : b.id.compareTo(a.id);
  }

  /// The SQL and arguments of one page (in one folder, or all).
  (String, List<Object?>) _pageSql(
    MessageQuery query,
    int? mailboxId,
    int limit,
  ) {
    final where = <String>[];
    final args = <Object?>[];
    if (mailboxId != null) {
      where.add('m.mailbox_id = ?');
      args.add(mailboxId);
    }
    if (query.accountIds case final ids? when mailboxId == null) {
      where.add('b.account_id IN (${_placeholders(ids.length)})');
      args.addAll(ids);
    }
    if (query.section case final section?) {
      where.add('m.section = ?');
      args.add(section.name);
    }
    if (query.category case final category?) {
      where.add('m.category = ?');
      args.add(category.storageName);
    }
    // Same expressions as the partial indexes, so they can be used.
    if (query.unreadOnly) where.add('(m.flags & 1) = 0');
    if (query.flaggedOnly) where.add('(m.flags & 4) != 0');
    if (query.before case final before?) {
      where.add('(m.received_at < ? OR (m.received_at = ? AND m.id < ?))');
      final at = before.receivedAt.millisecondsSinceEpoch;
      args.addAll([at, at, before.id]);
    }
    final sql = StringBuffer('SELECT $_columns $_from');
    if (where.isNotEmpty) sql.write(' WHERE ${where.join(' AND ')}');
    sql.write(' ORDER BY m.received_at DESC, m.id DESC LIMIT ?');
    args.add(limit);
    return (sql.toString(), args);
  }

  List<StoredMessage> _listPage(MessageQuery query, int? mailboxId, int limit) {
    final (sql, args) = _pageSql(query, mailboxId, limit);
    return _db.select(sql, args).map(_fromRow).toList(growable: false);
  }

  /// How SQLite runs one page of [query] (for tests that make sure lists
  /// stay index reads).
  List<String> debugQueryPlan(MessageQuery query, {int? mailboxId}) {
    final (sql, args) = _pageSql(query, mailboxId, query.limit);
    return [
      for (final row in _db.select('EXPLAIN QUERY PLAN $sql', args))
        row['detail'] as String,
    ];
  }

  /// Unread messages in a folder.
  int unreadCount(int mailboxId) =>
      _db
              .select(
                'SELECT count(*) FROM messages WHERE mailbox_id = ? AND (flags & 1) = 0',
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

  /// Addresses matching [text] (in the address or name) for recipient
  /// suggestions: people the user has written to first, then people who
  /// wrote to them (not newsletters or notifications). Most used first.
  List<MailAddress> suggestAddresses(String text, {int limit = 8}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const [];
    // Typed text is literal: escape LIKE wildcards.
    final escaped = trimmed.replaceAllMapped(
      RegExp(r'[\\%_]'),
      (m) => '\\${m[0]}',
    );
    final pattern = '%$escaped%';
    final rows = _db.select(
      'SELECT address, max(name) AS name, sum(weight) AS score FROM ('
      'SELECT a.address AS address, a.name AS name, 10 AS weight FROM message_addresses a '
      'JOIN messages m ON m.id = a.message_id JOIN mailboxes b ON b.id = m.mailbox_id '
      "WHERE b.special_use = 'sent' AND a.kind IN ('to', 'cc', 'bcc') "
      'UNION ALL '
      'SELECT from_address, from_name, 1 FROM messages '
      'WHERE from_address IS NOT NULL AND category = ?'
      r") WHERE address LIKE ? ESCAPE '\' OR name LIKE ? ESCAPE '\' "
      'GROUP BY address COLLATE NOCASE ORDER BY score DESC, address LIMIT ?',
      [
        MessageCategory.general.storageName,
        pattern,
        pattern,
        limit.clamp(1, 50),
      ],
    );
    return [
      for (final r in rows)
        ?_address(r['name'] as String?, r['address'] as String?),
    ];
  }

  /// Inbox messages of [accountId] from one list (by [listId]) or, for
  /// mail without one, from one sender: what "archive earlier mail" acts
  /// on after unsubscribing. Newest first, at most [limit].
  List<StoredMessage> inboxFromList(
    int accountId, {
    String? listId,
    String? fromAddress,
    int limit = 2000,
  }) {
    final inbox = inboxIds(accountIds: [accountId]);
    if (inbox.isEmpty || (listId == null && fromAddress == null)) {
      return const [];
    }
    final match = listId != null
        ? 'm.list_id = ?'
        : 'm.from_address = ? COLLATE NOCASE';
    return _db
        .select(
          'SELECT $_columns $_from WHERE m.mailbox_id = ? AND $match '
          'ORDER BY m.received_at DESC, m.id DESC LIMIT ?',
          [
            inbox.first,
            listId?.toLowerCase() ?? fromAddress,
            limit.clamp(1, 5000),
          ],
        )
        .map(_fromRow)
        .toList(growable: false);
  }

  /// Inbox messages of [accountId] from [domain] or its subdomains, newest
  /// first, at most [limit] (what "block everyone at" moves).
  List<StoredMessage> inboxFromDomain(
    int accountId,
    String domain, {
    int limit = 2000,
  }) {
    final inbox = inboxIds(accountIds: [accountId]);
    final d = domain.toLowerCase();
    if (inbox.isEmpty || !RegExp(r'^[a-z0-9.-]+$').hasMatch(d)) {
      return const [];
    }
    return _db
        .select(
          'SELECT $_columns $_from WHERE m.mailbox_id = ? '
          'AND (lower(m.from_address) LIKE ? OR lower(m.from_address) LIKE ?) '
          'ORDER BY m.received_at DESC, m.id DESC LIMIT ?',
          [inbox.first, '%@$d', '%.$d', limit.clamp(1, 5000)],
        )
        .map(_fromRow)
        .toList(growable: false);
  }

  /// Messages in [mailboxId] with Message-ID [messageId]
  /// (without brackets).
  List<StoredMessage> byMessageId(int mailboxId, String messageId) => _db
      .select(
        'SELECT $_columns $_from WHERE m.mailbox_id = ? AND m.message_id_header = ?',
        [mailboxId, messageId],
      )
      .map(_fromRow)
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

  /// The first (topmost) value of header [name] in each of the [limit]
  /// newest messages of [mailboxId], newest first; null for a message
  /// without one. Used to learn which server writes a header.
  List<String?> firstHeaderValues(
    int mailboxId,
    String name, {
    int limit = 100,
  }) => [
    for (final row in _db.select(
      'SELECT (SELECT value FROM message_headers h '
      '        WHERE h.message_id = m.id AND h.name = ? AND h.position = 0) AS value '
      'FROM messages m WHERE m.mailbox_id = ? '
      'ORDER BY m.received_at DESC, m.id DESC LIMIT ?',
      [name.toLowerCase(), mailboxId, limit.clamp(1, 500)],
    ))
      row['value'] as String?,
  ];

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

  /// Everything stored about messages [ids] (summary, addresses, headers,
  /// body, search text), to put them back with [restore] if the user
  /// undoes a move or delete within a few seconds.
  MessageSnapshot snapshot(List<int> ids) {
    List<Map<String, Object?>> rows(String table, String key) => [
      for (var i = 0; i < ids.length; i += 500)
        for (final row in _db.select(
          'SELECT * FROM $table WHERE $key IN (${_placeholders((ids.length - i).clamp(0, 500))})',
          ids.sublist(i, (i + 500).clamp(0, ids.length)),
        ))
          {for (final column in row.keys) column: row[column]},
    ];
    return MessageSnapshot._(
      messages: rows('messages', 'id'),
      addresses: rows('message_addresses', 'message_id'),
      headers: rows('message_headers', 'message_id'),
      bodies: rows('message_bodies', 'message_id'),
      search: [
        for (final row in _db.select(
          'SELECT rowid AS id, subject, participants, body FROM message_search WHERE rowid IN (${_placeholders(ids.length)})',
          ids,
        ))
          {for (final column in row.keys) column: row[column]},
      ],
    );
  }

  /// Puts back messages from a [snapshot]. A message whose folder is gone,
  /// or that is already back (its UID is in the folder again), is skipped.
  /// Returns the ids the messages have now (they may get new ids).
  Map<int, int> restore(MessageSnapshot snapshot) => _db.transaction(() {
    final newIds = <int, int>{};
    for (final row in snapshot.messages) {
      final oldId = row['id']! as int;
      final present = _db.select(
        'SELECT 1 FROM messages WHERE mailbox_id = ? AND uid = ?',
        [row['mailbox_id'], row['uid']],
      );
      final folder = _db.select('SELECT 1 FROM mailboxes WHERE id = ?', [
        row['mailbox_id'],
      ]);
      if (present.isNotEmpty || folder.isEmpty) continue;
      final idFree = _db.select('SELECT 1 FROM messages WHERE id = ?', [
        oldId,
      ]).isEmpty;
      final columns = [
        for (final c in row.keys)
          if (c != 'id' || idFree) c,
      ];
      _db.execute(
        'INSERT INTO messages (${columns.join(', ')}) VALUES (${_placeholders(columns.length)})',
        [for (final c in columns) row[c]],
      );
      newIds[oldId] = idFree ? oldId : _db.lastInsertRowId;
    }
    void copy(String table, List<Map<String, Object?>> rows) {
      for (final row in rows) {
        final id = newIds[row['message_id']];
        if (id == null) continue;
        final columns = row.keys.toList();
        _db.execute(
          'INSERT OR REPLACE INTO $table (${columns.join(', ')}) VALUES (${_placeholders(columns.length)})',
          [for (final c in columns) c == 'message_id' ? id : row[c]],
        );
      }
    }

    copy('message_addresses', snapshot.addresses);
    copy('message_headers', snapshot.headers);
    copy('message_bodies', snapshot.bodies);
    for (final row in snapshot.search) {
      final id = newIds[row['id']];
      if (id == null) continue;
      _db.execute('DELETE FROM message_search WHERE rowid = ?', [id]);
      _db.execute(
        'INSERT INTO message_search (rowid, subject, participants, body) VALUES (?, ?, ?, ?)',
        [id, row['subject'], row['participants'], row['body']],
      );
    }
    SectionSql.refreshIds(_db, newIds.values.toList());
    return newIds;
  });

  /// Stores new sorting decisions (e.g. after the rules changed).
  void updateCategories(List<CategoryDecision> decisions) =>
      _db.transaction(() {
        _db.executeMany(
          'UPDATE messages SET category = ?, category_source = ?, list_id = ? WHERE id = ?',
          [
            for (final d in decisions)
              [d.category.storageName, d.source.name, d.listId, d.messageId],
          ],
        );
        SectionSql.refreshIds(_db, [for (final d in decisions) d.messageId]);
      });

  /// Totals and unread counts of every Smart Inbox section, across the
  /// inboxes of [accountIds] (or all accounts). Reads the section index.
  Map<SmartSection, SectionCount> sectionCounts({List<int>? accountIds}) {
    final inboxes = inboxIds(accountIds: accountIds);
    final totals = {for (final s in SmartSection.values) s: 0};
    final unread = {for (final s in SmartSection.values) s: 0};
    if (inboxes.isEmpty) {
      return {for (final s in SmartSection.values) s: SectionCount.empty};
    }
    final where = 'mailbox_id IN (${_placeholders(inboxes.length)})';
    for (final row in _db.select(
      'SELECT section, count(*) AS n FROM messages WHERE $where GROUP BY section',
      inboxes,
    )) {
      totals[SmartSection.values.byName(row['section'] as String)] =
          row['n'] as int;
    }
    for (final row in _db.select(
      'SELECT section, count(*) AS n FROM messages WHERE $where AND (flags & 1) = 0 GROUP BY section',
      inboxes,
    )) {
      unread[SmartSection.values.byName(row['section'] as String)] =
          row['n'] as int;
    }
    return {
      for (final s in SmartSection.values)
        s: SectionCount(totals[s]!, unread[s]!),
    };
  }

  /// Unread messages per folder, for every folder at once.
  Map<int, int> unreadCounts() => {
    for (final row in _db.select(
      'SELECT mailbox_id, count(*) AS n FROM messages WHERE (flags & 1) = 0 GROUP BY mailbox_id',
    ))
      row['mailbox_id'] as int: row['n'] as int,
  };

  /// The INBOX folder ids of [accountIds] (or every account).
  List<int> inboxIds({List<int>? accountIds}) => [
    for (final row in _db.select(
      "SELECT id, account_id FROM mailboxes WHERE upper(encoded_name) = 'INBOX'",
    ))
      if (accountIds == null || accountIds.contains(row['account_id']))
        row['id'] as int,
  ];

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
      category: MessageCategory.fromStorage(row['category'] as String),
      categorySource: CategorySource.values.byName(
        row['category_source'] as String,
      ),
      snippet: row['snippet'] as String?,
      listId: row['list_id'] as String?,
      section: SmartSection.values.byName(row['section'] as String),
    );
  }
}

/// Stored rows of some messages, kept briefly so a move or delete can be
/// undone (see [MessageRepository.snapshot]). Lives in memory only.
final class MessageSnapshot {
  const MessageSnapshot._({
    required this.messages,
    required this.addresses,
    required this.headers,
    required this.bodies,
    required this.search,
  });

  final List<Map<String, Object?>> messages;
  final List<Map<String, Object?>> addresses;
  final List<Map<String, Object?>> headers;
  final List<Map<String, Object?>> bodies;
  final List<Map<String, Object?>> search;

  bool get isEmpty => messages.isEmpty;
}
