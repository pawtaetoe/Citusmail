// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mail_compose/mail_compose.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import '../services/app_services.dart';
import '../services/app_settings.dart';
import '../services/auto_reader.dart';
import '../services/mail_notifier.dart';
import '../services/secret_store.dart';

/// Whether this is the Google Play build (`flutter build appbundle
/// --flavor play`; Flutter passes the flavor to the app).
const bool playBuild = appFlavor == 'play';

/// Mail checks while the app is closed (Android). The Kotlin side runs the
/// entry points in main.dart in a background Flutter engine:
///
/// - [runOnce]: the periodic check (about every 5 minutes), which also
///   brings back snoozed mail whose time came;
/// - [runInstant]: "Instant mail", a live connection kept by a foreground
///   service.
///
/// Both use the same sync code and the same exactly-once new-mail marks as
/// the app, so nothing is announced twice, and tidy up old codes the same
/// way (at most once an hour between them, silently).
abstract final class BackgroundMail {
  static const _task = MethodChannel('citusmail/background-task');
  static const _app = MethodChannel('citusmail/background');

  /// Whether this build offers Instant mail: Android, except the Google
  /// Play build (`--flavor play`), which leaves its foreground service out
  /// (see packaging/README.md).
  static bool get instantAvailable => Platform.isAndroid && !playBuild;

  /// Turns the instant-mail service on or off.
  static Future<void> setInstant(bool on) async {
    if (!instantAvailable) return;
    await _app.invokeMethod<void>('setInstant', on);
  }

  /// Android: one more background check when the next message scheduled
  /// with "Send later" (or the next follow-up reminder) is due, so it goes
  /// out on time while the app is closed (ordinary WorkManager work, no
  /// exact alarms: Android may hold it a few minutes). [fromCheck] when
  /// called from a background check. Elsewhere the running app does it.
  static Future<void> checkWhenDue(
    MailStore store, {
    bool fromCheck = false,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      final next = [
        ?ScheduledSends(store, Sender(store)).nextDue(),
        ?FollowUpReminders(store).nextDue(),
      ].fold<DateTime?>(null, (a, b) => a == null || b.isBefore(a) ? b : a);
      if (next == null) return;
      await (fromCheck ? _task : _app).invokeMethod<void>(
        'checkAt',
        next.millisecondsSinceEpoch,
      );
    } on Object catch (e) {
      debugPrint('send later: ${e.runtimeType}');
    }
  }

  /// One check of every account; tells Android when done.
  static Future<void> runOnce() async {
    var ok = false;
    try {
      ok = await _syncOnce();
    } on Object {
      ok = false;
    } finally {
      await _task.invokeMethod<void>('done', ok);
    }
  }

  static Future<bool> _syncOnce() async {
    final opened = await AppStartup.openExisting();
    if (opened == null) return true; // nothing set up yet
    final (store, secrets) = opened;
    final engine = SyncEngine(
      store,
      DefaultMailConnector(KeychainCredentials(secrets)),
      syncCodes: KeychainSyncCodes(secrets),
    );
    try {
      final notifier = AppSettings(store).notifications
          ? await MailNotifier.create()
          : null;
      final tracker = NewMailTracker(store);
      var allOk = true;
      var newMail = false;
      for (final account in store.accounts.all()) {
        final report = await engine.syncAccount(account.id);
        if (report == null) {
          allOk = false;
          continue;
        }
        newMail |= report.mailboxes.values.any(
          (r) => r.added + r.backfilled > 0,
        );
        final mail = tracker.claim(account.id);
        await notifier?.announce(store, account, mail);
      }
      // Snoozed mail whose time came: back (unread, also on the server),
      // announced once.
      final back = SnoozeWaker(store, MailActions(store)).wake();
      await notifier?.announceBackFromSnooze(store, back);
      for (final accountId in back.accountIds) {
        await engine.syncAccount(accountId);
      }
      // Old codes leave the inbox (once agreed); the moves go to the
      // server right away.
      final tidied = CodeCleaner(
        store,
        MailActions(store),
      ).run(DateTime.now().toUtc());
      for (final accountId in tidied?.accountIds ?? const <int>{}) {
        await engine.syncAccount(accountId);
      }
      await notifier?.remind(store);
      // Sent mail that got no reply in time: back in the inbox, and
      // announced (in the daytime); a reply ends a follow-up quietly.
      FollowUpReminders(store).check();
      if (notifier != null) {
        await notifier.announceFollowUps(store);
      } else {
        // Notifications off: nothing to post later either.
        FollowUpReminders(store).claimUnnotified();
      }
      // Scheduled messages ("Send later") went out with the syncs above;
      // a quiet note for any that failed, and a check when the next one
      // is due.
      await notifier?.announceFailedSends(store);
      await checkWhenDue(store, fromCheck: true);
      // Last, once the news is out: receipts, bills and booking emails for
      // the pages, a few at a time (they stay unread).
      await readAhead(store, engine.loadBody, newMail: newMail);
      return allOk;
    } finally {
      await engine.dispose();
      store.close();
    }
  }

  /// When the background check last read emails ahead of time.
  static const _readAheadKey = 'autoRead.background';

  /// Reads ahead ([AutoReader], at most [AutoReader.backgroundCap]) after
  /// new mail came, and otherwise at most hourly, so what is left from
  /// earlier gets read too without parsing the pages' mail every check.
  @visibleForTesting
  static Future<int> readAhead(
    MailStore store,
    BodyLoader load, {
    required bool newMail,
    DateTime? now,
  }) async {
    if (!AppSettings(store).autoRead) return 0;
    now ??= DateTime.now();
    final last = int.tryParse(store.settings.read(_readAheadKey) ?? '');
    if (!newMail &&
        last != null &&
        now.difference(DateTime.fromMillisecondsSinceEpoch(last)) <
            const Duration(hours: 1)) {
      return 0;
    }
    store.settings.write(_readAheadKey, '${now.millisecondsSinceEpoch}');
    try {
      return await AutoReader.readOnce(store, load);
    } on Object catch (e) {
      debugPrint('read ahead: ${e.runtimeType}');
      return 0;
    }
  }

  /// Keeps syncing (IDLE on every inbox) until the service stops; announces
  /// new mail as it arrives.
  static Future<void> runInstant() async {
    final opened = await AppStartup.openExisting();
    if (opened == null) {
      await _task.invokeMethod<void>('done', false); // stops the service
      return;
    }
    final (store, secrets) = opened;
    final settings = AppSettings(store);
    final engine = SyncEngine(
      store,
      DefaultMailConnector(KeychainCredentials(secrets)),
      syncCodes: KeychainSyncCodes(secrets),
    );
    final tracker = NewMailTracker(store);
    final cleaner = CodeCleaner(store, MailActions(store));
    final snoozes = SnoozeWaker(store, MailActions(store));
    final notifier = await MailNotifier.create();
    engine.events.listen((event) {
      if (event is! AccountSynced) return;
      final tidied = cleaner.run(DateTime.now().toUtc());
      for (final accountId in tidied?.accountIds ?? const <int>{}) {
        engine.requestSync(accountId);
      }
      final mail = tracker.claim(event.accountId);
      final back = snoozes.wake();
      for (final accountId in back.accountIds) {
        engine.requestSync(accountId);
      }
      // A reply ends a follow-up; no reply in time brings it back.
      FollowUpReminders(store).check();
      final account = store.accounts.byId(event.accountId);
      if (account != null && settings.notifications) {
        unawaited(notifier?.announce(store, account, mail));
        unawaited(notifier?.announceBackFromSnooze(store, back));
        unawaited(notifier?.remind(store));
        unawaited(notifier?.announceFailedSends(store));
        unawaited(notifier?.announceFollowUps(store));
      }
    });
    engine.start();
  }
}
