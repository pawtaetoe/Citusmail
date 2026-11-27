// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'mailbox_synchronizer.dart';

/// What one pass of [ArchivedBackfill] did.
final class ArchivedBackfillResult {
  const ArchivedBackfillResult({
    this.stored = 0,
    this.updated = 0,
    this.removed = 0,
    this.complete = false,
  });

  /// Archived messages stored in All Mail.
  final int stored;

  /// Stored All Mail messages whose flags changed (pinned elsewhere).
  final int updated;

  /// Stored All Mail messages no longer there (deleted elsewhere).
  final int removed;

  /// Whether every archived message within [KeepMail]'s date is now on
  /// the device.
  final bool complete;

  @override
  String toString() =>
      'ArchivedBackfillResult(+$stored ~$updated -$removed'
      '${complete ? ', complete' : ''})';
}

/// Fills in archived Gmail mail this device never saw in another folder.
///
/// Gmail's All Mail is not synced in the background ([StoredMailbox.isView]),
/// and [ArchivedMail] only finds what this device saw leave a folder. Mail
/// archived before the device was added (or while it was away) would be
/// missing: not in search, not in Pins, not in Found. So on each full sync
/// of a Gmail account (one with the `X-GM-EXT-1` capability), Gmail's own
/// search finds the archived messages (in no system folder) received since
/// [KeepMail]'s date; those in no stored folder have their summaries
/// stored in All Mail, never their bodies. Pinned (starred) mail comes
/// first, then the rest, newest first, at most [SyncSettings.backfillBatch]
/// messages a sync; a cursor kept in the settings lets the next sync go on
/// where this one stopped, so a large mailbox fills in over several syncs.
/// Accounts that were set up before this existed have no cursor yet, and so
/// start at once.
///
/// It also keeps the flags of everything stored in All Mail in step (pins
/// made on another device), and drops what left All Mail (deleted
/// elsewhere): opening All Mail would, but it is rarely opened.
///
/// On other servers it does nothing: their archive is a real folder,
/// synced like any other.
final class ArchivedBackfill {
  ArchivedBackfill(this._store, this._mailboxSync, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final MailStore _store;
  final MailboxSynchronizer _mailboxSync;
  final DateTime Function() _now;

  /// Gmail's search for archived mail: in none of its system folders.
  /// Mail with only a user label matches too; it is skipped when that
  /// label's folder already has it.
  static const archivedQuery =
      '-in:inbox -in:sent -in:drafts -in:spam -in:trash -in:chats';

  /// How often stored All Mail messages are checked for removal.
  static const removalCheckInterval = Duration(hours: 1);

  /// UIDs per command when every stored message is named.
  static const _chunk = 500;

  static JsonSetting<_FillState?> _setting(int accountId) => JsonSetting(
    'sync.archivedFill.$accountId',
    fallback: null,
    fromJson: _FillState.fromJson,
    toJson: _FillState.toJson,
  );

  /// Whether [imap] is a Gmail-style server this applies to.
  static bool appliesTo(ImapClient imap) => imap.capabilities.has('X-GM-EXT-1');

  /// One pass over [imap] for [account]: stores the next archived
  /// messages and refreshes the flags of those stored. [pendingUids] are
  /// All Mail UIDs with local changes still queued, whose flags are left
  /// as they are. Null when it does not apply (not Gmail, no All Mail).
  Future<ArchivedBackfillResult?> run(
    ImapClient imap,
    Account account, {
    Set<int> pendingUids = const {},
  }) async {
    if (!appliesTo(imap)) return null;
    final allMail = _store.mailboxes.bySpecialUse(account.id, SpecialUse.all);
    if (allMail == null || !allMail.selectable) return null;
    final setting = _setting(account.id);
    var state = setting.read(_store.settings);
    final selected = await imap.select(allMail.encodedName, readOnly: true);
    final uidNext = selected.uidNext;
    if (uidNext == null) return null;

    // All Mail was reset on the server: what is stored under the old UIDs
    // means nothing now, and is filled in again from the start. Kept
    // otherwise: with its UIDVALIDITY known, what is stored opens and
    // can be pinned, even before All Mail is first opened (also mail
    // stored by an older version, which did not keep it).
    final known = allMail.syncState.uidValidity;
    if (known == null) {
      _store.mailboxes.saveSyncState(
        allMail.id,
        MailboxSyncState(uidValidity: selected.uidValidity),
      );
    } else if (known != selected.uidValidity) {
      _store.mailboxes.resetForUidValidity(allMail.id, selected.uidValidity);
      state = null;
    }
    if (state != null && state.uidValidity != selected.uidValidity) {
      state = null;
    }

    final keep = KeepMail.read(_store);
    var fill = state ?? _FillState.start(selected.uidValidity, keep, uidNext);
    // Keeping more (or less) mail: look through everything again. What is
    // stored already costs nothing.
    if (fill.keep != keep.storageName) fill = fill.restart(keep);

    final since = keep.since(_now());
    var budget = _mailboxSync.settings.backfillBatch;
    var stored = 0;
    final onDevice = _store.messages.uids(allMail.id).toSet();

    // Archived since the pass began (mail that arrived and was archived
    // while this device was away), oldest first.
    if (uidNext > fill.top && budget > 0) {
      final top = fill.top;
      final arrived = [
        for (final uid in await _search(
          imap,
          SequenceSet.range(top),
          since,
          starred: false,
        ))
          if (uid >= top && !onDevice.contains(uid)) uid,
      ];
      final batch = arrived.take(budget).toList();
      stored += await _storeNew(imap, account, allMail, batch);
      budget -= batch.length;
      fill = fill.copy(
        top: arrived.length <= batch.length ? uidNext : batch.last + 1,
      );
    }

    // Then back from where the pass is: pinned mail, then all of it.
    while (budget > 0 && fill.phase != _Phase.done) {
      final starred = fill.phase == _Phase.starred;
      final below = fill.below;
      final older = below <= 1
          ? const <int>[]
          : [
              for (final uid in (await _search(
                imap,
                SequenceSet.range(1, below - 1),
                since,
                starred: starred,
              )).reversed)
                if (uid < below && !onDevice.contains(uid)) uid,
            ];
      final batch = older.take(budget).toList();
      stored += await _storeNew(imap, account, allMail, batch);
      budget -= batch.length;
      onDevice.addAll(batch);
      fill = older.length > batch.length
          ? fill.copy(below: batch.last)
          : starred
          ? fill.copy(phase: _Phase.archived, below: fill.top)
          : fill.copy(phase: _Phase.done);
    }

    final (updated, removed, checkedAt) = await _refreshFlags(
      imap,
      allMail,
      selected,
      fill,
      pendingUids,
    );
    setting.write(
      _store.settings,
      fill.copy(modSeq: selected.highestModSeq, removalsCheckedAt: checkedAt),
    );
    return ArchivedBackfillResult(
      stored: stored,
      updated: updated,
      removed: removed,
      complete: fill.phase == _Phase.done,
    );
  }

  /// Archived messages in [range] received since [since] (all with null),
  /// only pinned ones when [starred]; UIDs ascending.
  Future<List<int>> _search(
    ImapClient imap,
    SequenceSet range,
    DateTime? since, {
    required bool starred,
  }) async => (await imap.uidSearch(
    SearchCriteria.and([
      SearchCriteria.uids(range),
      SearchCriteria.gmailRaw(archivedQuery),
      if (starred) SearchCriteria.flagged(),
      if (since != null) SearchCriteria.since(since),
    ]),
  )).matches.toList()..sort();

  /// Stores the summaries of those of [uids] that are in no stored folder
  /// of [account], by Message-ID (read first, a few bytes each). Mail
  /// without one is left out: it could not be told apart from a copy.
  Future<int> _storeNew(
    ImapClient imap,
    Account account,
    StoredMailbox allMail,
    List<int> uids,
  ) async {
    if (uids.isEmpty) return 0;
    final folders = [
      for (final m in _store.mailboxes.forAccount(account.id))
        if (m.id == allMail.id || !m.isView) m,
    ];
    final batch = _mailboxSync.settings.fetchBatch;
    final wanted = <int>[];
    for (var i = 0; i < uids.length; i += batch) {
      final part = uids.sublist(
        i,
        i + batch > uids.length ? uids.length : i + batch,
      );
      final fetched = await imap.uidFetch(
        SequenceSet.of(part),
        FetchItems(headerFields: const ['Message-ID']),
      );
      for (final m in fetched.messages) {
        final uid = m.uid;
        final id = _messageId(m.headerFields);
        if (uid == null || id == null) continue;
        if (folders.any(
          (f) => _store.messages.byMessageId(f.id, id).isNotEmpty,
        )) {
          continue;
        }
        wanted.add(uid);
      }
    }
    if (wanted.isEmpty) return 0;
    return _mailboxSync.fetchUids(imap, allMail, wanted..sort());
  }

  static String? _messageId(Uint8List? raw) {
    if (raw == null || raw.isEmpty) return null;
    final value = const HeaderParser().parse(raw).headers.value('message-id');
    return value == null ? null : const MessageIds().parseSingle(value);
  }

  /// Brings the flags of the messages stored in All Mail in line with the
  /// server, and drops those it no longer has. Returns how many changed,
  /// how many were removed, and when removals were last looked for.
  Future<(int, int, DateTime?)> _refreshFlags(
    ImapClient imap,
    StoredMailbox allMail,
    SelectedMailbox selected,
    _FillState state,
    Set<int> pendingUids,
  ) async {
    final cached = _store.messages.flagsByUid(allMail.id);
    var checkedAt = state.removalsCheckedAt;
    if (cached.isEmpty) return (0, 0, checkedAt);
    final uids = cached.keys.toList()..sort();
    final now = _now();
    final fetched = <FetchedMessage>[];
    var removed = <int>[];
    final modSeq = state.modSeq;
    if (selected.highestModSeq != null && modSeq != null) {
      // Only what changed since the last pass: usually nothing at all.
      if (selected.highestModSeq != modSeq) {
        fetched.addAll(
          (await imap.uidFetch(
            SequenceSet.range(uids.first),
            FetchItems.flagsOnly(modSeq: true),
            changedSince: modSeq,
          )).messages,
        );
      }
      if (checkedAt == null ||
          now.difference(checkedAt) > removalCheckInterval ||
          now.isBefore(checkedAt)) {
        checkedAt = now;
        final there = <int>{};
        for (final chunk in _chunks(uids)) {
          there.addAll(
            (await imap.uidSearch(SearchCriteria.uids(SequenceSet.of(chunk))))
                .matches
                .toList(),
          );
        }
        removed = [
          for (final uid in uids)
            if (!there.contains(uid)) uid,
        ];
      }
    } else {
      // No change tracking (or the first pass): every stored message's
      // flags, which also shows what is gone.
      checkedAt = now;
      final there = <int>{};
      for (final chunk in _chunks(uids)) {
        final part = await imap.uidFetch(
          SequenceSet.of(chunk),
          FetchItems.flagsOnly(modSeq: selected.highestModSeq != null),
        );
        fetched.addAll(part.messages);
        there.addAll([for (final m in part.messages) ?m.uid]);
      }
      removed = [
        for (final uid in uids)
          if (!there.contains(uid)) uid,
      ];
    }
    final changes = [
      for (final m in fetched)
        if ((m.uid, m.flags) case (final uid?, final flags?)
            when cached[uid] != null &&
                !pendingUids.contains(uid) &&
                cached[uid] != MessageFlags.fromImap(flags))
          (uid: uid, flags: MessageFlags.fromImap(flags), modSeq: m.modSeq),
    ];
    _store.transaction(() {
      if (removed.isNotEmpty) _store.messages.removeUids(allMail.id, removed);
      if (changes.isNotEmpty) {
        _store.messages.updateFlags(allMail.id, changes);
      }
    });
    return (changes.length, removed.length, checkedAt);
  }

  static Iterable<List<int>> _chunks(List<int> uids) sync* {
    for (var i = 0; i < uids.length; i += _chunk) {
      yield uids.sublist(
        i,
        i + _chunk > uids.length ? uids.length : i + _chunk,
      );
    }
  }
}

/// Which part of the archive the pass is filling in.
enum _Phase { starred, archived, done }

/// Where the pass over an account's archive is, kept between syncs.
final class _FillState {
  const _FillState({
    required this.uidValidity,
    required this.keep,
    required this.phase,
    required this.below,
    required this.top,
    this.modSeq,
    this.removalsCheckedAt,
  });

  /// A pass from the newest message down, for [keep].
  factory _FillState.start(int uidValidity, KeepMail keep, int uidNext) =>
      _FillState(
        uidValidity: uidValidity,
        keep: keep.storageName,
        phase: _Phase.starred,
        below: uidNext,
        top: uidNext,
      );

  /// All Mail's UIDVALIDITY the UIDs belong to.
  final int uidValidity;

  /// The [KeepMail.storageName] the pass is for.
  final String keep;
  final _Phase phase;

  /// The pass looks at UIDs below this one next.
  final int below;

  /// UIDs from this one up arrived after the pass began.
  final int top;

  /// All Mail's HIGHESTMODSEQ when its flags were last read.
  final int? modSeq;
  final DateTime? removalsCheckedAt;

  /// The pass again from the top, for [keep].
  _FillState restart(KeepMail keep) => _FillState(
    uidValidity: uidValidity,
    keep: keep.storageName,
    phase: _Phase.starred,
    below: top,
    top: top,
    modSeq: modSeq,
    removalsCheckedAt: removalsCheckedAt,
  );

  _FillState copy({
    _Phase? phase,
    int? below,
    int? top,
    int? modSeq,
    DateTime? removalsCheckedAt,
  }) => _FillState(
    uidValidity: uidValidity,
    keep: keep,
    phase: phase ?? this.phase,
    below: below ?? this.below,
    top: top ?? this.top,
    modSeq: modSeq ?? this.modSeq,
    removalsCheckedAt: removalsCheckedAt ?? this.removalsCheckedAt,
  );

  static _FillState? fromJson(Object? json) {
    final map = json! as Map<String, Object?>;
    return _FillState(
      uidValidity: map['v']! as int,
      keep: map['k']! as String,
      phase: _Phase.values.byName(map['p']! as String),
      below: map['b']! as int,
      top: map['t']! as int,
      modSeq: map['m'] as int?,
      removalsCheckedAt: switch (map['r']) {
        final int ms => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
        _ => null,
      },
    );
  }

  static Object? toJson(_FillState? state) => {
    'v': state!.uidValidity,
    'k': state.keep,
    'p': state.phase.name,
    'b': state.below,
    't': state.top,
    'm': ?state.modSeq,
    if (state.removalsCheckedAt case final at?) 'r': at.millisecondsSinceEpoch,
  };
}
