// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_appsync/mail_appsync.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import 'secret_store.dart';

/// Turning app data sync on and off on this device. The code lives only
/// in the system keychain; the sync itself runs with each mail sync of
/// the sync account (see `AppDataSync`).
final class DeviceSync {
  DeviceSync(this._store, this._secrets, this._worker);

  final MailStore _store;
  final SecretStore _secrets;
  final SyncWorker _worker;

  /// The code, or null when sync is off on this device.
  Future<SyncCode?> code() async {
    final text = await _secrets.read(KeychainSyncCodes.key);
    return text == null ? null : SyncCode.parse(text);
  }

  Future<bool> get enabled async => await code() != null;

  /// The account whose mailbox carries the data.
  Account? get account => AppDataSync.accountIn(_store);

  set account(Account? value) {
    if (value != null) AppDataSync.chooseAccount(_store, value);
  }

  /// How the last exchange went.
  AppDataSyncStatus? get status => AppDataSync.statusIn(_store);

  /// First device: makes a new code and starts syncing.
  Future<SyncCode> start() async {
    final code = SyncCode.generate();
    await _secrets.write(KeychainSyncCodes.key, code.toString());
    syncNow();
    return code;
  }

  /// Another device: uses the code from the first one. False if [text]
  /// isn't a valid code.
  Future<bool> join(String text) async {
    final code = SyncCode.parse(text);
    if (code == null) return false;
    await _secrets.write(KeychainSyncCodes.key, code.toString());
    syncNow();
    return true;
  }

  /// Exchanges data now (in the background).
  void syncNow() {
    final account = this.account;
    if (account != null) _worker.requestSync(account.id);
  }

  /// Turns sync off here: removes this device's data from the folder
  /// (when the server can be reached) and the code from the keychain.
  /// Other devices keep syncing with each other. Returns false if the
  /// server couldn't be reached: the data then stays in the folder, where
  /// it does no harm and can't be read without the code.
  Future<bool> stop() async {
    var reached = true;
    try {
      await _worker.forgetAppData();
    } on SyncWorkerException {
      reached = false;
    }
    await _secrets.delete(KeychainSyncCodes.key);
    _store.appDataSync.reset();
    return reached;
  }
}
