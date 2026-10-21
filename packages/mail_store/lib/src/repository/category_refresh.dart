// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../database/mail_database.dart';

/// Recomputes the category shown for messages, in one place:
///
/// 1. the user's choice for the message's mailing list, else
/// 2. the user's choice for its sender, else
/// 3. the automatic decision (`auto_category`).
///
/// Runs inside the caller's transaction, so a choice and the messages it
/// affects always change together, and a sync writing at the same time
/// cannot leave a stale category behind.
abstract final class CategoryRefresh {
  // `category_choices.key` is COLLATE NOCASE, so comparing it with
  // `from_address` folds ASCII case and can use the primary key index.
  static const _listChoice =
      "SELECT c.category FROM category_choices c WHERE c.scope = 'list' AND c.key = messages.list_id";
  static const _senderChoice =
      "SELECT c.category FROM category_choices c WHERE c.scope = 'sender' AND c.key = messages.from_address";

  static const _set =
      'UPDATE messages SET '
      'category = coalesce(($_listChoice), ($_senderChoice), auto_category), '
      'category_source = CASE WHEN ($_listChoice) IS NOT NULL OR ($_senderChoice) IS NOT NULL '
      "THEN 'manual' ELSE auto_source END ";

  /// One message.
  static void byId(MailDatabase db, int messageId) =>
      db.execute('${_set}WHERE id = ?', [messageId]);

  /// Every message from [address] (ASCII case-insensitive).
  static void bySender(MailDatabase db, String address) =>
      db.execute('${_set}WHERE from_address = ? COLLATE NOCASE', [address]);

  /// Every message of the list [listId] (already normalized).
  static void byList(MailDatabase db, String listId) =>
      db.execute('${_set}WHERE list_id = ?', [listId]);
}
