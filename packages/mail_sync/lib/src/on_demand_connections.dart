// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'connection_budget.dart';
import 'connector.dart';

/// One IMAP connection per account for work the user is waiting for
/// (opening a message, loading older mail), counted in the account's
/// [ConnectionBudget] with [priority]. It is kept for a short while so
/// opening several messages in a row does not log in each time, and
/// closed when idle. Work on one account runs one piece at a time, so a
/// folder selected by one request is never changed under another.
///
/// A login the server refuses for now (too many connections) is tried
/// again after each of [retryDelays], so the user sees the message rather
/// than an error; the budget has closed what it could meanwhile.
final class OnDemandConnections {
  OnDemandConnections(
    MailConnector connector, {
    this.idleTimeout = const Duration(minutes: 2),
    this.priority = ConnectionPriority.user,
    this.retryDelays = const [Duration(seconds: 2), Duration(seconds: 5)],
    ConnectionBudget? budget,
  }) : budget = budget ?? ConnectionBudget(connector);

  /// The account's budget, shared with the engine's other connections.
  final ConnectionBudget budget;
  final Duration idleTimeout;

  /// Where this work queues for a connection when the budget is full.
  final ConnectionPriority priority;

  /// Waits before trying again after a login refused for now.
  final List<Duration> retryDelays;

  final _tails = <AccountId, Future<void>>{};

  /// Runs [action] with a logged-in connection for [account]. A connection
  /// the server dropped while idle is replaced once, transparently.
  Future<T> run<T>(
    Account account,
    Future<T> Function(ImapClient imap) action,
  ) {
    final tail = _tails[account.id] ?? Future.value();
    final result = tail.then((_) async {
      for (var refused = 0; ; refused++) {
        try {
          return await _once(account, action);
        } on ImapAuthenticationException catch (e) {
          if (!e.temporary || refused >= retryDelays.length) rethrow;
          await Future<void>.delayed(retryDelays[refused]);
        }
      }
    });
    _tails[account.id] = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<T> _once<T>(
    Account account,
    Future<T> Function(ImapClient imap) action,
  ) async {
    for (var attempt = 0; ; attempt++) {
      final imap = await budget.take(account, owner: this, priority: priority);
      final T result;
      try {
        result = await action(imap);
      } on MailConnectionException {
        await budget.discard(account, imap);
        if (attempt > 0) rethrow;
        continue;
      } on MailTimeoutException {
        await budget.discard(account, imap);
        rethrow;
      } on Object {
        await _giveBack(account, imap);
        rethrow;
      }
      await _giveBack(account, imap);
      return result;
    }
  }

  Future<void> _giveBack(Account account, ImapClient imap) =>
      budget.give(account, imap, owner: this, keepFor: idleTimeout);

  /// Closes the connection of one account (e.g. after it was removed or
  /// its password changed).
  Future<void> close(AccountId accountId) async {
    final tail = _tails.remove(accountId);
    if (tail != null) await tail;
    await budget.closeKept(accountId, owner: this);
  }

  Future<void> closeAll() async {
    for (final id in {..._tails.keys, ...budget.accountIds}) {
      await close(id);
    }
  }
}
