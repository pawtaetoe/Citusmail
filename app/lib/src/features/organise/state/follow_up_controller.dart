// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import '../../../background/background_mail.dart';
import '../../../core/state/notice.dart';
import '../../accounts/state/own_addresses.dart';
import 'follow_up_times.dart';
import 'wake_timer.dart';

/// "Remind me if no reply" on sent mail: setting and ending reminders,
/// with Undo, and checking which got a reply or are due.
final class FollowUpController {
  FollowUpController(
    this._store,
    this.reminders,
    this._wakeTimer, {
    required this._refresh,
    required this._notify,
  });

  final MailStore _store;

  /// The reminders, kept on this device.
  final FollowUpReminders reminders;
  final WakeTimer _wakeTimer;

  /// Re-reads the mail screen after a change.
  final VoidCallback _refresh;
  final ShowNotice _notify;
  bool _disposed = false;

  /// Announces sent mail back with "No reply yet" (set by the screen that
  /// can post notifications).
  void Function()? onFollowUpsBack;

  /// Whether [m] is mail the user sent (in Sent, or from one of their
  /// addresses) that can get a follow-up reminder.
  bool canFollowUp(StoredMessage m) {
    if (m.messageId == null) return false;
    final use = _store.mailboxes.byId(m.mailboxId)?.specialUse;
    if (use == SpecialUse.drafts || use == SpecialUse.trash) return false;
    if (use == SpecialUse.sent) return true;
    final from = m.from?.address.toLowerCase();
    return from != null &&
        _store.ownAddresses.any((a) => a.toLowerCase() == from);
  }

  /// The follow-up of [m], if one is set.
  FollowUp? followUpFor(StoredMessage m) {
    final id = m.messageId;
    return id == null ? null : reminders.find(id);
  }

  /// Sets (or changes) "Remind me if no reply" on [m], with Undo.
  void remindIfNoReply(StoredMessage m, DateTime due, String done) {
    if (!canFollowUp(m)) {
      _notify('Only mail you sent can remind you.');
      return;
    }
    final before = followUpFor(m);
    reminders.remind(reminders.forMessage(m, due));
    _refresh();
    // Android: a background check at that time.
    unawaited(BackgroundMail.checkWhenDue(_store));
    _notify(
      done,
      undo: () {
        if (before == null) {
          reminders.cancel(m.messageId!);
        } else {
          reminders.restore(before);
        }
        _refresh();
      },
    );
  }

  /// Ends a follow-up: "Cancel" while waiting, "Done" once it came back.
  /// With Undo.
  void endFollowUp(FollowUp f) {
    final ended = reminders.cancel(f.messageId);
    if (ended == null) return;
    _refresh();
    _notify(
      ended.returned ? 'Marked done' : 'Reminder cancelled',
      undo: () {
        reminders.restore(ended);
        _refresh();
      },
    );
  }

  /// Ends follow-ups that got a reply, and brings back those whose time
  /// came without one ("No reply yet", announced by [onFollowUpsBack]).
  /// Run after each sync, when the app comes to the foreground, and at
  /// the next due time.
  void check([DateTime? now]) {
    if (_disposed) return;
    try {
      final result = reminders.check(
        now: (now ?? FollowUpTimes.clock()).toUtc(),
      );
      if (!result.isEmpty) _refresh();
      if (result.returned.isNotEmpty) onFollowUpsBack?.call();
    } on Object catch (e) {
      debugPrint('follow-ups: ${e.runtimeType}');
    }
    _wakeTimer.schedule();
  }

  void dispose() => _disposed = true;
}
