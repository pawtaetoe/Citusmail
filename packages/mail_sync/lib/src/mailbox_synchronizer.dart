// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'summary_mapper.dart';
import 'sync_lease.dart';

/// Tuning for message sync.
final class SyncSettings {
  const SyncSettings({
    this.initialWindow = 500,
    this.fetchBatch = 100,
    this.checkBatch = 1000,
    this.backfillBatch = 500,
    this.connections = 3,
    this.writeBatch = 25,
  });

  /// Newest messages downloaded on a folder's first sync. Older ones
  /// follow on later syncs, [backfillBatch] at a time, back to what
  /// [KeepMail] says; and on demand with [MailboxSynchronizer.fetchOlder].
  final int initialWindow;

  /// Messages per FETCH of summaries. Between two, the sync hands its
  /// connection to the user's work waiting for one ([SyncLease]), so it
  /// waits for one FETCH at most.
  final int fetchBatch;

  /// Stored messages whose flags (without change tracking) or presence on
  /// the server are compared per command, the user's work going first
  /// between two as between FETCHes.
  final int checkBatch;

  /// Summaries per stored transaction, with a pause between them: while
  /// the sync writes, a write from the screen (marking read, archiving)
  /// waits for one of them at most, never for a whole FETCH.
  final int writeBatch;

  /// Older messages downloaded per folder per sync, until the folder
  /// reaches back to [KeepMail]'s date.
  final int backfillBatch;

  /// Connections per account during a sync: folders are synced side by
  /// side, the inbox first. Servers allow a handful per account (Gmail
  /// 15, Outlook about 16, shared by all devices), so the extra ones are
  /// opened only while the account's `ConnectionBudget` has room (IDLE
  /// and opening messages count in it too).
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

  static const standard = KeepMail.twoYears;

  /// The user's choice, by [storageName].
  static const setting = EnumSetting(
    'sync.keepMail',
    values,
    fallback: standard,
    storedAs: _storageNameOf,
  );

  static String _storageNameOf(KeepMail keep) => keep.storageName;

  static KeepMail read(MailStore store) => setting.read(store.settings);

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

  /// Not opened: the folder's counters on the server (LIST-STATUS) showed
  /// nothing changed since the last sync.
  unchanged,
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
    this.removedMessageIds = const [],
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

  /// Message-IDs of the [removed] messages that had one (up to
  /// [MailboxSynchronizer.maxNotedRemovals]).
  final List<String> removedMessageIds;

  bool get hasChanges => added + updated + removed + backfilled > 0 || wasReset;

  MailboxSyncResult _reset() => MailboxSyncResult(
    method: method,
    added: added,
    updated: updated,
    removed: removed,
    wasReset: true,
    backfilled: backfilled,
    removedMessageIds: removedMessageIds,
  );

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

  /// Message-IDs removed during the current sync.
  List<String> _gone = [];

  /// The pause between two stored transactions of one FETCH, so another
  /// connection waiting to write gets its turn.
  static const writePause = Duration(milliseconds: 1);

  /// Most Message-IDs of removed messages a sync reports.
  static const maxNotedRemovals = 500;

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
  ///
  /// With a [lease] (instead of [imap] alone), the connection goes to the
  /// user's work waiting for one between two batches (FETCHes of
  /// summaries, chunks of flags or of the removals check), and the sync
  /// goes on where it stopped on the connection it gets back, the folder
  /// selected again. If the folder's UIDVALIDITY changed meanwhile, what
  /// was stored of it is dropped and the folder synced afresh.
  Future<MailboxSyncResult> sync(
    ImapClient imap,
    StoredMailbox mailbox, {
    Set<int> pendingUids = const {},
    bool refreshFlags = true,
    SyncLease? lease,
  }) async {
    final on = lease ?? SyncLease.fixed(imap);
    var folder = mailbox;
    var pending = pendingUids;
    for (var resets = 0; ; resets++) {
      try {
        final result = await _sync(on, folder, pending, refreshFlags);
        return resets == 0 ? result : result._reset();
      } on FolderResetException catch (e) {
        if (e.encodedName != folder.encodedName || resets >= 2) rethrow;
        // Reset while it was handed over: the UIDs stored so far mean
        // nothing now, nor those of the queued changes.
        _store.mailboxes.resetForUidValidity(folder.id, e.uidValidity);
        folder = _store.mailboxes.byId(folder.id) ?? (throw e);
        pending = const {};
      }
    }
  }

  Future<MailboxSyncResult> _sync(
    SyncLease lease,
    StoredMailbox mailbox,
    Set<int> pendingUids,
    bool refreshFlags,
  ) async {
    final imap = lease.client;
    _pending = pendingUids;
    _gone = [];
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

    // A folder never synced, though a few of its messages may be stored
    // (see [fetchUids]): its newest mail first, as for a new folder.
    final neverSynced =
        cached.uidNext == null &&
        cached.highestModSeq == null &&
        cached.lastSyncAt == null;
    if (cached.uidValidity == null ||
        neverSynced ||
        selected.uidValidity != cached.uidValidity) {
      final wasReset =
          cached.uidValidity != null &&
          selected.uidValidity != cached.uidValidity;
      if (wasReset) {
        _store.mailboxes.resetForUidValidity(mailbox.id, selected.uidValidity);
      }
      final (added, low, everything) = await _fullSync(
        lease,
        mailbox,
        selected,
      );
      _FolderMemo(
        uidValidity: selected.uidValidity,
        uidNext: selected.uidNext,
        exists: selected.exists,
        low: low,
        removalsCheckedAt: DateTime.now(),
        // All of it fit in the first window: no older mail to look for.
        backfillDone: everything ? KeepMail.read(_store).storageName : null,
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

    final range = _cachedRange(mailbox, memo);
    final validity = selected.uidValidity;
    final (method, updated, removed) = switch (_methodFor(
      cached,
      selected,
      usedQresync: canQresync,
    )) {
      SyncMethod.qresync => await _applyQresync(mailbox, selected),
      SyncMethod.condstore => await _condstoreChanges(
        lease,
        mailbox,
        range,
        cached,
        selected,
        mayHaveRemovals,
      ),
      _ when refreshFlags => await _plainChanges(
        lease,
        mailbox,
        range,
        validity,
        () => removalsCheckedAt = DateTime.now(),
      ),
      _ => await _plainRemovals(
        lease,
        mailbox,
        range,
        validity,
        mayHaveRemovals,
      ),
    };
    final added = await _fetchSummaries(
      lease,
      mailbox,
      newUids,
      uidValidity: validity,
    );
    _saveState(mailbox, selected);
    var backfillDone = memo?.backfillDone;
    // Where the synced range starts (messages stored outside it, like
    // mail found by [ArchivedMail], don't count).
    var low = memo == null ? lowest : memo.low;
    final keep = KeepMail.read(_store).storageName;
    var backfilled = 0;
    if (backfillDone != keep) {
      (backfilled, low) = await _backfill(
        lease,
        mailbox,
        validity,
        low,
        () => backfillDone = keep,
      );
    }
    _FolderMemo(
      uidValidity: selected.uidValidity,
      uidNext: selected.uidNext,
      exists: selected.exists,
      low: low,
      removalsCheckedAt: removalsCheckedAt,
      backfillDone: backfillDone,
    ).save(_store, mailbox.id);
    return MailboxSyncResult(
      method: method,
      added: added,
      backfilled: backfilled,
      updated: updated,
      removed: removed,
      removedMessageIds: _gone,
    );
  }

  /// Whether [mailbox] needs no sync, by its [counters] on the server (from
  /// LIST-STATUS, without selecting it): the same UIDVALIDITY, UIDNEXT,
  /// HIGHESTMODSEQ (so no flag changed and nothing was removed) and
  /// message count as at its last sync, its older mail complete, and its
  /// removals looked for within [removalCheckInterval]. Never without
  /// CONDSTORE, where a flag change shows in no counter.
  bool unchanged(StoredMailbox mailbox, MailboxStatus counters) {
    final cached = mailbox.syncState;
    if (cached.uidValidity == null ||
        cached.highestModSeq == null ||
        counters.uidValidity != cached.uidValidity ||
        counters.uidNext != cached.uidNext ||
        counters.highestModSeq != cached.highestModSeq) {
      return false;
    }
    final memo = _FolderMemo.read(_store, mailbox.id, cached);
    final checkedAt = memo?.removalsCheckedAt;
    final now = DateTime.now();
    return memo != null &&
        counters.messages == memo.exists &&
        memo.backfillDone == KeepMail.read(_store).storageName &&
        checkedAt != null &&
        !now.isBefore(checkedAt) &&
        now.difference(checkedAt) <= removalCheckInterval;
  }

  /// Downloads up to [count] messages older than the oldest synced one.
  Future<int> fetchOlder(
    ImapClient imap,
    StoredMailbox mailbox, {
    int count = 100,
  }) async {
    final memo = _FolderMemo.read(_store, mailbox.id, mailbox.syncState);
    final lowest = memo == null
        ? _store.messages.lowestUid(mailbox.id)
        : memo.low;
    if (lowest == null || lowest <= 1) return 0;
    if (imap.selected?.name != mailbox.encodedName) {
      await imap.select(mailbox.encodedName, readOnly: true);
    }
    final older = (await imap.uidSearch(
      SearchCriteria.uids(SequenceSet.range(1, lowest - 1)),
    )).matches;
    final uids = older.toList();
    final batch = uids.sublist(uids.length > count ? uids.length - count : 0);
    final stored = await _fetchSummaries(SyncLease.fixed(imap), mailbox, batch);
    if (memo != null && batch.isNotEmpty) {
      memo.withLow(batch.first).save(_store, mailbox.id);
    }
    return stored;
  }

  /// Older messages, newest first, back to [KeepMail]'s date (on the
  /// server's INTERNALDATE): at most [SyncSettings.backfillBatch] a time,
  /// so a sync stays short; the next one goes on. Calls [done] when the
  /// folder reaches back far enough, so later syncs stop looking (until
  /// the user keeps more). Not on a folder's first sync, which shows its
  /// newest mail first.
  ///
  /// [lowest] is the oldest synced UID; returns how many were stored and
  /// the new oldest one.
  Future<(int, int?)> _backfill(
    SyncLease lease,
    StoredMailbox mailbox,
    int uidValidity,
    int? lowest,
    void Function() done,
  ) async {
    if (settings.backfillBatch <= 0) return (0, lowest);
    if (lowest == null || lowest <= 1) {
      // Nothing older can appear: new mail always gets a higher UID.
      done();
      return (0, lowest);
    }
    final since = KeepMail.read(_store).since(DateTime.now());
    final range = SearchCriteria.uids(SequenceSet.range(1, lowest - 1));
    final imap = await lease.resume(mailbox.encodedName, uidValidity);
    final older = (await imap.uidSearch(
      since == null
          ? range
          : SearchCriteria.and([range, SearchCriteria.since(since)]),
    )).matches.toList();
    if (older.length <= settings.backfillBatch) done();
    if (older.isEmpty) return (0, lowest);
    final batch = older.sublist(
      older.length > settings.backfillBatch
          ? older.length - settings.backfillBatch
          : 0,
    );
    final stored = await _fetchSummaries(
      lease,
      mailbox,
      batch,
      uidValidity: uidValidity,
    );
    return (stored, batch.first);
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

  /// The newest messages; returns how many were stored, the oldest UID of
  /// them, and whether that was every message of the folder.
  Future<(int, int?, bool)> _fullSync(
    SyncLease lease,
    StoredMailbox mailbox,
    SelectedMailbox selected,
  ) async {
    var added = 0;
    int? low;
    var everything = true;
    if (selected.exists > 0) {
      final all = (await lease.client.uidSearch(SearchCriteria.all())).matches
          .toList();
      everything = all.length <= settings.initialWindow;
      final newest = all.sublist(
        all.length > settings.initialWindow
            ? all.length - settings.initialWindow
            : 0,
      );
      added = await _fetchSummaries(
        lease,
        mailbox,
        newest,
        uidValidity: selected.uidValidity,
      );
      low = newest.firstOrNull;
    }
    _saveState(mailbox, selected);
    return (added, low, everything);
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
      if (removed.isNotEmpty) _removeUids(mailbox, removed);
      if (changes.isNotEmpty) _store.messages.updateFlags(mailbox.id, changes);
    });
    return (SyncMethod.qresync, changes.length, removed.length);
  }

  /// CONDSTORE: flags changed since the cached mod-sequence (nothing to
  /// ask when it did not move); removals by comparing cached UIDs with
  /// the server's, when [mayHaveRemovals].
  Future<(SyncMethod, int, int)> _condstoreChanges(
    SyncLease lease,
    StoredMailbox mailbox,
    SequenceSet? range,
    MailboxSyncState cached,
    SelectedMailbox selected,
    bool Function() mayHaveRemovals,
  ) async {
    if (range == null) return (SyncMethod.condstore, 0, 0);
    final changes = selected.highestModSeq == cached.highestModSeq
        ? const <({int uid, MessageFlags flags, int? modSeq})>[]
        : _flagChanges(
            mailbox,
            (await lease.client.uidFetch(
              range,
              FetchItems.flagsOnly(modSeq: true),
              changedSince: cached.highestModSeq,
            )).messages,
          );
    final removed = mayHaveRemovals()
        ? await _removedFrom(lease, mailbox, range, selected.uidValidity)
        : const <int>[];
    _store.transaction(() {
      if (removed.isNotEmpty) _removeUids(mailbox, removed);
      if (changes.isNotEmpty) _store.messages.updateFlags(mailbox.id, changes);
    });
    return (SyncMethod.condstore, changes.length, removed.length);
  }

  /// No change tracking, only removals: by comparing cached UIDs with
  /// the server's, when [mayHaveRemovals].
  Future<(SyncMethod, int, int)> _plainRemovals(
    SyncLease lease,
    StoredMailbox mailbox,
    SequenceSet? range,
    int uidValidity,
    bool Function() mayHaveRemovals,
  ) async {
    if (range == null || !mayHaveRemovals()) return (SyncMethod.plain, 0, 0);
    final removed = await _removedFrom(lease, mailbox, range, uidValidity);
    if (removed.isNotEmpty) _removeUids(mailbox, removed);
    return (SyncMethod.plain, 0, removed.length);
  }

  /// No change tracking: compare every cached message's flags (which
  /// also shows what was removed; [checked] is told so),
  /// [SyncSettings.checkBatch] at a time.
  Future<(SyncMethod, int, int)> _plainChanges(
    SyncLease lease,
    StoredMailbox mailbox,
    SequenceSet? range,
    int uidValidity,
    void Function() checked,
  ) async {
    if (range == null) return (SyncMethod.plain, 0, 0);
    checked();
    final cachedFlags = _store.messages.flagsByUid(mailbox.id);
    final current = <FetchedMessage>[];
    for (final (_, part) in _parts(range, cachedFlags.keys.toList()..sort())) {
      final imap = await lease.resume(mailbox.encodedName, uidValidity);
      current.addAll(
        (await imap.uidFetch(part, FetchItems.flagsOnly())).messages,
      );
      lease.advanced();
    }
    final serverUids = <int>{for (final m in current) ?m.uid};
    final removed = cachedFlags.keys
        .where((uid) => !serverUids.contains(uid))
        .toList();
    final changes = [
      for (final m in current)
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
      if (removed.isNotEmpty) _removeUids(mailbox, removed);
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

  /// Which cached UIDs a sync compares with the server: those from the
  /// oldest one up, or null when nothing is cached. Messages stored below
  /// the synced range (found by [ArchivedMail] or a search on the server)
  /// are named one by one, so a few old ones never make every sync read
  /// the flags of the whole folder.
  SequenceSet? _cachedRange(StoredMailbox mailbox, _FolderMemo? memo) {
    final lowest = _store.messages.lowestUid(mailbox.id);
    if (lowest == null) return null;
    final low = memo?.low;
    if (low == null || lowest >= low) return SequenceSet.range(lowest);
    return SequenceSet.of([
      for (final uid in _store.messages.uids(mailbox.id))
        if (uid < low) uid,
    ]).union(SequenceSet.range(low));
  }

  /// UIDs cached in [range] that the server no longer has, asked
  /// [SyncSettings.checkBatch] at a time.
  Future<List<int>> _removedFrom(
    SyncLease lease,
    StoredMailbox mailbox,
    SequenceSet range,
    int uidValidity,
  ) async {
    final removed = <int>[];
    for (final (uids, part) in _parts(
      range,
      _store.messages.uids(mailbox.id),
    )) {
      final imap = await lease.resume(mailbox.encodedName, uidValidity);
      final onServer = (await imap.uidSearch(SearchCriteria.uids(part)))
          .matches;
      removed.addAll(uids.where((uid) => !onServer.contains(uid)));
      lease.advanced();
    }
    return removed;
  }

  /// [range] cut into parts of at most [SyncSettings.checkBatch] of the
  /// cached [uids] (ascending), each with the UIDs it covers; the last
  /// part keeps the end of [range] (often "*"). One part when they all
  /// fit.
  Iterable<(List<int>, SequenceSet)> _parts(
    SequenceSet range,
    List<int> uids,
  ) sync* {
    final size = settings.checkBatch < 1 ? 1 : settings.checkBatch;
    if (uids.length <= size) {
      yield (uids, range);
      return;
    }
    var from = 1;
    for (var i = 0; i < uids.length; i += size) {
      final last = i + size >= uids.length;
      final chunk = uids.sublist(i, last ? uids.length : i + size);
      final to = last ? null : chunk.last;
      SequenceSet? part;
      for (final (a, b) in range.ranges) {
        final low = a > from ? a : from;
        final high = to == null || b < to ? b : to;
        if (low > high) continue;
        final piece = range.hasStar && b == range.ranges.last.$2 && to == null
            ? SequenceSet.range(low)
            : SequenceSet.range(low, high);
        part = part == null ? piece : part.union(piece);
      }
      if (part != null) yield (chunk, part);
      if (to != null) from = to + 1;
    }
  }

  /// Downloads and stores the summaries of [uids] in [mailbox], which
  /// must be selected on [imap]. Returns how many were stored.
  ///
  /// For a folder not synced yet (Gmail's All Mail, for archived mail
  /// found there), its UIDVALIDITY is kept, so the messages can be opened
  /// and changed like any other; its first sync still starts with its
  /// newest mail.
  ///
  /// With a [lease], the connection goes to the user's work between two
  /// FETCHes, as in [sync].
  Future<int> fetchUids(
    ImapClient imap,
    StoredMailbox mailbox,
    List<int> uids, {
    SyncLease? lease,
  }) async {
    final selected = imap.selected;
    if (uids.isNotEmpty &&
        selected != null &&
        selected.name == mailbox.encodedName &&
        _store.mailboxes.byId(mailbox.id)?.syncState.uidValidity == null) {
      _store.mailboxes.saveSyncState(
        mailbox.id,
        MailboxSyncState(uidValidity: selected.uidValidity),
      );
    }
    return _fetchSummaries(lease ?? SyncLease.fixed(imap), mailbox, uids);
  }

  /// Removes [uids] from the cache, noting their Message-IDs.
  void _removeUids(StoredMailbox mailbox, List<int> uids) {
    for (final uid in uids) {
      if (_gone.length >= maxNotedRemovals) break;
      if (_store.messages.byUid(mailbox.id, uid)?.messageId case final id?) {
        _gone.add(id);
      }
    }
    _store.messages.removeUids(mailbox.id, uids);
  }

  /// Fetches and stores summaries in batches; returns how many were stored.
  /// Before each batch, the [lease] may go to the user's work: the folder
  /// is then selected again, expected at [uidValidity] (by default what
  /// is selected now).
  Future<int> _fetchSummaries(
    SyncLease lease,
    StoredMailbox mailbox,
    List<int> uids, {
    int? uidValidity,
  }) async {
    if (uids.isEmpty) return 0;
    var stored = 0;
    final first = lease.client;
    final validity =
        uidValidity ??
        (first.selected?.name == mailbox.encodedName
            ? first.selected!.uidValidity
            : null);
    final items = SummaryMapper.fetchItems(
      first.capabilities,
      modSeq: first.capabilities.has('CONDSTORE'),
    );
    final size = settings.fetchBatch < 1 ? 1 : settings.fetchBatch;
    for (var i = 0; i < uids.length; i += size) {
      final batch = uids.sublist(
        i,
        i + size > uids.length ? uids.length : i + size,
      );
      final imap = validity == null
          ? lease.client
          : await lease.resume(mailbox.encodedName, validity);
      final fetched = await imap.uidFetch(SequenceSet.of(batch), items);
      final summaries = [
        for (final m in fetched.messages)
          ?_mapper.map(m, mailboxUse: mailbox.specialUse),
      ];
      final step = settings.writeBatch < 1 ? 1 : settings.writeBatch;
      for (var j = 0; j < summaries.length; j += step) {
        if (j > 0) await Future<void>.delayed(writePause);
        _store.messages.upsertSummaries(
          mailbox.id,
          summaries.sublist(
            j,
            j + step > summaries.length ? summaries.length : j + step,
          ),
        );
      }
      stored += summaries.length;
      lease.advanced();
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
/// can tell what it may skip: the server's message count, where the
/// synced range starts, when removals were last looked for by comparing
/// UIDs, and whether older mail is complete for a [KeepMail] choice. Kept in the settings (one small
/// value per folder) and only trusted while it matches the folder's
/// stored sync state.
final class _FolderMemo {
  const _FolderMemo({
    required this.uidValidity,
    required this.uidNext,
    required this.exists,
    required this.low,
    this.removalsCheckedAt,
    this.backfillDone,
  });

  final int uidValidity;
  final int? uidNext;
  final int exists;

  /// The oldest UID of the synced range (null: nothing older exists).
  final int? low;
  final DateTime? removalsCheckedAt;

  /// The [KeepMail.storageName] older mail was complete for.
  final String? backfillDone;

  /// One folder's memo, by its id.
  static JsonSetting<_FolderMemo?> _setting(MailboxId mailboxId) => JsonSetting(
    'sync.folder.${mailboxId.value}',
    fallback: null,
    fromJson: _fromJson,
    toJson: _toJson,
  );

  static _FolderMemo _fromJson(Object? json) {
    final map = json! as Map<String, Object?>;
    return _FolderMemo(
      uidValidity: map['v']! as int,
      uidNext: map['n'] as int?,
      exists: map['e']! as int,
      low: map['l'] as int?,
      removalsCheckedAt: switch (map['r']) {
        final int ms => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
        _ => null,
      },
      backfillDone: map['b'] as String?,
    );
  }

  static Object? _toJson(_FolderMemo? memo) => {
    'v': memo!.uidValidity,
    'n': memo.uidNext,
    'e': memo.exists,
    'l': memo.low,
    if (memo.removalsCheckedAt case final at?) 'r': at.millisecondsSinceEpoch,
    'b': ?memo.backfillDone,
  };

  static _FolderMemo? read(
    MailStore store,
    MailboxId mailboxId,
    MailboxSyncState state,
  ) {
    final memo = _setting(mailboxId).read(store.settings);
    if (memo == null ||
        memo.uidValidity != state.uidValidity ||
        memo.uidNext != state.uidNext) {
      return null; // none, or from another time: trust nothing in it
    }
    return memo;
  }

  _FolderMemo withLow(int low) => _FolderMemo(
    uidValidity: uidValidity,
    uidNext: uidNext,
    exists: exists,
    low: low,
    removalsCheckedAt: removalsCheckedAt,
    backfillDone: backfillDone,
  );

  void save(MailStore store, MailboxId mailboxId) =>
      _setting(mailboxId).write(store.settings, this);
}
