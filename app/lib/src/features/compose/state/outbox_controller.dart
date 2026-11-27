// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_compose/mail_compose.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import '../../../background/background_mail.dart';
import '../../../core/state/notice.dart';
import '../../../services/app_services.dart';
import 'compose_starter.dart';
import 'send_later_times.dart';

/// Mail on its way out: failed sends to retry or discard, and messages
/// scheduled with "Send later" (send now, another time, keep writing,
/// don't send), each keeping its follow-up reminder.
final class OutboxController {
  OutboxController(
    this._services,
    this._followUps,
    this._compose, {
    required this._refresh,
    required this._notify,
  }) : scheduledSends = ScheduledSends(_services.store, _services.sender);

  final AppServices _services;

  /// "Remind me if no reply", which follows a message to its new time.
  final FollowUpReminders _followUps;
  final ComposeStarter _compose;

  /// Re-reads the mail screen after a change.
  final VoidCallback _refresh;
  final ShowNotice _notify;

  MailStore get _store => _services.store;

  /// Messages waiting to be sent or failed, oldest first.
  List<OutboxEntry> get outbox => _store.outbox.sends();

  void retrySend(OutboxEntry entry) {
    _store.outbox.retryFailed(entry.id);
    _services.worker.requestSync(entry.accountId);
    _refresh();
  }

  void discardSend(OutboxEntry entry) {
    _store.outbox.discardFailed(entry.id);
    _refresh();
  }

  /// Messages scheduled with "Send later".
  final ScheduledSends scheduledSends;

  static const _tooLate =
      'Too late to change: the message is already on its way.';

  /// Sends a scheduled message now (with Undo, which puts it back at its
  /// time).
  void sendScheduledNow(ScheduledSend s) {
    final now = SendLaterTimes.clock();
    final pending = scheduledSends.sendNow(s, now: now);
    if (pending != null) _followScheduled(s, pending, now);
    _refresh();
    if (pending == null) {
      _notify(_tooLate);
      return;
    }
    _services.worker.syncAt(pending.accountId, pending.undoUntil);
    _notify(
      'Sending…',
      undo: () {
        // Back to its time, unless it has started to go out.
        final undone =
            _services.sender.cancel(pending, now: SendLaterTimes.clock()) &&
            _rescheduleDraft(pending.draft, s.at, from: pending);
        _refresh();
        if (!undone) _notify('Too late: the message is on its way.');
      },
    );
  }

  bool _rescheduleDraft(Draft draft, DateTime at, {PendingSend? from}) {
    PendingSend pending;
    try {
      pending = _services.sender.schedule(
        draft,
        at.toLocal(),
        now: SendLaterTimes.clock(),
      );
      _armScheduled(pending);
    } on ArgumentError {
      // Its time has come meanwhile: send it.
      pending = _services.sender.send(draft, now: SendLaterTimes.clock());
      _services.worker.syncAt(pending.accountId, pending.undoUntil);
    }
    if (from != null) {
      final sentAt = pending.scheduledFor ?? SendLaterTimes.clock();
      final before = _followUps.find(from.messageId)?.sentAt;
      _followUps.move(
        from.messageId,
        pending.messageId,
        shift: before == null ? Duration.zero : sentAt.difference(before),
      );
    }
    return true;
  }

  /// A scheduled message's follow-up goes with it when it goes out under
  /// a new Message-ID ([pending], sent at its time or [now]), keeping the
  /// time between sending and the reminder.
  void _followScheduled(ScheduledSend s, PendingSend pending, DateTime now) {
    final id = _scheduledId(s);
    if (id == null) return;
    final sentAt = pending.scheduledFor ?? now;
    _followUps.move(id, pending.messageId, shift: sentAt.difference(s.at));
  }

  /// The Message-ID a scheduled message was to go out with.
  static String? _scheduledId(ScheduledSend s) {
    final data = s.entry.data;
    return data == null ? null : const MimeParser().parse(data).messageId;
  }

  /// Sends a scheduled message at [at] instead.
  void rescheduleSend(ScheduledSend s, DateTime at, String done) {
    final PendingSend? pending;
    final now = SendLaterTimes.clock();
    try {
      pending = scheduledSends.reschedule(s, at, now: now);
    } on ArgumentError {
      sendScheduledNow(s);
      return;
    }
    if (pending != null) _followScheduled(s, pending, now);
    _refresh();
    if (pending == null) {
      _notify(_tooLate);
      return;
    }
    _armScheduled(pending);
    _notify(done);
  }

  /// Takes a scheduled message back to keep writing it (the schedule
  /// ends; closing the window keeps it as a draft).
  void editScheduled(ScheduledSend s) {
    final draft = scheduledSends.edit(s, now: SendLaterTimes.clock());
    // Not sent: no reminder for it.
    if (draft != null) _followUps.cancel(_scheduledId(s) ?? '');
    _refresh();
    if (draft == null) {
      _notify(_tooLate);
      return;
    }
    _compose.show(draft);
  }

  /// Doesn't send a scheduled message: it goes to Drafts instead.
  void cancelScheduled(ScheduledSend s) {
    final id = _scheduledId(s);
    final outcome = scheduledSends.cancel(s, now: SendLaterTimes.clock());
    if (outcome != null) _followUps.cancel(id ?? '');
    _refresh();
    if (outcome == null) {
      _notify(_tooLate);
      return;
    }
    _services.worker.requestSync(s.entry.accountId);
    _notify(
      outcome == DraftOutcome.savedToServer
          ? 'It won\'t be sent. It\'s in Drafts.'
          : 'It won\'t be sent. It\'s kept as a draft on this device.',
    );
  }

  /// A sync at the scheduled time (and on Android, a background check).
  void _armScheduled(PendingSend pending) {
    _services.worker.syncAt(pending.accountId, pending.undoUntil);
    if (pending.scheduledFor case final at?) {
      _services.worker.syncAt(pending.accountId, at);
    }
    unawaited(BackgroundMail.checkWhenDue(_store));
  }
}
