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

  /// Whether Instant mail is offered: on Android (both the GitHub and the
  /// Google Play build).
  static bool get instantAvailable => Platform.isAndroid;

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

  /// After this long, a background check starts no more full syncs (the
  /// inboxes always come first). Android stops a check after 10 minutes.
  static const fullSyncBudget = Duration(minutes: 4);

  static const _lastCheckKey = 'background.lastCheck';

  /// Notes when a background check ran and whether every account synced,
  /// for Settings ("Last background check").
  @visibleForTesting
  static void recordCheck(MailStore store, {required bool ok, DateTime? at}) {
    try {
      final when = (at ?? DateTime.now()).toUtc().toIso8601String();
      store.settings.write(_lastCheckKey, '${ok ? 'ok' : 'failed'} $when');
    } on Object {
      // Only for display.
    }
  }

  /// The last background check: when, and whether it went well; null if
  /// none has run yet.
  static ({DateTime at, bool ok})? lastCheck(MailStore store) {
    final value = store.settings.read(_lastCheckKey);
    final parts = value?.split(' ');
    if (parts == null || parts.length != 2) return null;
    final at = DateTime.tryParse(parts[1]);
    if (at == null) return null;
    return (at: at.toLocal(), ok: parts[0] == 'ok');
  }

  /// Whether Android limits this app's background work to save battery
  /// (then checks may wait until the device wakes). False elsewhere.
  static Future<bool> batteryLimited() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _app.invokeMethod<bool>('batteryOptimized') ?? false;
    } on Object {
      return false;
    }
  }

  static const _askedKey = 'instant.askedBackground';

  /// Asks Android, with its own one-tap dialog, to let the app run in the
  /// background without battery limits, so Instant mail keeps its
  /// connection while the phone sleeps. Nothing if already allowed.
  static Future<void> askToRunInBackground() async {
    if (!Platform.isAndroid) return;
    try {
      await _app.invokeMethod<void>('askUnrestricted');
    } on Object {
      // Not offered on this phone: Settings shows the way.
    }
  }

  /// Once per install, with Instant mail on: asks Android's one-tap
  /// "run in background" question if the app is still battery limited.
  /// [limited] and [ask] are for tests.
  static Future<void> askOnce(
    MailStore store, {
    Future<bool> Function() limited = batteryLimited,
    Future<void> Function() ask = askToRunInBackground,
  }) async {
    if (store.settings.read(_askedKey) != null) return;
    if (!await limited()) return;
    store.settings.write(_askedKey, 'yes');
    await ask();
  }

  /// Opens this app's page in Android's settings (Battery: Unrestricted).
  static Future<void> openAppSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _app.invokeMethod<void>('openAppSettings');
    } on Object {
      // Nothing to open.
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
      final started = DateTime.now();
      void noteNew(AccountSyncReport report) {
        newMail |= report.mailboxes.values.any(
          (r) => r.added + r.backfilled > 0,
        );
      }

      // Every inbox first, announced at once: the other folders and older
      // mail can take longer than Android lets a check run.
      final accounts = store.accounts.all();
      for (final account in accounts) {
        final inbox = store.mailboxes.inbox(account.id);
        final report = await engine.syncAccount(
          account.id,
          mailboxIds: inbox == null ? null : {inbox.id},
        );
        if (report == null) {
          allOk = false;
          continue;
        }
        noteNew(report);
        await notifier?.announce(store, account, tracker.claim(account.id));
      }
      // Then the rest, while there is time. With Instant mail on, its
      // service syncs every folder (every 30 minutes), so this check only
      // looks at the inboxes: a cheap safety net if its connection died.
      final fullSync = !AppSettings(store).instantMail;
      for (final account in fullSync ? accounts : const <Account>[]) {
        if (DateTime.now().difference(started) > fullSyncBudget) break;
        final report = await engine.syncAccount(account.id);
        if (report == null) {
          allOk = false;
          continue;
        }
        noteNew(report);
        await notifier?.announce(store, account, tracker.claim(account.id));
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
      await readAhead(
        store,
        (id) => engine.loadBody(id, background: true),
        newMail: newMail,
      );
      recordCheck(store, ok: allOk);
      return allOk;
    } on Object {
      recordCheck(store, ok: false);
      rethrow;
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

  /// How often Instant mail syncs every folder. New inbox mail arrives
  /// through IDLE at once; this catches mail filed into other folders and
  /// changes made elsewhere, without waking the phone every few minutes.
  static const instantFullSyncInterval = Duration(minutes: 30);

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
      fullSyncInterval: instantFullSyncInterval,
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
