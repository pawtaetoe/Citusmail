// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:mail_setup/mail_setup.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:path_provider/path_provider.dart';

import 'secret_store.dart';

/// Everything the running app uses.
final class AppServices {
  AppServices(this.store, this.secrets)
    : sync = SyncEngine(
        store,
        DefaultMailConnector(KeychainCredentials(secrets)),
      ),
      actions = MailActions(store),
      corrections = CategoryCorrections(store),
      resorter = Resorter(store);

  final MailStore store;
  final SecretStore secrets;
  final SyncEngine sync;
  final MailActions actions;

  /// "Move to People / Newsletters / Notifications".
  final CategoryCorrections corrections;

  /// Re-sorts stored mail after the sorting rules change.
  final Resorter resorter;

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
    return account;
  }

  /// Removes an account, everything stored for it, and its password.
  Future<void> removeAccount(Account account) async {
    store.accounts.remove(account.id);
    await secrets.delete(account.keychainKey);
  }

  Future<void> dispose() async {
    await sync.dispose();
    store.close();
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
      final services = AppServices(MailStore.open(path, key), keychain);
      // Before sync starts: mail stored by an older version (or with older
      // rules) is sorted again from its stored headers.
      try {
        await services.resorter.resortIfNeeded();
      } on Object {
        await services.dispose();
        rethrow;
      }
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
