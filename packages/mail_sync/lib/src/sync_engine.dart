// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

import 'account_synchronizer.dart';
import 'connector.dart';
import 'idle_watcher.dart';
import 'mailbox_synchronizer.dart';
import 'outbox_replayer.dart';
import 'summary_mapper.dart';

/// Something the UI may want to show.
sealed class SyncEvent {
  const SyncEvent(this.accountId);

  final int accountId;
}

final class AccountSyncStarted extends SyncEvent {
  const AccountSyncStarted(super.accountId);
}

final class AccountSynced extends SyncEvent {
  const AccountSynced(super.accountId, this.report);

  final AccountSyncReport report;
}

final class AccountSyncFailed extends SyncEvent {
  const AccountSyncFailed(super.accountId, this.failure);

  final SyncFailure failure;
}

/// Runs syncs for all accounts: on demand, when IDLE reports a change,
/// and periodically. Syncs of one account never overlap.
final class SyncEngine {
  SyncEngine(
    this._store,
    this._connector, {
    MessageClassifier classifier = const HeaderRuleClassifier(),
    SyncSettings settings = const SyncSettings(),
    this.fullSyncInterval = const Duration(minutes: 15),
    this.changeDelay = const Duration(milliseconds: 500),
  }) : _synchronizer = AccountSynchronizer(
         _store,
         _connector,
         MailboxSynchronizer(
           _store,
           SummaryMapper(classifier),
           settings: settings,
         ),
         OutboxReplayer(_store),
       );

  final MailStore _store;
  final MailConnector _connector;
  final AccountSynchronizer _synchronizer;

  /// How often every folder is synced while running.
  final Duration fullSyncInterval;

  /// Changes arriving close together are handled in one sync.
  final Duration changeDelay;

  final _events = StreamController<SyncEvent>.broadcast();
  final Map<int, Future<void>> _running = {};
  final Map<int, Timer> _pendingRequests = {};
  Completer<void>? _stop;
  Timer? _periodic;

  Stream<SyncEvent> get events => _events.stream;

  bool get isRunning => _stop != null;

  /// Syncs one account now (after any sync already running for it).
  /// Failures are reported as [AccountSyncFailed] events, not thrown.
  Future<AccountSyncReport?> syncAccount(
    int accountId, {
    Set<int>? mailboxIds,
  }) {
    final previous = _running[accountId] ?? Future.value();
    final run = previous.then((_) async {
      final account = _store.accounts.byId(accountId);
      if (account == null) return null;
      _events.add(AccountSyncStarted(accountId));
      try {
        final report = await _synchronizer.sync(
          account,
          mailboxIds: mailboxIds,
        );
        _events.add(AccountSynced(accountId, report));
        return report;
      } on Object catch (e) {
        _events.add(AccountSyncFailed(accountId, SyncFailure.from(e)));
        return null;
      }
    });
    _running[accountId] = run.then((_) {});
    return run;
  }

  /// Asks for a sync soon (e.g. after the user acted on mail). Requests
  /// arriving within [changeDelay] are merged.
  void requestSync(int accountId, {Set<int>? mailboxIds}) {
    _pendingRequests[accountId]?.cancel();
    _pendingRequests[accountId] = Timer(changeDelay, () {
      _pendingRequests.remove(accountId);
      unawaited(syncAccount(accountId, mailboxIds: mailboxIds));
    });
  }

  /// Starts syncing every account, watching each inbox with IDLE.
  void start() {
    if (_stop != null) return;
    final stop = _stop = Completer<void>();
    for (final account in _store.accounts.all()) {
      unawaited(_runAccount(account, stop.future));
    }
    _periodic = Timer.periodic(fullSyncInterval, (_) {
      for (final account in _store.accounts.all()) {
        unawaited(syncAccount(account.id));
      }
    });
  }

  /// Stops watching and waits for running syncs to finish.
  Future<void> stop() async {
    _periodic?.cancel();
    for (final timer in _pendingRequests.values) {
      timer.cancel();
    }
    _pendingRequests.clear();
    final stop = _stop;
    _stop = null;
    if (stop != null && !stop.isCompleted) stop.complete();
    await Future.wait(_running.values);
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
  }

  Future<void> _runAccount(Account account, Future<void> stop) async {
    await syncAccount(account.id);
    final inbox = _store.mailboxes.inbox(account.id);
    if (inbox == null) return;
    await IdleWatcher(_connector).watch(
      account,
      inbox,
      stop: stop,
      onChange: () => requestSync(account.id, mailboxIds: {inbox.id}),
      onFailure: (failure) =>
          _events.add(AccountSyncFailed(account.id, failure)),
    );
  }
}
