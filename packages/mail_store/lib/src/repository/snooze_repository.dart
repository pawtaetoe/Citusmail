// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:sqlite3/sqlite3.dart';

import '../database/mail_database.dart';
import '../model/message.dart';
import 'app_data_sync_repository.dart';
import 'message_repository.dart';
import 'section_sql.dart';

/// A message put away until [until].
final class Snooze {
  const Snooze({
    required this.messageId,
    required this.until,
    required this.changedAt,
  });

  /// The message's Message-ID (without brackets): the same on every
  /// device and in every account it was delivered to.
  final String messageId;

  /// When it comes back (UTC).
  final DateTime until;

  /// When it was snoozed, or its time last changed (UTC).
  final DateTime changedAt;

  @override
  bool operator ==(Object other) =>
      other is Snooze &&
      other.messageId == messageId &&
      other.until == until &&
      other.changedAt == changedAt;

  @override
  int get hashCode => Object.hash(messageId, until, changedAt);

  @override
  String toString() => 'Snooze($messageId until $until)';
}

/// A snoozed message in an inbox, for the Snoozed list.
final class SnoozedMessage {
  const SnoozedMessage(this.snooze, this.message);

  final Snooze snooze;
  final StoredMessage message;
}

/// Why a snoozed message came back.
enum WakeReason {
  /// Its time came.
  due,

  /// A reply in the same conversation arrived.
  reply,
}

/// A message back from snooze.
final class WokenMessage {
  const WokenMessage(this.message, this.reason, this.at);

  /// The inbox copy, as it is now.
  final StoredMessage message;
  final WakeReason reason;

  /// When it came back (where it is listed).
  final DateTime at;
}

/// Snooze: inbox mail put away until a chosen time. Everything happens on
/// the device and nothing moves on the mail server (other mail apps still
/// show the message in the inbox): while snoozed, a message is in the
/// `snoozed` section ([SectionSql.snoozed]), left out of the Smart Inbox,
/// its counts and new-mail notifications.
///
/// When it comes back ([wake]), the snooze ends and the message is listed
/// at that time (`listed_at`), so it shows at the top of the inbox. Snoozes
/// are keyed by Message-ID, so they sync between the user's devices (an
/// ended snooze is a removal, see [AppDataSyncRepository]).
final class SnoozeRepository {
  SnoozeRepository(this._db);

  final MailDatabase _db;

  static const kind = 'snooze';
  static const _columns = 'message_id, until, changed_at';

  /// Snoozes [messageId] until [until] (or changes the time of its
  /// snooze). Throws [ArgumentError] for an empty Message-ID.
  Snooze snooze(
    String messageId,
    DateTime until, {
    DateTime? now,
  }) => _db.transaction(() {
    if (messageId.isEmpty || messageId.length > 998) {
      throw ArgumentError.value(messageId, 'messageId');
    }
    final at = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
    _db.execute(
      'INSERT INTO snoozes (message_id, until, changed_at) VALUES (?, ?, ?) '
      'ON CONFLICT (message_id) DO UPDATE SET until = excluded.until, '
      'changed_at = excluded.changed_at',
      [messageId, until.toUtc().millisecondsSinceEpoch, at],
    );
    // Snoozed again: an earlier end (in the same instant) is over.
    _db.execute('DELETE FROM sync_tombstones WHERE key = ?', [_key(messageId)]);
    _refresh(messageId);
    return find(messageId)!;
  });

  /// Puts back a snooze as another device has it, keeping its times.
  /// (Undo snoozes again with [snooze], so other devices see it as new.)
  void restore(Snooze snooze) => _db.transaction(() {
    _db.execute(
      'INSERT INTO snoozes (message_id, until, changed_at) VALUES (?, ?, ?) '
      'ON CONFLICT (message_id) DO UPDATE SET until = excluded.until, '
      'changed_at = excluded.changed_at',
      [
        snooze.messageId,
        snooze.until.millisecondsSinceEpoch,
        snooze.changedAt.millisecondsSinceEpoch,
      ],
    );
    _refresh(snooze.messageId);
  });

  /// Ends the snooze of [messageId] without it coming back as new
  /// (Unsnooze, or the message was moved or deleted): it shows where it
  /// was. The removal is remembered for the user's other devices ([at] and
  /// [device] when applying another device's). Returns the ended snooze.
  Snooze? cancel(String messageId, {DateTime? at, String? device}) =>
      _db.transaction(() {
        final snooze = find(messageId);
        if (snooze == null) return null;
        _end(snooze, at: at, device: device);
        return snooze;
      });

  /// Ends the snoozes of those of [messages] that are snoozed inbox mail
  /// (they are being moved or deleted). Returns the ended snoozes, for
  /// Undo ([restore]).
  List<Snooze> cancelFor(List<StoredMessage> messages) => _db.transaction(() {
    final ended = <Snooze>[];
    for (final m in messages) {
      final id = m.messageId;
      if (id == null || m.section != SmartSection.snoozed) continue;
      if (cancel(id) case final snooze?) ended.add(snooze);
    }
    return ended;
  });

  Snooze? find(String messageId) {
    final rows = _db.select(
      'SELECT $_columns FROM snoozes WHERE message_id = ?',
      [messageId],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Every snooze, soonest back first (also those whose message isn't
  /// on this device).
  List<Snooze> all() => _db
      .select('SELECT $_columns FROM snoozes ORDER BY until, message_id')
      .map(_fromRow)
      .toList(growable: false);

  /// When the next snooze is due, if any.
  DateTime? nextDue() {
    final ms =
        _db.select('SELECT min(until) FROM snoozes').first.columnAt(0) as int?;
    return ms == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }

  /// The snoozed mail in the inboxes of [accountIds] (or every account),
  /// soonest back first; a message in several inboxes once.
  List<SnoozedMessage> list({List<int>? accountIds}) {
    final inboxes = MessageRepository(_db).inboxIds(accountIds: accountIds);
    if (inboxes.isEmpty) return const [];
    final messages = MessageRepository(_db).list(
      MessageQuery(
        mailboxIds: inboxes,
        section: SmartSection.snoozed,
        limit: 500,
      ),
    );
    final byId = <String, StoredMessage>{};
    for (final m in messages) {
      byId.putIfAbsent(m.messageId!, () => m);
    }
    return [
      for (final s in all())
        if (byId[s.messageId] case final m?) SnoozedMessage(s, m),
    ];
  }

  /// How many messages are snoozed in the inboxes of [accountIds] (or
  /// every account). Reads the section index.
  int count({List<int>? accountIds}) {
    final inboxes = MessageRepository(_db).inboxIds(accountIds: accountIds);
    if (inboxes.isEmpty) return 0;
    return _db
            .select(
              'SELECT count(DISTINCT message_id_header) FROM messages '
              'WHERE mailbox_id IN (${List.filled(inboxes.length, '?').join(', ')}) '
              "AND section = 'snoozed'",
              inboxes,
            )
            .first
            .columnAt(0)
        as int;
  }

  /// Brings back the snoozes that are due at [now], and those whose
  /// conversation got a reply in an inbox since they were snoozed. Each
  /// comes back at the top of its inbox: listed at the time it was due
  /// (or at [now] for a reply). The ends are remembered for the user's
  /// other devices. Returns the inbox messages that came back, oldest
  /// return first; marking them unread is up to the caller.
  List<WokenMessage> wake({DateTime? now}) => _db.transaction(() {
    final at = (now ?? DateTime.now()).toUtc();
    final active = all();
    if (active.isEmpty) return const [];
    final replied = _replied(active);
    final woken = <WokenMessage>[];
    for (final s in active) {
      final WakeReason reason;
      final DateTime back;
      if (!s.until.isAfter(at)) {
        reason = WakeReason.due;
        back = s.until;
      } else if (replied.contains(s.messageId)) {
        reason = WakeReason.reply;
        back = at;
      } else {
        continue;
      }
      for (final m in _end(s, back: back, at: at)) {
        woken.add(WokenMessage(m, reason, back));
      }
    }
    woken.sort((a, b) => a.at.compareTo(b.at));
    return woken;
  });

  /// Ends [snooze] because it came back elsewhere: on another device, at
  /// [at] by its clock. Lists it at its due time, like [wake].
  void wokeElsewhere(Snooze snooze, {DateTime? at, String? device}) =>
      _db.transaction(() {
        _end(snooze, back: snooze.until, at: at, device: device);
      });

  /// Removes [snooze] (remembering that for other devices) and refreshes
  /// its messages; with [back], lists its inbox copies at that time.
  /// Returns its inbox messages, as they are now.
  List<StoredMessage> _end(
    Snooze snooze, {
    DateTime? back,
    DateTime? at,
    String? device,
  }) {
    _db.execute('DELETE FROM snoozes WHERE message_id = ?', [snooze.messageId]);
    AppDataSyncRepository(_db)
        .recordRemoval(_key(snooze.messageId), kind, at: at, device: device);
    final inbox = _inboxWhere;
    if (back != null) {
      _db.execute(
        'UPDATE messages SET listed_at = max(received_at, ?) '
        'WHERE message_id_header = ? AND $inbox',
        [back.toUtc().millisecondsSinceEpoch, snooze.messageId],
      );
    }
    _refresh(snooze.messageId);
    final messages = MessageRepository(_db);
    return [
      for (final row in _db.select(
        'SELECT id FROM messages WHERE message_id_header = ? AND $inbox '
        'ORDER BY id',
        [snooze.messageId],
      ))
        ?messages.byId(row['id'] as int),
    ];
  }

  /// Message-IDs of [active] snoozes whose conversation got a reply in an
  /// inbox after they were snoozed: a message that names the snoozed
  /// message, or one it answers, in In-Reply-To or References.
  Set<String> _replied(List<Snooze> active) {
    final messages = MessageRepository(_db);
    final inboxes = messages.inboxIds();
    if (inboxes.isEmpty) return const {};
    // What each snoozed message's conversation is known by.
    final keys = <String, String>{}; // Message-ID in a thread -> snooze
    final since = <String, int>{};
    for (final s in active) {
      since[s.messageId] = s.changedAt.millisecondsSinceEpoch;
      keys[s.messageId] = s.messageId;
      for (final row in _db.select(
        'SELECT in_reply_to, thread_references FROM messages '
        'WHERE message_id_header = ? AND $_inboxWhere LIMIT 1',
        [s.messageId],
      )) {
        final parent = row['in_reply_to'] as String?;
        final refs = (row['thread_references'] as String? ?? '')
            .split(' ')
            .where((r) => r.isNotEmpty);
        for (final key in [?parent, ...refs]) {
          keys.putIfAbsent(key, () => s.messageId);
        }
      }
    }
    final earliest = since.values.reduce((a, b) => a < b ? a : b);
    final found = <String>{};
    for (final inbox in inboxes) {
      for (final row in _db.select(
        'SELECT message_id_header, in_reply_to, thread_references, received_at '
        'FROM messages WHERE mailbox_id = ? AND received_at > ? '
        "AND (in_reply_to IS NOT NULL OR coalesce(thread_references, '') != '') "
        'ORDER BY received_at DESC, id DESC',
        [inbox, earliest],
      )) {
        final own = row['message_id_header'] as String?;
        final names = [
          ?row['in_reply_to'] as String?,
          ...(row['thread_references'] as String? ?? '')
              .split(' ')
              .where((r) => r.isNotEmpty),
        ];
        for (final name in names) {
          final snoozed = keys[name];
          if (snoozed == null || snoozed == own) continue;
          if ((row['received_at'] as int) > since[snoozed]!) found.add(snoozed);
        }
      }
    }
    return found;
  }

  static const _inboxWhere =
      "mailbox_id IN (SELECT id FROM mailboxes WHERE upper(encoded_name) = 'INBOX')";

  void _refresh(String messageId) =>
      SectionSql.refresh(_db, 'message_id_header = ?', [messageId]);

  static String _key(String messageId) => AppDataKeys.snooze(messageId);

  static Snooze _fromRow(Row row) => Snooze(
    messageId: row['message_id'] as String,
    until: DateTime.fromMillisecondsSinceEpoch(
      row['until'] as int,
      isUtc: true,
    ),
    changedAt: DateTime.fromMillisecondsSinceEpoch(
      row['changed_at'] as int,
      isUtc: true,
    ),
  );
}
