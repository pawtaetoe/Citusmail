// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:collection';
import 'dart:math';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'app_data/app_data_sync.dart';
import 'archived_backfill.dart';
import 'archived_mail.dart';
import 'code_reader.dart';
import 'connector.dart';
import 'folder_rules.dart';
import 'mailbox_synchronizer.dart';
import 'outbox_replayer.dart';
import 'receipt_collector.dart';
import 'screener_archiver.dart';
import 'sender_blocker.dart';
import 'server_rules.dart';
import 'sync_connections.dart';
import 'sync_lease.dart';
import 'sync_worker.dart';

/// Why a sync could not finish, in terms the app can act on.
enum SyncFailureKind {
  /// Wrong password or login refused: ask the user, do not retry blindly.
  authentication,

  /// TLS or certificate problem: show it, do not retry blindly.
  security,

  /// Offline, timeout, server unreachable: retry with backoff.
  network,

  /// The server misbehaved: retry later.
  server,
}

/// A sync that could not finish.
final class SyncFailure {
  const SyncFailure(this.kind, this.message);

  final SyncFailureKind kind;

  /// Safe to show: no credentials or mail content.
  final String message;

  static SyncFailure from(Object error) => switch (error) {
    SyncWorkerException(:final failure) => failure,
    // Refused for now (busy, too many connections): not the password.
    ImapAuthenticationException(temporary: true, :final message) => SyncFailure(
      SyncFailureKind.server,
      message,
    ),
    ImapAuthenticationException() ||
    SmtpAuthenticationException() => SyncFailure(
      SyncFailureKind.authentication,
      (error as MailException).message,
    ),
    MailTlsException() || MailSecurityException() => SyncFailure(
      SyncFailureKind.security,
      (error as MailException).message,
    ),
    MailConnectionException() || MailTimeoutException() => SyncFailure(
      SyncFailureKind.network,
      (error as MailException).message,
    ),
    MailException(:final message) => SyncFailure(
      SyncFailureKind.server,
      message,
    ),
    _ => SyncFailure(SyncFailureKind.server, error.toString()),
  };
}

/// The outcome of one account sync.
final class AccountSyncReport {
  AccountSyncReport({
    required this.replay,
    required Map<MailboxId, MailboxSyncResult> mailboxes,
    this.movedByRules = 0,
    this.receipts = 0,
    this.appData,
    this.appDataFailure,
    this.serverRules,
    this.archived,
  }) : mailboxes = Map.unmodifiable(mailboxes);

  /// Gmail's archived mail filled in on this full sync
  /// ([ArchivedBackfill]); null on other servers' syncs and inbox checks.
  final ArchivedBackfillResult? archived;

  /// Where the server rules stand, when they are turned on.
  final ServerRulesStatus? serverRules;

  final ReplayResult replay;

  /// Read receipts recorded for the user's sent mail.
  final int receipts;

  /// The exchange of app data with the user's other devices, when this is
  /// the sync account and sync is on.
  final AppDataSyncReport? appData;

  /// Why that exchange failed (mail sync itself still completed).
  final SyncFailure? appDataFailure;

  /// Inbox messages moved by blocks (to Junk) and the user's folder rules.
  final int movedByRules;

  /// Result per mailbox id.
  final Map<MailboxId, MailboxSyncResult> mailboxes;
}

/// One full sync of an account, in a fixed order:
///
/// 1. refresh the folder list (at most every [listInterval]);
/// 2. replay queued local actions (so the server has the user's changes);
/// 3. sync each folder (so the cache has everyone else's changes),
///    without overwriting changes still waiting in the queue.
final class AccountSynchronizer {
  AccountSynchronizer(
    this._store,
    this._connector,
    this._mailboxSync,
    this._replayer, {
    this._rules,
    this._blocker,
    this._screener,
    this._appData,
    this._serverRules,
    SyncConnections? connections,
    this.listInterval = const Duration(minutes: 15),
    DateTime Function()? now,
  }) : _connections = connections ?? SyncConnections.unpooled(_connector),
       _now = now ?? DateTime.now,
       _archived = ArchivedMail(_store, _mailboxSync),
       _archivedFill = ArchivedBackfill(_store, _mailboxSync, now: now);

  final MailStore _store;
  final MailConnector _connector;
  final MailboxSynchronizer _mailboxSync;
  final OutboxReplayer _replayer;
  final FolderRuleApplier? _rules;
  final SenderBlocker? _blocker;
  final ScreenerArchiver? _screener;
  final AppDataSync? _appData;
  final ServerRules? _serverRules;
  final SyncConnections _connections;
  final DateTime Function() _now;
  final ArchivedMail _archived;
  final ArchivedBackfill _archivedFill;

  /// How often the folder list is read again. Folders are rarely added
  /// or removed, and one that disappears in between is noticed when it
  /// can no longer be opened.
  final Duration listInterval;

  /// When each account's folders were last listed.
  final _listedAt = <AccountId, DateTime>{};

  /// Syncs [account]. With [mailboxIds], only those folders are synced
  /// (the folder list and the queue are always handled). Without, every
  /// folder except views like Gmail's Starred and Important
  /// ([StoredMailbox.isView]), which are synced when opened, unless they
  /// are in [alsoMailboxIds].
  ///
  /// Its connection goes to the user's work waiting for one between
  /// folders, between the steps after them, and inside every long step
  /// between two batches ([SyncLease]); see docs/architecture.md,
  /// "Connections".
  Future<AccountSyncReport> sync(
    Account account, {
    Set<MailboxId>? mailboxIds,
    Set<MailboxId> alsoMailboxIds = const {},
  }) async {
    // The connection can change hands (to the user's work waiting for
    // one), so it is read from the lease each time.
    final lease = _Lease(
      _connections,
      account,
      await _connections.take(account),
    );
    try {
      // On the full sync, each folder's counters too (one command, on a
      // server with LIST-STATUS): folders they show unchanged are not
      // opened.
      final (:listed, :status) = await _listFolders(
        account,
        lease.client,
        withStatus: mailboxIds == null,
      );
      final replay = await _replayer.replay(
        lease.client,
        account,
        smtp: () => _connector.smtp(account),
        lease: lease,
      );

      final results = await _syncFolders(
        account,
        lease,
        foldersToSync(
          _store.mailboxes.forAccount(account.id),
          mailboxIds,
          also: alsoMailboxIds,
        ),
        full: mailboxIds == null,
        listed: listed,
        status: status,
      );
      // 4. Blocked senders, then the user's folder rules, then screened-out
      // senders (when they go to Archive), on new inbox mail; their moves
      // go to the server right away, in this session.
      // Each looks only at mail that arrived since its last pass, unless
      // older mail was just downloaded.
      var movedByRules = 0;
      final inbox = _store.mailboxes.inbox(account.id);
      if (results[inbox?.id] case final result? when inbox != null) {
        final everything = result.backfilled > 0;
        movedByRules =
            (_blocker?.apply(account, everything: everything) ?? 0) +
            (_rules?.apply(account, everything: everything) ?? 0) +
            (_screener?.apply(account, everything: everything) ?? 0);
        if (movedByRules > 0) {
          await _replayer.replay(
            await _step(lease),
            account,
            smtp: () => _connector.smtp(account),
            lease: lease,
          );
        }
      }
      // 5. Read receipts that arrived for the user's sent mail.
      // Optional: a problem here is retried next time, never fatal.
      var receipts = 0;
      if (inbox != null && results.containsKey(inbox.id)) {
        try {
          receipts = await ReceiptCollector(_store)
              .collect(await _step(lease), account, lease: lease);
        } on MailException {
          receipts = 0;
        }
        // Codes in new verification mail, for the list. Also optional.
        try {
          await CodeReader(_store)
              .read(await _step(lease), account, lease: lease);
        } on MailException {
          // Read again next time.
        }
      }

      // Mail archived elsewhere, on the full sync (Gmail's All Mail is
      // not synced in the background). Optional, like the above.
      _archived.note(account, results);
      ArchivedBackfillResult? archived;
      if (mailboxIds == null) {
        try {
          await _archived.find(await _step(lease), account, lease: lease);
        } on MailException {
          // Looked up again next time.
        }
        // On Gmail, archived mail this device never saw in another folder
        // (it was archived before the device was added), a batch a sync;
        // and the flags of what All Mail has on the device.
        try {
          final allMail = _store.mailboxes.bySpecialUse(
            account.id,
            SpecialUse.all,
          );
          archived = await _archivedFill.run(
            await _step(lease),
            account,
            pendingUids: allMail == null
                ? const {}
                : pendingUids(account.id, allMail.id),
            lease: lease,
          );
        } on MailException {
          // Goes on next time, where it stopped.
        }
      }

      // 6. App data with the user's other devices, on the full sync only
      // (not the frequent inbox check). Its problems never fail the mail
      // sync.
      AppDataSyncReport? appData;
      SyncFailure? appDataFailure;
      if (_appData case final sync? when mailboxIds == null) {
        try {
          appData = await sync.run(await _step(lease), account);
        } on Object catch (e) {
          appDataFailure = SyncFailure.from(e);
          sync.recordProblem(appDataFailure.message);
        }
      }
      // 7. The rules on the mail server, when turned on. Never fatal.
      ServerRulesStatus? serverRules;
      if (_serverRules case final rules?) {
        try {
          serverRules = await rules.run(account);
        } on Object {
          serverRules = null;
        }
      }
      return AccountSyncReport(
        replay: replay,
        mailboxes: results,
        movedByRules: movedByRules,
        receipts: receipts,
        appData: appData,
        appDataFailure: appDataFailure,
        serverRules: serverRules,
        archived: archived,
      );
    } on Object {
      // List again next time, in case a folder changed.
      _listedAt.remove(account.id);
      rethrow;
    } finally {
      if (lease.held case final client?) {
        await _connections.give(account, client);
      }
    }
  }

  /// Makes the next sync of [accountId] read the folder list, however
  /// recently it was read (a folder was just added on the server).
  void listFoldersNextTime(AccountId accountId) => _listedAt.remove(accountId);

  /// Reads the folder list when it is older than [listInterval] (or there
  /// is none yet), or when [force]d. Returns whether it did; and [withStatus]
  /// on a server with LIST-STATUS, each folder's counters (by encoded
  /// name), read in the same command, which then also reads the list.
  Future<({bool listed, Map<String, MailboxStatus> status})> _listFolders(
    Account account,
    ImapClient imap, {
    bool force = false,
    bool withStatus = false,
  }) async {
    final now = _now();
    final last = _listedAt[account.id];
    final due =
        force ||
        last == null ||
        now.difference(last) >= listInterval ||
        _store.mailboxes.forAccount(account.id).isEmpty;
    if (withStatus) {
      final both = await imap.listMailboxesWithStatus(
        highestModSeq: imap.capabilities.has('CONDSTORE'),
      );
      if (both != null) {
        if (due) {
          _store.mailboxes.replaceAll(account.id, both.mailboxes);
          _listedAt[account.id] = now;
        }
        return (listed: due, status: both.status);
      }
    }
    if (!due) return (listed: false, status: const <String, MailboxStatus>{});
    _store.mailboxes.replaceAll(account.id, await imap.listMailboxes());
    _listedAt[account.id] = now;
    return (listed: true, status: const <String, MailboxStatus>{});
  }

  /// Syncs [folders], the inbox first, over the [main] connection and up
  /// to [SyncSettings.connections] - 1 more, as many as the account's
  /// connection budget has room for, each taking the next folder when it
  /// is done with one. A connection the server refuses is simply not
  /// used. After a folder fails, no new one is started and the first
  /// failure is thrown once the others are done.
  ///
  /// Between folders, an extra connection stops when another piece of
  /// work waits for one (it is handed over) or the budget was lowered.
  /// The main one is handed to the user's work waiting for a connection
  /// between folders and inside them, between two batches
  /// ([MailboxSynchronizer.sync] with a lease), and taken back after it.
  ///
  /// When the folder list was not [listed] in this sync, a folder the
  /// server refuses to open may have been deleted elsewhere: the list is
  /// read again, and a folder that is gone is no failure.
  Future<Map<MailboxId, MailboxSyncResult>> _syncFolders(
    Account account,
    _Lease main,
    Iterable<StoredMailbox> folders, {
    required bool full,
    required bool listed,
    Map<String, MailboxStatus> status = const {},
  }) async {
    final results = <MailboxId, MailboxSyncResult>{};
    final changed = <StoredMailbox>[];
    for (final mailbox in folders) {
      if (status[mailbox.encodedName] case final counters?
          when _mailboxSync.unchanged(mailbox, counters)) {
        results[mailbox.id] = const MailboxSyncResult(
          method: SyncMethod.unchanged,
        );
      } else {
        changed.add(mailbox);
      }
    }
    final queue = Queue.of(
      changed..sort((a, b) => (b.isInbox ? 1 : 0) - (a.isInbox ? 1 : 0)),
    );
    (Object, StackTrace)? failure;
    final refused = <StoredMailbox, (Object, StackTrace)>{};

    Future<void> work(_Lease lease, MailboxSynchronizer sync) async {
      while (queue.isNotEmpty && failure == null) {
        if (lease != main && _connections.contended(account.id)) return;
        await lease.handOverIfWanted();
        final mailbox = queue.removeFirst();
        try {
          results[mailbox.id] = await sync.sync(
            lease.client,
            mailbox,
            pendingUids: pendingUids(account.id, mailbox.id),
            // Without change tracking on the server, comparing every
            // message's flags waits for the full sync: the frequent
            // inbox check only looks for new and removed mail.
            refreshFlags: full || !mailbox.isInbox,
            lease: lease,
          );
          lease.advanced();
        } on Object catch (e, s) {
          if (e is ImapCommandException && !listed) {
            refused[mailbox] = (e, s);
            continue;
          }
          failure ??= (e, s);
        }
      }
    }

    Future<void> extra() async {
      final ImapClient? client;
      try {
        client = await _connections.takeExtra(account);
      } on Object {
        return; // Too many connections, or offline: the others go on.
      }
      if (client == null) return; // No room in the budget.
      try {
        // It never hands over: it stops between folders instead.
        await work(
          _Lease(_connections, account, client, handsOver: false),
          _mailboxSync.another(),
        );
      } finally {
        // Not kept: one connection per account waits for the next sync.
        await _connections.give(account, client, keep: false);
      }
    }

    final extras = min(_mailboxSync.settings.connections - 1, queue.length - 1);
    await Future.wait([
      work(main, _mailboxSync),
      for (var i = 0; i < extras; i++) extra(),
    ]);
    if (failure case (final e, final s)) Error.throwWithStackTrace(e, s);
    if (refused.isNotEmpty) {
      await _listFolders(account, main.client, force: true);
      final names = {
        for (final m in _store.mailboxes.forAccount(account.id)) m.encodedName,
      };
      for (final MapEntry(key: mailbox, value: (e, s)) in refused.entries) {
        if (names.contains(mailbox.encodedName)) {
          Error.throwWithStackTrace(e, s);
        }
      }
    }
    return results;
  }

  /// Before the next step: the one before it is done, so [lease]'s
  /// connection may go to the user's work waiting for one. Returns the
  /// connection to work on.
  static Future<ImapClient> _step(_Lease lease) async {
    lease.advanced();
    await lease.handOverIfWanted();
    return lease.client;
  }

  /// Which of [mailboxes] a sync covers: with [mailboxIds], those;
  /// without, all but views like Gmail's Starred and Important
  /// ([StoredMailbox.isView]). Never folders that can't be opened, nor the
  /// app's own sync data folder.
  static Iterable<StoredMailbox> foldersToSync(
    Iterable<StoredMailbox> mailboxes,
    Set<MailboxId>? mailboxIds, {
    Set<MailboxId> also = const {},
  }) => mailboxes.where(
    (m) =>
        m.selectable &&
        !m.isAppData &&
        (mailboxIds == null
            ? !m.isView || also.contains(m.id)
            : mailboxIds.contains(m.id)),
  );

  /// UIDs in [mailboxId] with local changes still queued.
  Set<int> pendingUids(AccountId accountId, MailboxId mailboxId) {
    final uids = <int>{};
    for (final entry in _store.outbox.all(accountId)) {
      final action = entry.action;
      if (entry.state == OutboxState.pending &&
          action is UidAction &&
          action.mailboxId == mailboxId) {
        uids.addAll(action.uids);
      }
    }
    return uids;
  }
}

/// The connection a sync works on. The main one goes to the user's work
/// waiting for one, at most once per batch of the sync's own work, and
/// comes back after a bounded wait ([ConnectionBudget.handBackAfter],
/// [ConnectionBudget.handBackWithin]): the sync always moves on.
final class _Lease extends SyncLease {
  _Lease(this._connections, this._account, this.held, {this.handsOver = true});

  final SyncConnections _connections;
  final Account _account;

  /// Whether it goes to the user's work waiting for a connection (the
  /// main connection; extra ones stop between folders instead).
  final bool handsOver;

  /// Null while it is handed over.
  ImapClient? held;

  /// Whether a batch was done since the last hand-over.
  bool _advanced = true;

  @override
  ImapClient get client => held!;

  @override
  void advanced() => _advanced = true;

  @override
  Future<bool> handOverIfWanted() async {
    if (!handsOver || !_advanced || !_connections.userWaiting(_account.id)) {
      return false;
    }
    final client = held!;
    held = null;
    _advanced = false;
    await _connections.give(_account, client, keep: false);
    held = await _connections.takeBack(_account);
    return true;
  }
}
