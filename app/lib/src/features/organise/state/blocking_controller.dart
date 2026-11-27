// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:mail_trust/mail_trust.dart';

import '../../../core/state/notice.dart';
import '../../inbox/state/message_actions.dart';
import '../../reader/state/reader_controller.dart';

/// How a sender can be blocked.
final class BlockChoice {
  const BlockChoice({
    required this.address,
    required this.domain,
    required this.fromAddress,
    required this.fromDomain,
  });

  final String address;

  /// The sender's domain, or null when blocking it would make no sense (a
  /// free mail service, or the user's own domain).
  final String? domain;

  /// Messages in the inboxes from the address, and from the domain.
  final int fromAddress;
  final int fromDomain;
}

/// Blocking senders (their mail goes to Junk) and unblocking them, with
/// Undo.
final class BlockingController {
  BlockingController(
    this._store,
    this._mailActions,
    this._actions,
    this._reader, {
    required this._notify,
  });

  final MailStore _store;

  /// Moves mail, local first and queued for the server.
  final MailActions _mailActions;
  final MessageActions _actions;
  final ReaderController _reader;
  final ShowNotice _notify;

  /// The block that applies to [message]'s sender, if any.
  BlockedSender? blockFor(StoredMessage message) =>
      _store.blocks.matching(message.from?.address);

  /// Whether [message]'s sender can be blocked: it has one, and it isn't
  /// one of the user's own addresses. Cheap enough for a toolbar.
  bool canBlock(StoredMessage message) {
    final address = message.from?.address.toLowerCase();
    if (address == null || !address.contains('@')) return false;
    return !_store.accounts.all().any((a) => a.email.toLowerCase() == address);
  }

  /// How [message]'s sender can be blocked, with how much mail each
  /// choice would move; null if it can't be blocked.
  BlockChoice? blockChoice(StoredMessage message) {
    if (!canBlock(message)) return null;
    final address = message.from!.address.toLowerCase();
    final own = _store.accounts.all();
    final domain = Domains.registrable(
      address.substring(address.lastIndexOf('@') + 1),
    );
    final ownDomains = {
      for (final a in own)
        ?Domains.registrable(a.email.substring(a.email.lastIndexOf('@') + 1)),
    };
    final usableDomain =
        domain != null &&
        !FreeMail.isProvider(domain) &&
        !ownDomains.contains(domain);
    return BlockChoice(
      address: address,
      domain: usableDomain ? domain : null,
      fromAddress: _inboxesFrom(BlockKind.address, address).length,
      fromDomain: usableDomain
          ? _inboxesFrom(BlockKind.domain, domain).length
          : 0,
    );
  }

  List<StoredMessage> _inboxesFrom(BlockKind kind, String value) => [
    for (final account in _store.accounts.all())
      ...switch (kind) {
        BlockKind.address => _store.messages.inboxFromList(
          account.id,
          fromAddress: value,
        ),
        BlockKind.domain => _store.messages.inboxFromDomain(account.id, value),
      },
  ];

  /// Blocks [value]: new mail from it goes to Junk. With [moveExisting],
  /// its mail already in the inboxes goes too. Undo reverses both.
  void block(BlockKind kind, String value, {bool moveExisting = true}) {
    final existing = _store.blocks.all().any(
      (b) => b.kind == kind && b.value == value.toLowerCase(),
    );
    final blocked = _store.blocks.block(kind, value);
    void unblock() {
      if (!existing) _store.blocks.unblock(blocked.id);
      _reader.refreshOpen();
    }

    final name = kind == BlockKind.domain
        ? 'everyone at ${blocked.value}'
        : blocked.value;
    final byAccount = <AccountId, List<StoredMessage>>{};
    if (moveExisting) {
      for (final m in _inboxesFrom(kind, blocked.value)) {
        byAccount.putIfAbsent(m.accountId, () => []).add(m);
      }
    }
    final moves = [
      for (final MapEntry(key: accountId, value: messages) in byAccount.entries)
        if (SenderBlocker.destination(_store, accountId) case final target?)
          () => _mailActions.move(messages, target),
    ];
    if (moves.isEmpty) {
      _reader.refreshOpen();
      _notify('Blocked $name', undo: unblock);
      return;
    }
    final count = byAccount.values.fold(0, (sum, l) => sum + l.length);
    _actions.remove(
      moves,
      'Blocked $name. Moved $count to Junk.',
      alsoUndo: unblock,
    );
  }

  void unblock(BlockedSender block) {
    _store.blocks.unblock(block.id);
    _reader.refreshOpen();
    _notify(
      'Unblocked ${block.kind == BlockKind.domain ? 'everyone at ' : ''}${block.value}',
    );
  }
}
