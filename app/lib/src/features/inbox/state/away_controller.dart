// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:mail_sync/mail_sync.dart';

import '../../../core/state/notice.dart';
import '../../organise/state/follow_up_controller.dart';
import '../../organise/state/snooze_controller.dart';
import 'message_actions.dart';
import 'message_list_model.dart';
import 'new_since_away.dart';

/// Leaving the app and coming back: "New since you were away", a look
/// for new mail, and what came due meanwhile.
final class AwayController {
  AwayController(
    this._worker,
    this._list,
    this._actions,
    this._snoozes,
    this._followUps, {
    required this._refresh,
    required this._notify,
  });

  final SyncWorker _worker;
  final MessageListModel _list;
  final MessageActions _actions;
  final SnoozeController _snoozes;
  final FollowUpController _followUps;

  /// Re-reads the mail screen after a change.
  final VoidCallback _refresh;
  final ShowNotice _notify;

  /// How long the app can be away before [onResume] reconnects.
  static const awayBeforeReconnect = NewSinceAway.awayFor;

  /// When the app was last hidden (another app in front, or minimized).
  DateTime? _hiddenAt;

  /// The app went to the background (or is closing): remembered for "New
  /// since you were away", also if the app is then closed.
  void onHide() {
    _hiddenAt ??= DateTime.now();
    _list.away.wentAway();
  }

  /// Coming back to the app: a look for new mail at once (a sign-in code
  /// is often why someone switches back), then snoozed mail and
  /// follow-ups that are due. After a minute away the mail connections
  /// may have died quietly, so they are opened afresh.
  void onResume() {
    final hiddenAt = _hiddenAt;
    _hiddenAt = null;
    // After more than a minute away, a new "New since you were away".
    if (_list.away.cameBack()) _list.refresh();
    if (hiddenAt != null) {
      if (DateTime.now().difference(hiddenAt) > awayBeforeReconnect) {
        _worker.reconnect();
      } else {
        _worker.checkInboxes();
      }
    }
    _snoozes.wake();
    _followUps.check();
  }

  /// "Done" on "New since you were away": its messages go back to their
  /// sections, still unread (only a view; nothing changes on the server).
  void doneWithAway() {
    final window = _list.away.window;
    if (window == null) return;
    _list.away.done();
    _refresh();
    _notify(
      'Back in their sections',
      undo: () {
        _list.away.window = window;
        _refresh();
      },
    );
  }

  /// "Mark all as read" on "New since you were away".
  void markAwayRead() {
    final unread = [
      for (final m in _list.newSinceAway.messages)
        if (!m.flags.seen) m,
    ];
    _actions.markAllRead(unread);
  }
}
