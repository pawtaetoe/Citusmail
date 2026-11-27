// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:mail_store/mail_store.dart';

/// Work for [StoreReader]: reads what it needs from the store it is given
/// and returns plain data. It is sent to another isolate, so make it with
/// a top-level function that captures only plain values (a date, a set of
/// ids), never a model, a controller or the UI's store.
typedef StoreTask<R> = FutureOr<R> Function(MailStore store);

/// Reads that take long, off the UI isolate: the "Found in your mail"
/// finders (hundreds of milliseconds of queries, parsing and rules over
/// a year of mail), the summary line's look at today, reading ahead and
/// Clean up's totals. The screen stays responsive while they run, and a
/// pushed page animates in at once.
///
/// [StoreReader.isolate] runs each task in one long-lived helper isolate
/// with its own read connection to the encrypted database (like the sync
/// worker's), so what it reads is what the UI committed. What a task
/// keeps in memory (the finders' reads of each message) stays in that
/// isolate for the next task. Tasks run as they come, like on the UI
/// isolate; a page drops a result it no longer wants ([PageModel]).
///
/// [StoreReader.inline] runs them on the calling isolate with its store:
/// for a store without a file, and the Android background check.
sealed class StoreReader {
  const StoreReader();

  /// A helper isolate that opens the database at [path] with [key] when
  /// the first task comes. Should it fail to start, tasks run on this
  /// isolate with [fallback], as before there was one.
  factory StoreReader.isolate(
    String path,
    DatabaseKey key, {
    required MailStore fallback,
  }) = _IsolateReader;

  /// On this isolate, with [store].
  const factory StoreReader.inline(MailStore store) = _InlineReader;

  /// Runs [task] and gives its result (or throws its error).
  Future<R> run<R>(StoreTask<R> task);

  /// Stops the helper isolate: it closes its connection once the tasks
  /// running are done; their results go nowhere.
  Future<void> dispose() async {}
}

final class _InlineReader extends StoreReader {
  const _InlineReader(this._store);

  final MailStore _store;

  @override
  Future<R> run<R>(StoreTask<R> task) async => task(_store);
}

final class _IsolateReader extends StoreReader {
  _IsolateReader(this._path, this._key, {required this._fallback});

  final String _path;
  final DatabaseKey _key;
  final MailStore _fallback;
  bool _failed = false;
  Future<SendPort>? _commands;
  SendPort? _ready;
  Isolate? _isolate;
  bool _disposed = false;

  Future<SendPort> _start() async {
    final ready = ReceivePort();
    try {
      _isolate = await Isolate.spawn(
        _main,
        (ready.sendPort, _path, _key),
        debugName: 'store reader',
        errorsAreFatal: false,
      );
      final first = await ready.first;
      if (first is SendPort) return _ready = first;
      final (error, stack) = first as (Object, String);
      Error.throwWithStackTrace(error, StackTrace.fromString(stack));
    } finally {
      ready.close();
    }
  }

  @override
  Future<R> run<R>(StoreTask<R> task) async {
    if (_disposed) throw StateError('the store reader was stopped');
    if (_failed) return task(_fallback);
    final SendPort commands;
    try {
      commands = await (_commands ??= _start());
    } on Object catch (e) {
      if (!_failed) debugPrint('store reader: ${e.runtimeType}');
      _failed = true;
      return task(_fallback);
    }
    final reply = ReceivePort();
    try {
      commands.send((task, reply.sendPort));
      final answer = await reply.first;
      return switch (answer) {
        (true, final Object? result) => result as R,
        (false, final Object error, final String stack) =>
          Error.throwWithStackTrace(error, StackTrace.fromString(stack)),
        _ => throw StateError('unexpected answer from the store reader'),
      };
    } finally {
      reply.close();
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Nothing is awaited here (the screen may be closing in a test's fake
    // time): the isolate closes its connection once the tasks running are
    // done, and ends; it is stopped if it hasn't after a few seconds.
    final commands = _ready;
    if (commands == null) {
      // Still starting (or never started): stopped once it is up.
      unawaited(_commands?.then((c) => c.send(null), onError: (Object _) {}));
      return;
    }
    commands.send(null);
    final isolate = _isolate;
    Timer(const Duration(seconds: 5), () => isolate?.kill());
  }

  static Future<void> _main((SendPort, String, DatabaseKey) start) async {
    final (ready, path, key) = start;
    final MailStore store;
    try {
      store = MailStore.open(path, key);
    } on Object catch (e, stack) {
      ready.send((_sendable(e), stack.toString()));
      return;
    }
    final commands = ReceivePort();
    ready.send(commands.sendPort);
    var running = 0;
    var closing = false;
    void closeWhenIdle() {
      if (!closing || running > 0) return;
      commands.close();
      store.close();
      Isolate.exit();
    }

    commands.listen((message) async {
      if (message == null) {
        closing = true;
        closeWhenIdle();
        return;
      }
      final (task, reply) = message as (StoreTask<Object?>, SendPort);
      running++;
      try {
        final result = await task(store);
        try {
          reply.send((true, result));
        } on Object catch (e, stack) {
          // A result that can't be sent is the task's mistake.
          reply.send((false, _sendable(e), stack.toString()));
        }
      } on Object catch (e, stack) {
        reply.send((false, _sendable(e), stack.toString()));
      } finally {
        running--;
        closeWhenIdle();
      }
    });
  }

  /// [error] itself when it can cross isolates (most errors), else its
  /// description.
  static Object _sendable(Object error) {
    try {
      // Throws for what can't be sent.
      final probe = RawReceivePort();
      try {
        probe.sendPort.send(error);
      } finally {
        probe.close();
      }
      return error;
    } on Object {
      return RemoteError(error.toString(), '');
    }
  }
}

/// For tests: whether [reader] runs tasks in a helper isolate.
@visibleForTesting
bool runsInIsolate(StoreReader reader) => reader is _IsolateReader;
