// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:sqlite3/sqlite3.dart';

import '../database/mail_database.dart';
import '../model/blocked_sender.dart';
import '../model/message.dart';
import 'app_data_sync_repository.dart';
import 'message_repository.dart';
import 'section_sql.dart';

/// What a Screener decision names: one address, or everyone at a domain
/// (and its subdomains).
enum ScreenerKind { address, domain }

/// The user's answer for a sender.
enum ScreenerDecision {
  /// Their mail goes to the Smart Inbox as usual.
  letIn('in'),

  /// Their mail goes somewhere quieter ([ScreenOutPlace]).
  screenOut('out');

  const ScreenerDecision(this.storageName);

  final String storageName;

  static ScreenerDecision fromStorage(String value) =>
      values.firstWhere((d) => d.storageName == value);
}

/// Where mail from screened-out senders goes. Never deleted, never the
/// server's Junk folder.
enum ScreenOutPlace {
  /// The Newsletters section of the Smart Inbox.
  newsletters,

  /// The Notifications section of the Smart Inbox.
  notifications,

  /// The account's Archive folder (moved on the server, like Archive).
  archive,
}

/// A decision about a sender.
final class ScreenedSender {
  const ScreenedSender({
    required this.id,
    required this.kind,
    required this.value,
    required this.decision,
    required this.since,
  });

  final int id;
  final ScreenerKind kind;

  /// Lower case: `ana@studio.example`, or `studio.example`.
  final String value;
  final ScreenerDecision decision;

  /// When it was decided; with Archive, mail received from then on moves.
  final DateTime since;

  /// Whether this decision is about mail from [address].
  bool matches(String address) => _asBlock.matches(address);

  BlockedSender get _asBlock => BlockedSender(
    id: id,
    kind: BlockKind.values.byName(kind.name),
    value: value,
    since: since,
  );

  /// [value] cleaned for [kind], or throws [ArgumentError].
  static String normalize(ScreenerKind kind, String value) =>
      BlockedSender.normalize(BlockKind.values.byName(kind.name), value);
}

/// One first-time sender waiting in the Screener, with their mail there.
final class WaitingSender {
  const WaitingSender({required this.address, required this.messages});

  /// Lower case.
  final String address;

  /// Oldest first: [first] is the email that brought them here.
  final List<StoredMessage> messages;

  StoredMessage get first => messages.first;
  StoredMessage get latest => messages.last;

  /// The name they gave in their latest email, if any.
  String? get name {
    for (final m in messages.reversed) {
      final name = m.from?.displayName?.trim();
      if (name != null && name.isNotEmpty) return name;
    }
    return null;
  }

  int get unread => messages.where((m) => !m.flags.seen).length;
}

/// The Screener: while it is on, mail from someone who has never written
/// before (and isn't someone the user wrote to, or one of their own
/// addresses) waits in its own place until the user lets the sender in or
/// screens them out. Everything happens on the device: it only changes
/// which Smart Inbox section mail is shown in ([SectionSql]), except that
/// screened-out mail can go to Archive (moved by `ScreenerArchiver` in
/// mail_sync, like any archive).
///
/// Turning it on counts every sender the user already has mail from as
/// let in, without listing them: only mail from senders with no mail from
/// before that moment can wait.
final class ScreenerRepository {
  ScreenerRepository(this._db);

  final MailDatabase _db;

  static const sinceKey = 'screener.since';
  static const outKey = 'screener.out';
  static const _columns = 'id, kind, value, decision, since';

  // ------------------------------------------------------------- settings

  bool get enabled => since != null;

  /// When it was turned on, or null while it is off.
  DateTime? get since {
    final value = _read(sinceKey);
    final ms = value == null ? null : int.tryParse(value);
    return ms == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }

  /// Turns the Screener on: senders with mail on the device count as let
  /// in, including mail that arrived a moment ago (by the server's clock).
  void enable({DateTime? now}) => _db.transaction(() {
    if (enabled) return;
    final newest =
        _db.select('SELECT max(received_at) FROM messages').first.columnAt(0)
            as int?;
    var at = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
    if (newest != null && newest >= at) at = newest + 1;
    _write(sinceKey, '$at');
    SectionSql.refresh(_db, 'received_at >= ?', [at]);
    // Decisions kept from an earlier time apply again.
    for (final s in all()) {
      if (s.decision == ScreenerDecision.screenOut) {
        _refreshSender(s.kind, s.value);
      }
    }
  });

  /// Turns it off: everything waiting goes to the Smart Inbox, and
  /// screened-out mail back to where it would be. Decisions are kept for
  /// when it is turned on again.
  void disable() => _db.transaction(() {
    if (!enabled) return;
    _db.execute('DELETE FROM settings WHERE key = ?', [sinceKey]);
    _refreshScreenerSections();
  });

  ScreenOutPlace get outPlace => ScreenOutPlace.values.firstWhere(
    (p) => p.name == _read(outKey),
    orElse: () => ScreenOutPlace.newsletters,
  );

  set outPlace(ScreenOutPlace place) => _db.transaction(() {
    _write(outKey, place.name);
    _refreshScreenerSections();
  });

  // ------------------------------------------------------------ decisions

  /// Records [decision] for [value] (replacing an earlier one), and moves
  /// the sender's mail on the device to match. Returns the decision as
  /// stored. Throws [ArgumentError] for a value that isn't an address or
  /// domain.
  ScreenedSender decide(
    ScreenerKind kind,
    String value,
    ScreenerDecision decision, {
    DateTime? now,
  }) => _db.transaction(() {
    final normalized = ScreenedSender.normalize(kind, value);
    final at = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
    _db.execute(
      'INSERT INTO screener_senders (kind, value, decision, since) VALUES (?, ?, ?, ?) '
      'ON CONFLICT (kind, value) DO UPDATE SET decision = excluded.decision, '
      'since = excluded.since WHERE decision != excluded.decision',
      [kind.name, normalized, decision.storageName, at],
    );
    _refreshSender(kind, normalized);
    return find(kind, normalized)!;
  });

  /// Forgets a decision, remembering that for the user's other devices
  /// ([at] and [device] when applying another device's removal). The
  /// sender's new mail waits in the Screener again.
  void remove(int id, {DateTime? at, String? device}) => _db.transaction(() {
    final rows = _db.select(
      'SELECT $_columns FROM screener_senders WHERE id = ?',
      [id],
    );
    if (rows.isEmpty) return;
    final s = _fromRow(rows.first);
    _db.execute('DELETE FROM screener_senders WHERE id = ?', [id]);
    AppDataSyncRepository(_db).recordRemoval(
      AppDataKeys.screener(s.kind, s.value),
      'screener',
      at: at,
      device: device,
    );
    _refreshSender(s.kind, s.value);
  });

  /// Puts back a decision as it was before (for Undo): [previous], or no
  /// decision for [current]'s sender if there was none.
  void restore(ScreenedSender current, ScreenedSender? previous) {
    if (previous == null) {
      remove(current.id);
    } else {
      decide(
        previous.kind,
        previous.value,
        previous.decision,
        now: previous.since,
      );
    }
  }

  ScreenedSender? find(ScreenerKind kind, String value) {
    final rows = _db.select(
      'SELECT $_columns FROM screener_senders WHERE kind = ? AND value = ?',
      [kind.name, value.toLowerCase()],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// The decision that applies to mail from [address] (an address
  /// decision before a domain one), if any.
  ScreenedSender? matching(String? address) {
    if (address == null) return null;
    final lower = address.toLowerCase();
    final at = lower.lastIndexOf('@');
    if (at < 0) return null;
    // The domain and each parent domain: a.b.shop.example -> shop.example.
    final labels = lower.substring(at + 1).split('.');
    final domains = [
      for (var i = 0; i < labels.length - 1; i++) labels.sublist(i).join('.'),
    ];
    final rows = _db.select(
      'SELECT $_columns FROM screener_senders '
      "WHERE (kind = 'address' AND value = ?) "
      "OR (kind = 'domain' AND value IN (${List.filled(domains.length, '?').join(', ')})) "
      "ORDER BY kind = 'domain', id LIMIT 1",
      [lower, ...domains],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Every decision, newest first.
  List<ScreenedSender> all() => _db
      .select(
        'SELECT $_columns FROM screener_senders ORDER BY since DESC, id DESC',
      )
      .map(_fromRow)
      .toList(growable: false);

  // -------------------------------------------------------------- waiting

  /// The senders waiting in the inboxes of [accountIds] (or every
  /// account), the one who wrote most recently first.
  List<WaitingSender> waiting({List<int>? accountIds}) {
    final messages = MessageRepository(_db).list(
      MessageQuery.smart(
        SmartSection.screener,
        accountIds: accountIds,
        limit: 500,
      ),
    );
    final bySender = <String, List<StoredMessage>>{};
    for (final m in messages.reversed) {
      final address = m.from?.address.toLowerCase();
      if (address == null) continue;
      bySender.putIfAbsent(address, () => []).add(m);
    }
    final senders = [
      for (final MapEntry(:key, :value) in bySender.entries)
        WaitingSender(address: key, messages: List.unmodifiable(value)),
    ];
    senders.sort((a, b) => b.latest.receivedAt.compareTo(a.latest.receivedAt));
    return senders;
  }

  /// How many senders are waiting (in the inboxes of [accountIds], or
  /// every account). Reads the section index.
  int waitingCount({List<int>? accountIds}) {
    final inboxes = MessageRepository(_db).inboxIds(accountIds: accountIds);
    if (inboxes.isEmpty) return 0;
    return _db
            .select(
              'SELECT count(DISTINCT lower(from_address)) FROM messages '
              'WHERE mailbox_id IN (${List.filled(inboxes.length, '?').join(', ')}) '
              "AND section = 'screener'",
              inboxes,
            )
            .first
            .columnAt(0)
        as int;
  }

  /// Ids of inbox messages of [mailboxId], received at or after [since],
  /// that the Screener sends elsewhere (screened out), newest first. Used
  /// to move them to Archive.
  List<int> screenedOutIds(int mailboxId, DateTime since) => [
    for (final row in _db.select(
      'SELECT id FROM messages WHERE mailbox_id = ? AND received_at >= ? '
      'AND (flags & 4) = 0 AND category != ? AND ${SectionSql.screenedOut} '
      'ORDER BY received_at DESC, id DESC',
      [
        mailboxId,
        since.toUtc().millisecondsSinceEpoch,
        MessageCategory.codes.storageName,
      ],
    ))
      row['id'] as int,
  ];

  // ---------------------------------------------------------------------

  void _refreshSender(ScreenerKind kind, String value) => switch (kind) {
    ScreenerKind.address => SectionSql.refresh(
      _db,
      'from_address = ? COLLATE NOCASE',
      [value],
    ),
    // Domains are [a-z0-9.-] (see BlockedSender.normalize): safe in LIKE.
    ScreenerKind.domain => SectionSql.refresh(
      _db,
      'from_address LIKE ? OR from_address LIKE ?',
      ['%@$value', '%.$value'],
    ),
  };

  /// Mail whose section the Screener's settings can change.
  void _refreshScreenerSections() => SectionSql.refresh(
    _db,
    "section IN ('screener', 'newsletters', 'notifications')",
  );

  String? _read(String key) {
    final rows = _db.select('SELECT value FROM settings WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first.columnAt(0) as String;
  }

  void _write(String key, String value) => _db.execute(
    'INSERT INTO settings (key, value) VALUES (?, ?) '
    'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
    [key, value],
  );

  static ScreenedSender _fromRow(Row row) => ScreenedSender(
    id: row['id'] as int,
    kind: ScreenerKind.values.byName(row['kind'] as String),
    value: row['value'] as String,
    decision: ScreenerDecision.fromStorage(row['decision'] as String),
    since: DateTime.fromMillisecondsSinceEpoch(
      row['since'] as int,
      isUtc: true,
    ),
  );
}
