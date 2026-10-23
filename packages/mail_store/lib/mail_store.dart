// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Encrypted local storage for accounts, folders, messages, search and the
/// offline action queue.
library;

export 'src/database/database_key.dart';
export 'src/database/mail_database.dart';
export 'src/database/schema.dart';
export 'src/database/store_exception.dart';
export 'src/mail_store.dart';
export 'src/model/account.dart';
export 'src/model/blocked_sender.dart';
export 'src/model/draft.dart';
export 'src/model/folder_rule.dart';
export 'src/model/mailbox.dart';
export 'src/model/message.dart';
export 'src/model/outbox.dart';
export 'src/model/unsubscription.dart';
export 'src/repository/account_repository.dart';
export 'src/repository/app_data_sync_repository.dart';
export 'src/repository/block_repository.dart';
export 'src/repository/draft_repository.dart';
export 'src/repository/folder_rule_repository.dart';
export 'src/repository/image_sender_repository.dart';
export 'src/repository/mailbox_repository.dart';
export 'src/repository/message_repository.dart';
export 'src/repository/outbox_repository.dart';
export 'src/repository/search_query.dart';
export 'src/repository/settings_repository.dart';
export 'src/repository/unsubscribe_repository.dart';
