// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:mail_compose/mail_compose.dart';
import 'package:mail_setup/mail_setup.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:mail_unsubscribe/mail_unsubscribe.dart';
import 'package:mail_web/mail_web.dart';
import 'package:path_provider/path_provider.dart';

import '../security/app_lock.dart';
import '../security/pin_hasher.dart';
import 'app_settings.dart';
import 'device_sync.dart';
import 'remote_images.dart';
import 'secret_store.dart';

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
  }) => AppServices._(
    store,
    secrets,
    worker,
    web ?? WebClient(),
    AppLock(store, secrets, biometrics: biometrics, pinRounds: pinRounds),
    databasePath,
  );

  AppServices._(
    this.store,
    this.secrets,
    this.worker,
    WebClient web,
    this.lock,
    this._databasePath,
  ) : deviceSync = DeviceSync(store, secrets, worker),
      actions = MailActions(store, undoWindow: const Duration(seconds: 5)),
      oneClick = OneClickUnsubscriber(web),
      images = RemoteImages(web),
      drafts = DraftStore(store),
      sender = Sender(store),
      replies = ReplyBuilder(store),
      settings = AppSettings(store);

  final MailStore store;
  final SecretStore secrets;
  final SyncWorker worker;
  final String? _databasePath;

  /// The app lock (PIN, biometrics, when to lock).
  final AppLock lock;

  /// App data sync between the user's devices.
  final DeviceSync deviceSync;

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

  static Future<StartupResult> open({SecretStore? secrets}) async {
    final keychain = secrets ?? KeychainSecretStore();
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    final path = '${directory.path}${Platform.pathSeparator}fmail.db';

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
        // Before the worker starts: mail stored by an older version (or
        // with older rules) is sorted again from its stored headers.
        await Resorter(store).resortIfNeeded();
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
      final path = '${directory.path}${Platform.pathSeparator}fmail.db';
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
