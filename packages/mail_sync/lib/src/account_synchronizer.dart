// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'app_data/app_data_sync.dart';
import 'connector.dart';
import 'folder_rules.dart';
import 'mailbox_synchronizer.dart';
import 'outbox_replayer.dart';
import 'sender_blocker.dart';
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
    this.appData,
    this.appDataFailure,
  }) : mailboxes = Map.unmodifiable(mailboxes);

  final ReplayResult replay;

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
/// 1. refresh the folder list;
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
    this._appData,
  });

  final MailStore _store;
  final MailConnector _connector;
  final MailboxSynchronizer _mailboxSync;
  final OutboxReplayer _replayer;
  final FolderRuleApplier? _rules;
  final SenderBlocker? _blocker;
  final AppDataSync? _appData;

  /// Syncs [account]. With [mailboxIds], only those folders are synced
  /// (the folder list and the queue are always handled).
  Future<AccountSyncReport> sync(
    Account account, {
    Set<int>? mailboxIds,
  }) async {
    final imap = await _connector.imap(account);
    try {
      _store.mailboxes.replaceAll(account.id, await imap.listMailboxes());
      final replay = await _replayer.replay(
        imap,
        account,
        smtp: () => _connector.smtp(account),
      );

      final results = <int, MailboxSyncResult>{};
      for (final mailbox in _store.mailboxes.forAccount(account.id)) {
        // The sync data folder holds the app's own data, not mail.
        if (!mailbox.selectable || mailbox.isAppData) continue;
        if (mailboxIds != null && !mailboxIds.contains(mailbox.id)) continue;
        results[mailbox.id] = await _mailboxSync.sync(
          imap,
          mailbox,
          pendingUids: pendingUids(account.id, mailbox.id),
        );
      }
      // 4. Blocked senders, then the user's folder rules, on new inbox
      // mail; their moves go to the server right away, in this session.
      var movedByRules = 0;
      final inbox = _store.mailboxes.inbox(account.id);
      if (inbox != null && results.containsKey(inbox.id)) {
        movedByRules =
            (_blocker?.apply(account) ?? 0) + (_rules?.apply(account) ?? 0);
        if (movedByRules > 0) {
          await _replayer.replay(
            imap,
            account,
            smtp: () => _connector.smtp(account),
          );
        }
      }
      // 5. App data with the user's other devices. Its problems never
      // fail the mail sync.
      AppDataSyncReport? appData;
      SyncFailure? appDataFailure;
      if (_appData case final sync?) {
        try {
          appData = await sync.run(imap, account);
        } on Object catch (e) {
          appDataFailure = SyncFailure.from(e);
        }
      }
      return AccountSyncReport(
        replay: replay,
        mailboxes: results,
        movedByRules: movedByRules,
        appData: appData,
        appDataFailure: appDataFailure,
      );
    } finally {
      await imap.logout();
    }
  }

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
