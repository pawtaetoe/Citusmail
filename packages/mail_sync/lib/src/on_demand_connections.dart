// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'connector.dart';

/// One IMAP connection per account for work the user is waiting for
/// (opening a message, loading older mail). It is kept for a short while
/// so opening several messages in a row does not log in each time, and
/// closed when idle. Work on one account runs one piece at a time, so a
/// folder selected by one request is never changed under another.
final class OnDemandConnections {
  OnDemandConnections(
    this._connector, {
    this.idleTimeout = const Duration(minutes: 2),
  });

  final MailConnector _connector;
  final Duration idleTimeout;
  final _sessions = <int, _Session>{};

  /// Runs [action] with a logged-in connection for [account]. A connection
  /// the server dropped while idle is replaced once, transparently.
  Future<T> run<T>(
    Account account,
    Future<T> Function(ImapClient imap) action,
  ) {
    final session = _sessions.putIfAbsent(account.id, _Session.new);
    final result = session.tail.then((_) async {
      session.idle?.cancel();
      try {
        for (var attempt = 0; ; attempt++) {
          final imap = await session.connect(() => _connector.imap(account));
          try {
            return await action(imap);
          } on MailConnectionException {
            await session.close();
            if (attempt > 0) rethrow;
          } on MailTimeoutException {
            await session.close();
            rethrow;
          }
        }
      } finally {
        session.idle = Timer(idleTimeout, () => unawaited(session.close()));
      }
    });
    session.tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Closes the connection of one account (e.g. after it was removed or
  /// its password changed).
  Future<void> close(int accountId) async {
    final session = _sessions.remove(accountId);
    if (session == null) return;
    await session.tail;
    await session.close();
  }

  Future<void> closeAll() async {
    for (final id in [..._sessions.keys]) {
      await close(id);
    }
  }
}

final class _Session {
  ImapClient? _client;
  Future<void> tail = Future.value();
  Timer? idle;

  Future<ImapClient> connect(Future<ImapClient> Function() open) async {
    final current = _client;
    if (current != null && current.isUsable) return current;
    if (current != null) await close();
    return _client = await open();
  }

  Future<void> close() async {
    idle?.cancel();
    final client = _client;
    _client = null;
    if (client == null) return;
    try {
      await client.logout();
    } on Object {
      await client.close();
    }
  }
}
