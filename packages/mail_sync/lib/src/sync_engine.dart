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
import 'connection_budget.dart';
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
import 'server_search.dart';
import 'summary_mapper.dart';
import 'sync_connections.dart';

/// Something the UI may want to show.
sealed class SyncEvent {
  const SyncEvent(this.accountId);

  final AccountId accountId;
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
///
/// Every IMAP connection it opens counts in one [ConnectionBudget] per
/// account (4 by default, IDLE included), shared by the syncs, the
/// on-demand work and IDLE; see docs/architecture.md, "Connections".
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
    ConnectionBudget? connections,
    List<Duration> refusalRetryDelays = const [
      Duration(seconds: 2),
      Duration(seconds: 5),
    ],
    Backoff? backoff,
  }) : connections = connections ?? ConnectionBudget(_connector),
       _backoff = backoff ?? Backoff(),
       appData = syncCodes == null ? null : AppDataSync(_store, syncCodes),
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
       _files = FileLookup(_store) {
    _onDemand = OnDemandConnections(
      _connector,
      budget: this.connections,
      retryDelays: refusalRetryDelays,
    );
    _background = OnDemandConnections(
      _connector,
      budget: this.connections,
      priority: ConnectionPriority.background,
      retryDelays: const [],
    );
    _syncConnections = SyncConnections(_connector, budget: this.connections);
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
      connections: _syncConnections,
    );
  }

  final MailStore _store;
  final MailConnector _connector;

  /// Every connection of an account counts here: the syncs', the
  /// on-demand ones and IDLE.
  final ConnectionBudget connections;

  /// After a login refused for being one connection too many, an
  /// account's periodic syncs and inbox checks wait this long (longer
  /// after each refusal in a row).
  final Backoff _backoff;
  final _refusals = <AccountId, ({int count, DateTime until})>{};

  /// App data sync between the user's devices; null without a code source.
  final AppDataSync? appData;
  final MailboxSynchronizer _mailboxSync;
  final MessageLoader _loader;
  final FileLookup _files;
  late final OnDemandConnections _onDemand;

  /// A second on-demand connection per account for work nobody waits on
  /// (reading receipts ahead of time), so a message the user opens never
  /// queues behind it.
  late final OnDemandConnections _background;

  /// Connections kept between syncs, so the frequent inbox check does
  /// not log in every time.
  late final SyncConnections _syncConnections;
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
  final Map<AccountId, _AccountSyncs> _syncs = {};
  final Map<AccountId, _PendingRequest> _pendingRequests = {};
  bool _stopping = false;
  bool _disposed = false;
  final List<Timer> _scheduled = [];
  final Set<Future<void>> _watching = {};
  Completer<void>? _stop;
  Completer<void>? _stopWatching;
  Timer? _periodic;
  Timer? _inboxChecks;

  Stream<SyncEvent> get events => _events.stream;

  bool get isRunning => _stop != null;

  /// Syncs one account now, or after the sync already running for it.
  /// Failures are reported as [AccountSyncFailed] events, not thrown.
  ///
  /// An account has at most one sync running and one waiting: what is
  /// asked for while one waits joins it (its folders added; a full sync
  /// covers every folder, and views like Gmail's Starred asked for are
  /// added), and every caller gets that sync's report. Different accounts
  /// sync side by side. While the engine stops, nothing new starts (null).
  Future<AccountSyncReport?> syncAccount(
    AccountId accountId, {
    Set<MailboxId>? mailboxIds,
  }) => _sync(accountId, _SyncRequest(mailboxIds));

  Future<AccountSyncReport?> _sync(AccountId accountId, _SyncRequest request) {
    if (_stopping || _disposed) return Future.value();
    final syncs = _syncs.putIfAbsent(accountId, _AccountSyncs.new);
    if (syncs.waiting case final waiting?) {
      waiting.request = waiting.request.join(request);
      return waiting.done.future;
    }
    final sync = _WaitingSync(request);
    if (syncs.done != null) {
      syncs.waiting = sync;
    } else {
      syncs.done = _runSyncs(accountId, syncs, sync);
    }
    return sync.done.future;
  }

  /// Runs [first], then the sync that waited meanwhile, one at a time.
  Future<void> _runSyncs(
    AccountId accountId,
    _AccountSyncs syncs,
    _WaitingSync first,
  ) async {
    // Runs after the caller noted that this account has a sync running.
    await null;
    _WaitingSync? next = first;
    while (next != null) {
      next.done.complete(await _syncOnce(accountId, next.request));
      next = syncs.waiting;
      syncs.waiting = null;
      if (next != null && (_stopping || _disposed)) {
        next.done.complete(null);
        next = null;
      }
    }
    _syncs.remove(accountId);
  }

  /// One sync of [accountId]; never throws.
  Future<AccountSyncReport?> _syncOnce(
    AccountId accountId,
    _SyncRequest request,
  ) async {
    try {
      final account = _store.accounts.byId(accountId);
      if (account == null) return null;
      _emit(AccountSyncStarted(accountId));
      final report = await _synchronizer.sync(
        account,
        mailboxIds: request.full ? null : request.mailboxIds,
        alsoMailboxIds: request.full ? request.mailboxIds : const {},
      );
      _refusals.remove(accountId);
      _emit(AccountSynced(accountId, report));
      return report;
    } on Object catch (e) {
      if (e is ImapAuthenticationException && e.temporary) {
        final count = (_refusals[accountId]?.count ?? 0) + 1;
        _refusals[accountId] = (
          count: count,
          until: DateTime.now().add(_backoff.after(count - 1)),
        );
      }
      _emit(AccountSyncFailed(accountId, SyncFailure.from(e)));
      return null;
    }
  }

  void _emit(SyncEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  /// Asks for a sync soon (e.g. after the user acted on mail). Requests
  /// arriving within [changeDelay] of the first are merged into one.
  void requestSync(AccountId accountId, {Set<MailboxId>? mailboxIds}) {
    final request = _SyncRequest(mailboxIds);
    if (_pendingRequests[accountId] case final pending?) {
      pending.request = pending.request.join(request);
      return;
    }
    final pending = _PendingRequest(request);
    pending.timer = Timer(changeDelay, () {
      if (_pendingRequests[accountId] == pending) {
        _pendingRequests.remove(accountId);
      }
      unawaited(_sync(accountId, pending.request));
    });
    _pendingRequests[accountId] = pending;
  }

  /// Starts syncing every account, watching each inbox with IDLE.
  void start() {
    if (_stop != null) return;
    _stop = Completer<void>();
    _watch();
    _periodic = Timer.periodic(fullSyncInterval, (_) {
      for (final account in _accounts()) {
        if (!_backingOff(account.id)) unawaited(syncAccount(account.id));
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
    for (final account in _accounts()) {
      final running = _runAccount(account, stop.future);
      _watching.add(running);
      unawaited(running.whenComplete(() => _watching.remove(running)));
    }
  }

  /// Whether [accountId]'s server refused a login for having too many
  /// connections a short while ago: background syncs wait then.
  bool _backingOff(AccountId accountId) {
    final refusals = _refusals[accountId];
    return refusals != null && DateTime.now().isBefore(refusals.until);
  }

  /// A quick look at every inbox for new mail.
  void checkInboxes() {
    for (final account in _accounts()) {
      if (_backingOff(account.id)) continue;
      final inbox = _inboxOf(account.id);
      if (inbox != null) requestSync(account.id, mailboxIds: {inbox.id});
    }
  }

  /// The accounts, or none when the store cannot be read just now (it is
  /// read again next time). Timers and IDLE call this: an error thrown
  /// there would end the sync worker.
  List<Account> _accounts() {
    try {
      return _store.accounts.all();
    } on Object {
      return const [];
    }
  }

  StoredMailbox? _inboxOf(AccountId accountId) {
    try {
      return _store.mailboxes.inbox(accountId);
    } on Object {
      return null;
    }
  }

  /// Syncs every account now and opens fresh IDLE connections, for when
  /// the app comes back after a while: the old connections may have died
  /// silently while it was in the background. Nothing while not running.
  void reconnect() {
    if (_stop == null) return;
    final old = _stopWatching;
    if (old != null && !old.isCompleted) old.complete();
    unawaited(_syncConnections.closeAll());
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

  /// Stops watching and waits for running syncs to finish. Syncs waiting
  /// to run, or asked for meanwhile, are dropped (null).
  Future<void> stop() async {
    _stopping = true;
    _periodic?.cancel();
    _inboxChecks?.cancel();
    _inboxChecks = null;
    final watching = _stopWatching;
    _stopWatching = null;
    if (watching != null && !watching.isCompleted) watching.complete();
    for (final pending in _pendingRequests.values) {
      pending.timer.cancel();
    }
    _pendingRequests.clear();
    for (final timer in _scheduled) {
      timer.cancel();
    }
    _scheduled.clear();
    final stop = _stop;
    _stop = null;
    if (stop != null && !stop.isCompleted) stop.complete();
    // Syncs waiting for a connection give up rather than start now.
    connections.cancelWaits();
    for (final syncs in _syncs.values) {
      syncs.waiting?.done.complete(null);
      syncs.waiting = null;
    }
    try {
      await Future.wait([
        for (final syncs in [..._syncs.values]) ?syncs.done,
      ]);
      // IDLE connections are closed when their watchers end.
      await Future.wait([..._watching]);
      await _syncConnections.closeAll();
    } finally {
      _stopping = false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await stop();
    await _onDemand.closeAll();
    await _background.closeAll();
    await connections.close();
    await _events.close();
  }

  /// The full message [messageId], downloaded now if it is not stored
  /// yet. Throws [BodyUnavailableException], or a [MailException] when the
  /// server cannot be reached. [background] downloads (nobody waiting)
  /// use their own connection, so they never hold up one the user opened.
  Future<Uint8List> loadBody(
    MessageId messageId, {
    bool background = false,
  }) async {
    final cached = _store.messages.body(messageId);
    if (cached != null) {
      _loader.findCode(messageId, cached);
      return cached;
    }
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
  Future<void> lookUpFiles(List<MessageId> messageIds) async {
    final byAccount = <AccountId, List<MessageId>>{};
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
  Future<int> fetchOlder(MailboxId mailboxId, {int count = 100}) async {
    final mailbox = _store.mailboxes.byId(mailboxId);
    if (mailbox == null) return 0;
    final account = _store.accounts.byId(mailbox.accountId);
    if (account == null) return 0;
    return _onDemand.run(
      account,
      (imap) => _mailboxSync.fetchOlder(imap, mailbox, count: count),
    );
  }

  /// Searches all of [accountId]'s mail on its server for [text], and
  /// stores the summaries of what it finds ([ServerSearch]). Returns the
  /// stored messages found, newest first, at most
  /// [ServerSearch.maxResults]. Throws a [MailException] when the server
  /// cannot be reached.
  Future<List<MessageId>> searchServer(AccountId accountId, String text) async {
    final account = _store.accounts.byId(accountId);
    if (account == null) return const [];
    return _onDemand.run(
      account,
      (imap) => ServerSearch(_store, _mailboxSync).search(imap, account, text),
    );
  }

  /// Syncs [accountId] at [at] (when a delayed send becomes due), so the
  /// message goes out then rather than at the next periodic sync.
  void syncAt(AccountId accountId, DateTime at) {
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
  Future<MailboxId> createFolder(AccountId accountId, String name) async {
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

  /// Closes the connections of an account (after it was removed or its
  /// settings changed): kept ones now, those in use when they are done.
  Future<void> accountChanged(AccountId accountId) async {
    await _onDemand.close(accountId);
    await _background.close(accountId);
    await _syncConnections.close(accountId);
    await connections.forget(accountId);
    _refusals.remove(accountId);
  }

  /// After accounts were added, removed or changed: [accountChanged] for
  /// each, also those no longer there.
  Future<void> accountsChanged() async {
    final ids = {
      for (final account in _store.accounts.all()) account.id,
      ...connections.accountIds,
    };
    for (final id in ids) {
      await accountChanged(id);
    }
  }

  Account _accountOfMessage(MessageId messageId) {
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
    final inbox = _inboxOf(account.id);
    if (inbox == null) return;
    await IdleWatcher(_connector, budget: connections).watch(
      account,
      inbox,
      stop: stop,
      onChange: () => requestSync(account.id, mailboxIds: {inbox.id}),
      onFailure: (failure) =>
          _events.add(AccountSyncFailed(account.id, failure)),
    );
  }
}

/// What a sync covers: every folder ([full], plus [mailboxIds] that a full
/// sync leaves out, such as Gmail's Starred), or only [mailboxIds].
final class _SyncRequest {
  _SyncRequest(Set<MailboxId>? mailboxIds)
    : full = mailboxIds == null,
      mailboxIds = {...?mailboxIds};

  _SyncRequest._(this.full, this.mailboxIds);

  final bool full;
  final Set<MailboxId> mailboxIds;

  /// One sync that covers both.
  _SyncRequest join(_SyncRequest other) =>
      _SyncRequest._(full || other.full, {...mailboxIds, ...other.mailboxIds});
}

/// An account's syncs: the one running (until [done]) and the next.
final class _AccountSyncs {
  Future<void>? done;
  _WaitingSync? waiting;
}

final class _WaitingSync {
  _WaitingSync(this.request);

  _SyncRequest request;
  final done = Completer<AccountSyncReport?>();
}

/// A [SyncEngine.requestSync] waiting for its delay.
final class _PendingRequest {
  _PendingRequest(this.request);

  _SyncRequest request;
  late final Timer timer;
}
