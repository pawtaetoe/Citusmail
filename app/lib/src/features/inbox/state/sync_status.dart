// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

/// How the accounts' sync is going, in one line for the list header.
sealed class SyncStatus {
  const SyncStatus();
}

final class SyncIdle extends SyncStatus {
  const SyncIdle(this.lastSynced);

  final DateTime? lastSynced;
}

final class SyncRunning extends SyncStatus {
  const SyncRunning();
}

final class SyncProblem extends SyncStatus {
  const SyncProblem(
    this.kind,
    this.account, {
    this.accountId,
    this.oauth = false,
  });

  final SyncFailureKind kind;
  final String account;
  final int? accountId;

  /// The account signs in with OAuth: a refused login means its sign-in
  /// ended, not a wrong password.
  final bool oauth;
}

/// Follows the sync worker's events: the last event of each account, and
/// the [status] line made from them.
final class SyncStatusController {
  SyncStatusController(this._store, this._worker, {this.onEvent}) {
    _events = _worker.events.listen(_record);
  }

  final MailStore _store;
  final SyncWorker _worker;

  /// Runs after each sync event, once [status] is up to date.
  void Function(SyncEvent event)? onEvent;

  /// Asks for an account's new password or sign-in (set by the screen
  /// that can show it).
  void Function(Account account)? onReconnect;

  final status = ValueNotifier<SyncStatus>(const SyncIdle(null));

  late final StreamSubscription<SyncEvent> _events;
  final Map<int, SyncEvent> _lastEvent = {};

  SyncEvent? lastEvent(int accountId) => _lastEvent[accountId];

  Future<void> syncNow() async {
    try {
      await _worker.syncNow();
    } on SyncWorkerException {
      // Shown through the account's failure event.
    }
  }

  /// Fixes the login of the account in [problem], if that is the problem.
  void reconnect(SyncProblem problem) {
    final account = problem.accountId == null
        ? null
        : _store.accounts.byId(problem.accountId!);
    if (account != null) onReconnect?.call(account);
  }

  void _record(SyncEvent event) {
    _lastEvent[event.accountId] = event;
    status.value = _computeStatus();
    onEvent?.call(event);
  }

  SyncStatus _computeStatus() {
    if (_lastEvent.values.any((e) => e is AccountSyncStarted)) {
      return const SyncRunning();
    }
    for (final MapEntry(key: accountId, value: event) in _lastEvent.entries) {
      if (event is AccountSyncFailed) {
        final account = _store.accounts.byId(accountId);
        return SyncProblem(
          event.failure.kind,
          account?.email ?? '',
          accountId: accountId,
          oauth: account?.usesOAuth ?? false,
        );
      }
    }
    return SyncIdle(DateTime.now());
  }

  /// Stops following the events.
  void dispose() {
    unawaited(_events.cancel());
    status.dispose();
  }
}
