// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'database/database_key.dart';
import 'database/mail_database.dart';
import 'repository/account_repository.dart';
import 'repository/block_repository.dart';
import 'repository/draft_repository.dart';
import 'repository/folder_rule_repository.dart';
import 'repository/image_sender_repository.dart';
import 'repository/mailbox_repository.dart';
import 'repository/message_repository.dart';
import 'repository/outbox_repository.dart';
import 'repository/settings_repository.dart';
import 'repository/unsubscribe_repository.dart';

/// The app's local mail storage: one encrypted database with a repository
/// per kind of data.
final class MailStore {
  MailStore._(this.database)
    : accounts = AccountRepository(database),
      mailboxes = MailboxRepository(database),
      messages = MessageRepository(database),
      outbox = OutboxRepository(database),
      settings = SettingsRepository(database),
      drafts = DraftRepository(database),
      folderRules = FolderRuleRepository(database),
      unsubscriptions = UnsubscribeRepository(database),
      blocks = BlockRepository(database),
      imageSenders = ImageSenderRepository(database);

  /// Opens (or creates) the store at [path], encrypted with [key].
  /// See [MailDatabase.open] for the errors it can raise.
  static MailStore open(String path, DatabaseKey key) =>
      MailStore._(MailDatabase.open(path, key));

  final MailDatabase database;
  final AccountRepository accounts;
  final MailboxRepository mailboxes;
  final MessageRepository messages;
  final OutboxRepository outbox;
  final SettingsRepository settings;
  final DraftRepository drafts;
  final FolderRuleRepository folderRules;
  final UnsubscribeRepository unsubscriptions;
  final BlockRepository blocks;
  final ImageSenderRepository imageSenders;

  /// Runs [action] atomically across repositories.
  T transaction<T>(T Function() action) => database.transaction(action);

  void close() => database.close();
}
