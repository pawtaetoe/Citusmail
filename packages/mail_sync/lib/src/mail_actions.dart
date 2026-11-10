// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

/// What an action did, so it can be undone ([MailActions.undo]).
sealed class ActionReceipt {
  const ActionReceipt(this.accountIds);

  /// Accounts whose queue changed (to sync them).
  final Set<int> accountIds;
}

/// Messages left a folder (move, delete). The server change waits until
/// [undoUntil]; undoing cancels it and puts the messages back.
final class RemovalReceipt extends ActionReceipt {
  const RemovalReceipt._(
    super.accountIds,
    this.entryIds,
    this.snapshot,
    this.undoUntil,
    this.snoozes,
  );

  final List<int> entryIds;
  final MessageSnapshot snapshot;
  final DateTime undoUntil;

  /// Snoozes the move or delete ended (put back by undoing it).
  final List<Snooze> snoozes;
}

/// A flag was set or cleared; undoing sets it back.
final class FlagReceipt extends ActionReceipt {
  const FlagReceipt._(
    super.accountIds,
    this.changed,
    this.flag,
    this.bit,
    this.on,
  );

  /// The messages that changed, as they were before.
  final List<StoredMessage> changed;
  final String flag;
  final int bit;
  final bool on;
}

/// What the app does when the user acts on mail. Each action changes the
/// local store at once (so the UI updates immediately, even offline) and
/// queues the same change for the server, in one transaction. Each returns
/// a receipt that [undo] can reverse.
final class MailActions {
  MailActions(this._store, {this.undoWindow = Duration.zero});

  final MailStore _store;

  /// How long moves and deletes wait before reaching the server, so they
  /// can be undone (zero: at the next sync).
  final Duration undoWindow;

  /// The account's Archive folder, if it has one. On Gmail, archiving
  /// means moving to All Mail (the message leaves the inbox, nothing else).
  static StoredMailbox? archiveFolder(MailStore store, int accountId) =>
      store.mailboxes.bySpecialUse(accountId, SpecialUse.archive) ??
      store.mailboxes.bySpecialUse(accountId, SpecialUse.all);

  FlagReceipt markRead(List<StoredMessage> messages, {bool read = true}) =>
      _setFlag(messages, r'\Seen', MessageFlags.seenBit, on: read);

  FlagReceipt markFlagged(
    List<StoredMessage> messages, {
    bool flagged = true,
  }) => _setFlag(messages, r'\Flagged', MessageFlags.flaggedBit, on: flagged);

  /// Reverses [receipt]. Returns false if it is too late (a move or delete
  /// already started on the server).
  bool undo(ActionReceipt receipt) => switch (receipt) {
    RemovalReceipt(:final entryIds, :final snapshot, :final snoozes) =>
      _store.transaction(() {
        if (!_store.outbox.cancel(entryIds)) return false;
        _store.messages.restore(snapshot);
        for (final z in snoozes) {
          _store.snoozes.snooze(z.messageId, z.until); // snoozed again now
        }
        return true;
      }),
    FlagReceipt(:final changed, :final flag, :final bit, :final on) => () {
      final current = [for (final m in changed) ?_store.messages.byId(m.id)];
      _setFlag(current, flag, bit, on: !on);
      return true;
    }(),
  };

  /// Moves messages to [target]. They leave the source list now and appear
  /// in the target after its next sync.
  RemovalReceipt move(List<StoredMessage> messages, StoredMailbox target) =>
      _remove(
        messages,
        (mailbox, group) => MoveAction(
          mailboxId: mailbox.id,
          uidValidity: _validity(mailbox),
          uids: [for (final m in group) m.uid],
          targetMailboxId: target.id,
        ),
        skip: target.id,
        dropCopies:
            target.specialUse == SpecialUse.trash ||
            target.specialUse == SpecialUse.junk,
      );

  /// Deletes messages: to Trash, or for good when already in Trash.
  RemovalReceipt delete(List<StoredMessage> messages) => _remove(
    messages,
    (mailbox, group) => DeleteAction(
      mailboxId: mailbox.id,
      uidValidity: _validity(mailbox),
      uids: [for (final m in group) m.uid],
    ),
    dropCopies: true,
  );

  RemovalReceipt _remove(
    List<StoredMessage> messages,
    UidAction Function(StoredMailbox mailbox, List<StoredMessage> group)
    action, {
    int? skip,
    bool dropCopies = false,
  }) {
    final undoUntil = DateTime.now().add(undoWindow);
    final entries = <int>[];
    final accounts = <int>{};
    final ids = <int>[];
    return _store.transaction(() {
      final groups = [
        for (final (mailbox, group) in _byMailbox(messages))
          if (mailbox.id != skip) (mailbox, group),
      ];
      for (final (_, group) in groups) {
        ids.addAll(group.map((m) => m.id));
      }
      // Mail going to Trash or Spam leaves Gmail's All Mail, Starred and
      // Important on the server; their local copies go now too (only
      // here: the server does it itself), else a copy would stay listed
      // until that folder is opened again. Undo puts them back.
      final copies = dropCopies
          ? _byMailbox(
              _store.messages.copiesOf([
                for (final (_, group) in groups) ...group,
              ]),
            )
          : const <(StoredMailbox, List<StoredMessage>)>[];
      for (final (_, group) in copies) {
        ids.addAll(group.map((m) => m.id));
      }
      final snapshot = _store.messages.snapshot(ids);
      // Moving, archiving or deleting snoozed mail ends its snooze.
      final snoozes = _store.snoozes.cancelFor([
        for (final (_, group) in groups) ...group,
      ]);
      for (final (mailbox, group) in groups) {
        _store.messages.removeUids(mailbox.id, group.map((m) => m.uid));
        entries.add(
          _store.outbox
              .enqueue(
                mailbox.accountId,
                action(mailbox, group),
                notBefore: undoWindow == Duration.zero ? null : undoUntil,
              )
              .id,
        );
        accounts.add(mailbox.accountId);
      }
      for (final (mailbox, group) in copies) {
        _store.messages.removeUids(mailbox.id, group.map((m) => m.uid));
      }
      return RemovalReceipt._(accounts, entries, snapshot, undoUntil, snoozes);
    });
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

  FlagReceipt _setFlag(
    List<StoredMessage> messages,
    String flag,
    int bit, {
    required bool on,
  }) {
    final allChanged = <StoredMessage>[];
    final accounts = <int>{};
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
      allChanged.addAll(changed);
      accounts.add(mailbox.accountId);
    }
    return FlagReceipt._(accounts, allChanged, flag, bit, on);
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
