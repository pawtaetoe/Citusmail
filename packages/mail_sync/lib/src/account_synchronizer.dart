// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:collection';
import 'dart:math';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'app_data/app_data_sync.dart';
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
    required Map<int, MailboxSyncResult> mailboxes,
    this.movedByRules = 0,
    this.receipts = 0,
    this.appData,
    this.appDataFailure,
    this.serverRules,
  }) : mailboxes = Map.unmodifiable(mailboxes);

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
  final Map<int, MailboxSyncResult> mailboxes;
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
       _now = now ?? DateTime.now;

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

  /// How often the folder list is read again. Folders are rarely added
  /// or removed, and one that disappears in between is noticed when it
  /// can no longer be opened.
  final Duration listInterval;

  /// When each account's folders were last listed.
  final _listedAt = <int, DateTime>{};

  /// Syncs [account]. With [mailboxIds], only those folders are synced
  /// (the folder list and the queue are always handled). Without, every
  /// folder except views like Gmail's Starred and Important
  /// ([StoredMailbox.isView]), which are synced when opened.
  Future<AccountSyncReport> sync(
    Account account, {
    Set<int>? mailboxIds,
  }) async {
    final imap = await _connections.take(account);
    try {
      final listed = await _listFolders(account, imap);
      final replay = await _replayer.replay(
        imap,
        account,
        smtp: () => _connector.smtp(account),
      );

      final results = await _syncFolders(
        account,
        imap,
        foldersToSync(_store.mailboxes.forAccount(account.id), mailboxIds),
        full: mailboxIds == null,
        listed: listed,
      );
      // 4. Blocked senders, then the user's folder rules, then screened-out
      // senders (when they go to Archive), on new inbox mail; their moves
      // go to the server right away, in this session.
      var movedByRules = 0;
      final inbox = _store.mailboxes.inbox(account.id);
      if (inbox != null && results.containsKey(inbox.id)) {
        movedByRules =
            (_blocker?.apply(account) ?? 0) +
            (_rules?.apply(account) ?? 0) +
            (_screener?.apply(account) ?? 0);
        if (movedByRules > 0) {
          await _replayer.replay(
            imap,
            account,
            smtp: () => _connector.smtp(account),
          );
        }
      }
      // 5. Read receipts that arrived for the user's sent mail.
      // Optional: a problem here is retried next time, never fatal.
      var receipts = 0;
      if (inbox != null && results.containsKey(inbox.id)) {
        try {
          receipts = await ReceiptCollector(_store).collect(imap, account);
        } on MailException {
          receipts = 0;
        }
        // Codes in new verification mail, for the list. Also optional.
        try {
          await CodeReader(_store).read(imap, account);
        } on MailException {
          // Read again next time.
        }
      }

      // 6. App data with the user's other devices. Its problems never
      // fail the mail sync.
      AppDataSyncReport? appData;
      SyncFailure? appDataFailure;
      if (_appData case final sync?) {
        try {
          appData = await sync.run(imap, account);
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
      );
    } on Object {
      // List again next time, in case a folder changed.
      _listedAt.remove(account.id);
      rethrow;
    } finally {
      await _connections.give(account, imap);
    }
  }

  /// Reads the folder list when it is older than [listInterval] (or there
  /// is none yet), or when [force]d. Returns whether it did.
  Future<bool> _listFolders(
    Account account,
    ImapClient imap, {
    bool force = false,
  }) async {
    final now = _now();
    final last = _listedAt[account.id];
    if (!force &&
        last != null &&
        now.difference(last) < listInterval &&
        _store.mailboxes.forAccount(account.id).isNotEmpty) {
      return false;
    }
    _store.mailboxes.replaceAll(account.id, await imap.listMailboxes());
    _listedAt[account.id] = now;
    return true;
  }

  /// Syncs [folders], the inbox first, over [imap] and up to
  /// [SyncSettings.connections] - 1 more connections, each taking the next
  /// folder when it is done with one. A connection the server refuses is
  /// simply not used. After a folder fails, no new one is started and the
  /// first failure is thrown once the others are done.
  ///
  /// When the folder list was not [listed] in this sync, a folder the
  /// server refuses to open may have been deleted elsewhere: the list is
  /// read again, and a folder that is gone is no failure.
  Future<Map<int, MailboxSyncResult>> _syncFolders(
    Account account,
    ImapClient imap,
    Iterable<StoredMailbox> folders, {
    required bool full,
    required bool listed,
  }) async {
    final queue = Queue.of(
      [...folders]..sort((a, b) => (b.isInbox ? 1 : 0) - (a.isInbox ? 1 : 0)),
    );
    final results = <int, MailboxSyncResult>{};
    (Object, StackTrace)? failure;
    final refused = <StoredMailbox, (Object, StackTrace)>{};

    Future<void> work(ImapClient client, MailboxSynchronizer sync) async {
      while (queue.isNotEmpty && failure == null) {
        final mailbox = queue.removeFirst();
        try {
          results[mailbox.id] = await sync.sync(
            client,
            mailbox,
            pendingUids: pendingUids(account.id, mailbox.id),
            // Without change tracking on the server, comparing every
            // message's flags waits for the full sync: the frequent
            // inbox check only looks for new and removed mail.
            refreshFlags: full || !mailbox.isInbox,
          );
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
      final ImapClient client;
      try {
        client = await _connections.take(account);
      } on Object {
        return; // Too many connections, or offline: the others go on.
      }
      try {
        await work(client, _mailboxSync.another());
      } finally {
        await _connections.give(account, client);
      }
    }

    final extras = min(_mailboxSync.settings.connections - 1, queue.length - 1);
    await Future.wait([
      work(imap, _mailboxSync),
      for (var i = 0; i < extras; i++) extra(),
    ]);
    if (failure case (final e, final s)) Error.throwWithStackTrace(e, s);
    if (refused.isNotEmpty) {
      await _listFolders(account, imap, force: true);
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

  /// Which of [mailboxes] a sync covers: with [mailboxIds], those;
  /// without, all but views like Gmail's Starred and Important
  /// ([StoredMailbox.isView]). Never folders that can't be opened, nor the
  /// app's own sync data folder.
  static Iterable<StoredMailbox> foldersToSync(
    Iterable<StoredMailbox> mailboxes,
    Set<int>? mailboxIds,
  ) => mailboxes.where(
    (m) =>
        m.selectable &&
        !m.isAppData &&
        (mailboxIds == null ? !m.isView : mailboxIds.contains(m.id)),
  );

  /// UIDs in [mailboxId] with local changes still queued.
  Set<int> pendingUids(int accountId, int mailboxId) {
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
