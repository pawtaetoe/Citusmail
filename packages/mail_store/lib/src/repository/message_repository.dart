// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../database/mail_database.dart';
import '../model/mailbox.dart';
import '../model/message.dart';
import 'search_query.dart';
import 'search_words.dart';
import 'search_words_repository.dart';
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

  final List<MailboxId>? mailboxIds;
  final List<AccountId>? accountIds;

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
  MessageRepository(this._db) : _words = SearchWordsRepository(_db);

  final MailDatabase _db;
  final SearchWordsRepository _words;

  static const _columns =
      'm.id, m.mailbox_id, b.account_id, m.uid, m.message_id_header, m.in_reply_to, '
      'm.thread_references, m.subject, m.from_name, m.from_address, m.sent_at, m.received_at, m.size, '
      'm.flags, m.keywords, m.mod_seq, m.has_attachments, m.category, m.category_source, m.snippet, m.list_id, m.section, m.code, m.listed_at';
  static const _from =
      'FROM messages m JOIN mailboxes b ON b.id = m.mailbox_id';

  static String _placeholders(int count) => List.filled(count, '?').join(', ');

  /// Leaves out the extra copies Gmail-style servers show in All Mail,
  /// Starred and Important, so lists across folders (pins, search) show
  /// each message once: a copy there is hidden when the same message is in
  /// an ordinary folder of the account, and a Starred or Important copy
  /// also when it is in All Mail.
  static final _notACopy = () {
    final uses = StoredMailbox.copyUses.map((u) => "'$u'").join(', ');
    return '(b.special_use IS NULL OR b.special_use NOT IN ($uses) '
        'OR m.message_id_header IS NULL OR NOT EXISTS ('
        'SELECT 1 FROM messages d JOIN mailboxes db ON db.id = d.mailbox_id '
        'WHERE d.message_id_header = m.message_id_header '
        'AND db.account_id = b.account_id AND d.id != m.id '
        'AND (db.special_use IS NULL OR db.special_use NOT IN ($uses) '
        "OR (db.special_use = 'all' AND b.special_use != 'all'))))";
  }();

  /// Inserts or updates summaries by UID, in one transaction.
  void upsertSummaries(MailboxId mailboxId, List<MessageSummary> summaries) =>
      _db.transaction(() {
        final ids = <MessageId>[];
        for (final s in summaries) {
          final rowId =
              _db
                      .select(
                        'INSERT INTO messages (mailbox_id, uid, message_id_header, in_reply_to, thread_references, '
                        'subject, from_name, from_address, sent_at, received_at, size, flags, keywords, mod_seq, '
                        'has_attachments, category, category_source, list_id, snippet, code, listed_at, from_domain) '
                        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
                        'ON CONFLICT (mailbox_id, uid) DO UPDATE SET '
                        'message_id_header = excluded.message_id_header, in_reply_to = excluded.in_reply_to, '
                        'thread_references = excluded.thread_references, subject = excluded.subject, '
                        'from_name = excluded.from_name, from_address = excluded.from_address, '
                        'from_domain = excluded.from_domain, '
                        'sent_at = excluded.sent_at, received_at = excluded.received_at, size = excluded.size, '
                        'flags = excluded.flags, keywords = excluded.keywords, mod_seq = excluded.mod_seq, '
                        'has_attachments = excluded.has_attachments, snippet = excluded.snippet, '
                        'category = excluded.category, category_source = excluded.category_source, '
                        'list_id = excluded.list_id, '
                        // A code read from the body is kept.
                        'code = coalesce(excluded.code, messages.code), '
                        // Mail back from snooze stays where it came back.
                        'listed_at = CASE WHEN messages.listed_at > messages.received_at '
                        'THEN max(messages.listed_at, excluded.received_at) '
                        'ELSE excluded.received_at END '
                        'RETURNING id',
                        [
                          mailboxId.value,
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
                          s.code,
                          s.receivedAt.toUtc().millisecondsSinceEpoch,
                          _domainOf(s.from),
                        ],
                      )
                      .first
                      .columnAt(0)
                  as int;
          final id = MessageId(rowId);
          _replaceAddresses(id, s);
          _replaceHeaders(id, s.headers);
          _replaceReferences(id, s.references);
          _indexSummary(id, s);
          ids.add(id);
        }
        _words.addNew();
        SectionSql.refreshIds(_db, ids);
        _refreshRelated(mailboxId, summaries);
      });

  /// Mail in Sent or the Important folder changes the section of other
  /// messages: those from the people written to, replies to the sent
  /// messages, or the same message in the inbox.
  void _refreshRelated(MailboxId mailboxId, List<MessageSummary> summaries) {
    final use = _db.select('SELECT special_use FROM mailboxes WHERE id = ?', [
      mailboxId.value,
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
      // Mail waiting in the Screener may refer to these (References).
      final inboxes = inboxIds();
      if (inboxes.isNotEmpty) {
        SectionSql.refresh(
          _db,
          "mailbox_id IN (${_placeholders(inboxes.length)}) AND section = 'screener'",
          [for (final id in inboxes) id.value],
        );
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
    MailboxId mailboxId,
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
            mailboxId.value,
            c.uid,
          ],
      ],
    );
    // Pinning (and the $Important keyword) changes the section: one
    // statement per 500 messages, not one per message.
    SectionSql.refreshUids(_db, mailboxId, [for (final c in changes) c.uid]);
  });

  /// Removes messages by UID (with addresses, headers, body and index).
  ///
  /// One statement per 500 messages, not one per message: each statement
  /// that fires the delete triggers runs in a statement savepoint, and at
  /// each one the full-text indexes write out what they have pending, so
  /// thousands of one-row statements left thousands of tiny index
  /// segments to merge and took seconds per thousand messages.
  void removeUids(MailboxId mailboxId, Iterable<int> uids) {
    final list = uids.toList(growable: false);
    if (list.isEmpty) return;
    _db.transaction(() {
      for (final chunk in _chunks(list, 500)) {
        _db.execute(
          'DELETE FROM messages WHERE mailbox_id = ? '
          'AND uid IN (${_placeholders(chunk.length)})',
          [mailboxId.value, ...chunk],
        );
      }
    });
  }

  /// All cached UIDs of a folder, ascending.
  List<int> uids(MailboxId mailboxId) => _db
      .select('SELECT uid FROM messages WHERE mailbox_id = ? ORDER BY uid', [
        mailboxId.value,
      ])
      .map((r) => r.columnAt(0) as int)
      .toList(growable: false);

  /// Cached UIDs of a folder above [uid], ascending: what arrived since a
  /// UID was seen.
  List<int> uidsAbove(MailboxId mailboxId, int uid) => _db
      .select(
        'SELECT uid FROM messages WHERE mailbox_id = ? AND uid > ? ORDER BY uid',
        [mailboxId.value, uid],
      )
      .map((r) => r.columnAt(0) as int)
      .toList(growable: false);

  /// Cached flags of every message in a folder, by UID.
  Map<int, MessageFlags> flagsByUid(MailboxId mailboxId) => {
    for (final row in _db.select(
      'SELECT uid, flags, keywords FROM messages WHERE mailbox_id = ?',
      [mailboxId.value],
    ))
      row['uid'] as int: MessageFlags(
        row['flags'] as int,
        Set.unmodifiable(
          (row['keywords'] as String).split(' ').where((k) => k.isNotEmpty),
        ),
      ),
  };

  int? lowestUid(MailboxId mailboxId) =>
      _db
              .select('SELECT min(uid) FROM messages WHERE mailbox_id = ?', [
                mailboxId.value,
              ])
              .first
              .columnAt(0)
          as int?;

  int? highestUid(MailboxId mailboxId) =>
      _db
              .select('SELECT max(uid) FROM messages WHERE mailbox_id = ?', [
                mailboxId.value,
              ])
              .first
              .columnAt(0)
          as int?;

  StoredMessage? byId(MessageId id) {
    final rows = _db.select('SELECT $_columns $_from WHERE m.id = ?', [
      id.value,
    ]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  StoredMessage? byUid(MailboxId mailboxId, int uid) {
    final rows = _db.select(
      'SELECT $_columns $_from WHERE m.mailbox_id = ? AND m.uid = ?',
      [mailboxId.value, uid],
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
    List<MailboxId>? folders = query.mailboxIds;
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
    final byDate = b.listedAt.compareTo(a.listedAt);
    return byDate != 0 ? byDate : b.id.value.compareTo(a.id.value);
  }

  /// The SQL and arguments of one page (in one folder, or all).
  (String, List<Object?>) _pageSql(
    MessageQuery query,
    MailboxId? mailboxId,
    int limit,
  ) {
    final where = <String>[];
    final args = <Object?>[];
    if (mailboxId != null) {
      where.add('m.mailbox_id = ?');
      args.add(mailboxId.value);
    }
    if (query.accountIds case final ids? when mailboxId == null) {
      where.add('b.account_id IN (${_placeholders(ids.length)})');
      args.addAll([for (final id in ids) id.value]);
    }
    if (mailboxId == null) where.add(_notACopy);
    if (query.section case final section?) {
      where.add('m.section = ?');
      args.add(section.name);
      if (SectionSql.receiptFreeSections.contains(section.name)) {
        where.add('NOT ${SectionSql.readReceipt('m')}');
      }
    } else {
      // Snoozed mail is only in the Snoozed list until it comes back.
      where.add("m.section != 'snoozed'");
    }
    if (query.category case final category?) {
      where.add('m.category = ?');
      args.add(category.storageName);
    }
    // Same expressions as the partial indexes, so they can be used.
    if (query.unreadOnly) where.add('(m.flags & 1) = 0');
    if (query.flaggedOnly) where.add('(m.flags & 4) != 0');
    if (query.before case final before?) {
      where.add('(m.listed_at < ? OR (m.listed_at = ? AND m.id < ?))');
      final at = before.listedAt.millisecondsSinceEpoch;
      args.addAll([at, at, before.id.value]);
    }
    final sql = StringBuffer('SELECT $_columns $_from');
    if (where.isNotEmpty) sql.write(' WHERE ${where.join(' AND ')}');
    // Mail back from snooze is listed at the time it came back.
    sql.write(' ORDER BY m.listed_at DESC, m.id DESC LIMIT ?');
    args.add(limit);
    return (sql.toString(), args);
  }

  List<StoredMessage> _listPage(
    MessageQuery query,
    MailboxId? mailboxId,
    int limit,
  ) {
    final (sql, args) = _pageSql(query, mailboxId, limit);
    return _db.select(sql, args).map(_fromRow).toList(growable: false);
  }

  /// How SQLite runs one page of [query] (for tests that make sure lists
  /// stay index reads).
  List<String> debugQueryPlan(MessageQuery query, {MailboxId? mailboxId}) {
    final (sql, args) = _pageSql(query, mailboxId, query.limit);
    return [
      for (final row in _db.select('EXPLAIN QUERY PLAN $sql', args))
        row['detail'] as String,
    ];
  }

  /// Unread messages in a folder (snoozed mail isn't counted).
  int unreadCount(MailboxId mailboxId) =>
      _db
              .select(
                'SELECT count(*) FROM messages WHERE mailbox_id = ? AND (flags & 1) = 0 '
                "AND section != 'snoozed'",
                [mailboxId.value],
              )
              .first
              .columnAt(0)
          as int;

  /// Pinned messages in every folder of every account, each once (what
  /// the Pins list shows; snoozed mail isn't counted).
  int pinnedCount() =>
      _db
              .select(
                'SELECT count(*) $_from WHERE (m.flags & 4) != 0 '
                "AND m.section != 'snoozed' AND $_notACopy",
              )
              .first
              .columnAt(0)
          as int;

  /// Searches subject, participants and downloaded bodies. Typed text is
  /// always literal (see [SearchQuery]). Newest first.
  List<StoredMessage> search(String text, {int limit = 100}) {
    final query = SearchQuery.parse(text);
    if (query == null) return const [];
    return _search(query, limit.clamp(1, 500));
  }

  /// Like [search], and forgiving of typos: when what was typed finds
  /// fewer than [SearchResults.enough] messages, each term that is not a
  /// word of the user's mail (and finds little by itself) is corrected to
  /// the closest word that is ([SearchWordsRepository.correct]), and what
  /// that finds follows the exact matches.
  SearchResults searchForgiving(String text, {int limit = 100}) {
    final query = SearchQuery.parse(text);
    if (query == null) return SearchResults(const []);
    final capped = limit.clamp(1, 500);
    final exact = _search(query, capped);
    if (exact.length >= SearchResults.enough) return SearchResults(exact);
    final corrections = <int, List<String>>{};
    for (final (i, term) in query.terms.indexed) {
      if (!SearchWords.isCorrectable(term) || _findsEnough(term)) continue;
      if (_words.correct(term) case final c?) corrections[i] = c.words;
    }
    if (corrections.isEmpty) return SearchResults(exact);
    final seen = {for (final m in exact) m.id};
    final more = [
      for (final m in _search(
        query.withCorrections(corrections),
        capped + exact.length,
      ))
        if (!seen.contains(m.id)) m,
    ];
    if (more.isEmpty) return SearchResults(exact);
    return SearchResults(
      [...exact, ...more].take(capped).toList(growable: false),
      exactCount: exact.length,
      correctedText: query.correctedText(corrections),
    );
  }

  /// Whether [term] alone finds [SearchResults.enough] messages: then it
  /// is no typo, even if it is not a word of subjects or senders.
  bool _findsEnough(String term) =>
      (_db
              .select(
                'SELECT count(*) FROM (SELECT 1 FROM message_search '
                'WHERE message_search MATCH ? LIMIT ?)',
                [SearchQuery.ftsWord(term), SearchResults.enough],
              )
              .first
              .columnAt(0)
          as int) >=
      SearchResults.enough;

  List<StoredMessage> _search(SearchQuery query, int limit) {
    if (query.usesIndex) {
      return _db
          .select(
            'SELECT $_columns $_from JOIN message_search s ON s.rowid = m.id '
            'WHERE message_search MATCH ? AND $_notACopy '
            'ORDER BY m.received_at DESC, m.id DESC LIMIT ?',
            [query.toFtsMatch(), limit],
          )
          .map(_fromRow)
          .toList(growable: false);
    }
    // Short terms: substring match on subject and sender (no index).
    final (conditions, args) = query.toLikeCondition(const [
      'm.subject',
      'm.from_name',
      'm.from_address',
    ]);
    return _db
        .select(
          'SELECT $_columns $_from WHERE $conditions AND $_notACopy '
          'ORDER BY m.received_at DESC, m.id DESC LIMIT ?',
          [...args, limit],
        )
        .map(_fromRow)
        .toList(growable: false);
  }

  /// Addresses of one kind (from, to, cc...), in order.
  List<MailAddress> addresses(MessageId messageId, String kind) => _db
      .select(
        'SELECT name, address FROM message_addresses WHERE message_id = ? AND kind = ? ORDER BY position',
        [messageId.value, kind],
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

  /// Everyone [suggestAddresses] can offer, in the same order (people
  /// the user has written to first, most used first), at most [limit]:
  /// read once while writing a message and searched in memory, instead of
  /// one query per key press.
  List<MailAddress> suggestionCandidates({int limit = 5000}) {
    final rows = _db.select(
      'SELECT address, max(name) AS name, sum(weight) AS score FROM ('
      'SELECT a.address AS address, a.name AS name, 10 AS weight FROM message_addresses a '
      'JOIN messages m ON m.id = a.message_id JOIN mailboxes b ON b.id = m.mailbox_id '
      "WHERE b.special_use = 'sent' AND a.kind IN ('to', 'cc', 'bcc') "
      'UNION ALL '
      'SELECT from_address, from_name, 1 FROM messages '
      'WHERE from_address IS NOT NULL AND category = ?'
      ') GROUP BY address COLLATE NOCASE ORDER BY score DESC, address LIMIT ?',
      [MessageCategory.general.storageName, limit.clamp(1, 20000)],
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
    AccountId accountId, {
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
            inbox.first.value,
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
    AccountId accountId,
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
          [inbox.first.value, '%@$d', '%.$d', limit.clamp(1, 5000)],
        )
        .map(_fromRow)
        .toList(growable: false);
  }

  /// Messages in [mailboxId] with Message-ID [messageId]
  /// (without brackets).
  List<StoredMessage> byMessageId(MailboxId mailboxId, String messageId) => _db
      .select(
        'SELECT $_columns $_from WHERE m.mailbox_id = ? AND m.message_id_header = ?',
        [mailboxId.value, messageId],
      )
      .map(_fromRow)
      .toList(growable: false);

  /// Messages in [mailboxId] received after [since] that answer another
  /// (they have In-Reply-To or References), newest first: what might be a
  /// reply to mail the user sent. Reads the folder's list index (a message
  /// is never listed before it was received).
  List<StoredMessage> threadedSince(
    MailboxId mailboxId,
    DateTime since, {
    int limit = 2000,
  }) {
    final ms = since.toUtc().millisecondsSinceEpoch;
    return _db
        .select(
          'SELECT $_columns $_from WHERE m.mailbox_id = ? AND m.listed_at > ? '
          'AND m.received_at > ? '
          "AND (m.in_reply_to IS NOT NULL OR coalesce(m.thread_references, '') != '') "
          'ORDER BY m.listed_at DESC, m.id DESC LIMIT ?',
          [mailboxId.value, ms, ms, limit.clamp(1, 10000)],
        )
        .map(_fromRow)
        .toList(growable: false);
  }

  /// The conversation [message] is in, oldest first: in its account, the
  /// messages it answers (by In-Reply-To and References), those that
  /// answer it or the same earlier messages, and [message] itself; each
  /// message once (not its copies in other folders), nothing from Trash
  /// or Junk but [message], and at most the [limit] newest.
  List<StoredMessage> conversation(StoredMessage message, {int limit = 20}) {
    final ids = {
      ?message.messageId,
      ?message.inReplyTo,
      ...message.references.where((r) => r.isNotEmpty),
    }.toList();
    if (ids.isEmpty) return [message];
    final marks = _placeholders(ids.length);
    final rows = _db.select(
      'SELECT $_columns $_from WHERE b.account_id = ? AND $_notACopy '
      "AND (m.id = ? OR b.special_use IS NULL OR b.special_use NOT IN ('trash', 'junk')) "
      'AND (m.id = ? OR m.message_id_header IN ($marks) OR m.in_reply_to IN ($marks) '
      'OR m.id IN (SELECT message_id FROM message_references WHERE ref IN ($marks))) '
      'ORDER BY coalesce(m.sent_at, m.received_at) DESC, m.id DESC LIMIT ?',
      [
        message.accountId.value,
        message.id.value,
        message.id.value,
        ...ids,
        ...ids,
        ...ids,
        (limit * 2).clamp(1, 1000),
      ],
    );
    final seen = <String>{};
    final found = <StoredMessage>[];
    for (final row in rows) {
      final m = _fromRow(row);
      final key = m.messageId ?? 'id:${m.id}';
      if (m.id != message.id && !seen.add(key)) continue;
      seen.add(key);
      found.add(m);
    }
    // [message] itself always stays, also when its copy came first.
    found.removeWhere(
      (m) =>
          m.id != message.id &&
          m.messageId != null &&
          m.messageId == message.messageId,
    );
    if (!found.any((m) => m.id == message.id)) found.add(message);
    final newest = found.take(limit).toList();
    if (!newest.any((m) => m.id == message.id)) {
      newest
        ..removeLast()
        ..add(message);
    }
    DateTime at(StoredMessage m) => m.sentAt ?? m.receivedAt;
    newest.sort((a, b) {
      final byTime = at(a).compareTo(at(b));
      return byTime != 0 ? byTime : a.id.value.compareTo(b.id.value);
    });
    return newest;
  }

  /// Stored headers of a message: lower-case name -> values.
  Map<String, List<String>> headers(MessageId messageId) {
    final result = <String, List<String>>{};
    for (final row in _db.select(
      'SELECT name, value FROM message_headers WHERE message_id = ? ORDER BY name, position',
      [messageId.value],
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
    MailboxId mailboxId,
    String name, {
    int limit = 100,
  }) => [
    for (final row in _db.select(
      'SELECT (SELECT value FROM message_headers h '
      '        WHERE h.message_id = m.id AND h.name = ? AND h.position = 0) AS value '
      'FROM messages m WHERE m.mailbox_id = ? '
      'ORDER BY m.received_at DESC, m.id DESC LIMIT ?',
      [name.toLowerCase(), mailboxId.value, limit.clamp(1, 500)],
    ))
      row['value'] as String?,
  ];

  /// Stores the full raw message and indexes its text for search.
  void saveBody(
    MessageId messageId,
    Uint8List raw, {
    required String searchableText,
  }) => _db.transaction(() {
    _db.execute(
      'INSERT INTO message_bodies (message_id, raw, fetched_at) VALUES (?, ?, ?) '
      'ON CONFLICT (message_id) DO UPDATE SET raw = excluded.raw, fetched_at = excluded.fetched_at',
      [messageId.value, raw, DateTime.now().toUtc().millisecondsSinceEpoch],
    );
    final existing = _db.select(
      'SELECT subject, participants FROM message_search WHERE rowid = ?',
      [messageId.value],
    );
    final subject = existing.isEmpty
        ? ''
        : existing.first['subject'] as String? ?? '';
    final participants = existing.isEmpty
        ? ''
        : existing.first['participants'] as String? ?? '';
    _db.execute('DELETE FROM message_search WHERE rowid = ?', [
      messageId.value,
    ]);
    _db.execute(
      'INSERT INTO message_search (rowid, subject, participants, body) VALUES (?, ?, ?, ?)',
      [messageId.value, subject, participants, searchableText],
    );
  });

  /// The full raw message, if downloaded.
  Uint8List? body(MessageId messageId) {
    final rows = _db.select(
      'SELECT raw FROM message_bodies WHERE message_id = ?',
      [messageId.value],
    );
    return rows.isEmpty ? null : rows.first.columnAt(0) as Uint8List;
  }

  /// Up to [limit] messages with an id above [afterId], in id order, with
  /// what sorting needs. For re-sorting stored mail without downloading.
  List<SortableMessage> sortable({
    MessageId afterId = const MessageId(0),
    int limit = 500,
  }) {
    final rows = _db.select(
      'SELECT m.id, m.from_name, m.from_address, m.subject, m.snippet, m.code, b.special_use '
      'FROM messages m JOIN mailboxes b ON b.id = m.mailbox_id '
      'WHERE m.id > ? ORDER BY m.id LIMIT ?',
      [afterId.value, limit.clamp(1, 5000)],
    );
    if (rows.isEmpty) return const [];
    final ids = [for (final r in rows) r['id'] as int];
    return _sortable(
      rows,
      _db.select(
        'SELECT message_id, name, value FROM message_headers '
        'WHERE message_id BETWEEN ? AND ? ORDER BY message_id, name, position',
        [ids.first, ids.last],
      ),
    );
  }

  /// The newest [limit] messages from [address] (any case) that others
  /// sent the user (not in Sent or Drafts), with what sorting needs.
  List<SortableMessage> sortableFrom(String address, {int limit = 50}) {
    final rows = _db.select(
      'SELECT m.id, m.from_name, m.from_address, m.subject, m.snippet, m.code, b.special_use '
      'FROM messages m JOIN mailboxes b ON b.id = m.mailbox_id '
      'WHERE m.from_address = ? COLLATE NOCASE '
      "AND (b.special_use IS NULL OR b.special_use NOT IN ('sent', 'drafts')) "
      'ORDER BY m.received_at DESC, m.id DESC LIMIT ?',
      [address, limit.clamp(1, 500)],
    );
    if (rows.isEmpty) return const [];
    final ids = [for (final r in rows) r['id'] as int];
    return _sortable(
      rows,
      _db.select(
        'SELECT message_id, name, value FROM message_headers '
        'WHERE message_id IN (${_placeholders(ids.length)}) '
        'ORDER BY message_id, name, position',
        ids,
      ),
    );
  }

  /// Whether the user has written to [address] (any case, To/Cc/Bcc of a
  /// message in a Sent folder).
  bool hasWrittenTo(String address) => _db.select(
    'SELECT 1 FROM message_addresses a '
    'JOIN messages m ON m.id = a.message_id '
    'JOIN mailboxes b ON b.id = m.mailbox_id '
    "WHERE a.address = ? COLLATE NOCASE AND a.kind IN ('to', 'cc', 'bcc') "
    "AND b.special_use = 'sent' LIMIT 1",
    [address],
  ).isNotEmpty;

  /// Every address the user has written to (To/Cc/Bcc of mail in a Sent
  /// folder), lower case.
  Set<String> writtenTo() => {
    for (final row in _db.select(
      'SELECT DISTINCT lower(a.address) AS address FROM message_addresses a '
      'JOIN messages m ON m.id = a.message_id '
      'JOIN mailboxes b ON b.id = m.mailbox_id '
      "WHERE a.kind IN ('to', 'cc', 'bcc') AND b.special_use = 'sent'",
    ))
      row['address'] as String,
  };

  /// Mail others sent the user, received since [since]: not in Sent,
  /// Drafts, Trash or Junk, each message once across folders, newest
  /// first, at most [limit]. With each, whether it has a
  /// `List-Unsubscribe` header. What the Clean up page counts per sender.
  List<({StoredMessage message, bool unsubscribe})> receivedSince(
    DateTime since, {
    int limit = 20000,
  }) => [
    for (final row in _db.select(
      'SELECT $_columns, EXISTS (SELECT 1 FROM message_headers h '
      "WHERE h.message_id = m.id AND h.name = 'list-unsubscribe') AS unsubscribe "
      '$_from WHERE m.received_at >= ? AND m.from_address IS NOT NULL '
      "AND (b.special_use IS NULL OR b.special_use NOT IN ('sent', 'drafts', 'trash', 'junk')) "
      'AND $_notACopy '
      'ORDER BY m.received_at DESC, m.id DESC LIMIT ?',
      [since.toUtc().millisecondsSinceEpoch, limit.clamp(1, 50000)],
    ))
      (message: _fromRow(row), unsubscribe: row['unsubscribe'] == 1),
  ];

  /// Mail from [addresses] (any case, any age) in every folder the Clean
  /// up page counts: not in Sent, Drafts, Trash or Junk, each message
  /// once across folders (the original, not a Gmail-style copy in All
  /// Mail, Starred or Important). Newest first, at most [limit]. What
  /// "Delete all" moves to Trash.
  List<StoredMessage> receivedFrom(
    Iterable<String> addresses, {
    int limit = 20000,
  }) {
    final list = {for (final a in addresses) a.toLowerCase()}.toList();
    if (list.isEmpty) return const [];
    return _db
        .select(
          'SELECT $_columns $_from WHERE lower(m.from_address) IN '
          '(${_placeholders(list.length)}) '
          "AND (b.special_use IS NULL OR b.special_use NOT IN ('sent', 'drafts', 'trash', 'junk')) "
          'AND $_notACopy '
          'ORDER BY m.received_at DESC, m.id DESC LIMIT ?',
          [...list, limit.clamp(1, 50000)],
        )
        .map(_fromRow)
        .toList(growable: false);
  }

  /// The Gmail-style copies (in All Mail, Starred or Important) of
  /// [messages]: the same Message-ID in a copy folder of the same
  /// account, not [messages] themselves. Gmail drops them on its own when
  /// a message goes to Trash or Spam, so the app drops them locally too
  /// (else a stale copy would stand in for the message that left).
  List<StoredMessage> copiesOf(Iterable<StoredMessage> messages) {
    final ids = {for (final m in messages) m.id};
    final byAccount = <AccountId, Set<String>>{};
    for (final m in messages) {
      if (m.messageId case final header?) {
        byAccount.putIfAbsent(m.accountId, () => {}).add(header);
      }
    }
    final uses = StoredMailbox.copyUses.map((u) => "'$u'").join(', ');
    return [
      for (final MapEntry(key: accountId, value: headers) in byAccount.entries)
        for (final chunk in _chunks(headers.toList(), 500))
          for (final row in _db.select(
            'SELECT $_columns $_from WHERE b.account_id = ? '
            'AND b.special_use IN ($uses) '
            'AND m.message_id_header IN (${_placeholders(chunk.length)})',
            [accountId.value, ...chunk],
          ))
            if (_fromRow(row) case final copy when !ids.contains(copy.id)) copy,
    ];
  }

  static Iterable<List<T>> _chunks<T>(List<T> list, int size) sync* {
    for (var i = 0; i < list.length; i += size) {
      yield list.sublist(i, (i + size).clamp(0, list.length));
    }
  }

  /// The mail [receivedSince] lists, without pinned mail (the user keeps
  /// that, so it is not clutter), added up per sender address (any
  /// case) by SQLite: how much, how much of it opened, when the newest
  /// came and which it is, and the newest with a `List-Unsubscribe`
  /// header (pinned or not). One row per address instead of one object
  /// per message, so the Clean up page does not read thousands of rows.
  /// Most mail first, then the most recent.
  List<SenderStats> senderStats(DateTime since) {
    const from =
        '$_from WHERE m.received_at >= ? AND m.from_address IS NOT NULL '
        "AND (b.special_use IS NULL OR b.special_use NOT IN ('sent', 'drafts', 'trash', 'junk')) ";
    final at = since.toUtc().millisecondsSinceEpoch;
    // Per address and display name; the bare columns (id, from_address)
    // come from the row with the newest received_at, as SQLite defines
    // for a query with one max().
    final rows = _db.select(
      'SELECT lower(m.from_address) AS address, m.from_name AS name, '
      'count(*) AS n, sum((m.flags & 1) != 0) AS opened, '
      "sum(m.category = 'newsletters') AS newsletters, "
      "sum(m.category = 'notifications') AS notifications, "
      'max(m.received_at) AS last, m.id AS newest_id, m.from_address AS spelled '
      '$from AND (m.flags & ${MessageFlags.flaggedBit}) = 0 AND $_notACopy '
      'GROUP BY lower(m.from_address), m.from_name',
      [at],
    );
    // The newest message with unsubscribe headers, per address.
    final unsubscribe = {
      for (final row in _db.select(
        'SELECT lower(m.from_address) AS address, max(m.received_at) AS last, m.id AS newest_id '
        '$from AND $_notACopy '
        'AND EXISTS (SELECT 1 FROM message_headers h '
        "WHERE h.message_id = m.id AND h.name = 'list-unsubscribe') "
        'GROUP BY lower(m.from_address)',
        [at],
      ))
        row['address'] as String: (
          MessageId(row['newest_id'] as int),
          row['last'] as int,
        ),
    };
    final byAddress = <String, _SenderTotals>{};
    for (final row in rows) {
      final totals = byAddress.putIfAbsent(
        row['address'] as String,
        _SenderTotals.new,
      );
      final n = row['n'] as int;
      final last = row['last'] as int;
      totals.count += n;
      totals.opened += row['opened'] as int;
      totals.newsletters += row['newsletters'] as int;
      totals.notifications += row['notifications'] as int;
      if (last > totals.last) {
        totals.last = last;
        totals.newestId = MessageId(row['newest_id'] as int);
        totals.spelled = row['spelled'] as String;
      }
      final name = (row['name'] as String?)?.trim();
      if (name != null && name.isNotEmpty) {
        totals.names.update(name, (c) => c + n, ifAbsent: () => n);
      }
    }
    final stats = [
      for (final MapEntry(key: address, value: t) in byAddress.entries)
        SenderStats(
          from: _address(t.mostUsedName, t.spelled)!,
          count: t.count,
          opened: t.opened,
          newsletters: t.newsletters,
          notifications: t.notifications,
          last: DateTime.fromMillisecondsSinceEpoch(t.last, isUtc: true),
          newestId: t.newestId,
          unsubscribeId: unsubscribe[address]?.$1,
          unsubscribeAt: switch (unsubscribe[address]?.$2) {
            final ms? => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
            null => null,
          },
        ),
    ];
    stats.sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      if (byCount != 0) return byCount;
      final byLast = b.last.compareTo(a.last);
      return byLast != 0 ? byLast : a.from.address.compareTo(b.from.address);
    });
    return stats;
  }

  List<SortableMessage> _sortable(
    Iterable<Row> rows,
    Iterable<Row> headerRows,
  ) {
    final headers = <int, Map<String, List<String>>>{};
    for (final row in headerRows) {
      headers
          .putIfAbsent(row['message_id'] as int, () => {})
          .putIfAbsent(row['name'] as String, () => [])
          .add(row['value'] as String);
    }
    return [
      for (final row in rows)
        SortableMessage(
          id: MessageId(row['id'] as int),
          from: _address(
            row['from_name'] as String?,
            row['from_address'] as String?,
          ),
          headers: headers[row['id'] as int] ?? const {},
          subject: row['subject'] as String?,
          snippet: row['snippet'] as String?,
          code: row['code'] as String?,
          mailboxUse: switch (row['special_use'] as String?) {
            final use? => SpecialUse.values.asNameMap()[use],
            null => null,
          },
        ),
    ];
  }

  /// How many bytes of downloaded bodies a [snapshot] keeps unless asked
  /// otherwise: every body of the mail people undo one or a few at a
  /// time, and a bound for "archive this whole list".
  static const defaultSnapshotBodyBytes = 4 << 20;

  /// Everything stored about messages [ids] (summary, addresses, headers,
  /// search text), to put them back with [restore] if the user undoes a
  /// move or delete within a few seconds. Downloaded bodies are kept
  /// while they fit in [bodyBytes], in the order of [ids]; a message
  /// whose body is left out comes back like one never downloaded (it is
  /// fetched again when opened), so undoing a move of thousands of
  /// messages never holds their bodies in memory.
  MessageSnapshot snapshot(
    List<MessageId> messageIds, {
    int bodyBytes = defaultSnapshotBodyBytes,
  }) {
    final ids = [for (final id in messageIds) id.value];
    List<Map<String, Object?>> rows(
      String table,
      String key,
      List<int> keys, [
      String columns = '*',
    ]) => [
      for (var i = 0; i < keys.length; i += 500)
        for (final row in _db.select(
          'SELECT $columns FROM $table WHERE $key IN (${_placeholders((keys.length - i).clamp(0, 500))})',
          keys.sublist(i, (i + 500).clamp(0, keys.length)),
        ))
          {for (final column in row.keys) column: row[column]},
    ];
    final sizes = {
      for (final row in rows(
        'message_bodies',
        'message_id',
        ids,
        'message_id, length(raw) AS size',
      ))
        row['message_id'] as int: row['size'] as int,
    };
    final kept = <int>[];
    var used = 0;
    for (final id in ids) {
      final size = sizes[id];
      if (size == null || used + size > bodyBytes) continue;
      kept.add(id);
      used += size;
    }
    // The indexed body text goes with the body.
    final search = rows(
      'message_search',
      'rowid',
      ids,
      'rowid AS id, subject, participants',
    );
    final bodyText = {
      for (final row in rows(
        'message_search',
        'rowid',
        kept,
        'rowid AS id, body',
      ))
        row['id'] as int: row['body'],
    };
    for (final row in search) {
      row['body'] = bodyText[row['id']] ?? '';
    }
    return MessageSnapshot._(
      messages: rows('messages', 'id', ids),
      addresses: rows('message_addresses', 'message_id', ids),
      headers: rows('message_headers', 'message_id', ids),
      bodies: rows('message_bodies', 'message_id', kept),
      search: search,
      bodiesLeftOut: sizes.length - kept.length,
    );
  }

  /// Puts back messages from a [snapshot]. A message whose folder is gone,
  /// or that is already back (its UID is in the folder again), is skipped.
  /// Returns the ids the messages have now (they may get new ids).
  ///
  /// Set-based, like [removeUids]: the checks read 500 messages per
  /// query, and each table is written with one prepared statement.
  Map<MessageId, MessageId> restore(
    MessageSnapshot snapshot,
  ) => _db.transaction(() {
    final newIds = <int, int>{};
    if (snapshot.messages.isEmpty) return const {};
    // Which folders still exist, which UIDs are back already, and which
    // ids are taken.
    List<int> found(String sql, List<Object?> before, List<int> keys) => [
      for (final chunk in _chunks(keys, 500))
        for (final r in _db.select('$sql (${_placeholders(chunk.length)})', [
          ...before,
          ...chunk,
        ]))
          r.columnAt(0) as int,
    ];
    final uidsByMailbox = <int, List<int>>{};
    for (final row in snapshot.messages) {
      uidsByMailbox
          .putIfAbsent(row['mailbox_id']! as int, () => [])
          .add(row['uid']! as int);
    }
    final folders = found(
      'SELECT id FROM mailboxes WHERE id IN',
      const [],
      uidsByMailbox.keys.toList(),
    ).toSet();
    final present = <(int, int)>{
      for (final MapEntry(key: mailboxId, value: uids) in uidsByMailbox.entries)
        for (final uid in found(
          'SELECT uid FROM messages WHERE mailbox_id = ? AND uid IN',
          [mailboxId],
          uids,
        ))
          (mailboxId, uid),
    };
    final taken = found('SELECT id FROM messages WHERE id IN', const [], [
      for (final row in snapshot.messages) row['id']! as int,
    ]).toSet();
    // Back with their own ids (one prepared statement), or, rarely, with
    // a new one when theirs was taken meanwhile.
    final columns = snapshot.messages.first.keys.toList();
    final sameIds = <Map<String, Object?>>[];
    for (final row in snapshot.messages) {
      final oldId = row['id']! as int;
      final mailboxId = row['mailbox_id']! as int;
      if (!folders.contains(mailboxId) ||
          present.contains((mailboxId, row['uid']! as int))) {
        continue;
      }
      if (taken.contains(oldId)) {
        final without = [
          for (final c in row.keys)
            if (c != 'id') c,
        ];
        _db.execute(
          'INSERT INTO messages (${without.join(', ')}) VALUES (${_placeholders(without.length)})',
          [for (final c in without) row[c]],
        );
        newIds[oldId] = _db.lastInsertRowId;
      } else {
        sameIds.add(row);
        newIds[oldId] = oldId;
      }
    }
    _db.executeMany(
      'INSERT INTO messages (${columns.join(', ')}) VALUES (${_placeholders(columns.length)})',
      [
        for (final row in sameIds) [for (final c in columns) row[c]],
      ],
    );
    _db.executeMany(
      'INSERT OR IGNORE INTO message_references (message_id, ref) VALUES (?, ?)',
      [
        for (final row in snapshot.messages)
          if (newIds[row['id']] case final id?)
            for (final ref in {
              ...((row['thread_references'] as String?) ?? '').split(' '),
            })
              if (ref.isNotEmpty) [id, ref],
      ],
    );
    void copy(String table, List<Map<String, Object?>> rows) {
      if (rows.isEmpty) return;
      final columns = rows.first.keys.toList();
      _db.executeMany(
        'INSERT OR REPLACE INTO $table (${columns.join(', ')}) VALUES (${_placeholders(columns.length)})',
        [
          for (final row in rows)
            if (newIds[row['message_id']] case final id?)
              [for (final c in columns) c == 'message_id' ? id : row[c]],
        ],
      );
    }

    copy('message_addresses', snapshot.addresses);
    copy('message_headers', snapshot.headers);
    copy('message_bodies', snapshot.bodies);
    final search = [
      for (final row in snapshot.search)
        if (newIds[row['id']] case final id?)
          [id, row['subject'], row['participants'], row['body']],
    ];
    for (final chunk in _chunks(search, 500)) {
      _db.execute(
        'DELETE FROM message_search WHERE rowid IN (${_placeholders(chunk.length)})',
        [for (final row in chunk) row.first],
      );
    }
    _db.executeMany(
      'INSERT INTO message_search (rowid, subject, participants, body) VALUES (?, ?, ?, ?)',
      search,
    );
    _words.addNew();
    SectionSql.refreshIds(_db, [for (final id in newIds.values) MessageId(id)]);
    return {
      for (final MapEntry(key: old, value: now) in newIds.entries)
        MessageId(old): MessageId(now),
    };
  });

  /// Stores new sorting decisions (e.g. after the rules changed).
  /// Mail received since [since] whose subject contains one of [words]
  /// (any case): receipts and renewal notices for finding subscriptions.
  /// Not the user's own mail, nor Trash and Junk; each message once
  /// across folders. Newsletters are included: bills often come with
  /// offers and an unsubscribe link. Newest first.
  List<StoredMessage> withSubjectWords(
    List<String> words, {
    required DateTime since,
    int limit = 1500,
  }) {
    if (words.isEmpty) return const [];
    final like = List.filled(words.length, 'm.subject LIKE ?').join(' OR ');
    return [
      for (final row in _db.select(
        'SELECT $_columns $_from WHERE ($like) AND m.received_at >= ? '
        "AND (b.special_use IS NULL OR b.special_use NOT IN ('sent', 'drafts', 'trash', 'junk')) "
        'AND $_notACopy '
        'ORDER BY m.received_at DESC, m.id DESC LIMIT ?',
        [
          for (final w in words)
            '%${w.replaceAll('%', '').replaceAll('_', '')}%',
          since.toUtc().millisecondsSinceEpoch,
          limit.clamp(1, 5000),
        ],
      ))
        _fromRow(row),
    ];
  }

  /// Mail received since [since], other than the user's own (Sent,
  /// Drafts), each message once across folders: how many there are, and
  /// the newest [limit] of them whose full text is on the device, newest
  /// first. For the privacy report, which counts only what is stored.
  ({int received, List<StoredMessage> downloaded}) downloadedSince(
    DateTime since, {
    int limit = 3000,
  }) {
    const where =
        'WHERE m.received_at >= ? '
        "AND (b.special_use IS NULL OR b.special_use NOT IN ('sent', 'drafts')) ";
    final at = since.toUtc().millisecondsSinceEpoch;
    final received =
        _db.select('SELECT COUNT(*) AS n $_from $where AND $_notACopy', [
              at,
            ]).first['n']
            as int;
    final downloaded = [
      for (final row in _db.select(
        'SELECT $_columns $_from $where AND $_notACopy '
        'AND EXISTS (SELECT 1 FROM message_bodies mb WHERE mb.message_id = m.id) '
        'ORDER BY m.received_at DESC, m.id DESC LIMIT ?',
        [at, limit.clamp(1, 10000)],
      ))
        _fromRow(row),
    ];
    return (received: received, downloaded: downloaded);
  }

  /// Folders whose mail is not listed among received files: Trash,
  /// Junk, Drafts and the app's sync data folder.
  static final _filesFolders =
      "(b.special_use IS NULL OR b.special_use NOT IN ('trash', 'junk', 'drafts')) "
      "AND b.name != '${StoredMailbox.appDataName}' "
      "AND b.name NOT LIKE '%${StoredMailbox.appDataName}'";

  /// One page of messages with attachments, newest first, for a list of
  /// files: every account and folder but Trash, Junk and Drafts, each
  /// message once. [header] is the kept header that lists a message's
  /// files (one value per file), returned with each message, with
  /// whether its body is on the device.
  ///
  /// [peopleOnly] leaves out newsletters, notifications and codes. Each
  /// word of [words] must be in the subject, the sender or the [field]
  /// of one of the file values (a JSON object).
  List<({StoredMessage message, List<String> files, bool downloaded})>
  withAttachments({
    required String header,
    String field = 'name',
    bool peopleOnly = false,
    List<String> words = const [],
    StoredMessage? before,
    int limit = 200,
  }) {
    final where = ['m.has_attachments = 1', _filesFolders, _notACopy];
    final args = <Object?>[];
    if (peopleOnly) {
      where.add('m.category = ?');
      args.add(MessageCategory.general.storageName);
    }
    for (final word in words) {
      final like = '%${_escapeLike(word)}%';
      where.add(
        r"(m.subject LIKE ? ESCAPE '\' OR m.from_name LIKE ? ESCAPE '\' "
        r"OR m.from_address LIKE ? ESCAPE '\' OR EXISTS (SELECT 1 FROM message_headers h "
        'WHERE h.message_id = m.id AND h.name = ? AND json_valid(h.value) '
        r"AND json_extract(h.value, '$.' || ?) LIKE ? ESCAPE '\'))",
      );
      args.addAll([like, like, like, header.toLowerCase(), field, like]);
    }
    if (before != null) {
      where.add('(m.received_at < ? OR (m.received_at = ? AND m.id < ?))');
      final at = before.receivedAt.millisecondsSinceEpoch;
      args.addAll([at, at, before.id.value]);
    }
    final messages = _db
        .select(
          'SELECT $_columns, EXISTS (SELECT 1 FROM message_bodies x '
          'WHERE x.message_id = m.id) AS downloaded $_from '
          'WHERE ${where.join(' AND ')} '
          'ORDER BY m.received_at DESC, m.id DESC LIMIT ?',
          [...args, limit.clamp(1, 1000)],
        )
        .map((row) => (_fromRow(row), row['downloaded'] == 1))
        .toList(growable: false);
    final files = _headerValues([for (final (m, _) in messages) m.id], header);
    return [
      for (final (m, downloaded) in messages)
        (message: m, files: files[m.id] ?? const [], downloaded: downloaded),
    ];
  }

  /// Messages with attachments (in the folders [withAttachments] lists)
  /// whose files are not known on the device: [header] was never stored
  /// and the body is not downloaded. Newest first.
  List<StoredMessage> withUnknownFiles({
    required String header,
    int limit = 500,
  }) => [
    for (final row in _db.select(
      'SELECT $_columns $_from WHERE m.has_attachments = 1 '
      'AND $_filesFolders AND $_notACopy '
      'AND NOT EXISTS (SELECT 1 FROM message_headers h '
      'WHERE h.message_id = m.id AND h.name = ?) '
      'AND NOT EXISTS (SELECT 1 FROM message_bodies x WHERE x.message_id = m.id) '
      'ORDER BY m.received_at DESC, m.id DESC LIMIT ?',
      [header.toLowerCase(), limit.clamp(1, 5000)],
    ))
      _fromRow(row),
  ];

  /// Replaces the values of the kept header [name] of message
  /// [messageId] (none removes it). For what the app learns about a
  /// message later, such as the files found in it.
  void setHeader(
    MessageId messageId,
    String name,
    List<String> values,
  ) => _db.transaction(() {
    _db.execute(
      'DELETE FROM message_headers WHERE message_id = ? AND name = ?',
      [messageId.value, name.toLowerCase()],
    );
    _db.executeMany(
      'INSERT INTO message_headers (message_id, name, position, value) '
      'SELECT ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM messages WHERE id = ?)',
      [
        for (var i = 0; i < values.length; i++)
          [messageId.value, name.toLowerCase(), i, values[i], messageId.value],
      ],
    );
  });

  /// Values of header [name] of [ids], by message, in order.
  Map<MessageId, List<String>> _headerValues(List<MessageId> ids, String name) {
    final result = <MessageId, List<String>>{};
    for (var i = 0; i < ids.length; i += 500) {
      final chunk = ids.sublist(i, (i + 500).clamp(0, ids.length));
      for (final row in _db.select(
        'SELECT message_id, value FROM message_headers '
        'WHERE name = ? AND message_id IN (${_placeholders(chunk.length)}) '
        'ORDER BY message_id, position',
        [name.toLowerCase(), for (final id in chunk) id.value],
      )) {
        result
            .putIfAbsent(MessageId(row['message_id'] as int), () => [])
            .add(row['value'] as String);
      }
    }
    return result;
  }

  static String _escapeLike(String text) => text
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  /// Code mail in [mailboxId] received since [since] whose body was not
  /// looked at for a code yet, at most [maxSize] bytes, newest first.
  List<StoredMessage> codesToRead(
    MailboxId mailboxId, {
    required DateTime since,
    required int maxSize,
    int limit = 20,
  }) => [
    for (final row in _db.select(
      'SELECT $_columns $_from WHERE m.mailbox_id = ? AND m.category = ? '
      'AND m.code IS NULL AND m.received_at >= ? AND m.size <= ? '
      'ORDER BY m.received_at DESC, m.id DESC LIMIT ?',
      [
        mailboxId.value,
        MessageCategory.codes.storageName,
        since.toUtc().millisecondsSinceEpoch,
        maxSize,
        limit.clamp(1, 200),
      ],
    ))
      _fromRow(row),
  ];

  /// Records the code found in message [id] ('' for none).
  void setCode(MessageId id, String code) => _db.execute(
    'UPDATE messages SET code = ? WHERE id = ?',
    [code, id.value],
  );

  void updateCategories(List<CategoryDecision> decisions) =>
      _db.transaction(() {
        _db.executeMany(
          'UPDATE messages SET category = ?, category_source = ?, list_id = ?, '
          'code = coalesce(code, ?) WHERE id = ?',
          [
            for (final d in decisions)
              [
                d.category.storageName,
                d.source.name,
                d.listId,
                d.code,
                d.messageId.value,
              ],
          ],
        );
        SectionSql.refreshIds(_db, [for (final d in decisions) d.messageId]);
      });

  /// Totals and unread counts of every Smart Inbox section, across the
  /// inboxes of [accountIds] (or all accounts). Reads the section index
  /// (and, for Notifications and the Screener, leaves read receipts out).
  Map<SmartSection, SectionCount> sectionCounts({
    List<AccountId>? accountIds,
  }) => addSectionCounts(sectionCountsByInbox(accountIds: accountIds).values);

  /// [sectionCounts] of each inbox of [accountIds] (or every account), in
  /// one pass over the section index: the counts of any set of accounts
  /// are the sum of their inboxes' ([addSectionCounts]).
  Map<MailboxId, Map<SmartSection, SectionCount>> sectionCountsByInbox({
    List<AccountId>? accountIds,
  }) {
    final inboxes = inboxIds(accountIds: accountIds);
    final byInbox = {
      for (final id in inboxes)
        id: {for (final s in SmartSection.values) s: SectionCount.empty},
    };
    if (inboxes.isEmpty) return byInbox;
    final args = [for (final id in inboxes) id.value];
    final [totals, unread, receipts] = [
      for (final sql in _sectionCountSql(inboxes.length)) _db.select(sql, args),
    ];
    void add(
      ResultSet rows,
      int Function(Row) total,
      int Function(Row) unread,
    ) {
      for (final row in rows) {
        final counts = byInbox[MailboxId(row['mailbox_id'] as int)]!;
        final section = SmartSection.values.byName(row['section'] as String);
        final was = counts[section]!;
        counts[section] = SectionCount(
          was.total + total(row),
          was.unread + unread(row),
        );
      }
    }

    add(totals, (r) => r['n'] as int, (_) => 0);
    add(unread, (_) => 0, (r) => r['n'] as int);
    add(receipts, (r) => -(r['n'] as int), (r) => -(r['unread'] as int));
    return byInbox;
  }

  /// The queries of [sectionCountsByInbox] for [folders] inboxes: every
  /// row, then those unread, each read from an index alone (grouped in
  /// its order, so SQLite counts as it reads); then the read receipts to
  /// leave out, found through the index of report headers.
  static List<String> _sectionCountSql(int folders) {
    final ids = _placeholders(folders);
    final hidden = SectionSql.receiptFreeSections.map((s) => "'$s'").join(', ');
    const grouped = 'GROUP BY mailbox_id, section ORDER BY mailbox_id, section';
    final totals =
        'SELECT mailbox_id, section, count(*) AS n FROM messages '
        'WHERE mailbox_id IN ($ids) $grouped';
    final unread =
        'SELECT mailbox_id, section, count(*) AS n FROM messages '
        'WHERE mailbox_id IN ($ids) AND (flags & 1) = 0 $grouped';
    // From the few receipts to their rows (not through the inbox).
    final receipts =
        'SELECT mailbox_id, section, count(*) AS n, '
        'sum((flags & 1) = 0) AS unread FROM messages '
        'WHERE id IN (${SectionSql.readReceiptIds}) '
        'AND +mailbox_id IN ($ids) AND +section IN ($hidden) '
        "AND +category = 'notifications' GROUP BY mailbox_id, section";
    return [totals, unread, receipts];
  }

  /// How SQLite runs the queries of [sectionCountsByInbox] (for tests that
  /// make sure counting stays index reads).
  List<String> debugSectionCountPlan() {
    final inboxes = inboxIds();
    return [
      for (final sql in _sectionCountSql(inboxes.length))
        for (final row in _db.select('EXPLAIN QUERY PLAN $sql', [
          for (final id in inboxes) id.value,
        ]))
          row['detail'] as String,
    ];
  }

  /// The section counts of several inboxes together.
  static Map<SmartSection, SectionCount> addSectionCounts(
    Iterable<Map<SmartSection, SectionCount>> inboxes,
  ) {
    final totals = {for (final s in SmartSection.values) s: 0};
    final unread = {for (final s in SmartSection.values) s: 0};
    for (final counts in inboxes) {
      for (final MapEntry(key: s, value: c) in counts.entries) {
        totals[s] = totals[s]! + c.total;
        unread[s] = unread[s]! + c.unread;
      }
    }
    return {
      for (final s in SmartSection.values)
        s: SectionCount(totals[s]!, unread[s]!),
    };
  }

  /// Unread messages per folder, for every folder at once (snoozed mail
  /// isn't counted).
  Map<MailboxId, int> unreadCounts() => {
    for (final row in _db.select(
      'SELECT mailbox_id, count(*) AS n FROM messages WHERE (flags & 1) = 0 '
      "AND section != 'snoozed' GROUP BY mailbox_id",
    ))
      MailboxId(row['mailbox_id'] as int): row['n'] as int,
  };

  /// The INBOX folder ids of [accountIds] (or every account).
  List<MailboxId> inboxIds({List<AccountId>? accountIds}) => [
    for (final row in _db.select(
      "SELECT id, account_id FROM mailboxes WHERE upper(encoded_name) = 'INBOX'",
    ))
      if (accountIds == null ||
          accountIds.contains(AccountId(row['account_id'] as int)))
        MailboxId(row['id'] as int),
  ];

  // ---------------------------------------------------------------------

  void _replaceAddresses(MessageId messageId, MessageSummary s) {
    _db.execute('DELETE FROM message_addresses WHERE message_id = ?', [
      messageId.value,
    ]);
    final rows = <List<Object?>>[];
    void add(String kind, List<MailAddress> list) {
      for (var i = 0; i < list.length; i++) {
        rows.add([
          messageId.value,
          kind,
          i,
          list[i].displayName,
          list[i].address,
        ]);
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

  void _replaceHeaders(MessageId messageId, Map<String, List<String>> headers) {
    _db.execute('DELETE FROM message_headers WHERE message_id = ?', [
      messageId.value,
    ]);
    _db.executeMany(
      'INSERT INTO message_headers (message_id, name, position, value) VALUES (?, ?, ?, ?)',
      [
        for (final MapEntry(key: name, value: values) in headers.entries)
          for (var i = 0; i < values.length; i++)
            [messageId.value, name.toLowerCase(), i, values[i]],
      ],
    );
  }

  /// Stores the message's References one per row (`message_references`),
  /// so that "is this a reply to something the user sent" is an index
  /// lookup. The joined list stays in `messages.thread_references`.
  void _replaceReferences(MessageId messageId, Iterable<String> references) {
    _db.execute('DELETE FROM message_references WHERE message_id = ?', [
      messageId.value,
    ]);
    _db.executeMany(
      'INSERT OR IGNORE INTO message_references (message_id, ref) VALUES (?, ?)',
      [
        for (final ref in references.toSet())
          if (ref.isNotEmpty) [messageId.value, ref],
      ],
    );
  }

  /// The sender's domain in lower case (`messages.from_domain`), or null
  /// without a sender or a domain.
  static String? _domainOf(MailAddress? from) {
    final domain = from?.domain.toLowerCase();
    return domain == null || domain.isEmpty ? null : domain;
  }

  /// Indexes subject and participants, keeping any body text already
  /// indexed for this message.
  void _indexSummary(MessageId messageId, MessageSummary s) {
    final existing = _db.select(
      'SELECT body FROM message_search WHERE rowid = ?',
      [messageId.value],
    );
    final body = existing.isEmpty
        ? ''
        : existing.first['body'] as String? ?? '';
    final participants = [
      ?s.from,
      ...s.to,
      ...s.cc,
    ].map((a) => '${a.displayName ?? ''} ${a.address}').join(' ');
    _db.execute('DELETE FROM message_search WHERE rowid = ?', [
      messageId.value,
    ]);
    _db.execute(
      'INSERT INTO message_search (rowid, subject, participants, body) VALUES (?, ?, ?, ?)',
      [messageId.value, s.subject ?? '', participants, body],
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
      id: MessageId(row['id'] as int),
      mailboxId: MailboxId(row['mailbox_id'] as int),
      accountId: AccountId(row['account_id'] as int),
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
      code: row['code'] as String?,
      listedAt: DateTime.fromMillisecondsSinceEpoch(
        row['listed_at'] as int,
        isUtc: true,
      ),
    );
  }
}

/// One sender's received mail, added up by the store (see
/// [MessageRepository.senderStats]). What the Clean up page counts.
final class SenderStats {
  const SenderStats({
    required this.from,
    required this.count,
    required this.opened,
    required this.newsletters,
    required this.notifications,
    required this.last,
    required this.newestId,
    this.unsubscribeId,
    this.unsubscribeAt,
  });

  /// The address as the newest message spelt it, with the display name
  /// used most (or none).
  final MailAddress from;

  /// How many messages, and how many of them were opened.
  final int count;
  final int opened;

  /// How many are newsletters, and notifications.
  final int newsletters;
  final int notifications;

  /// When the newest came, and its stored id.
  final DateTime last;
  final MessageId newestId;

  /// The newest message with a `List-Unsubscribe` header, if any, and
  /// when it came.
  final MessageId? unsubscribeId;
  final DateTime? unsubscribeAt;
}

/// Running totals of one address while [MessageRepository.senderStats]
/// adds up its rows (one per display name).
final class _SenderTotals {
  int count = 0, opened = 0, newsletters = 0, notifications = 0;
  int last = -1;
  MessageId newestId = const MessageId(0);
  String spelled = '';
  final names = <String, int>{};

  String? get mostUsedName {
    String? best;
    var most = 0;
    for (final MapEntry(key: name, value: n) in names.entries) {
      if (n > most) {
        best = name;
        most = n;
      }
    }
    return best;
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
    required this.bodiesLeftOut,
  });

  final List<Map<String, Object?>> messages;
  final List<Map<String, Object?>> addresses;
  final List<Map<String, Object?>> headers;

  /// The downloaded bodies that fit the snapshot's size limit.
  final List<Map<String, Object?>> bodies;
  final List<Map<String, Object?>> search;

  /// How many downloaded bodies did not fit: those messages come back
  /// without one, and are downloaded again when opened.
  final int bodiesLeftOut;

  bool get isEmpty => messages.isEmpty;

  /// Bytes of the downloaded bodies kept.
  int get bodyBytes => bodies.fold(
    0,
    (sum, row) => sum + ((row['raw'] as Uint8List?)?.length ?? 0),
  );

  /// Several snapshots as one: a removal done in steps keeps one per
  /// step, and is undone as a whole.
  factory MessageSnapshot.join(Iterable<MessageSnapshot> parts) {
    final list = parts.toList(growable: false);
    if (list.length == 1) return list.single;
    return MessageSnapshot._(
      messages: [for (final p in list) ...p.messages],
      addresses: [for (final p in list) ...p.addresses],
      headers: [for (final p in list) ...p.headers],
      bodies: [for (final p in list) ...p.bodies],
      search: [for (final p in list) ...p.search],
      bodiesLeftOut: list.fold(0, (sum, p) => sum + p.bodiesLeftOut),
    );
  }

  /// This snapshot in parts of at most [size] messages, in order, each
  /// with its own messages' addresses, headers, body and search text: to
  /// put thousands of messages back a part at a time.
  List<MessageSnapshot> split(int size) {
    if (size < 1) throw ArgumentError.value(size, 'size');
    if (messages.length <= size) return [this];
    final part = <int, int>{
      for (final (i, row) in messages.indexed) row['id']! as int: i ~/ size,
    };
    final count = (messages.length + size - 1) ~/ size;
    List<List<Map<String, Object?>>> byPart(
      List<Map<String, Object?>> rows,
      String key,
    ) {
      final parts = [for (var i = 0; i < count; i++) <Map<String, Object?>>[]];
      for (final row in rows) {
        if (part[row[key]] case final i?) parts[i].add(row);
      }
      return parts;
    }

    final addresses = byPart(this.addresses, 'message_id');
    final headers = byPart(this.headers, 'message_id');
    final bodies = byPart(this.bodies, 'message_id');
    final search = byPart(this.search, 'id');
    return [
      for (var i = 0; i < count; i++)
        MessageSnapshot._(
          messages: messages.sublist(
            i * size,
            (i + 1) * size > messages.length ? messages.length : (i + 1) * size,
          ),
          addresses: addresses[i],
          headers: headers[i],
          bodies: bodies[i],
          search: search[i],
          // Counted once, with the first part.
          bodiesLeftOut: i == 0 ? bodiesLeftOut : 0,
        ),
    ];
  }
}

/// What a search found ([MessageRepository.searchForgiving]).
final class SearchResults {
  SearchResults(this.messages, {int? exactCount, this.correctedText})
    : exactCount = exactCount ?? messages.length;

  /// Fewer exact matches than this, and typos are corrected.
  static const enough = 5;

  /// The exact matches first, newest first, then those found with the
  /// corrections, newest first.
  final List<StoredMessage> messages;

  /// How many of [messages], from the start, match what was typed.
  final int exactCount;

  /// What was searched for with the corrections ("receive invoice" for
  /// "recieve invoice"), when some of [messages] were found that way.
  final String? correctedText;

  bool get corrected => correctedText != null;
}
