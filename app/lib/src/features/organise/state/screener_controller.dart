// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:mail_trust/mail_trust.dart';

import '../../../core/state/notice.dart';
import '../../accounts/state/own_addresses.dart';
import '../../inbox/state/message_actions.dart';

/// The Screener: first-time senders waiting, and letting them in or
/// screening them out (one address or everyone at a domain), with Undo.
final class ScreenerController {
  ScreenerController(
    this._store,
    this._mailActions,
    this._actions, {
    required this._refresh,
    required this._notify,
  });

  final MailStore _store;

  /// Moves mail, local first and queued for the server.
  final MailActions _mailActions;
  final MessageActions _actions;

  /// Re-reads the mail screen after a change.
  final VoidCallback _refresh;
  final ShowNotice _notify;

  /// First-time senders waiting in the Screener, in the inbox of
  /// [accountId] (or every inbox).
  List<WaitingSender> waitingSenders({int? accountId}) => _store.screener
      .waiting(accountIds: accountId == null ? null : [accountId]);

  /// Whether [m] comes from someone the Screener would hold back if it
  /// were on: the only email on the device from them, someone the user
  /// never wrote to, and not one of the user's own addresses. False while
  /// the Screener is on (it decides then).
  bool isFirstTimeSender(StoredMessage m) {
    if (_store.screener.enabled) return false;
    final from = m.from?.address.toLowerCase();
    if (from == null || from.isEmpty) return false;
    if (_store.ownAddresses.any((a) => a.toLowerCase() == from)) return false;
    return _store.messages.sortableFrom(from, limit: 2).length <= 1 &&
        !_store.messages.hasWrittenTo(from);
  }

  /// The domain "everyone at …" choices offer for [address]: a company's
  /// own domain, never a free mail provider's or the user's own.
  String? screenerDomain(String address) {
    final lower = address.toLowerCase();
    final domain = Domains.registrable(
      lower.substring(lower.lastIndexOf('@') + 1),
    );
    if (domain == null || FreeMail.isProvider(domain)) return null;
    final own = {
      for (final a in _store.accounts.all())
        ?Domains.registrable(a.email.substring(a.email.lastIndexOf('@') + 1)),
    };
    return own.contains(domain) ? null : domain;
  }

  /// Lets [sender] in (or, with [wholeDomain], everyone at their domain):
  /// their mail goes to the Smart Inbox from now on. Offers Undo.
  void letIn(WaitingSender sender, {bool wholeDomain = false}) =>
      _screen(sender, ScreenerDecision.letIn, wholeDomain: wholeDomain);

  /// Screens [sender] out (or everyone at their domain): their mail goes
  /// where the user chose (Newsletters, Notifications or Archive), never
  /// deleted. Offers Undo.
  void screenOut(WaitingSender sender, {bool wholeDomain = false}) =>
      _screen(sender, ScreenerDecision.screenOut, wholeDomain: wholeDomain);

  void _screen(
    WaitingSender sender,
    ScreenerDecision decision, {
    required bool wholeDomain,
  }) {
    final screener = _store.screener;
    final domain = wholeDomain ? screenerDomain(sender.address) : null;
    final kind = domain == null ? ScreenerKind.address : ScreenerKind.domain;
    final value = domain ?? sender.address;
    final previous = screener.find(kind, value);
    final waiting = waitingSenders();
    final decided = screener.decide(kind, value, decision);
    void undo() => screener.restore(decided, previous);

    final who = domain == null
        ? (sender.name ?? sender.address)
        : 'Everyone at $domain';
    if (decision == ScreenerDecision.letIn) {
      _refresh();
      _notify(
        '$who can now reach your inbox',
        undo: () {
          undo();
          _refresh();
        },
      );
      return;
    }
    final place = screener.outPlace;
    if (place == ScreenOutPlace.archive) {
      // Their waiting mail goes now; later mail with each sync.
      final byAccount = <int, List<StoredMessage>>{};
      for (final w in waiting) {
        if (!decided.matches(w.address)) continue;
        for (final m in w.messages) {
          final archive = _actions.archiveFor(m);
          if (archive != null && archive.id != m.mailboxId) {
            byAccount.putIfAbsent(m.accountId, () => []).add(m);
          }
        }
      }
      final moves = [
        for (final MapEntry(key: accountId, value: group) in byAccount.entries)
          () => _mailActions.move(group, _actions.archiveFolder(accountId)!),
      ];
      if (moves.isNotEmpty) {
        _actions.remove(
          moves,
          '$who screened out. Moved to Archive.',
          alsoUndo: undo,
        );
        return;
      }
    }
    _refresh();
    final where = switch (place) {
      ScreenOutPlace.newsletters => 'Newsletters',
      ScreenOutPlace.notifications => 'Notifications',
      ScreenOutPlace.archive => 'Archive',
    };
    _notify(
      '$who screened out. Their mail goes to $where.',
      undo: () {
        undo();
        _refresh();
      },
    );
  }
}
