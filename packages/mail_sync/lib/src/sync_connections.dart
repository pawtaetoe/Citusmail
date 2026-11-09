// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'connector.dart';

/// The IMAP connections syncs use, kept between syncs: the inbox check
/// every minute and the full sync every few minutes reuse a logged-in
/// connection instead of opening a new one (TLS and login each time).
///
/// A connection unused for [idleTimeout] is logged out. One that sat
/// unused for more than [checkAfter] is asked a NOOP before it is handed
/// out again, so a connection the network dropped silently is replaced
/// before a sync starts on it, never in the middle of one.
final class SyncConnections {
  SyncConnections(
    this._connector, {
    this.idleTimeout = const Duration(minutes: 6),
    this.checkAfter = const Duration(seconds: 20),
  });

  /// Connections that are never kept: each sync opens and closes its own.
  SyncConnections.unpooled(this._connector)
    : idleTimeout = Duration.zero,
      checkAfter = Duration.zero;

  final MailConnector _connector;

  /// How long an unused connection is kept. Longer than the full sync
  /// interval, so the extra connections of a full sync are reused by the
  /// next one too.
  final Duration idleTimeout;

  /// After how long unused a connection is checked before reuse.
  final Duration checkAfter;

  final _idle = <int, List<_Idle>>{};

  /// A logged-in connection for [account]: a kept one that still answers,
  /// else a new one. Give it back with [give] when done.
  Future<ImapClient> take(Account account) async {
    final kept = _idle[account.id];
    while (kept != null && kept.isNotEmpty) {
      final idle = kept.removeLast();
      idle.timer.cancel();
      final client = idle.client;
      if (!client.isUsable) {
        await _logout(client);
        continue;
      }
      if (DateTime.now().difference(idle.since) > checkAfter) {
        try {
          await client.noop();
        } on Object {
          await _logout(client);
          continue;
        }
      }
      return client;
    }
    return _connector.imap(account);
  }

  /// Gives [client] of [account] back after a sync. A connection that
  /// broke is closed.
  Future<void> give(Account account, ImapClient client) async {
    if (idleTimeout <= Duration.zero || !client.isUsable) {
      await _logout(client);
      return;
    }
    final list = _idle.putIfAbsent(account.id, () => []);
    late final _Idle idle;
    idle = _Idle(
      client,
      DateTime.now(),
      Timer(idleTimeout, () {
        list.remove(idle);
        unawaited(_logout(client));
      }),
    );
    list.add(idle);
  }

  /// Closes the kept connections of one account (removed, its settings
  /// changed, or the app came back and they may have died).
  Future<void> close(int accountId) =>
      _closeKept(_idle.remove(accountId) ?? const []);

  Future<void> closeAll() async {
    final kept = [for (final list in _idle.values) ...list];
    _idle.clear();
    await _closeKept(kept);
  }

  static Future<void> _closeKept(List<_Idle> kept) async {
    for (final idle in kept) {
      idle.timer.cancel();
    }
    await Future.wait([for (final idle in kept) _logout(idle.client)]);
  }

  static Future<void> _logout(ImapClient client) async {
    try {
      await client.logout();
    } on Object {
      try {
        await client.close();
      } on Object {
        // Already gone.
      }
    }
  }
}

final class _Idle {
  _Idle(this.client, this.since, this.timer);

  final ImapClient client;
  final DateTime since;
  final Timer timer;
}
