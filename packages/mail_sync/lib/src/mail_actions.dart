// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

/// What an action did, so it can be undone ([MailActions.undo]).
sealed class ActionReceipt {
  const ActionReceipt(this.accountIds);

  /// Accounts whose queue changed (to sync them).
  final Set<AccountId> accountIds;
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

/// How far an action done in steps has got: [done] of [total] messages.
typedef StepProgress = void Function(int done, int total);

/// [messages] to move to [target], or to delete when it is null (see
/// [MailActions.removeInSteps]).
typedef Removal = ({List<StoredMessage> messages, StoredMailbox? target});

/// What the app does when the user acts on mail. Each action changes the
/// local store at once (so the UI updates immediately, even offline) and
/// queues the same change for the server, in one transaction. Each returns
/// a receipt that [undo] can reverse.
///
/// For thousands of messages (a sender's whole history, a big folder
/// selected) the same actions run in steps ([moveInSteps],
/// [deleteInSteps], [markReadInSteps], [undoInSteps]): a few dozen to a
/// few hundred messages per transaction, sized to take about [stepTime],
/// with the event loop free in between so the UI keeps drawing. They
/// still queue one server change per folder, and return one receipt.
final class MailActions {
  MailActions(
    this._store, {
    this.undoWindow = Duration.zero,
    this.stepTime = const Duration(milliseconds: 8),
    this.stepSize,
  }) : assert(stepSize == null || stepSize > 0);

  final MailStore _store;

  /// How long moves and deletes wait before reaching the server, so they
  /// can be undone (zero: at the next sync).
  final Duration undoWindow;

  /// About how long one step of an action done in steps keeps the store
  /// busy: the steps grow or shrink to take this long.
  final Duration stepTime;

  /// A fixed number of messages per step instead of [stepTime] (tests).
  final int? stepSize;

  /// Above this many messages, the app does an action in steps.
  static const stepsAbove = 200;

  /// The fewest and the most messages in one step.
  static const smallestStep = 20, largestStep = 500;

  /// The first step's size, before its time is known.
  static const _firstStep = 50;

  /// While an action in steps runs, its queued server changes wait at
  /// least this much longer than the undo window: the queue entries grow
  /// with each step, so the sync worker must not replay them meanwhile.
  /// If the app stops half way, the part done reaches the server then.
  static const holdDuringSteps = Duration(minutes: 1);

  /// The account's Archive folder, if it has one. On Gmail, archiving
  /// means moving to All Mail (the message leaves the inbox, nothing else).
  static StoredMailbox? archiveFolder(MailStore store, AccountId accountId) =>
      store.mailboxes.bySpecialUse(accountId, SpecialUse.archive) ??
      store.mailboxes.bySpecialUse(accountId, SpecialUse.all);

  FlagReceipt markRead(List<StoredMessage> messages, {bool read = true}) =>
      _setFlag(messages, r'\Seen', MessageFlags.seenBit, on: read);

  FlagReceipt markFlagged(
    List<StoredMessage> messages, {
    bool flagged = true,
  }) => _setFlag(messages, r'\Flagged', MessageFlags.flaggedBit, on: flagged);

  /// [markRead] in steps, for thousands of messages.
  Future<FlagReceipt> markReadInSteps(
    List<StoredMessage> messages, {
    bool read = true,
    StepProgress? progress,
  }) => _setFlagInSteps(
    messages,
    r'\Seen',
    MessageFlags.seenBit,
    on: read,
    progress: progress,
  );

  /// [markFlagged] in steps, for thousands of messages.
  Future<FlagReceipt> markFlaggedInSteps(
    List<StoredMessage> messages, {
    bool flagged = true,
    StepProgress? progress,
  }) => _setFlagInSteps(
    messages,
    r'\Flagged',
    MessageFlags.flaggedBit,
    on: flagged,
    progress: progress,
  );

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

  /// [undo] in steps, for a receipt of thousands of messages. The server
  /// changes are cancelled first, all at once (or none: false, too
  /// late); then the messages come back a step at a time.
  Future<bool> undoInSteps(
    ActionReceipt receipt, {
    StepProgress? progress,
  }) async {
    switch (receipt) {
      case RemovalReceipt(:final entryIds, :final snapshot, :final snoozes):
        if (!_store.outbox.cancel(entryIds)) return false;
        // Each message with its own rows; a step puts back several. Should
        // the app stop half way, the server still has the rest, and they
        // come back with the next sync.
        await _inSteps(
          snapshot.split(1),
          (parts) => _store.transaction(
            () => _store.messages.restore(MessageSnapshot.join(parts)),
          ),
          progress,
        );
        _store.transaction(() {
          for (final z in snoozes) {
            _store.snoozes.snooze(z.messageId, z.until);
          }
        });
        return true;
      case FlagReceipt(:final changed, :final flag, :final bit, :final on):
        await _setFlagInSteps(
          changed,
          flag,
          bit,
          on: !on,
          progress: progress,
          readAgain: true,
        );
        return true;
    }
  }

  /// Moves messages to [target]. They leave the source list now and appear
  /// in the target after its next sync.
  RemovalReceipt move(List<StoredMessage> messages, StoredMailbox target) {
    final now = DateTime.now();
    final removal = _Removal.move(this, target)
      ..step(messages, notBefore: _undoUntil(now));
    return removal.receipt(now);
  }

  /// Deletes messages: to Trash, or for good when already in Trash.
  RemovalReceipt delete(List<StoredMessage> messages) {
    final now = DateTime.now();
    final removal = _Removal.delete(this)
      ..step(messages, notBefore: _undoUntil(now));
    return removal.receipt(now);
  }

  /// [move] in steps, for thousands of messages: one queued move per
  /// folder all the same, one receipt, and the undo window starts when
  /// the last step is done.
  Future<RemovalReceipt> moveInSteps(
    List<StoredMessage> messages,
    StoredMailbox target, {
    StepProgress? progress,
  }) async => (await removeInSteps([
    (messages: messages, target: target),
  ], progress: progress)).single;

  /// [delete] in steps, for thousands of messages (see [moveInSteps]).
  Future<RemovalReceipt> deleteInSteps(
    List<StoredMessage> messages, {
    StepProgress? progress,
  }) async => (await removeInSteps([
    (messages: messages, target: null),
  ], progress: progress)).single;

  /// Several moves and deletes in steps as one action (archiving mail of
  /// several accounts, each to its own Archive): every queued change is
  /// held until the last step of the last one, and the undo window
  /// starts then for all. One receipt per removal, in order; [progress]
  /// counts the messages of all of them.
  Future<List<RemovalReceipt>> removeInSteps(
    List<Removal> removals, {
    StepProgress? progress,
  }) async {
    final total = removals.fold(0, (sum, r) => sum + r.messages.length);
    final started = <_Removal>[];
    late final DateTime end;
    try {
      var before = 0;
      for (final r in removals) {
        final removal = switch (r.target) {
          final target? => _Removal.move(this, target),
          null => _Removal.delete(this),
        };
        started.add(removal);
        await _inSteps(
          r.messages,
          (step) {
            final hold = DateTime.now().add(undoWindow + holdDuringSteps);
            removal.step(step, notBefore: hold);
            for (final earlier in started) {
              if (earlier != removal) earlier.queue.hold(hold);
            }
          },
          progress == null ? null : (done, _) => progress(before + done, total),
        );
        before += r.messages.length;
      }
    } finally {
      // Done (or stopped by an error): what was removed goes to the
      // server after the undo window.
      end = DateTime.now();
      for (final removal in started) {
        removal.queue.release(_undoUntil(end));
      }
    }
    return [for (final removal in started) removal.receipt(end)];
  }

  DateTime? _undoUntil(DateTime now) =>
      undoWindow == Duration.zero ? null : now.add(undoWindow);

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

  /// Runs [work] on [items] a step at a time, each step sized to take
  /// about [stepTime] (or [stepSize] items), and lets the event loop run
  /// between steps: timers, input and frames. The first step runs before
  /// this returns its future.
  Future<void> _inSteps<T>(
    List<T> items,
    void Function(List<T> step) work,
    StepProgress? progress,
  ) async {
    var size = stepSize ?? _firstStep;
    var done = 0;
    final watch = Stopwatch();
    while (done < items.length) {
      final end = min(done + size, items.length);
      watch
        ..reset()
        ..start();
      work(items.sublist(done, end));
      watch.stop();
      done = end;
      progress?.call(done, items.length);
      if (stepSize == null) size = _nextStep(size, watch.elapsedMicroseconds);
      if (done < items.length) await Future<void>.delayed(Duration.zero);
    }
  }

  /// The size of the next step after one of [size] took [micros]: about
  /// [stepTime], changing at most by half or double at a time.
  int _nextStep(int size, int micros) {
    final wanted = micros <= 0
        ? size * 2
        : size * stepTime.inMicroseconds ~/ micros;
    return wanted.clamp(
      max(smallestStep, size ~/ 2),
      max(smallestStep, min(largestStep, size * 2)),
    );
  }

  FlagReceipt _setFlag(
    List<StoredMessage> messages,
    String flag,
    int bit, {
    required bool on,
  }) {
    final change = _FlagChange(this, flag, bit, on: on)
      ..step(messages, notBefore: null);
    return change.receipt();
  }

  Future<FlagReceipt> _setFlagInSteps(
    List<StoredMessage> messages,
    String flag,
    int bit, {
    required bool on,
    StepProgress? progress,
    bool readAgain = false,
  }) async {
    final change = _FlagChange(this, flag, bit, on: on);
    try {
      await _inSteps(
        messages,
        (step) => change.step(
          readAgain
              ? [for (final m in step) ?_store.messages.byId(m.id)]
              : step,
          notBefore: DateTime.now().add(holdDuringSteps),
        ),
        progress,
      );
    } finally {
      change.queue.release(null);
    }
    return change.receipt();
  }

  List<(StoredMailbox, List<StoredMessage>)> _byMailbox(
    List<StoredMessage> messages,
  ) {
    final groups = <MailboxId, List<StoredMessage>>{};
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

/// The server changes of one action: one queue entry per folder. An
/// action done in steps adds each step's UIDs to the same entry, so the
/// server gets one command per folder (or a few, for long UID lists; see
/// [OutboxReplayer.uidSets]), not one per step.
final class _Queue {
  _Queue(this._store, this._action);

  final MailStore _store;
  final UidAction Function(StoredMailbox mailbox, List<int> uids) _action;

  /// Entry ids, by folder id.
  final entries = <MailboxId, int>{};
  final _uids = <MailboxId, List<int>>{};
  final accountIds = <AccountId>{};

  /// Queues [uids] of [mailbox] (in the open transaction). Every entry
  /// waits until [notBefore].
  void add(StoredMailbox mailbox, Iterable<int> uids, DateTime? notBefore) {
    final all = _uids.putIfAbsent(mailbox.id, () => [])..addAll(uids);
    final action = _action(mailbox, all);
    if (entries[mailbox.id] case final id?) {
      _store.outbox.updateAction(id, action);
    } else {
      entries[mailbox.id] = _store.outbox
          .enqueue(mailbox.accountId, action, notBefore: notBefore)
          .id;
    }
    accountIds.add(mailbox.accountId);
  }

  /// Every entry waits until [notBefore] (null: due now).
  void hold(DateTime? notBefore) =>
      _store.outbox.reschedule(entries.values, notBefore);

  /// The action is complete: the server gets it from [notBefore].
  void release(DateTime? notBefore) => hold(notBefore);
}

/// One move or delete, done at once or in steps.
final class _Removal {
  _Removal._(this._actions, this.queue, {this.skip, this.dropCopies = false});

  factory _Removal.move(MailActions actions, StoredMailbox target) =>
      _Removal._(
        actions,
        _Queue(
          actions._store,
          (mailbox, uids) => MoveAction(
            mailboxId: mailbox.id,
            uidValidity: MailActions._validity(mailbox),
            uids: uids,
            targetMailboxId: target.id,
          ),
        ),
        skip: target.id,
        dropCopies:
            target.specialUse == SpecialUse.trash ||
            target.specialUse == SpecialUse.junk,
      );

  factory _Removal.delete(MailActions actions) => _Removal._(
    actions,
    _Queue(
      actions._store,
      (mailbox, uids) => DeleteAction(
        mailboxId: mailbox.id,
        uidValidity: MailActions._validity(mailbox),
        uids: uids,
      ),
    ),
    dropCopies: true,
  );

  final MailActions _actions;
  final _Queue queue;

  /// The target folder: its messages stay.
  final MailboxId? skip;

  /// Whether Gmail-style copies leave too (see [step]).
  final bool dropCopies;

  final _snapshots = <MessageSnapshot>[];
  final _snoozes = <Snooze>[];
  var _bodyBytes = MessageRepository.defaultSnapshotBodyBytes;

  MailStore get _store => _actions._store;

  /// Removes [messages] in one transaction and queues the server change,
  /// waiting until [notBefore].
  void step(List<StoredMessage> messages, {required DateTime? notBefore}) =>
      _store.transaction(() {
        final groups = [
          for (final (mailbox, group) in _actions._byMailbox(messages))
            if (mailbox.id != skip) (mailbox, group),
        ];
        final moving = [for (final (_, group) in groups) ...group];
        // Mail going to Trash or Spam leaves Gmail's All Mail, Starred
        // and Important on the server; their local copies go now too
        // (only here: the server does it itself), else a copy would stay
        // listed until that folder is opened again. Undo puts them back.
        final copies = dropCopies
            ? _actions._byMailbox(_store.messages.copiesOf(moving))
            : const <(StoredMailbox, List<StoredMessage>)>[];
        final snapshot = _store.messages.snapshot([
          for (final m in moving) m.id,
          for (final (_, group) in copies)
            for (final m in group) m.id,
        ], bodyBytes: max(0, _bodyBytes));
        _bodyBytes -= snapshot.bodyBytes;
        _snapshots.add(snapshot);
        // Moving, archiving or deleting snoozed mail ends its snooze.
        _snoozes.addAll(_store.snoozes.cancelFor(moving));
        for (final (mailbox, group) in groups) {
          final uids = [for (final m in group) m.uid];
          _store.messages.removeUids(mailbox.id, uids);
          queue.add(mailbox, uids, notBefore);
        }
        for (final (mailbox, group) in copies) {
          _store.messages.removeUids(mailbox.id, [
            for (final m in group) m.uid,
          ]);
        }
        queue.hold(notBefore);
      });

  RemovalReceipt receipt(DateTime now) => RemovalReceipt._(
    queue.accountIds,
    queue.entries.values.toList(),
    MessageSnapshot.join(_snapshots),
    now.add(_actions.undoWindow),
    _snoozes,
  );
}

/// One flag set or cleared, done at once or in steps.
final class _FlagChange {
  _FlagChange(this._actions, this.flag, this.bit, {required this.on})
    : queue = _Queue(
        _actions._store,
        (mailbox, uids) => SetFlagsAction(
          mailboxId: mailbox.id,
          uidValidity: MailActions._validity(mailbox),
          uids: uids,
          add: on ? [flag] : const [],
          remove: on ? const [] : [flag],
        ),
      );

  final MailActions _actions;
  final String flag;
  final int bit;
  final bool on;
  final _Queue queue;
  final _changed = <StoredMessage>[];

  MailStore get _store => _actions._store;

  /// Changes [messages] (one transaction per folder) and queues the
  /// server change, waiting until [notBefore].
  void step(List<StoredMessage> messages, {required DateTime? notBefore}) {
    for (final (mailbox, group) in _actions._byMailbox(messages)) {
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
        queue.add(mailbox, [for (final m in changed) m.uid], notBefore);
        if (notBefore != null) queue.hold(notBefore);
      });
      _changed.addAll(changed);
    }
  }

  FlagReceipt receipt() =>
      FlagReceipt._(queue.accountIds, _changed, flag, bit, on);
}
