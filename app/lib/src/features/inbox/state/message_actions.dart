// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import '../../../core/state/notice.dart';
import '../../../services/app_services.dart';
import '../../organise/state/folder_controller.dart';
import '../../reader/state/reader_controller.dart';
import 'location_controller.dart';
import 'message_list_model.dart';
import 'selection_controller.dart';

/// What the user does to messages: pin, read, archive, move, delete and
/// "Not spam", each with Undo. Moves leave the list the same way for
/// everyone ([remove]): the selection ends and, if the open message
/// left, the next one opens.
final class MessageActions {
  MessageActions(
    this._services,
    this._list,
    this._location,
    this._selection,
    this._reader, {
    required this._refresh,
    required this._notify,
  });

  final AppServices _services;
  final MessageListModel _list;
  final LocationController _location;
  final SelectionController _selection;
  final ReaderController _reader;

  /// Re-reads the mail screen after a change.
  final VoidCallback _refresh;
  final ShowNotice _notify;

  MailStore get _store => _services.store;

  void togglePin(List<StoredMessage> messages) {
    if (messages.isEmpty) return;
    final on = !messages.every((m) => m.flags.flagged);
    final receipt = _services.actions.markFlagged(messages, flagged: on);
    _afterFlags(receipt, on ? 'Pinned' : 'Unpinned', messages.length);
  }

  void toggleRead(List<StoredMessage> messages) {
    if (messages.isEmpty) return;
    final read = !messages.every((m) => m.flags.seen);
    final receipt = _services.actions.markRead(messages, read: read);
    _afterFlags(
      receipt,
      read ? 'Marked as read' : 'Marked as unread',
      messages.length,
    );
  }

  void markSectionRead(SmartSection section) {
    final accountId = _location.location.value.accountId;
    final unread = [
      for (final m in _store.messages.list(
        MessageQuery(
          inboxesOnly: true,
          accountIds: accountId == null ? null : [accountId],
          section: section,
          unreadOnly: true,
          limit: 500,
        ),
      ))
        // Shown in "New since you were away" instead.
        if (!_list.isAway(m)) m,
    ];
    markAllRead(unread);
  }

  /// Marks [unread] as read, always with Undo ("Mark all as read").
  void markAllRead(List<StoredMessage> unread) {
    if (unread.isEmpty) return;
    final receipt = _services.actions.markRead(unread);
    _afterFlags(receipt, 'Marked as read', unread.length, alwaysUndo: true);
  }

  void _afterFlags(
    FlagReceipt receipt,
    String done,
    int count, {
    bool alwaysUndo = false,
  }) {
    for (final id in receipt.accountIds) {
      _services.worker.requestSync(id);
    }
    _selection.clear();
    _refresh();
    if (count > 1 || alwaysUndo) {
      _notify(
        '$done ($count)',
        undo: () {
          _services.actions.undo(receipt);
          _refresh();
        },
      );
    }
  }

  /// The account's Archive folder, if it has one. On Gmail, archiving
  /// means moving to All Mail (the message leaves the inbox, nothing else).
  StoredMailbox? archiveFor(StoredMessage m) => archiveFolder(m.accountId);

  /// The Archive folder of [accountId], if it has one.
  StoredMailbox? archiveFolder(AccountId accountId) =>
      MailActions.archiveFolder(_store, accountId);

  bool isInTrash(StoredMessage m) =>
      _store.mailboxes.byId(m.mailboxId)?.specialUse == SpecialUse.trash;

  /// Whether deleting [m] removes it for good: it is in Trash, or its
  /// account has no Trash folder (the server then deletes it at once).
  bool deletesForever(StoredMessage m) =>
      isInTrash(m) ||
      _store.mailboxes.bySpecialUse(m.accountId, SpecialUse.trash) == null;

  bool isInJunk(StoredMessage m) =>
      _store.mailboxes.byId(m.mailboxId)?.specialUse == SpecialUse.junk;

  /// "Not spam": back to each account's inbox. Moving mail out of Spam is
  /// how Gmail and other providers learn it isn't spam.
  void notSpam(List<StoredMessage> messages) {
    final byAccount = <AccountId, List<StoredMessage>>{};
    for (final m in messages) {
      if (isInJunk(m)) byAccount.putIfAbsent(m.accountId, () => []).add(m);
    }
    final moves = [
      for (final MapEntry(key: accountId, value: group) in byAccount.entries)
        if (_store.mailboxes.inbox(accountId) case final inbox?)
          () => _services.actions.move(group, inbox),
    ];
    if (moves.isEmpty) return;
    final count = byAccount.values.fold(0, (sum, g) => sum + g.length);
    remove(
      moves,
      count == 1
          ? 'Not spam. Moved to Inbox.'
          : 'Not spam. Moved $count to Inbox.',
    );
  }

  /// Archives into each account's Archive folder (skipping messages already
  /// there or in accounts without one).
  void archive(List<StoredMessage> messages, {String? done}) {
    final byAccount = <AccountId, List<StoredMessage>>{};
    for (final m in messages) {
      final archive = archiveFor(m);
      if (archive != null && archive.id != m.mailboxId) {
        byAccount.putIfAbsent(m.accountId, () => []).add(m);
      }
    }
    if (byAccount.isEmpty) {
      _notify('There is no Archive folder for this account.');
      return;
    }
    final count = byAccount.values.fold(0, (sum, g) => sum + g.length);
    remove([
      for (final MapEntry(key: accountId, value: group) in byAccount.entries)
        () => _services.actions.move(group, archiveFolder(accountId)!),
    ], done ?? (count == 1 ? 'Archived' : 'Archived $count'));
  }

  void moveTo(List<StoredMessage> messages, StoredMailbox target) => remove([
    () => _services.actions.move(messages, target),
  ], 'Moved to ${_folderName(target)}');

  /// Moves to Trash (or deletes for good when already in Trash, or the
  /// account has none; the caller confirms that).
  void delete(List<StoredMessage> messages) => remove(
    [() => _services.actions.delete(messages)],
    messages.every(deletesForever)
        ? 'Deleted'
        : (messages.length == 1
              ? 'Moved to Trash'
              : 'Moved ${messages.length} to Trash'),
  );

  /// "Always move mail from this sender here", then moves this message.
  void moveAlways(StoredMessage message, StoredMailbox target) {
    final from = message.from?.address;
    if (from != null && FolderController.canHaveRules(target)) {
      try {
        _store.folderRules.add(
          accountId: target.accountId,
          mailboxId: target.id,
          field: RuleField.fromAddress,
          value: from,
        );
      } on ArgumentError {
        // An address a rule can't hold: just move this one.
      }
    }
    moveTo([message], target);
  }

  /// Removes messages from the list with [changes], opens the next message
  /// if the open one left, and offers Undo for a few seconds ([alsoUndo]
  /// reverses anything else the action did).
  void remove(
    List<RemovalReceipt Function()> changes,
    String done, {
    VoidCallback? alsoUndo,
  }) {
    final open = _reader.selected;
    final visible = _list.visible;
    final receipts = [for (final change in changes) change()];
    final removedIds = {
      for (final r in receipts)
        for (final row in r.snapshot.messages) MessageId(row['id']! as int),
    };
    for (final receipt in receipts) {
      for (final id in receipt.accountIds) {
        _services.worker.syncAt(id, receipt.undoUntil);
      }
    }
    _selection.clear();
    leaveList(open, visible, removedIds);
    _notify(
      done,
      undo: () {
        alsoUndo?.call();
        final undone = receipts.every(_services.actions.undo);
        _refresh();
        if (!undone) {
          _notify('Too late to undo: the change reached the server.');
        }
      },
    );
  }

  /// After [removedIds] left the list: refreshes, and if [open] was one
  /// of them, opens the next message (or the one before). [visible] is
  /// the list as it was before.
  void leaveList(
    StoredMessage? open,
    List<StoredMessage> visible,
    Set<MessageId> removedIds,
  ) {
    StoredMessage? next;
    if (open != null && removedIds.contains(open.id)) {
      final index = visible.indexWhere((m) => m.id == open.id);
      next = [
        ...visible.skip(index + 1),
        ...visible.take(index < 0 ? 0 : index).toList().reversed,
      ].where((m) => !removedIds.contains(m.id)).firstOrNull;
      _reader.close();
    }
    _refresh();
    if (next != null) unawaited(_reader.open(next));
  }

  static String _folderName(StoredMailbox m) =>
      m.isInbox ? 'Inbox' : m.name.split(m.delimiter ?? '/').last;
}
