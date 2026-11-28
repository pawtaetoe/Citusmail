// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'connection_budget.dart';
import 'connector.dart';

/// The IMAP connections syncs use, counted in the account's
/// [ConnectionBudget]. One is kept between syncs: the inbox check every
/// minute and the full sync every few minutes reuse a logged-in
/// connection instead of opening a new one (TLS and login each time).
/// The extra connections of a full sync are closed when it is done.
///
/// A kept connection unused for [idleTimeout] is logged out. One that sat
/// unused for more than [checkAfter] is asked a NOOP before it is handed
/// out again, so a connection the network dropped silently is replaced
/// before a sync starts on it, never in the middle of one.
final class SyncConnections {
  SyncConnections(
    MailConnector connector, {
    this.idleTimeout = const Duration(minutes: 6),
    this.checkAfter = const Duration(seconds: 20),
    ConnectionBudget? budget,
  }) : budget = budget ?? ConnectionBudget(connector);

  /// Connections that are never kept: each sync opens and closes its own.
  SyncConnections.unpooled(MailConnector connector, {ConnectionBudget? budget})
    : idleTimeout = Duration.zero,
      checkAfter = Duration.zero,
      budget = budget ?? ConnectionBudget(connector);

  /// The account's budget, shared with the engine's other connections.
  final ConnectionBudget budget;

  /// How long the unused connection is kept. Longer than the full sync
  /// interval, so the next full sync reuses it too.
  final Duration idleTimeout;

  /// After how long unused a connection is checked before reuse.
  final Duration checkAfter;

  /// A logged-in connection for [account]: the kept one if it still
  /// answers, else a new one, waiting for room in the budget. Give it
  /// back with [give] when done.
  Future<ImapClient> take(Account account) => budget.take(account, owner: this);

  /// One more connection for a full sync, only if the budget has room
  /// now (null otherwise: the sync goes on with the ones it has).
  Future<ImapClient?> takeExtra(Account account) =>
      budget.takeIfFree(account, owner: this);

  /// Whether the user's work waits for a connection of [accountId]: a
  /// sync then hands its connection over between folders.
  bool userWaiting(AccountId accountId) => budget.userWaiting(accountId);

  /// Whether a connection of [accountId] is wanted elsewhere, or it has
  /// more open than its budget allows: an extra connection stops.
  bool contended(AccountId accountId) => budget.contended(accountId);

  /// Gives [client] of [account] back after a sync: kept for the next
  /// one unless [keep] is false, a connection is kept already, or someone
  /// waits for it. A connection that broke is closed.
  Future<void> give(Account account, ImapClient client, {bool keep = true}) =>
      budget.give(
        account,
        client,
        owner: this,
        keepFor: keep ? idleTimeout : Duration.zero,
        checkAfter: checkAfter,
      );

  /// Closes the kept connection of one account (removed, its settings
  /// changed, or the app came back and it may have died).
  Future<void> close(AccountId accountId) =>
      budget.closeKept(accountId, owner: this);

  Future<void> closeAll() => budget.closeAllKept(owner: this);
}
