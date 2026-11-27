// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import '../../../core/state/notice.dart';
import '../../../core/text/numbers.dart';
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

  /// While an action on thousands of messages runs in steps: what it is
  /// doing and how far it got ("Moving to Trash… 2,400 of 7,080"), for a
  /// notice that updates in place; null otherwise.
  final working = ValueNotifier<String?>(null);

  MailActions get _mail => _services.actions;

  void togglePin(List<StoredMessage> messages) {
    if (messages.isEmpty) return;
    final on = !messages.every((m) => m.flags.flagged);
    _changeFlags(
      messages,
      pin: true,
      on: on,
      done: on ? 'Pinned' : 'Unpinned',
      doing: on ? 'Pinning' : 'Unpinning',
    );
  }

  void toggleRead(List<StoredMessage> messages) {
    if (messages.isEmpty) return;
    final read = !messages.every((m) => m.flags.seen);
    _changeFlags(
      messages,
      pin: false,
      on: read,
      done: read ? 'Marked as read' : 'Marked as unread',
      doing: read ? 'Marking as read' : 'Marking as unread',
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
    _changeFlags(
      unread,
      pin: false,
      on: true,
      done: 'Marked as read',
      doing: 'Marking as read',
      alwaysUndo: true,
    );
  }

  /// Pins ([pin]) or marks read, or the opposite when not [on]: at once,
  /// or in steps for more than [MailActions.stepsAbove] messages.
  void _changeFlags(
    List<StoredMessage> messages, {
    required bool pin,
    required bool on,
    required String done,
    required String doing,
    bool alwaysUndo = false,
  }) {
    if (messages.length <= MailActions.stepsAbove) {
      final receipt = pin
          ? _mail.markFlagged(messages, flagged: on)
          : _mail.markRead(messages, read: on);
      _afterFlags(receipt, done, messages.length, alwaysUndo: alwaysUndo);
      return;
    }
    _selection.clear();
    unawaited(() async {
      final receipt = await _inSteps(
        doing,
        messages.length,
        (progress) => pin
            ? _mail.markFlaggedInSteps(
                messages,
                flagged: on,
                progress: progress,
              )
            : _mail.markReadInSteps(messages, read: on, progress: progress),
      );
      _afterFlags(receipt, done, messages.length, alwaysUndo: alwaysUndo);
    }());
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
        '$done (${grouped(count)})',
        undo: () {
          if (count <= MailActions.stepsAbove) {
            _mail.undo(receipt);
            _refresh();
            return;
          }
          unawaited(() async {
            await _inSteps(
              'Undoing',
              receipt.changed.length,
              (progress) => _mail.undoInSteps(receipt, progress: progress),
            );
            for (final id in receipt.accountIds) {
              _services.worker.requestSync(id);
            }
            _refresh();
          }());
        },
      );
    }
  }

  /// Runs an action in steps, saying what it does and how far it got in
  /// [working] ("[doing]… 2,400 of 7,080").
  Future<T> _inSteps<T>(
    String doing,
    int total,
    Future<T> Function(StepProgress progress) run,
  ) async {
    String text(int done) => '$doing… ${grouped(done)} of ${grouped(total)}';
    working.value = text(0);
    try {
      return await run((done, _) => working.value = text(done));
    } finally {
      working.value = null;
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
    final moves = <Removal>[
      for (final MapEntry(key: accountId, value: group) in byAccount.entries)
        if (_store.mailboxes.inbox(accountId) case final inbox?)
          (messages: group, target: inbox),
    ];
    if (moves.isEmpty) return;
    final count = byAccount.values.fold(0, (sum, g) => sum + g.length);
    remove(
      moves,
      count == 1
          ? 'Not spam. Moved to Inbox.'
          : 'Not spam. Moved ${grouped(count)} to Inbox.',
      doing: 'Moving to Inbox',
    );
  }

  /// Archives into each account's Archive folder (skipping messages already
  /// there or in accounts without one).
  void archive(List<StoredMessage> messages, {String? done}) {
    final byAccount = <AccountId, List<StoredMessage>>{};
    var alreadyArchived = 0;
    for (final m in messages) {
      final archive = archiveFor(m);
      if (archive == null) continue;
      if (archive.id == m.mailboxId) {
        alreadyArchived++;
      } else {
        byAccount.putIfAbsent(m.accountId, () => []).add(m);
      }
    }
    if (byAccount.isEmpty) {
      _notify(
        alreadyArchived > 0
            ? 'Already in Archive.'
            : 'There is no Archive folder for this account.',
      );
      return;
    }
    final count = byAccount.values.fold(0, (sum, g) => sum + g.length);
    remove(
      [
        for (final MapEntry(key: accountId, value: group) in byAccount.entries)
          (messages: group, target: archiveFolder(accountId)!),
      ],
      done ?? (count == 1 ? 'Archived' : 'Archived ${grouped(count)}'),
      doing: 'Archiving',
    );
  }

  void moveTo(List<StoredMessage> messages, StoredMailbox target) => remove(
    [(messages: messages, target: target)],
    'Moved to ${_folderName(target)}',
    doing: 'Moving to ${_folderName(target)}',
  );

  /// Moves to Trash (or deletes for good when already in Trash, or the
  /// account has none; the caller confirms that).
  void delete(List<StoredMessage> messages) {
    final forever = messages.every(deletesForever);
    remove(
      [(messages: messages, target: null)],
      forever
          ? 'Deleted'
          : (messages.length == 1
                ? 'Moved to Trash'
                : 'Moved ${grouped(messages.length)} to Trash'),
      doing: forever ? 'Deleting' : 'Moving to Trash',
    );
  }

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

  /// Removes messages from the list with [removals] (moves, or deletes
  /// where the target is null), opens the next message if the open one
  /// left, and offers Undo for a few seconds ([alsoUndo] reverses
  /// anything else the action did). More than [MailActions.stepsAbove]
  /// messages go in steps, saying how far they got ([doing], in
  /// [working]), so the app keeps drawing; Undo then goes in steps too.
  void remove(
    List<Removal> removals,
    String done, {
    VoidCallback? alsoUndo,
    String doing = 'Moving',
  }) {
    final open = _reader.selected;
    final visible = _list.visible;
    final total = removals.fold(0, (sum, r) => sum + r.messages.length);
    if (total <= MailActions.stepsAbove) {
      final receipts = [
        for (final r in removals)
          switch (r.target) {
            final target? => _mail.move(r.messages, target),
            null => _mail.delete(r.messages),
          },
      ];
      _afterRemoval(receipts, open, visible, done, alsoUndo, inSteps: false);
      return;
    }
    _selection.clear();
    unawaited(() async {
      final receipts = await _inSteps(
        doing,
        total,
        (progress) => _mail.removeInSteps(removals, progress: progress),
      );
      _afterRemoval(receipts, open, visible, done, alsoUndo, inSteps: true);
    }());
  }

  void _afterRemoval(
    List<RemovalReceipt> receipts,
    StoredMessage? open,
    List<StoredMessage> visible,
    String done,
    VoidCallback? alsoUndo, {
    required bool inSteps,
  }) {
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
    void undone(bool all) {
      _refresh();
      if (!all) _notify('Too late to undo: the change reached the server.');
    }

    _notify(
      done,
      undo: () {
        alsoUndo?.call();
        if (!inSteps) return undone(receipts.every(_mail.undo));
        unawaited(() async {
          var all = true;
          final count = receipts.fold(
            0,
            (sum, r) => sum + r.snapshot.messages.length,
          );
          await _inSteps('Putting back', count, (progress) async {
            var before = 0;
            for (final r in receipts) {
              final back = await _mail.undoInSteps(
                r,
                progress: (d, _) => progress(before + d, count),
              );
              if (!back) all = false;
              before += r.snapshot.messages.length;
            }
          });
          undone(all);
        }());
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
