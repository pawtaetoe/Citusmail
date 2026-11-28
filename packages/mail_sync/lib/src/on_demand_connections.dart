// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'connection_budget.dart';
import 'connector.dart';

/// IMAP connections for work done on demand (opening a message, loading
/// older mail, reading ahead), counted in the account's
/// [ConnectionBudget]: each piece of work takes one with its priority
/// ([priority] unless it says otherwise), so the user's most urgent work
/// goes first, and gives it back when done. One is kept for a short
/// while so opening several messages in a row does not log in each time,
/// and closed when idle. Each piece has its connection to itself, so a
/// folder selected by one is never changed under another.
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

  /// Where this work queues for a connection when the budget is full,
  /// unless a piece of work says otherwise.
  final ConnectionPriority priority;

  /// Waits before trying again after a login refused for now.
  final List<Duration> retryDelays;

  /// The work under way, per account.
  final _running = <AccountId, Set<Future<void>>>{};

  /// Runs [action] with a logged-in connection for [account], taken with
  /// [priority] (this one's by default). A connection the server dropped
  /// while idle is replaced once, transparently.
  Future<T> run<T>(
    Account account,
    Future<T> Function(ImapClient imap) action, {
    ConnectionPriority? priority,
  }) {
    final result = () async {
      for (var refused = 0; ; refused++) {
        try {
          return await _once(account, action, priority ?? this.priority);
        } on ImapAuthenticationException catch (e) {
          if (!e.temporary || refused >= retryDelays.length) rethrow;
          await Future<void>.delayed(retryDelays[refused]);
        }
      }
    }();
    final running = _running.putIfAbsent(account.id, () => {});
    final done = result.then<void>((_) {}, onError: (Object _) {});
    running.add(done);
    unawaited(done.whenComplete(() => running.remove(done)));
    return result;
  }

  Future<T> _once<T>(
    Account account,
    Future<T> Function(ImapClient imap) action,
    ConnectionPriority priority,
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
  /// its password changed), once the work under way is done.
  Future<void> close(AccountId accountId) async {
    await Future.wait([...?_running.remove(accountId)]);
    await budget.closeKept(accountId, owner: this);
  }

  Future<void> closeAll() async {
    for (final id in {..._running.keys, ...budget.accountIds}) {
      await close(id);
    }
  }
}
