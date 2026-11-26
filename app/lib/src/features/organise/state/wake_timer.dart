// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

/// A timer for the next snooze or follow-up due, which then runs
/// [_onDue]. Checked at least hourly: timers may stop while the device
/// sleeps (coming back to the app checks too).
final class WakeTimer {
  WakeTimer(this._store, this._followUps, {required this._onDue});

  final MailStore _store;
  final FollowUpReminders _followUps;

  /// Brings back what is due (snoozed mail, follow-ups).
  final VoidCallback _onDue;
  Timer? _timer;
  bool _disposed = false;

  /// Whether a timer is set.
  @visibleForTesting
  bool get isSet => _timer?.isActive ?? false;

  /// Sets the timer for the next due time (none if nothing is due).
  void schedule() {
    _timer?.cancel();
    _timer = null;
    if (_disposed) return;
    final next = [
      ?_store.snoozes.nextDue(),
      ?_followUps.nextDue(),
    ].fold<DateTime?>(null, (a, b) => a == null || b.isBefore(a) ? b : a);
    if (next == null) return;
    var delay = next.difference(DateTime.now());
    if (delay > const Duration(hours: 1)) delay = const Duration(hours: 1);
    if (delay < const Duration(seconds: 1)) delay = const Duration(seconds: 1);
    _timer = Timer(delay, _onDue);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}
