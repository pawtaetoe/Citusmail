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

import '../services/ai_assistant.dart';
import '../services/ai_sorter.dart';
import '../services/app_services.dart';
import '../services/app_settings.dart';
import '../services/auto_reader.dart';
import '../services/latest_code.dart';
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
/// way (at most once an hour between them, silently). Both keep the
/// "Latest code" tile's value up to date ([LatestCode]).
///
/// The background engines run in the app's process but have mail
/// connections of their own, and a server allows only a few per account
/// (Gmail about 15, shared by all the user's devices). So while the app's
/// own engine syncs ([setAppSyncing]), they leave the mail to it: the
/// periodic check asks the app to check instead, and Instant mail pauses
/// ([DeferToApp]). With the app gone and Instant mail running, the
/// periodic check asks Instant mail's engine to look at the inboxes.
abstract final class BackgroundMail {
  static const _task = MethodChannel('citusmail/background-task');
  static const _app = MethodChannel('citusmail/background');

  /// Whether Instant mail is offered: on Android (both the GitHub and the
  /// Google Play build).
  static bool get instantAvailable => Platform.isAndroid;

  /// Android: the app's own sync engine started ([on]) or stopped. While
  /// it runs, a periodic check calls [check] (the app's engine checks
  /// every account; true when all went well) instead of connecting
  /// itself, and Instant mail pauses.
  static Future<void> setAppSyncing(
    bool on, {
    Future<bool> Function()? check,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      _app.setMethodCallHandler(
        on && check != null
            ? (call) async {
                if (call.method == 'checkNow') return check();
                throw MissingPluginException();
              }
            : null,
      );
      await _app.invokeMethod<void>('appSyncing', on);
    } on Object catch (e) {
      debugPrint('app syncing: ${e.runtimeType}');
    }
  }

  /// In a background engine: whether the app's own engine syncs now.
  static Future<bool> _appSyncing() async {
    try {
      return await _task.invokeMethod<bool>('appSyncing') ?? false;
    } on Object {
      return false;
    }
  }

  /// In the periodic check: asks the engine already running in this
  /// process (the app's, else Instant mail's) to check the accounts.
  /// Whether all went well; null when none runs, to check here.
  static Future<bool?> _checkElsewhere() async {
    try {
      return await _task
          .invokeMethod<bool>('checkElsewhere')
          .timeout(fullSyncBudget);
    } on TimeoutException {
      return false;
    } on Object {
      return null;
    }
  }

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

  static const lastCheckSetting = BackgroundCheckSetting(
    'background.lastCheck',
  );

  /// Notes when a background check ran and whether every account synced,
  /// for Settings ("Last background check").
  @visibleForTesting
  static void recordCheck(MailStore store, {required bool ok, DateTime? at}) {
    try {
      lastCheckSetting.write(store.settings, (
        at: at ?? DateTime.now(),
        ok: ok,
      ));
    } on Object {
      // Only for display.
    }
  }

  /// The last background check: when, and whether it went well; null if
  /// none has run yet.
  static ({DateTime at, bool ok})? lastCheck(MailStore store) =>
      lastCheckSetting.read(store.settings);

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

  /// Whether Android's "run in background" question was asked (`yes`).
  static const askedSetting = BoolSetting(
    'instant.askedBackground',
    onText: 'yes',
    offText: 'no',
  );

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
    if (askedSetting.isSetIn(store.settings)) return;
    if (!await limited()) return;
    askedSetting.write(store.settings, true);
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

  /// One check of every account; tells Android when done. While the app
  /// or Instant mail runs, its engine does the check, so this device does
  /// not open a second set of connections.
  static Future<void> runOnce() async {
    var ok = false;
    try {
      final elsewhere = await _checkElsewhere();
      ok = elsewhere == null
          ? await _syncOnce()
          : await _checkedElsewhere(ok: elsewhere);
    } on Object {
      ok = false;
    } finally {
      await _task.invokeMethod<void>('done', ok);
    }
  }

  /// After another engine did the check: noted for Settings, and a check
  /// when the next scheduled message is due, as after a check here.
  static Future<bool> _checkedElsewhere({required bool ok}) async {
    final opened = await AppStartup.openExisting();
    if (opened == null) return ok;
    final (store, _) = opened;
    try {
      recordCheck(store, ok: ok);
      await checkWhenDue(store, fromCheck: true);
    } finally {
      store.close();
    }
    return ok;
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
    // The app opened meanwhile: it syncs now, this check stops early.
    var appStarted = false;
    _task.setMethodCallHandler((call) async {
      if (call.method == 'appSyncing' && call.arguments == true) {
        appStarted = true;
      }
    });
    try {
      final notifier = AppSettings(store).notifications
          ? await MailNotifier.create()
          : null;
      final tracker = NewMailTracker(store);
      final latestCode = LatestCode(store);
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
        if (appStarted) break;
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
      await latestCode.update();
      // Then the rest, while there is time. With Instant mail on, its
      // service syncs every folder (every 30 minutes), so this check only
      // looks at the inboxes: a cheap safety net if its connection died.
      final fullSync = !AppSettings(store).instantMail;
      for (final account in fullSync ? accounts : const <Account>[]) {
        if (appStarted) break;
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
      for (final accountId in tidied?.accountIds ?? const <AccountId>{}) {
        await engine.syncAccount(accountId);
      }
      // Deleted elsewhere, or too old by now: the tile lets go of it.
      await latestCode.update();
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
      // the pages, a few at a time (they stay unread). The app reads ahead
      // on its own when it runs.
      if (!appStarted) {
        await readAhead(
          store,
          (id) => engine.loadBody(id, background: true),
          newMail: newMail,
        );
      }
      // New mail the sorting rules can't place, to the AI assistant: only
      // with "Sorting backup" on and a key (else nothing at all).
      if (newMail && !appStarted) {
        await AiSorter.sortOnce(
          store,
          AiAssistant(store, secrets),
          (id) => engine.loadBody(id, background: true),
        );
      }
      recordCheck(store, ok: allOk);
      return allOk;
    } on Object {
      recordCheck(store, ok: false);
      rethrow;
    } finally {
      _task.setMethodCallHandler(null);
      await engine.dispose();
      store.close();
    }
  }

  /// When the background check last read emails ahead of time.
  static const readAheadSetting = DateTimeSetting('autoRead.background');

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
    final last = readAheadSetting.read(store.settings);
    if (!newMail &&
        last != null &&
        now.difference(last) < const Duration(hours: 1)) {
      return 0;
    }
    readAheadSetting.write(store.settings, now);
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
  /// new mail as it arrives. Paused while the app's own engine syncs.
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
    final latestCode = LatestCode(store);
    engine.events.listen((event) {
      if (event is! AccountSynced) return;
      unawaited(latestCode.update());
      final tidied = cleaner.run(DateTime.now().toUtc());
      for (final accountId in tidied?.accountIds ?? const <AccountId>{}) {
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
    final deferral = DeferToApp(start: engine.start, stop: engine.stop);
    _task.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'appSyncing':
          await deferral.appSyncing(call.arguments == true);
        // The periodic check, done here (every inbox) while this runs.
        case 'checkNow' when deferral.running:
          final reports = await Future.wait([
            for (final account in store.accounts.all())
              if (store.mailboxes.inbox(account.id) case final inbox)
                engine.syncAccount(
                  account.id,
                  mailboxIds: inbox == null ? null : {inbox.id},
                ),
          ]);
          return reports.every((r) => r != null);
      }
      return null;
    });
    await deferral.appSyncing(await _appSyncing());
  }
}

/// Runs Instant mail's engine only while the app's own engine does not
/// sync: two engines would each hold their connections to every account
/// (IDLE, syncs), and servers allow only a few per account. Changes are
/// applied one at a time, so a stop always ends before the next start.
final class DeferToApp {
  DeferToApp({required this.start, required this.stop});

  final void Function() start;
  final Future<void> Function() stop;

  bool _running = false;
  Future<void> _changes = Future.value();

  /// Whether the engine runs (once the changes asked for are done).
  bool get running => _running;

  /// The app's engine syncs now ([on]: this one stops) or no longer
  /// (this one starts).
  Future<void> appSyncing(bool on) => _changes = _changes.then((_) async {
    if (on && _running) {
      _running = false;
      await stop();
    } else if (!on && !_running) {
      _running = true;
      start();
    }
  });
}

/// The last background check, as stored: `ok` or `failed`, a space, and
/// when in ISO-8601 (UTC). Read back in local time.
final class BackgroundCheckSetting extends Setting<({DateTime at, bool ok})?> {
  const BackgroundCheckSetting(super.key) : super(fallback: null);

  @override
  ({DateTime at, bool ok})? tryDecode(String stored) {
    final parts = stored.split(' ');
    if (parts.length != 2) return null;
    final at = DateTime.tryParse(parts[1]);
    if (at == null) return null;
    return (at: at.toLocal(), ok: parts[0] == 'ok');
  }

  @override
  String encode(({DateTime at, bool ok})? value) => switch (value) {
    null => '',
    (:final at, :final ok) =>
      '${ok ? 'ok' : 'failed'} ${at.toUtc().toIso8601String()}',
  };
}
