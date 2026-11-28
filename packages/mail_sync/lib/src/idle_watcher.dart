// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'account_synchronizer.dart';
import 'connection_budget.dart';
import 'connector.dart';
import 'outbox_replayer.dart';

/// Keeps one connection waiting (IDLE) on a folder and reports changes, so
/// other devices' changes and new mail show up within seconds.
///
/// The connection counts in the account's [ConnectionBudget], and is the
/// first to go when the budget is short: while other work waits for a
/// connection, or the account has more open than it may, the watcher hands
/// its connection over, waits [resumeAfter], and queues for one again.
///
/// Reconnects with backoff after network errors; stops on authentication
/// or security errors, which retrying cannot fix.
final class IdleWatcher {
  IdleWatcher(
    MailConnector connector, {
    Backoff? backoff,
    this.pollInterval = const Duration(minutes: 2),
    this.resumeAfter = const Duration(seconds: 10),
    ConnectionBudget? budget,
  }) : _backoff = backoff ?? Backoff(),
       _budget = budget ?? ConnectionBudget(connector);

  final Backoff _backoff;
  final ConnectionBudget _budget;

  /// How often to check when the server has no IDLE.
  final Duration pollInterval;

  /// How long the watcher waits after handing its connection over.
  final Duration resumeAfter;

  /// Watches [mailbox] until [stop] completes. Calls [onChange] when the
  /// server reports a change, and [onFailure] for errors that end watching.
  Future<void> watch(
    Account account,
    StoredMailbox mailbox, {
    required Future<void> stop,
    required void Function() onChange,
    void Function(SyncFailure failure)? onFailure,
  }) async {
    var stopped = false;
    unawaited(stop.whenComplete(() => stopped = true));
    var failures = 0;

    while (!stopped) {
      ImapClient? imap;
      var handedOver = false;
      try {
        imap = await _budget.take(account, owner: this, until: stop);
        if (!stopped) {
          await imap.select(mailbox.encodedName, readOnly: true);
          failures = 0;
          handedOver = await _wait(imap, account, stop, onChange);
        }
      } on Object catch (e) {
        if (stopped) break;
        final failure = SyncFailure.from(e);
        if (failure.kind == SyncFailureKind.authentication ||
            failure.kind == SyncFailureKind.security) {
          onFailure?.call(failure);
          return;
        }
        await Future.any([
          Future<void>.delayed(_backoff.after(failures++)),
          stop,
        ]);
      } finally {
        // Handed to whoever waits for it, else logged out.
        if (imap != null) await _budget.give(account, imap, owner: this);
      }
      if (handedOver && !stopped) {
        await Future.any([Future<void>.delayed(resumeAfter), stop]);
      }
    }
  }

  /// Waits on [imap] for changes until [stop], or until the connection is
  /// wanted elsewhere (then true). Without IDLE, one [pollInterval].
  Future<bool> _wait(
    ImapClient imap,
    Account account,
    Future<void> stop,
    void Function() onChange,
  ) async {
    var stopped = false;
    var wanted = false;
    final pressure = _budget.pressure(account.id).then((_) => wanted = true);
    final ended = Future.any([
      stop.whenComplete(() => stopped = true),
      pressure,
    ]);
    if (!imap.capabilities.has('IDLE')) {
      await Future.any([Future<void>.delayed(pollInterval), ended]);
      if (!stopped && !wanted) onChange();
      return wanted && !stopped;
    }
    while (!stopped && !wanted) {
      final changed = Completer<void>();
      final subscription = imap.events.listen((event) {
        if (event is! ImapAlertEvent && !changed.isCompleted) {
          changed.complete();
        }
      });
      try {
        await imap.idle(until: Future.any([changed.future, ended]));
      } finally {
        await subscription.cancel();
      }
      if (changed.isCompleted && !stopped) onChange();
    }
    return wanted && !stopped;
  }
}
