// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_store/mail_store.dart';
import 'package:mail_view/mail_view.dart';

import 'draft.dart';
import 'draft_store.dart';
import 'sender.dart';

/// A message waiting in the outbox for the time the user chose.
final class ScheduledSend {
  const ScheduledSend._(this.entry, this.schedule);

  /// [entry] as a scheduled message, or null if it is an ordinary send
  /// (or not a send at all).
  static ScheduledSend? of(OutboxEntry entry) => switch (entry.action) {
    SendAction(:final schedule?) => ScheduledSend._(entry, schedule),
    _ => null,
  };

  final OutboxEntry entry;
  final SendSchedule schedule;

  /// The chosen time (UTC).
  DateTime get at => schedule.at;

  /// Still waiting for its time, nothing tried yet: it can be changed,
  /// sent now or taken back.
  bool waitingAt(DateTime now) =>
      entry.state == OutboxState.pending &&
      entry.attempts == 0 &&
      entry.notBefore.isAfter(now);
}

/// "Send later": the messages waiting for their time, and changing your
/// mind about one (send it now, at another time, edit it, or keep it as a
/// draft instead).
///
/// A scheduled message is an ordinary queued send whose not-before time
/// is the chosen time, so the sync sends it with the same once-only
/// replay as any other message: SMTP first, then saved to Sent once. It
/// stays on this device until then; nothing about it is synced to the
/// user's other devices, so only this one sends it.
///
/// Each change takes the message back first (only while nothing has been
/// tried, as undo does), so it never goes out while being changed.
final class ScheduledSends {
  ScheduledSends(this._store, this._sender)
    : _drafts = DraftStore(_store, messages: _sender.messages);

  final MailStore _store;
  final Sender _sender;
  final DraftStore _drafts;

  /// Every scheduled message (waiting, being sent or failed), oldest
  /// first.
  List<ScheduledSend> all() => [
    for (final entry in _store.outbox.sends()) ?ScheduledSend.of(entry),
  ];

  /// The soonest time a waiting message is due, if any.
  DateTime? nextDue({DateTime? now}) {
    final at = now ?? DateTime.now();
    DateTime? soonest;
    for (final s in all()) {
      if (!s.waitingAt(at)) continue;
      if (soonest == null || s.entry.notBefore.isBefore(soonest)) {
        soonest = s.entry.notBefore;
      }
    }
    return soonest;
  }

  /// Sends [s] at [at] instead. Returns the new pending send, or null if
  /// it was too late (the message may already be going out). Throws
  /// [ArgumentError] if [at] is not later than the undo delay.
  PendingSend? reschedule(ScheduledSend s, DateTime at, {DateTime? now}) {
    final start = now ?? DateTime.now();
    if (!at.isAfter(start.add(_sender.undoDelay))) {
      throw ArgumentError.value(at, 'at', 'must be later');
    }
    return _store.transaction(() {
      final draft = _takeBack(s, start);
      return draft == null ? null : _sender.schedule(draft, at, now: start);
    });
  }

  /// Sends [s] now (with the usual undo delay). Returns the pending send,
  /// or null if it was too late.
  PendingSend? sendNow(ScheduledSend s, {DateTime? now}) =>
      _store.transaction(() {
        final draft = _takeBack(s, now ?? DateTime.now());
        return draft == null ? null : _sender.send(draft, now: now);
      });

  /// Takes [s] back to keep writing it: the schedule ends and the draft
  /// is saved on the device (the compose window then handles it as any
  /// draft). Null if it was too late.
  Draft? edit(ScheduledSend s, {DateTime? now}) => _store.transaction(() {
    final draft = _takeBack(s, now ?? DateTime.now());
    return draft == null ? null : _drafts.save(draft);
  });

  /// Doesn't send [s]: it goes to the Drafts folder instead (or stays on
  /// the device if the account has none). Null if it was too late.
  DraftOutcome? cancel(ScheduledSend s, {DateTime? now}) =>
      _store.transaction(() {
        final draft = _takeBack(s, now ?? DateTime.now());
        return draft == null ? null : _drafts.close(draft);
      });

  /// Scheduled messages that failed to send and that the user has not
  /// been told about yet. Each is returned once (the mark is written in
  /// the same transaction), also when the app and the background check
  /// look at the same time.
  List<ScheduledSend> claimFailures() => _store.transaction(() {
    final claimed = <ScheduledSend>[];
    for (final s in all()) {
      if (s.entry.state != OutboxState.failed || s.schedule.failureNoticed) {
        continue;
      }
      final action = s.entry.action as SendAction;
      _store.outbox.updateAction(
        s.entry.id,
        action.withSchedule(s.schedule.copyWith(failureNoticed: true)),
      );
      claimed.add(s);
    }
    return claimed;
  });

  /// The draft [s] was made from, with its attachments (read back from
  /// the queued message).
  Draft draftOf(ScheduledSend s) {
    final data = s.entry.data;
    final attachments = data == null
        ? const <DraftAttachment>[]
        : [
            for (final a in MessageView.parse(data).attachments)
              DraftAttachment(
                fileName: a.fileName,
                mimeType: a.mimeType,
                bytes: a.bytes(),
              ),
          ];
    return Draft.decodeContent(
      s.schedule.draft,
      id: 0,
      accountId: s.entry.accountId,
      attachments: attachments,
    ).copyWith(clearId: true);
  }

  /// Removes [s] and what goes with it from the queue, if nothing has
  /// been tried yet, and undoes the local "answered" mark. Returns its
  /// draft, or null if it was too late.
  Draft? _takeBack(ScheduledSend s, DateTime now) {
    final current = _store.outbox.byId(s.entry.id);
    final fresh = current == null ? null : ScheduledSend.of(current);
    if (fresh == null || !fresh.waitingAt(now)) return null;
    final followUps = [
      for (final id in fresh.schedule.followUps) ?_store.outbox.byId(id),
    ];
    if (!_store.outbox.cancel([
      fresh.entry.id,
      for (final f in followUps) f.id,
    ], now: now)) {
      return null;
    }
    for (final f in followUps) {
      if (f.action case final SetFlagsAction a
          when a.add.contains(r'\Answered')) {
        _unmarkAnswered(a);
      }
    }
    return draftOf(fresh);
  }

  void _unmarkAnswered(SetFlagsAction action) {
    final changes = [
      for (final uid in action.uids)
        if (_store.messages.byUid(action.mailboxId, uid) case final m?
            when m.flags.answered)
          (
            uid: uid,
            flags: m.flags.withBit(MessageFlags.answeredBit, false),
            modSeq: null,
          ),
    ];
    if (changes.isNotEmpty) {
      _store.messages.updateFlags(action.mailboxId, changes);
    }
  }
}
