// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

import 'account_synchronizer.dart';
import 'app_data/app_data_sync.dart';
import 'connector.dart';
import 'folder_rules.dart';
import 'idle_watcher.dart';
import 'mailbox_synchronizer.dart';
import 'message_loader.dart';
import 'on_demand_connections.dart';
import 'outbox_replayer.dart';
import 'screener_archiver.dart';
import 'sender_blocker.dart';
import 'server_rules.dart';
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
    MessageClassifier? classifier,
    SyncSettings settings = const SyncSettings(),
    this.fullSyncInterval = const Duration(minutes: 5),
    this.inboxCheckInterval,
    this.changeDelay = const Duration(milliseconds: 500),
    SyncCodeProvider? syncCodes,
  }) : appData = syncCodes == null ? null : AppDataSync(_store, syncCodes),
       _mailboxSync = MailboxSynchronizer(
         _store,
         // By default the header rules, plus what each sender's other
         // mail shows (on the device; see LearnedClassifier).
         SummaryMapper(
           classifier ??
               LearnedClassifier(
                 const HeaderRuleClassifier(),
                 StoreSenderHistory(_store),
               ),
         ),
         settings: settings,
       ),
       _loader = MessageLoader(_store),
       _files = FileLookup(_store),
       _onDemand = OnDemandConnections(_connector),
       _background = OnDemandConnections(_connector) {
    _synchronizer = AccountSynchronizer(
      _store,
      _connector,
      _mailboxSync,
      OutboxReplayer(_store),
      rules: FolderRuleApplier(_store),
      blocker: SenderBlocker(_store),
      screener: ScreenerArchiver(_store),
      appData: appData,
      serverRules: ServerRules(_store, _connector.sieve),
    );
  }

  final MailStore _store;
  final MailConnector _connector;

  /// App data sync between the user's devices; null without a code source.
  final AppDataSync? appData;
  final MailboxSynchronizer _mailboxSync;
  final MessageLoader _loader;
  final FileLookup _files;
  final OnDemandConnections _onDemand;

  /// A second on-demand connection per account for work nobody waits on
  /// (reading receipts ahead of time), so a message the user opens never
  /// queues behind it.
  final OnDemandConnections _background;
  late final AccountSynchronizer _synchronizer;

  /// How often every folder is synced while running.
  final Duration fullSyncInterval;

  /// How often each inbox is checked while running, besides IDLE; null
  /// for none. IDLE delivers new mail at once, but a connection can die
  /// without notice (a phone network drops it, the device slept), and a
  /// sign-in code should never wait for the next full sync.
  final Duration? inboxCheckInterval;

  /// Changes arriving close together are handled in one sync.
  final Duration changeDelay;

  // Delivered when they happen, so an event is always seen before the call
  // that caused it returns (the sync worker relies on this order).
  final _events = StreamController<SyncEvent>.broadcast(sync: true);
  final Map<int, Future<void>> _running = {};
  final Map<int, Timer> _pendingRequests = {};
  final List<Timer> _scheduled = [];
  Completer<void>? _stop;
  Completer<void>? _stopWatching;
  Timer? _periodic;
  Timer? _inboxChecks;

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
    _stop = Completer<void>();
    _watch();
    _periodic = Timer.periodic(fullSyncInterval, (_) {
      for (final account in _store.accounts.all()) {
        unawaited(syncAccount(account.id));
      }
    });
    if (inboxCheckInterval case final interval?) {
      _inboxChecks = Timer.periodic(interval, (_) => checkInboxes());
    }
    _syncWhenDue();
  }

  /// A sync of every account, then IDLE on each inbox until [stop] or
  /// [reconnect].
  void _watch() {
    final stop = _stopWatching = Completer<void>();
    for (final account in _store.accounts.all()) {
      unawaited(_runAccount(account, stop.future));
    }
  }

  /// A quick look at every inbox for new mail.
  void checkInboxes() {
    for (final account in _store.accounts.all()) {
      final inbox = _store.mailboxes.inbox(account.id);
      if (inbox != null) requestSync(account.id, mailboxIds: {inbox.id});
    }
  }

  /// Syncs every account now and opens fresh IDLE connections, for when
  /// the app comes back after a while: the old connections may have died
  /// silently while it was in the background. Nothing while not running.
  void reconnect() {
    if (_stop == null) return;
    final old = _stopWatching;
    if (old != null && !old.isCompleted) old.complete();
    _watch();
  }

  /// A sync when each queued change waiting for its time becomes due
  /// (messages scheduled with "Send later", sends in their undo delay),
  /// so they go out on time after the app starts again. The periodic
  /// sync catches them too, a little later, if a timer does not fire
  /// (for example while the device sleeps).
  void _syncWhenDue() {
    final now = DateTime.now();
    for (final account in _store.accounts.all()) {
      final times = {
        for (final entry in _store.outbox.all(account.id))
          if (entry.state == OutboxState.pending &&
              entry.notBefore.isAfter(now))
            entry.notBefore,
      };
      for (final at in times) {
        syncAt(account.id, at);
      }
    }
  }

  /// Stops watching and waits for running syncs to finish.
  Future<void> stop() async {
    _periodic?.cancel();
    _inboxChecks?.cancel();
    _inboxChecks = null;
    final watching = _stopWatching;
    _stopWatching = null;
    if (watching != null && !watching.isCompleted) watching.complete();
    for (final timer in _pendingRequests.values) {
      timer.cancel();
    }
    _pendingRequests.clear();
    for (final timer in _scheduled) {
      timer.cancel();
    }
    _scheduled.clear();
    final stop = _stop;
    _stop = null;
    if (stop != null && !stop.isCompleted) stop.complete();
    await Future.wait(_running.values);
  }

  Future<void> dispose() async {
    await stop();
    await _onDemand.closeAll();
    await _background.closeAll();
    await _events.close();
  }

  /// The full message [messageId], downloaded now if it is not stored
  /// yet. Throws [BodyUnavailableException], or a [MailException] when the
  /// server cannot be reached. [background] downloads (nobody waiting)
  /// use their own connection, so they never hold up one the user opened.
  Future<Uint8List> loadBody(int messageId, {bool background = false}) async {
    final cached = _store.messages.body(messageId);
    if (cached != null) return cached;
    final account = _accountOfMessage(messageId);
    try {
      return await (background ? _background : _onDemand).run(
        account,
        (imap) => _loader.load(imap, messageId),
      );
    } on BodyUnavailableException catch (e) {
      // The cache is out of date: let a sync catch up.
      if (e.problem != BodyProblem.tooLarge) requestSync(account.id);
      rethrow;
    }
  }

  /// Looks up which files [messageIds] have (names, types and sizes from
  /// the server's BODYSTRUCTURE; nothing is downloaded or marked read),
  /// for mail synced before the app kept that. Throws a [MailException]
  /// when a server cannot be reached.
  Future<void> lookUpFiles(List<int> messageIds) async {
    final byAccount = <int, List<int>>{};
    for (final id in messageIds) {
      if (_store.messages.byId(id) case final m?) {
        byAccount.putIfAbsent(m.accountId, () => []).add(id);
      }
    }
    for (final MapEntry(key: accountId, value: ids) in byAccount.entries) {
      final account = _store.accounts.byId(accountId);
      if (account == null) continue;
      await _onDemand.run(account, (imap) => _files.lookUp(imap, ids));
    }
  }

  /// Downloads up to [count] messages older than the oldest stored one in
  /// [mailboxId] ("load older mail"). Returns how many were added.
  Future<int> fetchOlder(int mailboxId, {int count = 100}) async {
    final mailbox = _store.mailboxes.byId(mailboxId);
    if (mailbox == null) return 0;
    final account = _store.accounts.byId(mailbox.accountId);
    if (account == null) return 0;
    return _onDemand.run(
      account,
      (imap) => _mailboxSync.fetchOlder(imap, mailbox, count: count),
    );
  }

  /// Syncs [accountId] at [at] (when a delayed send becomes due), so the
  /// message goes out then rather than at the next periodic sync.
  void syncAt(int accountId, DateTime at) {
    final delay = at.difference(DateTime.now());
    _scheduled.add(
      Timer(delay.isNegative ? Duration.zero : delay, () {
        if (_stop != null) unawaited(syncAccount(accountId));
      }),
    );
    _scheduled.removeWhere((t) => !t.isActive);
  }

  /// Creates the folder [name] on the server ("Projects/2026" makes a
  /// subfolder) and returns its id. A folder that already exists counts
  /// as created. Throws [ArgumentError] for an unusable name, or a
  /// [MailException] when the server cannot be reached.
  Future<int> createFolder(int accountId, String name) async {
    final account = _store.accounts.byId(accountId);
    if (account == null) throw ArgumentError.value(accountId, 'accountId');
    final encoded = FolderNames.newFolder(
      _store.mailboxes.forAccount(accountId),
      name,
    );
    return _onDemand.run(account, (imap) async {
      await imap.create(encoded); // an existing folder counts as created
      _store.mailboxes.replaceAll(accountId, await imap.listMailboxes());
      return _store.mailboxes
          .forAccount(accountId)
          .firstWhere(
            (m) => m.encodedName == encoded,
            orElse: () =>
                throw StateError('the server did not list the new folder'),
          )
          .id;
    });
  }

  /// Removes this device's sync data from the sync account's folder and
  /// forgets the merged state (sync was turned off on this device).
  Future<void> forgetAppData() async {
    final sync = appData;
    final account = sync?.account;
    if (sync == null || account == null) return;
    await _onDemand.run(account, (imap) => sync.forget(imap, account));
  }

  /// Forgets the on-demand connection of an account (after it was removed
  /// or its settings changed).
  Future<void> accountChanged(int accountId) async {
    await _onDemand.close(accountId);
    await _background.close(accountId);
  }

  Account _accountOfMessage(int messageId) {
    final message = _store.messages.byId(messageId);
    final account = message == null
        ? null
        : _store.accounts.byId(message.accountId);
    if (account == null) {
      throw const BodyUnavailableException(BodyProblem.gone);
    }
    return account;
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
