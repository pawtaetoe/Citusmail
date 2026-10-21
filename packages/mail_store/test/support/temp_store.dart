// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

/// A store in a fresh temporary directory, deleted after the test.
final class TempStore {
  TempStore._(this.directory, this.key, this.store);

  static TempStore create() {
    final directory = Directory.systemTemp.createTempSync('mail_store_test');
    final key = DatabaseKey.generate();
    return TempStore._(
      directory,
      key,
      MailStore.open('${directory.path}/mail.db', key),
    );
  }

  final Directory directory;
  final DatabaseKey key;
  MailStore store;

  String get path => '${directory.path}/mail.db';

  /// Closes and opens again with the same key.
  void reopen() {
    store.close();
    store = MailStore.open(path, key);
  }

  void dispose() {
    store.close();
    directory.deleteSync(recursive: true);
  }

  Account addAccount([String email = 'alice@fmail.test']) => store.accounts.add(
    NewAccount(
      email: email,
      username: email,
      imap: ServerSettings(
        host: 'mail.fmail.test',
        port: 993,
        security: ConnectionSecurity.implicitTls,
      ),
      smtp: ServerSettings(
        host: 'mail.fmail.test',
        port: 465,
        security: ConnectionSecurity.implicitTls,
      ),
    ),
  );
}
