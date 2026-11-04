// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:mail_sync/mail_sync.dart';

import 'app_services.dart';
import 'mail_notifier.dart';

/// While the app runs: after each sync, claims new mail and announces it,
/// unless the user is looking at the app (then the list shows it); posts
/// reminders of bills and trials when it is time; and announces snoozed
/// mail that came back ([backFromSnooze]).
final class NewMailAnnouncer {
  NewMailAnnouncer(this._services, this._notifier)
    : _tracker = NewMailTracker(_services.store) {
    _events = _services.worker.events.listen(_onEvent);
  }

  final AppServices _services;
  final MailNotifier? _notifier;
  final NewMailTracker _tracker;
  late final StreamSubscription<SyncEvent> _events;

  void _onEvent(SyncEvent event) {
    if (event is! AccountSynced) return;
    // Always claimed, so mail seen here is not announced later by the
    // background job.
    final mail = _tracker.claim(event.accountId);
    final notifier = _notifier;
    if (notifier == null) return;
    unawaited(notifier.remind(_services.store));
    if (mail.isEmpty) return;
    if (!_services.settings.notifications) return;
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      return;
    }
    final account = _services.store.accounts.byId(event.accountId);
    if (account != null) {
      unawaited(notifier.announce(_services.store, account, mail));
    }
  }

  /// Announces snoozed mail that came back, by the same rules as new
  /// mail: not while the user is looking at the app (the list shows it on
  /// top), nor with notifications off.
  void backFromSnooze(BackFromSnooze back) {
    final notifier = _notifier;
    if (notifier == null || back.isEmpty) return;
    if (!_services.settings.notifications) return;
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      return;
    }
    unawaited(notifier.announceBackFromSnooze(_services.store, back));
  }

  Future<void> dispose() => _events.cancel();
}
