// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'folder_rules.dart';
import 'mail_actions.dart';

/// Moves new inbox mail from blocked senders to the account's Junk folder
/// (Trash if it has none) on the server, through the outbox, so other
/// devices and mail apps see it gone too.
///
/// Runs before the folder rules: a block wins. Like the rules, it moves
/// only mail received since the block (with [FolderRuleApplier]'s clock
/// tolerance) and never moves a message twice (by Message-ID), so mail
/// the user brings back stays where they put it.
final class SenderBlocker {
  SenderBlocker(this._store) : _actions = MailActions(_store);

  final MailStore _store;
  final MailActions _actions;

  /// Where blocked mail of [accountId] goes, or null if nowhere fits.
  static StoredMailbox? destination(MailStore store, int accountId) =>
      store.mailboxes.bySpecialUse(accountId, SpecialUse.junk) ??
      store.mailboxes.bySpecialUse(accountId, SpecialUse.trash);

  /// Moves blocked inbox mail of [account]; returns how many.
  int apply(Account account) {
    // Address blocks first: the more specific one is reported.
    final blocks = [..._store.blocks.all()]
      ..sort((a, b) => a.kind.index.compareTo(b.kind.index));
    if (blocks.isEmpty) return 0;
    final inbox = _store.mailboxes.inbox(account.id);
    final target = destination(_store, account.id);
    if (inbox == null || target == null || !target.selectable) return 0;

    DateTime start(BlockedSender b) =>
        b.since.subtract(FolderRuleApplier.clockTolerance);
    final earliest = blocks.map(start).reduce((a, b) => a.isBefore(b) ? a : b);

    final moving = <StoredMessage>[];
    for (final message in InboxScan.since(_store, inbox, earliest)) {
      final from = message.from?.address;
      if (from == null) continue;
      final block = blocks.where((b) => b.matches(from)).firstOrNull;
      if (block == null || message.receivedAt.isBefore(start(block))) continue;
      final id = message.messageId;
      if (id != null && _store.folderRules.wasMoved(account.id, id)) continue;
      moving.add(message);
    }
    if (moving.isEmpty) return 0;
    _store.transaction(() {
      _actions.move(moving, target);
      for (final m in moving) {
        if (m.messageId case final id?) {
          _store.folderRules.recordMoved(account.id, id);
        }
      }
    });
    return moving.length;
  }
}
