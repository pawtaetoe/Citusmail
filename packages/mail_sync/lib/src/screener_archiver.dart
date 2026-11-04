// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_store/mail_store.dart';

import 'folder_rules.dart';
import 'mail_actions.dart';

/// When the user chose "Screened-out mail goes to Archive": moves new
/// inbox mail from screened-out senders to the account's Archive folder,
/// through the outbox, like the Archive button. Without that choice the
/// Screener changes nothing on the server.
///
/// Like blocked senders, only mail received since the decision moves
/// (with [FolderRuleApplier]'s clock tolerance), and a message is never
/// moved twice (by Message-ID), so mail the user brings back stays.
/// Pinned mail, codes and replies to the user stay (see
/// [ScreenerRepository.screenedOutIds]).
final class ScreenerArchiver {
  ScreenerArchiver(this._store) : _actions = MailActions(_store);

  final MailStore _store;
  final MailActions _actions;

  /// Moves screened-out inbox mail of [account]; returns how many.
  int apply(Account account) {
    final screener = _store.screener;
    if (!screener.enabled || screener.outPlace != ScreenOutPlace.archive) {
      return 0;
    }
    final out = [
      for (final s in screener.all())
        if (s.decision == ScreenerDecision.screenOut) s,
    ];
    if (out.isEmpty) return 0;
    final inbox = _store.mailboxes.inbox(account.id);
    final target = MailActions.archiveFolder(_store, account.id);
    if (inbox == null || target == null || !target.selectable) return 0;
    if (target.id == inbox.id) return 0;

    DateTime start(ScreenedSender s) =>
        s.since.subtract(FolderRuleApplier.clockTolerance);
    final earliest = out.map(start).reduce((a, b) => a.isBefore(b) ? a : b);

    final moving = <StoredMessage>[];
    for (final id in screener.screenedOutIds(inbox.id, earliest)) {
      final message = _store.messages.byId(id);
      final decision = screener.matching(message?.from?.address);
      if (message == null || decision == null) continue;
      if (message.receivedAt.isBefore(start(decision))) continue;
      final messageId = message.messageId;
      if (messageId == null ||
          _store.folderRules.wasMoved(account.id, messageId)) {
        continue;
      }
      moving.add(message);
    }
    if (moving.isEmpty) return 0;
    _store.transaction(() {
      _actions.move(moving, target);
      for (final m in moving) {
        _store.folderRules.recordMoved(account.id, m.messageId!);
      }
    });
    return moving.length;
  }
}
