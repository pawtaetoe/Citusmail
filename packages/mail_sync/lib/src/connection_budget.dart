// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'connector.dart';

/// Who waits for a connection, which decides who gets the next free one:
/// the first tier first, and within a tier first come, first served. See
/// [ConnectionBudget] for how waiting moves work up, so that nothing
/// waits for ever.
enum ConnectionPriority {
  /// The user sent a message: its copy in Sent and the flags and draft
  /// clean-up that go with it, once the undo delay is over.
  send,

  /// The user opens a message: its body, or the files it has.
  open,

  /// Other work of the user's: a server search, older mail, a new
  /// folder, and the moves, deletions and flags they just made.
  user,

  /// Nobody is waiting: syncs, reading ahead, IDLE.
  background;

  /// Whether this is the user's work, which a sync hands its connection
  /// to.
  bool get isUser => this != background;
}

/// No connection to the account's server came free in time, or the
/// connections were closed while waiting (the engine stopped).
final class ConnectionBusyException extends MailException {
  const ConnectionBusyException(super.message);
}

/// Every IMAP connection the engine holds to an account, counted against
/// one budget per account: in use and kept idle alike. Mail servers allow
/// only a few per account, shared by all the user's devices and apps
/// (Gmail about 15), and refuse the next login with "Too many simultaneous
/// connections".
///
/// A connection is taken for a piece of work and given back afterwards;
/// its owner (a pool: the syncs, opening messages, IDLE) may keep it for
/// a while to reuse. When the account's budget is full, taking:
///
/// 1. reuses one of the owner's own kept connections;
/// 2. else, for [take], reuses another owner's kept one;
/// 3. else waits in a queue until a connection is given back (handed
///    over directly, still logged in) or closed, or [waitTimeout] passes.
///
/// The next free connection goes to the first tier of
/// [ConnectionPriority] that waits, and within a tier to the one that
/// came first. Nothing waits for ever:
///
/// - the user's work moves up a tier for each [promoteAfter] it waited,
///   so a search waits for at most a couple of seconds of opened
///   messages and sends;
/// - a sync that handed its connection to the user's work
///   ([take] with `afterHandOver`) gets one back after at most
///   [handBackAfter] pieces of other work, or [handBackWithin], whichever
///   comes first;
/// - any work that has waited [ageAfter] is not overtaken any more.
///
/// No one holds a connection while waiting for another (a sync hands its
/// connection over before it queues for one again), so the queue always
/// moves: at a budget of 1 everything still finishes, one after another.
///
/// A login the server refuses for now ([ImapAuthenticationException.
/// temporary]) lowers the account's budget to [whenRefused], back up to
/// [perAccount] over [recovery], and closes the account's kept
/// connections so the server has room again.
final class ConnectionBudget {
  ConnectionBudget(
    this._connector, {
    this.perAccount = 4,
    this.whenRefused = 2,
    this.recovery = const Duration(minutes: 30),
    this.waitTimeout = const Duration(minutes: 2),
    this.checkAfter = const Duration(seconds: 20),
    this.ageAfter = const Duration(seconds: 30),
    this.promoteAfter = const Duration(milliseconds: 500),
    this.handBackAfter = 3,
    this.handBackWithin = const Duration(seconds: 2),
    this.onTaken,
    DateTime Function()? now,
  }) : assert(perAccount >= 1 && whenRefused >= 1 && handBackAfter >= 1),
       _now = now ?? DateTime.now;

  final MailConnector _connector;

  /// Connections per account, counting IDLE and kept ones.
  final int perAccount;

  /// The budget right after the server refused a login for having too
  /// many connections.
  final int whenRefused;

  /// How long the lowered budget takes to come back to [perAccount], one
  /// connection at a time.
  final Duration recovery;

  /// How long a taker waits for a connection before giving up.
  final Duration waitTimeout;

  /// A kept connection of another owner unused for longer than this is
  /// asked a NOOP before it is reused.
  final Duration checkAfter;

  /// Work that has waited this long is not overtaken any more, whoever
  /// comes after it.
  final Duration ageAfter;

  /// The user's work moves up one tier of [ConnectionPriority] for each
  /// time it waited this long.
  final Duration promoteAfter;

  /// A sync that handed its connection over gets one back after at most
  /// this many pieces of other work (the one it handed to included)...
  final int handBackAfter;

  /// ... or once it waited this long, whichever comes first.
  final Duration handBackWithin;

  /// Told of each connection [take] hands out, in order, with what it
  /// was taken for: to see who went first (diagnostics and tests).
  final void Function(
    AccountId accountId,
    ConnectionPriority priority, {
    required bool afterHandOver,
  })?
  onTaken;

  final DateTime Function() _now;
  final _accounts = <AccountId, _Slots>{};
  bool _closed = false;

  /// How many connections [accountId] may have open now.
  int limitFor(AccountId accountId) =>
      _accounts[accountId]?.limit(this) ?? perAccount;

  /// How many connections [accountId] has open now (in use, kept,
  /// opening and closing).
  int openFor(AccountId accountId) => _accounts[accountId]?.open ?? 0;

  /// Whether someone waits for a connection of [accountId], or it has
  /// more open than its budget allows: connections that are not needed
  /// should be given back.
  bool contended(AccountId accountId) {
    final slots = _accounts[accountId];
    return slots != null &&
        (slots.waiters.isNotEmpty || slots.open > slots.limit(this));
  }

  /// Whether the user's work waits for a connection of [accountId].
  bool userWaiting(AccountId accountId) =>
      _accounts[accountId]?.waiters.any((w) => w.priority.isUser) ?? false;

  /// The priorities of what waits for a connection of [accountId], in the
  /// order they arrived.
  List<ConnectionPriority> waitingFor(AccountId accountId) => [
    for (final w in _accounts[accountId]?.waiters ?? const <_Waiter>[])
      w.priority,
  ];

  /// Completes once [accountId] is [contended]: at once if it is now. A
  /// long-held connection (IDLE) gives itself back then.
  Future<void> pressure(AccountId accountId) {
    if (contended(accountId)) return Future.value();
    return (_slots(accountId).pressure ??= Completer<void>()).future;
  }

  /// A logged-in connection for [account], for [owner]. Waits when the
  /// account's budget is full (see the class comment); [until] completing
  /// ends the wait with a [ConnectionBusyException]. Give it back with
  /// [give] or [discard].
  ///
  /// [afterHandOver]: a sync takes a connection again after handing its
  /// own to the user's work. It waits for at most [handBackAfter] pieces
  /// of other work, the one it handed to included, or [handBackWithin].
  Future<ImapClient> take(
    Account account, {
    required Object owner,
    ConnectionPriority priority = ConnectionPriority.background,
    Future<void>? until,
    bool afterHandOver = false,
  }) async {
    final client = await _take(
      account,
      owner,
      priority,
      until,
      wait: true,
      afterHandOver: afterHandOver,
    );
    onTaken?.call(account.id, priority, afterHandOver: afterHandOver);
    return client!;
  }

  /// Like [take], but only the owner's own kept connection or a free slot:
  /// null instead of waiting or taking another owner's connection (the
  /// extra connections of a full sync).
  Future<ImapClient?> takeIfFree(Account account, {required Object owner}) =>
      _take(account, owner, ConnectionPriority.background, null, wait: false);

  Future<ImapClient?> _take(
    Account account,
    Object owner,
    ConnectionPriority priority,
    Future<void>? until, {
    required bool wait,
    bool afterHandOver = false,
  }) async {
    final slots = _slots(account.id);
    while (true) {
      if (_closed) throw const ConnectionBusyException('connections closed');
      if (await _reuse(slots, slots.keptOf(owner), owner) case final c?) {
        return c;
      }
      if (slots.waiters.isEmpty && slots.open < slots.limit(this)) {
        slots.opening++;
        return _open(account, slots);
      }
      if (!wait) return null;
      if (slots.kept.isNotEmpty) {
        if (await _reuse(slots, slots.kept.first, owner) case final c?) {
          return c;
        }
        continue;
      }
      switch (await _wait(slots, priority, until, afterHandOver)) {
        case _Handed(:final client):
          return client;
        case _Slot():
          return _open(account, slots); // its slot is reserved
      }
    }
  }

  /// Takes [kept] out of keeping; the client if it still answers, else
  /// null (and it is closed).
  Future<ImapClient?> _reuse(_Slots slots, _Kept? kept, Object owner) async {
    if (kept == null) return null;
    slots.kept.remove(kept);
    kept.timer.cancel();
    final client = kept.client;
    slots.inUse.add(client);
    final check = kept.owner == owner ? kept.checkAfter : checkAfter;
    var usable = client.isUsable;
    if (usable && check != null && _now().difference(kept.since) > check) {
      try {
        await client.noop();
      } on Object {
        usable = false;
      }
    }
    if (usable && !_closed) return client;
    slots.inUse.remove(client);
    await _closeCounted(slots, client);
    return null;
  }

  /// Logs in on a slot already counted in [_Slots.opening].
  Future<ImapClient> _open(Account account, _Slots slots) async {
    final ImapClient client;
    try {
      client = await _connector.imap(account);
    } on ImapAuthenticationException catch (e) {
      slots.opening--;
      if (e.temporary) _refused(slots);
      _grant(slots);
      rethrow;
    } on Object {
      slots.opening--;
      _grant(slots);
      rethrow;
    }
    slots.opening--;
    slots.inUse.add(client);
    if (_closed) {
      slots.inUse.remove(client);
      await _closeCounted(slots, client);
      throw const ConnectionBusyException('connections closed');
    }
    return client;
  }

  Future<_Grant> _wait(
    _Slots slots,
    ConnectionPriority priority,
    Future<void>? until,
    bool afterHandOver,
  ) {
    // In order of arrival; [_next] picks who goes first.
    final waiter = _Waiter(priority, _now(), afterHandOver: afterHandOver);
    slots.waiters.add(waiter);
    void giveUp(String why) {
      if (waiter.done.isCompleted) return;
      slots.waiters.remove(waiter);
      waiter.timer?.cancel();
      waiter.done.completeError(ConnectionBusyException(why));
    }

    waiter.timer = Timer(
      waitTimeout,
      () => giveUp('no free connection to the server; try again'),
    );
    unawaited(
      until?.then(
        (_) => giveUp('stopped'),
        onError: (Object _) => giveUp('stopped'),
      ),
    );
    // The budget may have grown back since the last slot was given.
    _grant(slots);
    if (!waiter.done.isCompleted) slots.wake();
    return waiter.done.future;
  }

  /// Gives [client] back after work: handed to the first one waiting, or
  /// kept for [keepFor] when the budget has room and [owner] keeps fewer
  /// than [maxKept], or closed. A kept connection taken again by [owner]
  /// after [checkAfter] (null: never) is asked a NOOP first.
  Future<void> give(
    Account account,
    ImapClient client, {
    required Object owner,
    Duration keepFor = Duration.zero,
    Duration? checkAfter,
    int maxKept = 1,
  }) async {
    final slots = _accounts[account.id];
    if (slots == null || !slots.inUse.contains(client)) {
      // Not counted here (taken before the budget closed): just close it.
      await _logout(client);
      return;
    }
    final retired = slots.retired.remove(client);
    if (client.isUsable && !retired && !_closed) {
      if (slots.waiters.isNotEmpty && slots.open <= slots.limit(this)) {
        final waiter = _next(slots);
        waiter.timer?.cancel();
        waiter.done.complete(_Handed(client));
        return;
      }
      if (keepFor > Duration.zero &&
          slots.waiters.isEmpty &&
          slots.open <= slots.limit(this) &&
          slots.kept.where((k) => k.owner == owner).length < maxKept) {
        slots.inUse.remove(client);
        late final _Kept kept;
        kept = _Kept(
          client,
          owner,
          _now(),
          checkAfter,
          Timer(keepFor, () {
            if (slots.kept.remove(kept)) {
              unawaited(_closeCounted(slots, client));
            }
          }),
        );
        slots.kept.add(kept);
        return;
      }
    }
    slots.inUse.remove(client);
    await _closeCounted(slots, client);
  }

  /// Closes [client] (it broke, or is not wanted any more) and frees its
  /// slot.
  Future<void> discard(Account account, ImapClient client) async {
    final slots = _accounts[account.id];
    if (slots == null || !slots.inUse.remove(client)) {
      await _logout(client);
      return;
    }
    slots.retired.remove(client);
    await _closeCounted(slots, client);
  }

  /// Closes the kept connections of [accountId]: [owner]'s, or everyone's.
  Future<void> closeKept(AccountId accountId, {Object? owner}) async {
    final slots = _accounts[accountId];
    if (slots == null) return;
    final closing = [
      for (final k in slots.kept)
        if (owner == null || k.owner == owner) k,
    ];
    await _closeKeptOf(slots, closing);
  }

  /// Closes the kept connections of every account: [owner]'s, or
  /// everyone's.
  Future<void> closeAllKept({Object? owner}) async {
    await Future.wait([
      for (final id in [..._accounts.keys]) closeKept(id, owner: owner),
    ]);
  }

  /// After an account was removed or its settings changed: ends the
  /// waits for its connections (they would log in with what it was),
  /// closes its kept connections, and those in use once they are given
  /// back.
  Future<void> forget(AccountId accountId) async {
    final slots = _accounts[accountId];
    if (slots == null) return;
    _endWaits(slots, 'the account changed; try again');
    slots.retired.addAll(slots.inUse);
    await closeKept(accountId);
  }

  /// The accounts connections were counted for.
  Iterable<AccountId> get accountIds => _accounts.keys;

  /// Ends every wait for a connection with a [ConnectionBusyException]
  /// (the engine is stopping: nothing should start now).
  void cancelWaits() {
    for (final slots in _accounts.values) {
      _endWaits(slots, 'stopped');
    }
  }

  void _endWaits(_Slots slots, String why) {
    final waiters = [...slots.waiters];
    slots.waiters.clear();
    for (final waiter in waiters) {
      waiter.timer?.cancel();
      waiter.done.completeError(ConnectionBusyException(why));
    }
    slots.wake();
  }

  /// Stops for good: closes every kept connection, ends every wait, and
  /// closes connections still in use when they are given back.
  Future<void> close() async {
    _closed = true;
    cancelWaits();
    await closeAllKept();
  }

  _Slots _slots(AccountId accountId) =>
      _accounts.putIfAbsent(accountId, _Slots.new);

  /// The server refused a login for having too many connections.
  void _refused(_Slots slots) {
    final now = _now();
    final current = slots.limit(this);
    slots.lowered = (
      limit: current < whenRefused ? current : whenRefused,
      at: now,
    );
    unawaited(_closeKeptOf(slots, [...slots.kept]));
    slots.wake();
  }

  Future<void> _closeKeptOf(_Slots slots, List<_Kept> closing) async {
    for (final k in closing) {
      k.timer.cancel();
      slots.kept.remove(k);
    }
    await Future.wait([
      for (final k in closing) _closeCounted(slots, k.client),
    ]);
  }

  /// Logs [client] out, counted as open until it is, then lets the next
  /// one waiting have its slot.
  Future<void> _closeCounted(_Slots slots, ImapClient client) async {
    slots.closing++;
    try {
      await _logout(client);
    } finally {
      slots.closing--;
      _grant(slots);
    }
  }

  /// Free slots go to those waiting, in turn ([_next]): each is reserved
  /// for the waiter it was given to.
  void _grant(_Slots slots) {
    while (slots.waiters.isNotEmpty && slots.open < slots.limit(this)) {
      final waiter = _next(slots);
      waiter.timer?.cancel();
      slots.opening++;
      waiter.done.complete(const _Slot());
    }
  }

  /// Takes the one whose turn it is out of the queue: the lowest [_rank],
  /// and of those the one that came first. Every sync still waiting after
  /// a hand-over counts one more piece of work done before it.
  _Waiter _next(_Slots slots) {
    final now = _now();
    final waiters = slots.waiters;
    var best = 0;
    var bestRank = _rank(waiters[0], now);
    for (var i = 1; i < waiters.length; i++) {
      final rank = _rank(waiters[i], now);
      if (rank < bestRank) {
        best = i;
        bestRank = rank;
      }
    }
    final waiter = waiters.removeAt(best);
    for (final w in waiters) {
      if (w.afterHandOver) w.served++;
    }
    return waiter;
  }

  /// Lower goes first; ties in order of arrival (the queue's order).
  int _rank(_Waiter w, DateTime now) {
    final waited = now.difference(w.since);
    if (waited >= ageAfter) return -1;
    if (w.afterHandOver &&
        (w.served >= handBackAfter || waited >= handBackWithin)) {
      return -1;
    }
    final tier = w.priority.index;
    if (!w.priority.isUser || promoteAfter <= Duration.zero) return tier;
    final up = waited.inMicroseconds ~/ promoteAfter.inMicroseconds;
    return up >= tier ? 0 : tier - up;
  }

  static Future<void> _logout(ImapClient client) async {
    try {
      await client.logout();
    } on Object {
      try {
        await client.close();
      } on Object {
        // Already gone.
      }
    }
  }
}

/// One account's connections.
final class _Slots {
  final inUse = <ImapClient>{};
  final kept = <_Kept>[];
  final waiters = <_Waiter>[];

  /// In use, but closed when given back ([ConnectionBudget.forget]).
  final retired = <ImapClient>{};

  /// Logins under way (and slots reserved for those that waited).
  int opening = 0;

  /// Logouts under way: still open on the server until they are done.
  int closing = 0;

  ({int limit, DateTime at})? lowered;
  Completer<void>? pressure;

  int get open => opening + inUse.length + kept.length + closing;

  /// The newest connection [owner] keeps.
  _Kept? keptOf(Object owner) => kept.lastWhereOrNull((k) => k.owner == owner);

  int limit(ConnectionBudget budget) {
    final low = lowered;
    if (low == null) return budget.perAccount;
    final steps = budget.perAccount - low.limit;
    final elapsed = budget._now().difference(low.at);
    final regained = steps <= 0 || budget.recovery <= Duration.zero
        ? steps
        : elapsed.inMicroseconds * steps ~/ budget.recovery.inMicroseconds;
    if (regained >= steps) {
      lowered = null;
      return budget.perAccount;
    }
    return low.limit + (regained < 0 ? 0 : regained);
  }

  /// Tells a long-held connection to give itself back, if it is wanted.
  void wake() {
    final waiting = pressure;
    if (waiting == null) return;
    pressure = null;
    if (!waiting.isCompleted) waiting.complete();
  }
}

final class _Kept {
  _Kept(this.client, this.owner, this.since, this.checkAfter, this.timer);

  final ImapClient client;
  final Object owner;
  final DateTime since;
  final Duration? checkAfter;
  final Timer timer;
}

final class _Waiter {
  _Waiter(this.priority, this.since, {this.afterHandOver = false})
    : served = afterHandOver ? 1 : 0; // the work it handed its own to

  final ConnectionPriority priority;
  final DateTime since;

  /// A sync taking a connection back after handing its own over.
  final bool afterHandOver;

  /// Pieces of other work given a connection before it (with
  /// [afterHandOver]).
  int served;
  final done = Completer<_Grant>();
  Timer? timer;
}

sealed class _Grant {
  const _Grant();
}

/// A connection given back, still logged in.
final class _Handed extends _Grant {
  const _Handed(this.client);

  final ImapClient client;
}

/// A free slot, reserved: log in on it.
final class _Slot extends _Grant {
  const _Slot();
}

extension<T> on List<T> {
  T? lastWhereOrNull(bool Function(T) test) {
    for (var i = length - 1; i >= 0; i--) {
      if (test(this[i])) return this[i];
    }
    return null;
  }
}
