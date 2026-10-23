// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:mail_sync/mail_sync.dart';

import '../security/app_lock.dart';
import 'app_services.dart';
import 'mail_notifier.dart';

/// While the app runs: after each sync, claims new mail and announces it,
/// unless the user is looking at the app (then the list shows it).
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
    if (mail.isEmpty || notifier == null) return;
    if (!_services.settings.notifications) return;
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      return;
    }
    final account = _services.store.accounts.byId(event.accountId);
    if (account != null) {
      unawaited(
        notifier.show(
          account,
          mail,
          hideContent: AppLock.isEnabledIn(_services.store),
        ),
      );
    }
  }

  Future<void> dispose() => _events.cancel();
}
