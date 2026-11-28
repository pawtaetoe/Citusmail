// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'sync_lease.dart';

/// Retry delays: 30 s, 1 min, 2 min, ... up to 1 hour, plus up to 10%
/// random jitter so many devices do not retry in lockstep.
final class Backoff {
  Backoff({Random? random}) : _random = random ?? Random();

  final Random _random;

  static const Duration first = Duration(seconds: 30);
  static const Duration longest = Duration(hours: 1);

  Duration after(int attempts) {
    final base = first * pow(2, attempts.clamp(0, 12)).toInt();
    final capped = base > longest ? longest : base;
    return capped + capped * (_random.nextDouble() * 0.1);
  }
}

/// What a replay did.
final class ReplayResult {
  const ReplayResult({this.completed = 0, this.failed = 0, this.deferred = 0});

  final int completed;

  /// Given up: shown to the user.
  final int failed;

  /// Will be retried later.
  final int deferred;

  ReplayResult operator +(ReplayResult other) => ReplayResult(
    completed: completed + other.completed,
    failed: failed + other.failed,
    deferred: deferred + other.deferred,
  );
}

/// Thrown inside the replayer for a problem that retrying cannot fix.
final class _PermanentFailure implements Exception {
  const _PermanentFailure(this.reason);

  final String reason;
}

/// How one entry went.
enum _Outcome { completed, failed, deferred, later }

/// Replays queued actions against the server, oldest first.
///
/// Every action is idempotent, so replaying one that already reached the
/// server (because the app stopped before removing it from the queue) does
/// no harm: flags are set again, a message already moved or deleted counts
/// as done, and appends are skipped when a message with the same
/// Message-ID is already in the target folder. A message SMTP accepted is
/// marked so before anything else, and never sent again.
///
/// One replay of an account runs at a time: a sync's [replay] does nothing
/// while the user's [replayForUser] runs, and stops before its next entry
/// when one waits, which then goes on where it stopped.
final class OutboxReplayer {
  OutboxReplayer(this._store, {Backoff? backoff, this.maxAttempts = 5})
    : _backoff = backoff ?? Backoff();

  final MailStore _store;
  final Backoff _backoff;

  /// After this many failed tries an entry is given up.
  final int maxAttempts;

  /// The replay under way, per account.
  final _running = <AccountId, Completer<void>>{};

  /// The user's replays waiting for it, per account.
  final _usersWaiting = <AccountId, int>{};

  /// Replays what is due for [account], for a sync. Connection-level
  /// failures stop the replay (the entry is retried later) and are
  /// rethrown, because the connection can no longer be used.
  ///
  /// Nothing while another replay of the account runs (the user's, which
  /// replays it all); it stops before the next entry when the user's
  /// waits. With a [lease], the connection may go to the user's work
  /// between two entries.
  Future<ReplayResult> replay(
    ImapClient imap,
    Account account, {
    required Future<SmtpClient> Function() smtp,
    DateTime? now,
    SyncLease? lease,
  }) async {
    if (_running.containsKey(account.id)) return const ReplayResult();
    final on = lease ?? SyncLease.fixed(imap);
    return _alone(
      account.id,
      () => _replay(
        account,
        smtp: smtp,
        now: now,
        imap: () async {
          await on.handOverIfWanted();
          return on.client;
        },
        done: on.advanced,
        stop: (_) => (_usersWaiting[account.id] ?? 0) > 0,
      ),
    );
  }

  /// Replays what is due for [account] now, for the user (a message just
  /// sent, a change just made), outside the account's syncs: after the
  /// replay under way, if any (a sync's stops before its next entry).
  /// Messages due go to the SMTP server first, on its own connection;
  /// then what is due is replayed in order on the IMAP connection
  /// [withImap] gives, if anything is due (it takes one only then).
  /// Failures are handled as in [replay], except that a connection that
  /// fails (offline, a timeout) leaves the entry as it was, not tried:
  /// the sync that follows tries again, and backs off if it must.
  ///
  /// The IMAP connection is not held for long: it is given back before a
  /// message that has not been sent yet (it goes to the SMTP server
  /// first, without holding it), and after [holdFor] when [othersWait]
  /// (a sync, the user's other work); the rest follows on a connection
  /// taken again.
  Future<ReplayResult> replayForUser(
    Account account, {
    required Future<SmtpClient> Function() smtp,
    required Future<ReplayResult> Function(
      Future<ReplayResult> Function(ImapClient imap) replay,
    )
    withImap,
    bool Function()? othersWait,
    Duration holdFor = const Duration(milliseconds: 300),
    DateTime? now,
  }) async {
    final id = account.id;
    _usersWaiting[id] = (_usersWaiting[id] ?? 0) + 1;
    var waiting = true;
    void waited() {
      if (!waiting) return;
      waiting = false;
      final left = _usersWaiting[id]! - 1;
      if (left == 0) {
        _usersWaiting.remove(id);
      } else {
        _usersWaiting[id] = left;
      }
    }

    try {
      return await _alone(id, () async {
        waited();
        var result = const ReplayResult();
        while (true) {
          result += await _replay(
            account,
            smtp: smtp,
            now: now,
            backOff: false,
          );
          final due = _store.outbox.due(id, now: now);
          if (due.isEmpty) return result;
          // Queued meanwhile: to the SMTP server first.
          if (due.first.action case SendAction(smtpAccepted: false)) continue;
          var stopped = false;
          result += await withImap((imap) {
            final held = Stopwatch()..start();
            return _replay(
              account,
              smtp: smtp,
              now: now,
              imap: () async => imap,
              backOff: false,
              stop: (entry) => stopped =
                  switch (entry.action) {
                    SendAction(smtpAccepted: false) => true,
                    _ => false,
                  } ||
                  (held.elapsed >= holdFor && (othersWait?.call() ?? false)),
            );
          });
          if (!stopped) return result;
        }
      });
    } finally {
      waited();
    }
  }

  /// Runs [work] as the only replay of [accountId], after the one under
  /// way.
  Future<T> _alone<T>(AccountId accountId, Future<T> Function() work) async {
    for (
      var running = _running[accountId];
      running != null;
      running = _running[accountId]
    ) {
      await running.future;
    }
    final done = _running[accountId] = Completer<void>();
    try {
      return await work();
    } finally {
      _running.remove(accountId);
      done.complete();
    }
  }

  /// Replays the entries due, oldest first, the connection [imap] gives
  /// before each; [done] is told after each, and [stop] asked before
  /// (the rest is left for later). Without [imap], only messages not sent
  /// yet go to the SMTP server (their copy in Sent waits for a replay
  /// with a connection).
  Future<ReplayResult> _replay(
    Account account, {
    required Future<SmtpClient> Function() smtp,
    DateTime? now,
    Future<ImapClient> Function()? imap,
    void Function()? done,
    bool Function(OutboxEntry entry)? stop,
    bool backOff = true,
  }) async {
    var completed = 0, failed = 0, deferred = 0;
    SmtpClient? smtpClient;
    Future<SmtpClient> smtpOnce() async => smtpClient ??= await smtp();

    try {
      for (final entry in _store.outbox.due(account.id, now: now)) {
        if (stop?.call(entry) ?? false) break;
        final action = entry.action;
        final _Outcome outcome;
        if (imap == null) {
          if (action is! SendAction || action.smtpAccepted) continue;
          outcome = await _attempt(entry, backOff: backOff, () async {
            await _sendOnce(entry, action, smtpOnce);
            // Without a Sent folder, it is done.
            return _sentFolder(action) == null;
          });
        } else {
          final client = await imap();
          outcome = await _attempt(entry, backOff: backOff, () async {
            await _apply(client, account, entry, smtpOnce);
            return true;
          });
          done?.call();
        }
        switch (outcome) {
          case _Outcome.completed:
            completed++;
          case _Outcome.failed:
            failed++;
          case _Outcome.deferred:
            deferred++;
          case _Outcome.later:
            break;
        }
      }
    } finally {
      await smtpClient?.quit();
    }
    return ReplayResult(
      completed: completed,
      failed: failed,
      deferred: deferred,
    );
  }

  /// Runs [work] for [entry], which returns whether the entry is done
  /// (it is then removed from the queue). Connection-level failures are
  /// rethrown, after the entry was set to be retried later if [backOff].
  Future<_Outcome> _attempt(
    OutboxEntry entry,
    Future<bool> Function() work, {
    required bool backOff,
  }) async {
    try {
      if (!await work()) return _Outcome.later;
      _store.outbox.complete(entry.id);
      return _Outcome.completed;
    } on _PermanentFailure catch (e) {
      _store.outbox.markFailed(entry.id, e.reason);
      return _Outcome.failed;
    } on ImapAuthenticationException {
      rethrow;
    } on SmtpAuthenticationException {
      rethrow;
    } on ImapCommandException catch (e) {
      if (_isPermanent(e) || entry.attempts + 1 >= maxAttempts) {
        _store.outbox.markFailed(entry.id, e.message);
        return _Outcome.failed;
      }
      _retryLater(entry, e.message);
      return _Outcome.deferred;
    } on SmtpRecipientsRejectedException catch (e) {
      // 4xx ("try again later", too many messages for now): retried.
      final forNow = e.rejected.values.every((r) => !r.isPermanentFailure);
      if (forNow && entry.attempts + 1 < maxAttempts) {
        _retryLater(entry, e.message);
        return _Outcome.deferred;
      }
      _store.outbox.markFailed(entry.id, e.message);
      return _Outcome.failed;
    } on SmtpMessageTooLargeException catch (e) {
      _store.outbox.markFailed(entry.id, e.message);
      return _Outcome.failed;
    } on SmtpReplyException catch (e) {
      if (e.reply.isPermanentFailure || entry.attempts + 1 >= maxAttempts) {
        _store.outbox.markFailed(entry.id, e.message);
        return _Outcome.failed;
      }
      _retryLater(entry, e.message);
      return _Outcome.deferred;
    } on MailException catch (e) {
      if (backOff) _retryLater(entry, e.message); // offline, timeout...
      rethrow;
    }
  }

  /// The longest UID set in one command, in characters.
  static const maxUidSetLength = 4000;

  /// [uids] as few UID sets as fit in command lines: ranges where the
  /// UIDs run on (`1:500,502,510:900`), and for thousands of scattered
  /// UIDs a few commands of at most [maxUidSetLength] characters, never
  /// one command per message.
  static List<SequenceSet> uidSets(List<int> uids) =>
      SequenceSet.of(uids).split(maxLength: maxUidSetLength);

  void _retryLater(OutboxEntry entry, String error) => _store.outbox.retryLater(
    entry.id,
    error,
    DateTime.now().toUtc().add(_backoff.after(entry.attempts)),
  );

  static bool _isPermanent(ImapCommandException e) => const {
    'NONEXISTENT',
    'TRYCREATE',
    'CANNOT',
    'NOPERM',
    'LIMIT',
  }.contains(e.code?.name);

  Future<void> _apply(
    ImapClient imap,
    Account account,
    OutboxEntry entry,
    Future<SmtpClient> Function() smtp,
  ) async {
    switch (entry.action) {
      case final SetFlagsAction a:
        await _selectFor(imap, a);
        for (final uids in uidSets(a.uids)) {
          if (a.add.isNotEmpty) {
            await imap.uidStore(uids, FlagChange.add, a.add.toSet());
          }
          if (a.remove.isNotEmpty) {
            await imap.uidStore(uids, FlagChange.remove, a.remove.toSet());
          }
        }
      case final MoveAction a:
        final target = _mailbox(a.targetMailboxId);
        await _selectFor(imap, a);
        for (final uids in uidSets(a.uids)) {
          await imap.uidMove(uids, target.encodedName);
        }
      case final DeleteAction a:
        final source = await _selectFor(imap, a);
        final trash = _store.mailboxes.bySpecialUse(
          account.id,
          SpecialUse.trash,
        );
        for (final uids in uidSets(a.uids)) {
          if (trash == null || trash.id == source.id) {
            // Already in Trash (or there is none): remove for good.
            await imap.uidStore(uids, FlagChange.add, {r'\Deleted'});
            if (imap.capabilities.has('UIDPLUS')) {
              await imap.uidExpunge(uids);
            }
          } else {
            await imap.uidMove(uids, trash.encodedName);
          }
        }
      case final AppendAction a:
        final target = _mailbox(a.mailboxId);
        await _appendOnce(imap, target, _data(entry), a.flags.toSet());
      case final RemoveDraftAction a:
        await _removeDraft(imap, _mailbox(a.mailboxId), a.messageId);
      case final SendAction a:
        final action = await _sendOnce(entry, a, smtp);
        if (_sentFolder(action) case final sent?) {
          await _appendOnce(imap, sent, _data(entry), {r'\Seen'});
        }
    }
  }

  /// Hands [action]'s message to the SMTP server unless it accepted it
  /// already; returns the action as it is now.
  Future<SendAction> _sendOnce(
    OutboxEntry entry,
    SendAction action,
    Future<SmtpClient> Function() smtp,
  ) async {
    if (action.smtpAccepted) return action;
    final data = _data(entry);
    final client = await smtp();
    await client.send(_builtMessage(data, action), from: _address(action.from));
    // Record success before anything else can fail, so a crash or an
    // error saving to Sent never causes a second send.
    final accepted = action.markAccepted();
    _store.outbox.updateAction(entry.id, accepted);
    return accepted;
  }

  /// Where a copy of [action]'s message goes, if anywhere.
  StoredMailbox? _sentFolder(SendAction action) =>
      switch (action.sentMailboxId) {
        final id? => _store.mailboxes.byId(id),
        null => null,
      };

  /// Selects the action's folder and checks it is the same folder the
  /// action was taken in (same UIDVALIDITY).
  Future<StoredMailbox> _selectFor(ImapClient imap, UidAction action) async {
    final mailbox = _mailbox(action.mailboxId);
    final selected =
        imap.selected?.name == mailbox.encodedName && !imap.selected!.readOnly
        ? imap.selected!
        : await imap.select(mailbox.encodedName);
    if (selected.uidValidity != action.uidValidity) {
      throw const _PermanentFailure(
        'the folder was reset on the server; the action no longer applies',
      );
    }
    return mailbox;
  }

  /// Deletes older copies of a draft: messages in [drafts] with this
  /// Message-ID that are marked as drafts. Without UIDPLUS they stay
  /// flagged as deleted, because a plain EXPUNGE would also remove other
  /// messages someone flagged as deleted.
  Future<void> _removeDraft(
    ImapClient imap,
    StoredMailbox drafts,
    String messageId,
  ) async {
    if (imap.selected?.name != drafts.encodedName || imap.selected!.readOnly) {
      await imap.select(drafts.encodedName);
    }
    final found = (await imap.uidSearch(
      SearchCriteria.and([
        SearchCriteria.header('Message-ID', messageId),
        SearchCriteria.draft(),
      ]),
    )).matches;
    if (found.isEmpty) return; // already gone: nothing to do
    await imap.uidStore(found, FlagChange.add, {r'\Deleted'});
    if (imap.capabilities.has('UIDPLUS')) await imap.uidExpunge(found);
  }

  /// Appends unless a message with the same Message-ID is already there.
  Future<void> _appendOnce(
    ImapClient imap,
    StoredMailbox target,
    Uint8List data,
    Set<String> flags,
  ) async {
    final messageId = const MimeParser().parse(data).messageId;
    if (messageId != null) {
      if (imap.selected?.name != target.encodedName) {
        await imap.select(target.encodedName, readOnly: true);
      }
      final existing = await imap.uidSearch(
        SearchCriteria.header('Message-ID', messageId),
      );
      if (!existing.matches.isEmpty) return;
    }
    await imap.append(target.encodedName, data, flags: flags);
  }

  StoredMailbox _mailbox(MailboxId id) =>
      _store.mailboxes.byId(id) ??
      (throw const _PermanentFailure('the folder no longer exists'));

  static Uint8List _data(OutboxEntry entry) =>
      entry.data ??
      (throw const _PermanentFailure('the queued message data is missing'));

  static BuiltMessage _builtMessage(Uint8List data, SendAction action) =>
      BuiltMessage(
        bytes: data,
        messageId: const MimeParser().parse(data).messageId ?? '',
        recipients: [for (final r in action.recipients) _address(r)],
      );

  static MailAddress _address(String text) {
    final parsed = const AddressParser().parse(text).mailboxes;
    if (parsed.length != 1) {
      throw _PermanentFailure('invalid address in queued message: $text');
    }
    return parsed.single;
  }
}
