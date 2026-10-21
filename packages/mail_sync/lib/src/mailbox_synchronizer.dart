// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'summary_mapper.dart';

/// Tuning for message sync.
final class SyncSettings {
  const SyncSettings({this.initialWindow = 500, this.fetchBatch = 100});

  /// Newest messages downloaded on a folder's first sync; older ones are
  /// fetched on demand with [MailboxSynchronizer.fetchOlder].
  final int initialWindow;

  /// Messages per FETCH and per stored transaction.
  final int fetchBatch;
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
  });

  final SyncMethod method;
  final int added;
  final int updated;
  final int removed;

  /// The server's UIDVALIDITY changed and the cache was rebuilt.
  final bool wasReset;

  bool get hasChanges => added + updated + removed > 0 || wasReset;

  @override
  String toString() =>
      'MailboxSyncResult(${method.name}, +$added ~$updated -$removed${wasReset ? ', reset' : ''})';
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

  /// UIDs whose flags must not be overwritten during the current sync.
  Set<int> _pending = const {};

  /// Syncs [mailbox]. Flags of messages in [pendingUids] (local changes
  /// still queued for the server) are not overwritten, so the user's change
  /// does not flicker back before the queue reaches the server.
  Future<MailboxSyncResult> sync(
    ImapClient imap,
    StoredMailbox mailbox, {
    Set<int> pendingUids = const {},
  }) async {
    _pending = pendingUids;
    final cached = mailbox.syncState;
    final knownUids = _store.messages.uids(mailbox.id);
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
              knownUids: knownUids.isEmpty ? null : SequenceSet.of(knownUids),
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
      return MailboxSyncResult(
        method: SyncMethod.full,
        added: added,
        wasReset: wasReset,
      );
    }

    final (method, updated, removed) = switch (_methodFor(
      cached,
      selected,
      usedQresync: canQresync,
    )) {
      SyncMethod.qresync => await _applyQresync(mailbox, selected),
      SyncMethod.condstore => await _condstoreChanges(imap, mailbox, cached),
      _ => await _plainChanges(imap, mailbox),
    };
    final added = await _fetchNew(imap, mailbox, cached, selected);
    _saveState(mailbox, selected);
    return MailboxSyncResult(
      method: method,
      added: added,
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

  /// CONDSTORE: flags changed since the cached mod-sequence; removals by
  /// comparing cached UIDs with the server's.
  Future<(SyncMethod, int, int)> _condstoreChanges(
    ImapClient imap,
    StoredMailbox mailbox,
    MailboxSyncState cached,
  ) async {
    final lowest = _store.messages.lowestUid(mailbox.id);
    if (lowest == null) return (SyncMethod.condstore, 0, 0);
    final changed = await imap.uidFetch(
      SequenceSet.range(lowest),
      FetchItems.flagsOnly(modSeq: true),
      changedSince: cached.highestModSeq,
    );
    final changes = _flagChanges(mailbox, changed.messages);
    final removed = await _removedSince(imap, mailbox, lowest);
    _store.transaction(() {
      if (removed.isNotEmpty) _store.messages.removeUids(mailbox.id, removed);
      if (changes.isNotEmpty) _store.messages.updateFlags(mailbox.id, changes);
    });
    return (SyncMethod.condstore, changes.length, removed.length);
  }

  /// No change tracking: compare every cached message's flags.
  Future<(SyncMethod, int, int)> _plainChanges(
    ImapClient imap,
    StoredMailbox mailbox,
  ) async {
    final lowest = _store.messages.lowestUid(mailbox.id);
    if (lowest == null) return (SyncMethod.plain, 0, 0);
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

  /// Messages that arrived since the last sync.
  Future<int> _fetchNew(
    ImapClient imap,
    StoredMailbox mailbox,
    MailboxSyncState cached,
    SelectedMailbox selected,
  ) async {
    final from =
        cached.uidNext ?? ((_store.messages.highestUid(mailbox.id) ?? 0) + 1);
    if (selected.uidNext != null && selected.uidNext! <= from) return 0;
    if (selected.exists == 0) return 0;
    // "UID n:*" also matches the highest UID when it is below n (RFC 9051
    // 6.4.8), so filter the result.
    final found = (await imap.uidSearch(
      SearchCriteria.uids(SequenceSet.range(from)),
    )).matches;
    final uids = found.toList().where((uid) => uid >= from).toList();
    return _fetchSummaries(imap, mailbox, uids);
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
