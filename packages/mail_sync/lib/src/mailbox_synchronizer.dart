// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'summary_mapper.dart';

/// Tuning for message sync.
final class SyncSettings {
  const SyncSettings({
    this.initialWindow = 500,
    this.fetchBatch = 100,
    this.backfillBatch = 500,
    this.connections = 3,
  });

  /// Newest messages downloaded on a folder's first sync. Older ones
  /// follow on later syncs, [backfillBatch] at a time, back to what
  /// [KeepMail] says; and on demand with [MailboxSynchronizer.fetchOlder].
  final int initialWindow;

  /// Messages per FETCH and per stored transaction.
  final int fetchBatch;

  /// Older messages downloaded per folder per sync, until the folder
  /// reaches back to [KeepMail]'s date.
  final int backfillBatch;

  /// Connections per account during a sync: folders are synced side by
  /// side, the inbox first. Servers allow a handful per account (Gmail
  /// 15, Outlook about 16); the app also keeps one for IDLE and one for
  /// opening messages.
  final int connections;
}

/// How far back mail is kept on the device (summaries: headers and a
/// preview; whole messages download when opened). The user's choice, in
/// the settings under [key].
enum KeepMail {
  threeMonths('3m', 91),
  year('1y', 366),
  twoYears('2y', 731),
  everything('all', null);

  const KeepMail(this.storageName, this._days);

  final String storageName;
  final int? _days;

  static const key = 'sync.keepMail';
  static const standard = KeepMail.twoYears;

  static KeepMail read(MailStore store) {
    final value = store.settings.read(key);
    return values.firstWhere(
      (k) => k.storageName == value,
      orElse: () => standard,
    );
  }

  /// The oldest date kept, or null for everything.
  DateTime? since(DateTime now) =>
      _days == null ? null : now.subtract(Duration(days: _days));
}

/// How a folder was synchronised.
enum SyncMethod {
  /// First sync, or after the server reset the folder (UIDVALIDITY).
  full,

  /// QRESYNC (RFC 7162): removals and changes come with SELECT.
  qresync,

  /// CONDSTORE: changed flags by mod-sequence, removals by UID search.
  condstore,

  /// Plain IMAP: all flags in the cached range, removals by UID search.
  plain,
}

/// What a folder sync changed.
final class MailboxSyncResult {
  const MailboxSyncResult({
    required this.method,
    this.added = 0,
    this.updated = 0,
    this.removed = 0,
    this.wasReset = false,
    this.backfilled = 0,
  });

  final SyncMethod method;

  /// New messages.
  final int added;

  /// Older messages downloaded to reach back to [KeepMail]'s date.
  final int backfilled;
  final int updated;
  final int removed;

  /// The server's UIDVALIDITY changed and the cache was rebuilt.
  final bool wasReset;

  bool get hasChanges => added + updated + removed + backfilled > 0 || wasReset;

  @override
  String toString() =>
      'MailboxSyncResult(${method.name}, +$added ~$updated -$removed'
      '${backfilled > 0 ? ' <$backfilled' : ''}${wasReset ? ', reset' : ''})';
}

/// Brings one cached folder in line with the server.
///
/// Safe to interrupt at any point: summaries are stored in batches, and the
/// folder's sync state is saved only after everything has been applied, so
/// an interrupted sync is simply repeated (every write is an upsert).
final class MailboxSynchronizer {
  MailboxSynchronizer(
    this._store,
    this._mapper, {
    this.settings = const SyncSettings(),
  });

  final MailStore _store;
  final SummaryMapper _mapper;
  final SyncSettings settings;

  /// Another synchronizer like this one, for a second connection: one
  /// instance syncs one folder at a time.
  MailboxSynchronizer another() =>
      MailboxSynchronizer(_store, _mapper, settings: settings);

  /// UIDs whose flags must not be overwritten during the current sync.
  Set<int> _pending = const {};

  /// How often removals are looked for by comparing every UID, even when
  /// the folder's counts say nothing was removed: a safety net.
  static const removalCheckInterval = Duration(hours: 1);

  /// Syncs [mailbox]. Flags of messages in [pendingUids] (local changes
  /// still queued for the server) are not overwritten, so the user's change
  /// does not flicker back before the queue reaches the server.
  ///
  /// A folder that did not change costs a SELECT and nothing else: new
  /// mail is looked for only when UIDNEXT moved, changed flags only when
  /// the mod-sequence moved (CONDSTORE), removals only when the message
  /// count says some are gone (QRESYNC reports them with SELECT), and
  /// older mail only until the folder reaches back far enough. On a
  /// server without CONDSTORE, every message's flags are compared only
  /// with [refreshFlags] (the full sync, not the frequent inbox check).
  Future<MailboxSyncResult> sync(
    ImapClient imap,
    StoredMailbox mailbox, {
    Set<int> pendingUids = const {},
    bool refreshFlags = true,
  }) async {
    _pending = pendingUids;
    final cached = mailbox.syncState;
    final lowest = _store.messages.lowestUid(mailbox.id);
    final highest = _store.messages.highestUid(mailbox.id);
    final canQresync =
        imap.enabled.contains('QRESYNC') &&
        cached.uidValidity != null &&
        cached.highestModSeq != null;

    final selected = await imap.select(
      mailbox.encodedName,
      qresync: canQresync
          ? QresyncParameters(
              uidValidity: cached.uidValidity!,
              highestModSeq: cached.highestModSeq!,
              // The range of cached UIDs: a superset is allowed, and it
              // spares reading every UID of the folder.
              knownUids: lowest == null || highest == null
                  ? null
                  : SequenceSet.range(lowest, highest),
            )
          : null,
    );

    if (cached.uidValidity == null ||
        selected.uidValidity != cached.uidValidity) {
      final wasReset = cached.uidValidity != null;
      if (wasReset) {
        _store.mailboxes.resetForUidValidity(mailbox.id, selected.uidValidity);
      }
      final added = await _fullSync(imap, mailbox, selected);
      _FolderMemo(
        uidValidity: selected.uidValidity,
        uidNext: selected.uidNext,
        exists: selected.exists,
        removalsCheckedAt: DateTime.now(),
      ).save(_store, mailbox.id);
      return MailboxSyncResult(
        method: SyncMethod.full,
        added: added,
        wasReset: wasReset,
      );
    }

    final memo = _FolderMemo.read(_store, mailbox.id, cached);
    final newUids = await _newUids(imap, mailbox, cached, selected);
    var removalsCheckedAt = memo?.removalsCheckedAt;
    // Whether messages may have been removed: the count at the last sync,
    // plus the new ones the server had at this SELECT, minus its count
    // now. Any doubt (no count kept, or it is old) means looking.
    bool mayHaveRemovals() {
      final now = DateTime.now();
      final uidNext = selected.uidNext;
      final checkedAt = removalsCheckedAt;
      if (memo == null ||
          uidNext == null ||
          checkedAt == null ||
          now.difference(checkedAt) > removalCheckInterval ||
          now.isBefore(checkedAt)) {
        removalsCheckedAt = now;
        return true;
      }
      final arrived = newUids.where((uid) => uid < uidNext).length;
      if (memo.exists + arrived - selected.exists == 0) return false;
      removalsCheckedAt = now;
      return true;
    }

    final (method, updated, removed) = switch (_methodFor(
      cached,
      selected,
      usedQresync: canQresync,
    )) {
      SyncMethod.qresync => await _applyQresync(mailbox, selected),
      SyncMethod.condstore => await _condstoreChanges(
        imap,
        mailbox,
        cached,
        selected,
        mayHaveRemovals,
      ),
      _ when refreshFlags => await _plainChanges(imap, mailbox, () {
        removalsCheckedAt = DateTime.now();
      }),
      _ => await _plainRemovals(imap, mailbox, mayHaveRemovals),
    };
    final added = await _fetchSummaries(imap, mailbox, newUids);
    _saveState(mailbox, selected);
    var backfillDone = memo?.backfillDone;
    final keep = KeepMail.read(_store).storageName;
    final backfilled = backfillDone == keep
        ? 0
        : await _backfill(imap, mailbox, () => backfillDone = keep);
    _FolderMemo(
      uidValidity: selected.uidValidity,
      uidNext: selected.uidNext,
      exists: selected.exists,
      removalsCheckedAt: removalsCheckedAt,
      backfillDone: backfillDone,
    ).save(_store, mailbox.id);
    return MailboxSyncResult(
      method: method,
      added: added,
      backfilled: backfilled,
      updated: updated,
      removed: removed,
    );
  }

  /// Downloads up to [count] messages older than the oldest cached one.
  Future<int> fetchOlder(
    ImapClient imap,
    StoredMailbox mailbox, {
    int count = 100,
  }) async {
    final lowest = _store.messages.lowestUid(mailbox.id);
    if (lowest == null || lowest <= 1) return 0;
    if (imap.selected?.name != mailbox.encodedName) {
      await imap.select(mailbox.encodedName, readOnly: true);
    }
    final older = (await imap.uidSearch(
      SearchCriteria.uids(SequenceSet.range(1, lowest - 1)),
    )).matches;
    final uids = older.toList();
    return _fetchSummaries(
      imap,
      mailbox,
      uids.sublist(uids.length > count ? uids.length - count : 0),
    );
  }

  /// Older messages, newest first, back to [KeepMail]'s date (on the
  /// server's INTERNALDATE): at most [SyncSettings.backfillBatch] a time,
  /// so a sync stays short; the next one goes on. Calls [done] when the
  /// folder reaches back far enough, so later syncs stop looking (until
  /// the user keeps more). Not on a folder's first sync, which shows its
  /// newest mail first.
  Future<int> _backfill(
    ImapClient imap,
    StoredMailbox mailbox,
    void Function() done,
  ) async {
    if (settings.backfillBatch <= 0) return 0;
    final lowest = _store.messages.lowestUid(mailbox.id);
    if (lowest == null || lowest <= 1) {
      // Nothing older can appear: new mail always gets a higher UID.
      done();
      return 0;
    }
    final since = KeepMail.read(_store).since(DateTime.now());
    final range = SearchCriteria.uids(SequenceSet.range(1, lowest - 1));
    final older = (await imap.uidSearch(
      since == null
          ? range
          : SearchCriteria.and([range, SearchCriteria.since(since)]),
    )).matches.toList();
    if (older.length <= settings.backfillBatch) done();
    if (older.isEmpty) return 0;
    return _fetchSummaries(
      imap,
      mailbox,
      older.sublist(
        older.length > settings.backfillBatch
            ? older.length - settings.backfillBatch
            : 0,
      ),
    );
  }

  // ---------------------------------------------------------------------

  SyncMethod _methodFor(
    MailboxSyncState cached,
    SelectedMailbox selected, {
    required bool usedQresync,
  }) {
    if (usedQresync && selected.highestModSeq != null) {
      return SyncMethod.qresync;
    }
    if (selected.highestModSeq != null && cached.highestModSeq != null) {
      return SyncMethod.condstore;
    }
    return SyncMethod.plain;
  }

  Future<int> _fullSync(
    ImapClient imap,
    StoredMailbox mailbox,
    SelectedMailbox selected,
  ) async {
    var added = 0;
    if (selected.exists > 0) {
      final all = (await imap.uidSearch(SearchCriteria.all())).matches.toList();
      final newest = all.sublist(
        all.length > settings.initialWindow
            ? all.length - settings.initialWindow
            : 0,
      );
      added = await _fetchSummaries(imap, mailbox, newest);
    }
    _saveState(mailbox, selected);
    return added;
  }

  /// QRESYNC delivered removals (VANISHED) and changes (FETCH) with SELECT.
  Future<(SyncMethod, int, int)> _applyQresync(
    StoredMailbox mailbox,
    SelectedMailbox selected,
  ) async {
    final vanished = selected.vanished;
    final removed = vanished == null ? <int>[] : _cachedIn(mailbox, vanished);
    final changes = _flagChanges(mailbox, selected.changedMessages);
    _store.transaction(() {
      if (removed.isNotEmpty) _store.messages.removeUids(mailbox.id, removed);
      if (changes.isNotEmpty) _store.messages.updateFlags(mailbox.id, changes);
    });
    return (SyncMethod.qresync, changes.length, removed.length);
  }

  /// CONDSTORE: flags changed since the cached mod-sequence (nothing to
  /// ask when it did not move); removals by comparing cached UIDs with
  /// the server's, when [mayHaveRemovals].
  Future<(SyncMethod, int, int)> _condstoreChanges(
    ImapClient imap,
    StoredMailbox mailbox,
    MailboxSyncState cached,
    SelectedMailbox selected,
    bool Function() mayHaveRemovals,
  ) async {
    final lowest = _store.messages.lowestUid(mailbox.id);
    if (lowest == null) return (SyncMethod.condstore, 0, 0);
    final changes = selected.highestModSeq == cached.highestModSeq
        ? const <({int uid, MessageFlags flags, int? modSeq})>[]
        : _flagChanges(
            mailbox,
            (await imap.uidFetch(
              SequenceSet.range(lowest),
              FetchItems.flagsOnly(modSeq: true),
              changedSince: cached.highestModSeq,
            )).messages,
          );
    final removed = mayHaveRemovals()
        ? await _removedSince(imap, mailbox, lowest)
        : const <int>[];
    _store.transaction(() {
      if (removed.isNotEmpty) _store.messages.removeUids(mailbox.id, removed);
      if (changes.isNotEmpty) _store.messages.updateFlags(mailbox.id, changes);
    });
    return (SyncMethod.condstore, changes.length, removed.length);
  }

  /// No change tracking, only removals: by comparing cached UIDs with
  /// the server's, when [mayHaveRemovals].
  Future<(SyncMethod, int, int)> _plainRemovals(
    ImapClient imap,
    StoredMailbox mailbox,
    bool Function() mayHaveRemovals,
  ) async {
    final lowest = _store.messages.lowestUid(mailbox.id);
    if (lowest == null || !mayHaveRemovals()) return (SyncMethod.plain, 0, 0);
    final removed = await _removedSince(imap, mailbox, lowest);
    if (removed.isNotEmpty) _store.messages.removeUids(mailbox.id, removed);
    return (SyncMethod.plain, 0, removed.length);
  }

  /// No change tracking: compare every cached message's flags (which
  /// also shows what was removed; [checked] is told so).
  Future<(SyncMethod, int, int)> _plainChanges(
    ImapClient imap,
    StoredMailbox mailbox,
    void Function() checked,
  ) async {
    final lowest = _store.messages.lowestUid(mailbox.id);
    if (lowest == null) return (SyncMethod.plain, 0, 0);
    checked();
    final current = await imap.uidFetch(
      SequenceSet.range(lowest),
      FetchItems.flagsOnly(),
    );
    final serverUids = <int>{for (final m in current.messages) ?m.uid};
    final cachedFlags = _store.messages.flagsByUid(mailbox.id);
    final removed = cachedFlags.keys
        .where((uid) => !serverUids.contains(uid))
        .toList();
    final changes = [
      for (final m in current.messages)
        if (m.uid != null &&
            !_pending.contains(m.uid) &&
            cachedFlags[m.uid] != null &&
            cachedFlags[m.uid] != MessageFlags.fromImap(m.flags ?? const {}))
          (
            uid: m.uid!,
            flags: MessageFlags.fromImap(m.flags ?? const {}),
            modSeq: null,
          ),
    ];
    _store.transaction(() {
      if (removed.isNotEmpty) _store.messages.removeUids(mailbox.id, removed);
      if (changes.isNotEmpty) _store.messages.updateFlags(mailbox.id, changes);
    });
    return (SyncMethod.plain, changes.length, removed.length);
  }

  /// UIDs of messages that arrived since the last sync.
  Future<List<int>> _newUids(
    ImapClient imap,
    StoredMailbox mailbox,
    MailboxSyncState cached,
    SelectedMailbox selected,
  ) async {
    final from =
        cached.uidNext ?? ((_store.messages.highestUid(mailbox.id) ?? 0) + 1);
    if (selected.uidNext != null && selected.uidNext! <= from) return const [];
    if (selected.exists == 0) return const [];
    // "UID n:*" also matches the highest UID when it is below n (RFC 9051
    // 6.4.8), so filter the result.
    final found = (await imap.uidSearch(
      SearchCriteria.uids(SequenceSet.range(from)),
    )).matches;
    return found.toList().where((uid) => uid >= from).toList();
  }

  /// UIDs cached from [lowest] up that the server no longer has.
  Future<List<int>> _removedSince(
    ImapClient imap,
    StoredMailbox mailbox,
    int lowest,
  ) async {
    final onServer = (await imap.uidSearch(
      SearchCriteria.uids(SequenceSet.range(lowest)),
    )).matches;
    return [
      for (final uid in _store.messages.uids(mailbox.id))
        if (!onServer.contains(uid)) uid,
    ];
  }

  /// Fetches and stores summaries in batches; returns how many were stored.
  Future<int> _fetchSummaries(
    ImapClient imap,
    StoredMailbox mailbox,
    List<int> uids,
  ) async {
    var stored = 0;
    final items = SummaryMapper.fetchItems(
      imap.capabilities,
      modSeq: imap.capabilities.has('CONDSTORE'),
    );
    for (var i = 0; i < uids.length; i += settings.fetchBatch) {
      final batch = uids.sublist(
        i,
        i + settings.fetchBatch > uids.length
            ? uids.length
            : i + settings.fetchBatch,
      );
      final fetched = await imap.uidFetch(SequenceSet.of(batch), items);
      final summaries = [
        for (final m in fetched.messages)
          ?_mapper.map(m, mailboxUse: mailbox.specialUse),
      ];
      _store.messages.upsertSummaries(mailbox.id, summaries);
      stored += summaries.length;
    }
    return stored;
  }

  List<({int uid, MessageFlags flags, int? modSeq})> _flagChanges(
    StoredMailbox mailbox,
    List<FetchedMessage> messages,
  ) {
    if (messages.isEmpty) return const [];
    final cached = _store.messages.flagsByUid(mailbox.id);
    return [
      for (final m in messages)
        if (m.uid != null &&
            m.flags != null &&
            cached.containsKey(m.uid) &&
            !_pending.contains(m.uid))
          (
            uid: m.uid!,
            flags: MessageFlags.fromImap(m.flags!),
            modSeq: m.modSeq,
          ),
    ];
  }

  List<int> _cachedIn(StoredMailbox mailbox, SequenceSet set) => [
    for (final uid in _store.messages.uids(mailbox.id))
      if (set.contains(uid)) uid,
  ];

  void _saveState(StoredMailbox mailbox, SelectedMailbox selected) {
    _store.mailboxes.saveSyncState(
      mailbox.id,
      MailboxSyncState(
        uidValidity: selected.uidValidity,
        uidNext: selected.uidNext,
        highestModSeq: selected.highestModSeq,
        lastSyncAt: DateTime.now().toUtc(),
      ),
    );
  }
}

/// What a folder's last sync saw, beyond its sync state, so the next one
/// can tell what it may skip: the server's message count, when removals
/// were last looked for by comparing UIDs, and whether older mail is
/// complete for a [KeepMail] choice. Kept in the settings (one small
/// value per folder) and only trusted while it matches the folder's
/// stored sync state.
final class _FolderMemo {
  const _FolderMemo({
    required this.uidValidity,
    required this.uidNext,
    required this.exists,
    this.removalsCheckedAt,
    this.backfillDone,
  });

  final int uidValidity;
  final int? uidNext;
  final int exists;
  final DateTime? removalsCheckedAt;

  /// The [KeepMail.storageName] older mail was complete for.
  final String? backfillDone;

  static String _key(int mailboxId) => 'sync.folder.$mailboxId';

  static _FolderMemo? read(
    MailStore store,
    int mailboxId,
    MailboxSyncState state,
  ) {
    final text = store.settings.read(_key(mailboxId));
    if (text == null) return null;
    try {
      final json = jsonDecode(text) as Map<String, Object?>;
      final memo = _FolderMemo(
        uidValidity: json['v']! as int,
        uidNext: json['n'] as int?,
        exists: json['e']! as int,
        removalsCheckedAt: switch (json['r']) {
          final int ms => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
          _ => null,
        },
        backfillDone: json['b'] as String?,
      );
      if (memo.uidValidity != state.uidValidity ||
          memo.uidNext != state.uidNext) {
        return null; // from another time: trust nothing in it
      }
      return memo;
    } on Object {
      return null;
    }
  }

  void save(MailStore store, int mailboxId) => store.settings.write(
    _key(mailboxId),
    jsonEncode({
      'v': uidValidity,
      'n': uidNext,
      'e': exists,
      if (removalsCheckedAt case final at?) 'r': at.millisecondsSinceEpoch,
      'b': ?backfillDone,
    }),
  );
}
