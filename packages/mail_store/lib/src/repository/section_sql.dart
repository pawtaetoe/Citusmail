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

  /// The section's name as schema versions 6 to 13 worked it out. Used by
  /// migration 6, which runs before the Screener's table exists; never
  /// change it, it is part of a released migration.
  static const migration6Expression =
      'CASE '
      "WHEN (messages.flags & 4) != 0 THEN 'pinned' "
      "WHEN messages.category = 'codes' THEN 'codes' "
      "WHEN messages.category = 'newsletters' THEN 'newsletters' "
      "WHEN messages.category = 'notifications' THEN 'notifications' "
      "WHEN $_important THEN 'important' "
      "ELSE 'general' END";

  /// The section's name, first rule that applies (see `SmartSection`).
  /// 4 is the flagged bit; 'people' is the stored name of General. Pinned
  /// mail and codes are never screened.
  static final expression =
      'CASE '
      "WHEN $snoozed THEN 'snoozed' "
      "WHEN (messages.flags & 4) != 0 THEN 'pinned' "
      "WHEN messages.category = 'codes' THEN 'codes' "
      'WHEN $screenedOut THEN $_outSection '
      "WHEN $waiting THEN 'screener' "
      "WHEN messages.category = 'newsletters' THEN 'newsletters' "
      "WHEN messages.category = 'notifications' THEN 'notifications' "
      "WHEN $_important THEN 'important' "
      "ELSE 'general' END";

  /// Inbox mail the user snoozed (by Message-ID, see `SnoozeRepository`),
  /// until it comes back. Copies in other folders aren't hidden.
  static const snoozed =
      '(messages.message_id_header IS NOT NULL '
      'AND EXISTS (SELECT 1 FROM snoozes z WHERE z.message_id = messages.message_id_header) '
      'AND EXISTS (SELECT 1 FROM mailboxes ib WHERE ib.id = messages.mailbox_id '
      "AND upper(ib.encoded_name) = 'INBOX'))";

  // ------------------------------------------------------ Read receipts

  /// A read receipt (RFC 8098 report, known by its stored Content-Type).
  /// It is sorted as a notification but left out of the Smart Inbox's
  /// [receiptFreeSections], so it is never listed there or announced: it
  /// shows on the sent message it is about instead. It stays in the Inbox
  /// folder and in search. Refers to the row as [alias].
  static String readReceipt(String alias) =>
      "($alias.category = 'notifications' AND EXISTS (SELECT 1 FROM message_headers rh "
      "WHERE rh.message_id = $alias.id AND rh.name = 'content-type' "
      "AND lower(rh.value) LIKE '%multipart/report%' "
      "AND lower(rh.value) LIKE '%disposition-notification%'))";

  /// The sections read receipts would otherwise be in (pinned or snoozed
  /// ones stay where the user put them).
  static const receiptFreeSections = {'notifications', 'screener'};

  // ----------------------------------------------------------- Screener

  /// When the Screener was turned on (milliseconds since the epoch), or
  /// NULL while it is off. See `ScreenerRepository`.
  static const _screenerSince =
      "(SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'screener.since')";

  /// The sender's domain: the text after the last '@', in lower case.
  static const _domain =
      'lower(substr(messages.from_address, '
      "length(rtrim(messages.from_address, replace(messages.from_address, '@', ''))) + 1))";

  /// Whether a `kind`/`value` row of [table] (an address, or a domain and
  /// its subdomains) names the sender.
  static String _names(String table) =>
      "(($table.kind = 'address' AND $table.value = lower(messages.from_address)) "
      "OR ($table.kind = 'domain' AND ($_domain = $table.value "
      "OR substr($_domain, -length($table.value) - 1) = '.' || $table.value)))";

  /// The user's decision for the sender ('in' or 'out'; an address
  /// decision before a domain one), or NULL.
  static final _decision =
      '(SELECT d.decision FROM screener_senders d WHERE ${_names('d')} '
      "ORDER BY d.kind = 'domain' LIMIT 1)";

  /// Mail the Screener never holds back or moves: replies to the user's
  /// own messages (In-Reply-To or References), and mail from blocked
  /// senders (it keeps going to Junk).
  static final _exempt =
      '('
      'EXISTS (SELECT 1 FROM messages s JOIN mailboxes sb ON sb.id = s.mailbox_id '
      "WHERE s.message_id_header = messages.in_reply_to AND sb.special_use = 'sent') "
      "OR (coalesce(messages.thread_references, '') != '' AND EXISTS (SELECT 1 FROM messages s "
      'JOIN mailboxes sb ON sb.id = s.mailbox_id '
      "WHERE sb.special_use = 'sent' AND s.message_id_header IS NOT NULL "
      "AND instr(' ' || messages.thread_references || ' ', ' ' || s.message_id_header || ' ') > 0)) "
      'OR EXISTS (SELECT 1 FROM blocked_senders bs WHERE ${_names('bs')})'
      ')';

  /// A sender the user already knows: one of their own addresses, someone
  /// they wrote to, or someone with mail from before the Screener was
  /// turned on (in any folder except Junk and Trash).
  static const _known =
      '('
      'EXISTS (SELECT 1 FROM accounts WHERE accounts.email = messages.from_address) '
      'OR EXISTS (SELECT 1 FROM messages e JOIN mailboxes eb ON eb.id = e.mailbox_id '
      'WHERE e.from_address = messages.from_address COLLATE NOCASE '
      'AND e.received_at < $_screenerSince '
      "AND (eb.special_use IS NULL OR eb.special_use NOT IN ('junk', 'trash'))) "
      'OR EXISTS (SELECT 1 FROM message_addresses a JOIN messages s ON s.id = a.message_id '
      'JOIN mailboxes sb ON sb.id = s.mailbox_id '
      "WHERE a.address = messages.from_address COLLATE NOCASE AND a.kind IN ('to', 'cc', 'bcc') "
      "AND sb.special_use = 'sent')"
      ')';

  /// Mail from a sender the user screened out (while the Screener is on).
  static final screenedOut =
      '($_screenerSince IS NOT NULL AND messages.from_address IS NOT NULL '
      "AND $_decision = 'out' AND NOT $_exempt)";

  /// Mail from a first-time sender, waiting for the user's decision.
  static final waiting =
      '($_screenerSince IS NOT NULL AND messages.from_address IS NOT NULL '
      'AND $_decision IS NULL AND NOT $_known AND NOT $_exempt)';

  /// Where screened-out mail is shown: Notifications when chosen, else
  /// Newsletters (also while it waits to be moved to Archive).
  static const _outSection =
      "(CASE (SELECT value FROM settings WHERE key = 'screener.out') "
      "WHEN 'notifications' THEN 'notifications' ELSE 'newsletters' END)";

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
