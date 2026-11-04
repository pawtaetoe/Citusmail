// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'draft.dart';
import 'draft_store.dart';
import 'outgoing.dart';

/// A message handed to the outbox, still undoable until [undoUntil].
final class PendingSend {
  const PendingSend._({
    required this.accountId,
    required this.entryIds,
    required this.undoUntil,
    required this.draft,
    required this.answered,
    this.scheduledFor,
  });

  final int accountId;

  /// When the message goes out, if the user chose a time ("Send later").
  final DateTime? scheduledFor;

  /// The queued send and its follow-ups (answered flag, old draft copy).
  final List<int> entryIds;
  final DateTime undoUntil;

  /// What was sent, to bring back on undo.
  final Draft draft;

  /// The replied-to message whose \Answered flag was set here.
  final StoredMessage? answered;
}

/// Sends drafts through the outbox: the message waits [undoDelay] before
/// the sync worker hands it to the SMTP server, so the user can take it
/// back. Sending also works offline; it goes out with the next sync.
final class Sender {
  Sender(
    this._store, {
    this.undoDelay = const Duration(seconds: 5),
    this.messages = const OutgoingMessages(),
  }) : _drafts = DraftStore(_store, messages: messages);

  final MailStore _store;
  final DraftStore _drafts;
  final OutgoingMessages messages;
  final Duration undoDelay;

  /// Queues [draft] for sending. Throws [ComposeException] if it cannot be
  /// sent (no recipients, bad address, too large...).
  PendingSend send(Draft draft, {DateTime? now}) => _queue(draft, now: now);

  /// Queues [draft] to go out at [at] ("Send later"). It waits in the
  /// outbox on this device until then; it can be undone like a send for
  /// [undoDelay], and taken back later with [ScheduledSends]. Throws
  /// [ComposeException] like [send], or [ArgumentError] if [at] is not
  /// after the undo delay.
  PendingSend schedule(Draft draft, DateTime at, {DateTime? now}) {
    final undoUntil = (now ?? DateTime.now()).add(undoDelay);
    if (!at.isAfter(undoUntil)) {
      throw ArgumentError.value(at, 'at', 'must be later');
    }
    return _queue(draft, now: now, at: at);
  }

  PendingSend _queue(Draft draft, {DateTime? now, DateTime? at}) {
    final account = _store.accounts.byId(draft.accountId);
    // A scheduled message is dated when it is due to go out.
    final built = messages.forSending(draft, account, date: at);
    final undoUntil = (now ?? DateTime.now()).add(undoDelay);
    final sendAt = at ?? undoUntil;
    final sentFolder = _store.mailboxes.bySpecialUse(
      account!.id,
      SpecialUse.sent,
    );
    final draftsFolder = _store.mailboxes.bySpecialUse(
      account.id,
      SpecialUse.drafts,
    );

    return _store.transaction(() {
      final send = SendAction(
        from: account.email,
        recipients: [for (final r in built.recipients) r.address],
        sentMailboxId: sentFolder?.id,
        schedule: at == null
            ? null
            : SendSchedule(at: at, draft: draft.encodeContent()),
      );
      final sendId = _store.outbox
          .enqueue(account.id, send, data: built.bytes, notBefore: sendAt)
          .id;
      final ids = <int>[sendId];
      // The older copy in the Drafts folder goes once the undo delay is
      // over, also for a scheduled message: until it is sent, it waits in
      // the Outbox (and comes back to Drafts if cancelled).
      if (draft.savedMessageId case final saved? when draftsFolder != null) {
        try {
          ids.add(
            _store.outbox
                .enqueue(
                  account.id,
                  RemoveDraftAction(
                    mailboxId: draftsFolder.id,
                    messageId: saved,
                  ),
                  notBefore: undoUntil,
                )
                .id,
          );
        } on ArgumentError {
          // Not an id we wrote: leave that copy alone.
        }
      }
      if (draft.requestReceipt) {
        _store.receipts.requested(account.id, built.messageId);
      }
      // Marked answered when it goes out.
      final before = ids.length;
      final answered = _markAnswered(draft.answeredMessageId, sendAt, ids);
      if (send.schedule case final schedule? when ids.length > before) {
        // Taken back with the message, if it is cancelled.
        _store.outbox.updateAction(
          sendId,
          send.withSchedule(schedule.copyWith(followUps: ids.sublist(before))),
        );
      }
      if (draft.id case final id?) _store.drafts.delete(id);
      return PendingSend._(
        accountId: account.id,
        entryIds: List.unmodifiable(ids),
        undoUntil: undoUntil,
        draft: draft.copyWith(clearId: true),
        answered: answered,
        scheduledFor: at,
      );
    });
  }

  /// Takes the message back if it has not started to go out. Returns the
  /// draft (saved on the device again) to keep editing, or null if it was
  /// too late.
  Draft? undo(PendingSend pending, {DateTime? now}) => _store.transaction(() {
    if (!cancel(pending, now: now)) return null;
    return _drafts.save(pending.draft);
  });

  /// Takes the message back without keeping it as a draft (for messages
  /// the app wrote itself, such as an answer to an invitation). Returns
  /// whether it was in time.
  bool cancel(PendingSend pending, {DateTime? now}) => _store.transaction(() {
    if (!_store.outbox.cancel(pending.entryIds, now: now)) return false;
    if (pending.answered case final original?) {
      _store.messages.updateFlags(original.mailboxId, [
        (uid: original.uid, flags: original.flags, modSeq: null),
      ]);
    }
    return true;
  });

  /// Sets \Answered on the replied-to message (locally now, on the server
  /// with the send). Returns the message as it was, for undo.
  StoredMessage? _markAnswered(
    int? messageId,
    DateTime notBefore,
    List<int> ids,
  ) {
    if (messageId == null) return null;
    final original = _store.messages.byId(messageId);
    if (original == null || original.flags.answered) return null;
    final mailbox = _store.mailboxes.byId(original.mailboxId);
    final validity = mailbox?.syncState.uidValidity;
    if (mailbox == null || validity == null) return null;
    _store.messages.updateFlags(mailbox.id, [
      (
        uid: original.uid,
        flags: original.flags.withBit(MessageFlags.answeredBit, true),
        modSeq: null,
      ),
    ]);
    ids.add(
      _store.outbox
          .enqueue(
            mailbox.accountId,
            SetFlagsAction(
              mailboxId: mailbox.id,
              uidValidity: validity,
              uids: [original.uid],
              add: const [r'\Answered'],
            ),
            notBefore: notBefore,
          )
          .id,
    );
    return original;
  }
}
