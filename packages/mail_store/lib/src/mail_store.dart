// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'database/database_key.dart';
import 'database/mail_database.dart';
import 'repository/account_repository.dart';
import 'repository/mailbox_repository.dart';
import 'repository/message_repository.dart';
import 'repository/outbox_repository.dart';

/// The app's local mail storage: one encrypted database with a repository
/// per kind of data.
final class MailStore {
  MailStore._(this.database)
    : accounts = AccountRepository(database),
      mailboxes = MailboxRepository(database),
      messages = MessageRepository(database),
      outbox = OutboxRepository(database);

  /// Opens (or creates) the store at [path], encrypted with [key].
  /// See [MailDatabase.open] for the errors it can raise.
  static MailStore open(String path, DatabaseKey key) =>
      MailStore._(MailDatabase.open(path, key));

  final MailDatabase database;
  final AccountRepository accounts;
  final MailboxRepository mailboxes;
  final MessageRepository messages;
  final OutboxRepository outbox;

  /// Runs [action] atomically across repositories.
  T transaction<T>(T Function() action) => database.transaction(action);

  void close() => database.close();
}
