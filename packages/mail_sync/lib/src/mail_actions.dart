// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

/// What the app does when the user acts on mail. Each action changes the
/// local store at once (so the UI updates immediately, even offline) and
/// queues the same change for the server, in one transaction.
final class MailActions {
  MailActions(this._store);

  final MailStore _store;

  void markRead(List<StoredMessage> messages, {bool read = true}) =>
      _setFlag(messages, r'\Seen', MessageFlags.seenBit, on: read);

  void markFlagged(List<StoredMessage> messages, {bool flagged = true}) =>
      _setFlag(messages, r'\Flagged', MessageFlags.flaggedBit, on: flagged);

  /// Moves messages to [target]. They leave the source list now and appear
  /// in the target after its next sync.
  void move(List<StoredMessage> messages, StoredMailbox target) {
    for (final (mailbox, group) in _byMailbox(messages)) {
      if (mailbox.id == target.id) continue;
      _store.transaction(() {
        _store.messages.removeUids(mailbox.id, group.map((m) => m.uid));
        _store.outbox.enqueue(
          mailbox.accountId,
          MoveAction(
            mailboxId: mailbox.id,
            uidValidity: _validity(mailbox),
            uids: [for (final m in group) m.uid],
            targetMailboxId: target.id,
          ),
        );
      });
    }
  }

  /// Deletes messages: to Trash, or for good when already in Trash.
  void delete(List<StoredMessage> messages) {
    for (final (mailbox, group) in _byMailbox(messages)) {
      _store.transaction(() {
        _store.messages.removeUids(mailbox.id, group.map((m) => m.uid));
        _store.outbox.enqueue(
          mailbox.accountId,
          DeleteAction(
            mailboxId: mailbox.id,
            uidValidity: _validity(mailbox),
            uids: [for (final m in group) m.uid],
          ),
        );
      });
    }
  }

  /// Queues a built message for sending; it is saved to the account's Sent
  /// folder after the server accepts it.
  OutboxEntry send(Account account, BuiltMessage message) {
    final sent = _store.mailboxes.bySpecialUse(account.id, SpecialUse.sent);
    return _store.outbox.enqueue(
      account.id,
      SendAction(
        from: account.email,
        recipients: [for (final r in message.recipients) r.address],
        sentMailboxId: sent?.id,
      ),
      data: message.bytes,
    );
  }

  // ---------------------------------------------------------------------

  void _setFlag(
    List<StoredMessage> messages,
    String flag,
    int bit, {
    required bool on,
  }) {
    for (final (mailbox, group) in _byMailbox(messages)) {
      final changed = [
        for (final m in group)
          if (m.flags.withBit(bit, on) != m.flags) m,
      ];
      if (changed.isEmpty) continue;
      _store.transaction(() {
        _store.messages.updateFlags(mailbox.id, [
          for (final m in changed)
            (uid: m.uid, flags: m.flags.withBit(bit, on), modSeq: null),
        ]);
        _store.outbox.enqueue(
          mailbox.accountId,
          SetFlagsAction(
            mailboxId: mailbox.id,
            uidValidity: _validity(mailbox),
            uids: [for (final m in changed) m.uid],
            add: on ? [flag] : const [],
            remove: on ? const [] : [flag],
          ),
        );
      });
    }
  }

  List<(StoredMailbox, List<StoredMessage>)> _byMailbox(
    List<StoredMessage> messages,
  ) {
    final groups = <int, List<StoredMessage>>{};
    for (final m in messages) {
      groups.putIfAbsent(m.mailboxId, () => []).add(m);
    }
    return [
      for (final MapEntry(key: id, value: group) in groups.entries)
        if (_store.mailboxes.byId(id) case final mailbox?) (mailbox, group),
    ];
  }

  static int _validity(StoredMailbox mailbox) =>
      mailbox.syncState.uidValidity ??
      (throw StateError('${mailbox.name} has not been synchronised yet'));
}
