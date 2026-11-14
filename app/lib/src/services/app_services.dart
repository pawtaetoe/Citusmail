// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'package:mail_ai/mail_ai.dart';
import 'package:mail_compose/mail_compose.dart';
import 'package:mail_oauth/mail_oauth.dart';
import 'package:mail_setup/mail_setup.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:mail_unsubscribe/mail_unsubscribe.dart';
import 'package:mail_web/mail_web.dart';
import 'package:path_provider/path_provider.dart';

import '../mail/summaries.dart';
import '../security/app_lock.dart';
import '../security/pin_hasher.dart';
import 'ai_assistant.dart';
import 'app_settings.dart';
import 'auto_reader.dart';
import 'device_sync.dart';
import 'link_safety.dart';
import 'remote_images.dart';
import 'secret_store.dart';
import 'virus_total_checks.dart';

/// Everything the running app uses.
///
/// The UI reads the encrypted store directly (fast, synchronous queries);
/// syncing, downloading messages and replaying offline changes happen in
/// the background [worker], which has its own connection to the same file.
final class AppServices {
  factory AppServices(
    MailStore store,
    SecretStore secrets,
    SyncWorker worker, {
    WebClient? web,
    Biometrics? biometrics,
    String? databasePath,
    int pinRounds = PinHasher.iterations,
    AiProviderFactory? aiProviders,
  }) => AppServices._(
    store,
    secrets,
    worker,
    web ?? WebClient(),
    AppLock(store, secrets, biometrics: biometrics, pinRounds: pinRounds),
    databasePath,
    AiAssistant(store, secrets, providers: aiProviders),
  );

  AppServices._(
    this.store,
    this.secrets,
    this.worker,
    WebClient web,
    this.lock,
    this._databasePath,
    this.ai,
  ) : deviceSync = DeviceSync(store, secrets, worker),
      virusTotal = VirusTotalChecks(store, secrets, web),
      linkSafety = LinkSafety(
        store,
        secrets,
        web,
        listFile: _databasePath == null
            ? null
            : File('${File(_databasePath).parent.path}/safebrowsing.bin'),
      ),
      actions = MailActions(store, undoWindow: const Duration(seconds: 5)),
      oneClick = OneClickUnsubscriber(web),
      images = RemoteImages(web),
      drafts = DraftStore(store),
      sender = Sender(store),
      replies = ReplyBuilder(store),
      settings = AppSettings(store),
      summaries = MessageSummaries(store, ai, loadBody: worker.loadBody),
      autoRead = AutoReader(store, worker.loadBodyInBackground) {
    // Summaries are forgotten when the user turns them off.
    ai.whenTurnedOff(AiFeatures.summaries.id, summaries.forgetAll);
    // Preferences synced from the user's other devices show at once.
    _syncEvents = worker.events.listen((event) {
      if (event is AccountSynced) {
        if (event.report.appData case final exchange?) {
          settings.syncApplied(exchange.changes);
        }
      }
    });
  }

  late final StreamSubscription<SyncEvent> _syncEvents;

  final MailStore store;
  final SecretStore secrets;
  final SyncWorker worker;
  final String? _databasePath;

  /// The app lock (PIN, biometrics, when to lock).
  final AppLock lock;

  /// App data sync between the user's devices.
  final DeviceSync deviceSync;

  /// Optional Google Safe Browsing link checks (off by default).
  final LinkSafety linkSafety;

  /// Optional VirusTotal lookups with the user's key (off by default).
  final VirusTotalChecks virusTotal;

  /// The optional AI assistant with the user's own key (every feature off
  /// by default). Features get their provider from
  /// [AiAssistant.providerFor], which is null while they are off.
  final AiAssistant ai;

  /// "Summarise" in the reader (an [ai] feature, off by default).
  final MessageSummaries summaries;

  /// Local changes (read, pin, move, delete); the worker sends them on.
  final MailActions actions;

  /// Writing mail: drafts, sending with undo, replies and forwards.
  final DraftStore drafts;
  final Sender sender;
  final ReplyBuilder replies;

  /// One-click unsubscribe requests (the only HTTPS the app sends to
  /// servers named in mail; see packages/mail_web).
  final OneClickUnsubscriber oneClick;

  /// Images the user chose to load (same hardened client).
  final RemoteImages images;

  /// The user's app settings (notifications, instant mail).
  final AppSettings settings;

  /// Receipts, bills and booking emails read ahead of time for the pages
  /// (started by the mail screen).
  final AutoReader autoRead;

  /// Changes when stored mail was sorted again ([resortWhenIdle]): the
  /// lists and counts are read again.
  final resorted = ValueNotifier<int>(0);

  /// Sorts mail stored by an older version (or with older rules) again
  /// from its stored headers, without holding up start-up: after the
  /// first frame and [idle] more, in small batches with a frame's pause
  /// between them. Ends when the app closes; an unfinished run starts
  /// again next time. Returns how many messages were looked at.
  Future<int> resortWhenIdle({
    Duration idle = const Duration(seconds: 2),
  }) async {
    try {
      final resorter = Resorter(store, batchSize: 100);
      if (!resorter.isNeeded) return 0;
      await SchedulerBinding.instance.endOfFrame;
      await Future<void>.delayed(idle);
      bool stopped() => _disposing != null;
      if (stopped()) return 0;
      final count = await resorter.resortAll(
        pause: const Duration(milliseconds: 16),
        stopped: stopped,
      );
      if (!stopped()) resorted.value++;
      return count;
    } on Object catch (e) {
      // Tried again at the next start.
      debugPrint('resort: ${e.runtimeType}');
      return 0;
    }
  }

  /// Saves a verified account: settings in the encrypted store, password in
  /// the keychain. If the keychain write fails, the account is removed
  /// again so no account exists without its password.
  Future<Account> addAccount(
    DiscoveredSettings settings,
    String password, {
    String? displayName,
  }) async {
    final account = store.accounts.add(
      NewAccount(
        email: settings.email,
        displayName: displayName,
        username: settings.username,
        imap: ServerSettings(
          host: settings.imap.host,
          port: settings.imap.port,
          security: settings.imap.security,
        ),
        smtp: ServerSettings(
          host: settings.smtp.host,
          port: settings.smtp.port,
          security: settings.smtp.security,
        ),
      ),
    );
    try {
      await secrets.write(account.keychainKey, password);
    } on Object {
      store.accounts.remove(account.id);
      rethrow;
    }
    await worker.accountsChanged();
    return account;
  }

  /// Saves an account that signs in with [provider]: settings in the
  /// encrypted store, [tokens] in the keychain (removed again if that
  /// fails, so no account exists without its sign-in).
  Future<Account> addOAuthAccount(
    DiscoveredSettings settings,
    OAuthProvider provider,
    OAuthTokens tokens, {
    String? displayName,
  }) async {
    final account = store.accounts.add(
      NewAccount(
        email: settings.email,
        displayName: displayName,
        username: settings.username,
        imap: ServerSettings(
          host: settings.imap.host,
          port: settings.imap.port,
          security: settings.imap.security,
        ),
        smtp: ServerSettings(
          host: settings.smtp.host,
          port: settings.smtp.port,
          security: settings.smtp.security,
        ),
        oauthProvider: provider.id,
      ),
    );
    try {
      await secrets.write(account.keychainKey, tokens.toJson());
    } on Object {
      store.accounts.remove(account.id);
      rethrow;
    }
    await worker.accountsChanged();
    return account;
  }

  /// Replaces an account's password or OAuth tokens (already checked with
  /// a real login) and checks for mail with them right away.
  Future<void> replaceSecret(Account account, String secret) async {
    await secrets.write(account.keychainKey, secret);
    try {
      await worker.syncNow(account.id);
    } on SyncWorkerException {
      // Shown through the account's sync status.
    }
  }

  /// Removes an account, everything stored for it, and its password.
  Future<void> removeAccount(Account account) async {
    store.accounts.remove(account.id);
    await secrets.delete(account.keychainKey);
    await worker.accountsChanged();
  }

  Future<void>? _disposing;

  /// Stops the worker and closes the store. Safe to call more than once:
  /// every caller waits for the same shutdown.
  Future<void> dispose() => _disposing ??= _close();

  Future<void> _close() async {
    await _syncEvents.cancel();
    autoRead.stop();
    lock.dispose();
    await worker.close();
    store.close();
    _closed = true;
  }

  bool _closed = false;

  /// Whether [dispose] has finished.
  bool get closed => _closed;

  /// "Forgot PIN": removes everything on this device: every account and
  /// its password, the local mail, the database key and the PIN. Mail on
  /// the servers is untouched; the user adds their accounts again.
  Future<void> resetEverything() async {
    final accounts = store.accounts.all();
    await dispose();
    for (final account in accounts) {
      await secrets.delete(account.keychainKey);
    }
    await secrets.delete(AppLock.pinKey);
    await secrets.delete(KeychainSyncCodes.key);
    await ai.forgetKeys();
    final path = _databasePath;
    if (path != null) await AppStartup.resetLocalData(path, secrets: secrets);
  }
}

/// How app start-up went.
sealed class StartupResult {
  const StartupResult();
}

final class StartupReady extends StartupResult {
  const StartupReady(this.services);

  final AppServices services;
}

/// No usable keychain: nothing secret can be stored safely.
final class StartupKeychainUnavailable extends StartupResult {
  const StartupKeychainUnavailable(this.detail);

  final String detail;
}

/// The local data cannot be opened (its key is gone or does not match).
/// Mail can be downloaded again; only unsent local changes are lost.
final class StartupDataUnreadable extends StartupResult {
  const StartupDataUnreadable(this.databasePath);

  final String databasePath;
}

/// The SQLite library cannot encrypt: refuse to store mail.
final class StartupEncryptionUnavailable extends StartupResult {
  const StartupEncryptionUnavailable(this.detail);

  final String detail;
}

/// Opens the encrypted store with the key from the keychain, creating both
/// on first run.
abstract final class AppStartup {
  static const _databaseKeyName = 'database-key';

  /// The database in [directory]. Versions before the rename called it
  /// `fmail.db`: such a database (with its WAL and shared-memory files) is
  /// moved to the new name once, so mail and accounts carry over. The key
  /// in the keychain is unchanged.
  static String databasePath(Directory directory) {
    String inDir(String name) =>
        '${directory.path}${Platform.pathSeparator}$name';
    final path = inDir('citusmail.db');
    final old = inDir('fmail.db');
    if (!File(path).existsSync() && File(old).existsSync()) {
      // The main file last: until it moves, the next start finishes the
      // move. Another process (background sync) may be doing the same.
      for (final suffix in ['-wal', '-shm', '']) {
        try {
          final file = File('$old$suffix');
          if (file.existsSync()) file.renameSync('$path$suffix');
        } on FileSystemException {
          // Moved by the other process, or retried next start.
        }
      }
    }
    return path;
  }

  static Future<StartupResult> open({SecretStore? secrets}) async {
    final keychain = secrets ?? KeychainSecretStore();
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    final path = databasePath(directory);

    try {
      final stored = await keychain.read(_databaseKeyName);
      final DatabaseKey key;
      if (stored == null) {
        if (File(path).existsSync()) {
          return StartupDataUnreadable(path); // key lost
        }
        key = DatabaseKey.generate();
        await keychain.write(_databaseKeyName, key.hex);
      } else {
        key = DatabaseKey.fromBytes(_hexToBytes(stored));
      }
      final store = MailStore.open(path, key);
      final SyncWorker worker;
      try {
        // Drafts left on the device (the app stopped while writing) go to
        // the server's Drafts folder with the next sync.
        DraftStore(store).moveLeftoversToServer();
        worker = await SyncWorker.spawn(
          SyncWorkerConfig(databasePath: path, key: key),
          credentials: KeychainCredentials(keychain),
          syncCodes: KeychainSyncCodes(keychain),
        );
      } on Object {
        store.close();
        rethrow;
      }
      final services = AppServices(store, keychain, worker, databasePath: path);
      await services.lock.start();
      // Mail stored by an older version (or with older rules) is sorted
      // again once the mail screen is up.
      unawaited(services.resortWhenIdle());
      return StartupReady(services);
    } on SecretStoreUnavailableException catch (e) {
      return StartupKeychainUnavailable(e.message);
    } on WrongKeyException {
      return StartupDataUnreadable(path);
    } on FormatException {
      return StartupDataUnreadable(path);
    } on ArgumentError {
      return StartupDataUnreadable(path); // malformed stored key
    } on EncryptionUnavailableException catch (e) {
      return StartupEncryptionUnavailable(e.message);
    }
  }

  /// For background work: opens the existing encrypted store, or returns
  /// null if there is nothing to open (no key or no data yet) or anything
  /// is wrong. Never creates a key or a database; the app does that.
  static Future<(MailStore, SecretStore)?> openExisting() async {
    try {
      final keychain = KeychainSecretStore();
      final directory = await getApplicationSupportDirectory();
      final path = databasePath(directory);
      if (!File(path).existsSync()) return null;
      final stored = await keychain.read(_databaseKeyName);
      if (stored == null) return null;
      final key = DatabaseKey.fromBytes(_hexToBytes(stored));
      return (MailStore.open(path, key), keychain as SecretStore);
    } on Object {
      return null;
    }
  }

  /// Deletes unreadable local data and its key, so start-up can begin
  /// fresh. Accounts must then be added again.
  static Future<void> resetLocalData(
    String databasePath, {
    SecretStore? secrets,
  }) async {
    MailDatabase.destroy(databasePath);
    await (secrets ?? KeychainSecretStore()).delete(_databaseKeyName);
  }

  static List<int> _hexToBytes(String hex) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) {
      throw const FormatException('bad stored key');
    }
    return [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
  }
}
