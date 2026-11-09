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
/// [ScreenerRepository.screenedOutIds]). Each pass looks only at mail
/// that arrived since the last one, unless the Screener's decisions or
/// settings changed ([InboxPass]).
final class ScreenerArchiver {
  ScreenerArchiver(this._store) : _actions = MailActions(_store);

  final MailStore _store;
  final MailActions _actions;

  /// Moves screened-out inbox mail of [account]; returns how many. With
  /// [everything], every message since the oldest decision is looked at.
  int apply(Account account, {bool everything = false}) {
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
    var earliest = out.map(start).reduce((a, b) => a.isBefore(b) ? a : b);

    final pass = InboxPass.start(
      _store,
      'screener',
      inbox,
      InboxPass.digest([
        target.id,
        for (final s in out)
          [s.id, s.kind.name, s.value, s.since.millisecondsSinceEpoch],
      ]),
      everything: everything,
    );
    // Only the new mail, unless everything is looked at: the query then
    // covers just the time since the oldest of it.
    Set<int>? only;
    if (!pass.everything) {
      final fresh = pass.messages(earliest).toList();
      if (fresh.isEmpty) {
        pass.finish();
        return 0;
      }
      only = {for (final m in fresh) m.id};
      final oldest = fresh
          .map((m) => m.receivedAt)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      if (oldest.isAfter(earliest)) earliest = oldest;
    }

    final moving = <StoredMessage>[];
    for (final id in screener.screenedOutIds(inbox.id, earliest)) {
      if (only != null && !only.contains(id)) continue;
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
    if (moving.isNotEmpty) {
      _store.transaction(() {
        _actions.move(moving, target);
        for (final m in moving) {
          _store.folderRules.recordMoved(account.id, m.messageId!);
        }
      });
    }
    pass.finish();
    return moving.length;
  }
}
