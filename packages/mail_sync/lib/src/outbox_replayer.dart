// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

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
}

/// Thrown inside the replayer for a problem that retrying cannot fix.
final class _PermanentFailure implements Exception {
  const _PermanentFailure(this.reason);

  final String reason;
}

/// Replays queued actions against the server, oldest first.
///
/// Every action is idempotent, so replaying one that already reached the
/// server (because the app stopped before removing it from the queue) does
/// no harm: flags are set again, a message already moved or deleted counts
/// as done, and appends are skipped when a message with the same
/// Message-ID is already in the target folder.
final class OutboxReplayer {
  OutboxReplayer(this._store, {Backoff? backoff, this.maxAttempts = 5})
    : _backoff = backoff ?? Backoff();

  final MailStore _store;
  final Backoff _backoff;

  /// After this many failed tries an entry is given up.
  final int maxAttempts;

  /// Replays what is due for [account]. Connection-level failures stop the
  /// replay (the entry is retried later) and are rethrown, because the
  /// connection can no longer be used.
  Future<ReplayResult> replay(
    ImapClient imap,
    Account account, {
    required Future<SmtpClient> Function() smtp,
    DateTime? now,
  }) async {
    var completed = 0, failed = 0, deferred = 0;
    SmtpClient? smtpClient;
    Future<SmtpClient> smtpOnce() async => smtpClient ??= await smtp();

    try {
      for (final entry in _store.outbox.due(account.id, now: now)) {
        try {
          await _apply(imap, account, entry, smtpOnce);
          _store.outbox.complete(entry.id);
          completed++;
        } on _PermanentFailure catch (e) {
          _store.outbox.markFailed(entry.id, e.reason);
          failed++;
        } on ImapAuthenticationException {
          rethrow;
        } on SmtpAuthenticationException {
          rethrow;
        } on ImapCommandException catch (e) {
          if (_isPermanent(e) || entry.attempts + 1 >= maxAttempts) {
            _store.outbox.markFailed(entry.id, e.message);
            failed++;
          } else {
            _retryLater(entry, e.message);
            deferred++;
          }
        } on SmtpRecipientsRejectedException catch (e) {
          _store.outbox.markFailed(entry.id, e.message);
          failed++;
        } on SmtpMessageTooLargeException catch (e) {
          _store.outbox.markFailed(entry.id, e.message);
          failed++;
        } on SmtpReplyException catch (e) {
          if (e.reply.isPermanentFailure || entry.attempts + 1 >= maxAttempts) {
            _store.outbox.markFailed(entry.id, e.message);
            failed++;
          } else {
            _retryLater(entry, e.message);
            deferred++;
          }
        } on MailException catch (e) {
          _retryLater(entry, e.message); // offline, timeout...
          rethrow;
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
        if (a.add.isNotEmpty) {
          await imap.uidStore(
            SequenceSet.of(a.uids),
            FlagChange.add,
            a.add.toSet(),
          );
        }
        if (a.remove.isNotEmpty) {
          await imap.uidStore(
            SequenceSet.of(a.uids),
            FlagChange.remove,
            a.remove.toSet(),
          );
        }
      case final MoveAction a:
        final target = _mailbox(a.targetMailboxId);
        await _selectFor(imap, a);
        await imap.uidMove(SequenceSet.of(a.uids), target.encodedName);
      case final DeleteAction a:
        final source = await _selectFor(imap, a);
        final trash = _store.mailboxes.bySpecialUse(
          account.id,
          SpecialUse.trash,
        );
        if (trash == null || trash.id == source.id) {
          // Already in Trash (or there is none): remove for good.
          await imap.uidStore(SequenceSet.of(a.uids), FlagChange.add, {
            r'\Deleted',
          });
          if (imap.capabilities.has('UIDPLUS')) {
            await imap.uidExpunge(SequenceSet.of(a.uids));
          }
        } else {
          await imap.uidMove(SequenceSet.of(a.uids), trash.encodedName);
        }
      case final AppendAction a:
        final target = _mailbox(a.mailboxId);
        await _appendOnce(imap, target, _data(entry), a.flags.toSet());
      case final SendAction a:
        final data = _data(entry);
        var action = a;
        if (!action.smtpAccepted) {
          final client = await smtp();
          await client.send(
            _builtMessage(data, action),
            from: _address(action.from),
          );
          // Record success before anything else can fail, so a crash or an
          // error saving to Sent never causes a second send.
          action = action.markAccepted();
          _store.outbox.updateAction(entry.id, action);
        }
        final sentId = action.sentMailboxId;
        final sent = sentId == null ? null : _store.mailboxes.byId(sentId);
        if (sent != null) await _appendOnce(imap, sent, data, {r'\Seen'});
    }
  }

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

  StoredMailbox _mailbox(int id) =>
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
