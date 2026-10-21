// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'account_synchronizer.dart';
import 'connector.dart';
import 'outbox_replayer.dart';

/// Keeps one connection waiting (IDLE) on a folder and reports changes, so
/// other devices' changes and new mail show up within seconds.
///
/// Reconnects with backoff after network errors; stops on authentication
/// or security errors, which retrying cannot fix.
final class IdleWatcher {
  IdleWatcher(
    this._connector, {
    Backoff? backoff,
    this.pollInterval = const Duration(minutes: 2),
  }) : _backoff = backoff ?? Backoff();

  final MailConnector _connector;
  final Backoff _backoff;

  /// How often to check when the server has no IDLE.
  final Duration pollInterval;

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
      try {
        imap = await _connector.imap(account);
        await imap.select(mailbox.encodedName, readOnly: true);
        failures = 0;
        if (!imap.capabilities.has('IDLE')) {
          await Future.any([Future<void>.delayed(pollInterval), stop]);
          if (!stopped) onChange();
          continue;
        }
        while (!stopped) {
          final changed = Completer<void>();
          final subscription = imap.events.listen((event) {
            if (event is! ImapAlertEvent && !changed.isCompleted) {
              changed.complete();
            }
          });
          try {
            await imap.idle(until: Future.any([changed.future, stop]));
          } finally {
            await subscription.cancel();
          }
          if (changed.isCompleted && !stopped) onChange();
        }
      } on MailException catch (e) {
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
        await imap?.close();
      }
    }
  }
}
