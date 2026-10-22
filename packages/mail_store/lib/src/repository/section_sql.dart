// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../database/mail_database.dart';

/// The Smart Inbox section of a message, kept in `messages.section` so
/// lists and counts read an index instead of working it out for every
/// message in the inbox.
///
/// The section changes when the message's flags or category change, when
/// the user writes to its sender or replies to its thread (Important), or
/// when the server's Important folder changes. Every such change refreshes
/// the affected rows with [SectionSql.refresh] in the same transaction, so
/// the stored value is never stale.
abstract final class SectionSql {
  /// Whether General mail is important: the server marks it (`$Important`
  /// keyword, or the same message in the account's `\Important` folder),
  /// it replies to a message in a Sent folder, or its sender was written
  /// to from a Sent folder. Refers to the row being updated as `messages`.
  static const _important =
      '('
      r"(' ' || messages.keywords || ' ') LIKE '% $important %' "
      'OR EXISTS (SELECT 1 FROM messages i JOIN mailboxes ib ON ib.id = i.mailbox_id '
      "WHERE i.message_id_header = messages.message_id_header AND ib.special_use = 'important' "
      'AND ib.account_id = (SELECT account_id FROM mailboxes WHERE id = messages.mailbox_id)) '
      'OR EXISTS (SELECT 1 FROM messages s JOIN mailboxes sb ON sb.id = s.mailbox_id '
      "WHERE s.message_id_header = messages.in_reply_to AND sb.special_use = 'sent') "
      'OR EXISTS (SELECT 1 FROM message_addresses a JOIN messages s ON s.id = a.message_id '
      'JOIN mailboxes sb ON sb.id = s.mailbox_id '
      "WHERE a.address = messages.from_address COLLATE NOCASE AND a.kind IN ('to', 'cc', 'bcc') "
      "AND sb.special_use = 'sent')"
      ')';

  /// The section's name, first rule that applies (see `SmartSection`).
  /// 4 is the flagged bit; 'people' is the stored name of General.
  static const expression =
      'CASE '
      "WHEN (messages.flags & 4) != 0 THEN 'pinned' "
      "WHEN messages.category = 'newsletters' THEN 'newsletters' "
      "WHEN messages.category = 'notifications' THEN 'notifications' "
      "WHEN $_important THEN 'important' "
      "ELSE 'general' END";

  /// Recomputes the section of the rows matching [where].
  static void refresh(
    MailDatabase db,
    String where, [
    List<Object?> args = const [],
  ]) => db.execute(
    'UPDATE messages SET section = $expression WHERE $where',
    args,
  );

  /// Recomputes the rows [ids], in chunks (SQLite limits bound values).
  static void refreshIds(MailDatabase db, List<int> ids) {
    for (var i = 0; i < ids.length; i += 500) {
      final chunk = ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
      refresh(
        db,
        'id IN (${List.filled(chunk.length, '?').join(', ')})',
        chunk,
      );
    }
  }

  /// Every message of [accountId] (after its special folders changed).
  static void refreshAccount(MailDatabase db, int accountId) => refresh(
    db,
    'mailbox_id IN (SELECT id FROM mailboxes WHERE account_id = ?)',
    [accountId],
  );
}
