// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_store/mail_store.dart';

import 'mail_actions.dart';

/// Snoozed mail that came back.
final class BackFromSnooze {
  const BackFromSnooze(this.messages, this.accountIds);

  static const none = BackFromSnooze([], {});

  /// The inbox messages, oldest return first, as they are now (unread).
  final List<WokenMessage> messages;

  /// Accounts with a change queued for the server (marked unread): sync
  /// them soon.
  final Set<int> accountIds;

  bool get isEmpty => messages.isEmpty;
}

/// Brings snoozed mail back when its time comes (or a reply arrives),
/// marked unread, also on the server (where the message never left the
/// inbox). Run after each sync, when the app comes to the foreground, at
/// the next due time while the app runs, and by the background check.
///
/// Each snooze ends exactly once ([SnoozeRepository.wake] works in one
/// write transaction), so when the app and a background job both check,
/// only one of them gets it to announce.
final class SnoozeWaker {
  SnoozeWaker(this._store, this._actions);

  final MailStore _store;
  final MailActions _actions;

  BackFromSnooze wake({DateTime? now}) {
    final woken = _store.snoozes.wake(now: now);
    if (woken.isEmpty) return BackFromSnooze.none;
    final receipt = _actions.markRead([
      for (final w in woken) w.message,
    ], read: false);
    return BackFromSnooze([
      for (final w in woken)
        WokenMessage(
          _store.messages.byId(w.message.id) ?? w.message,
          w.reason,
          w.at,
        ),
    ], receipt.accountIds);
  }

  /// When to check next: the soonest snooze's time, if any.
  DateTime? get nextDue => _store.snoozes.nextDue();
}
