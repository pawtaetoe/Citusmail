// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:mail_store/mail_store.dart';

/// How much an action kept the UI isolate busy: each synchronous slice
/// of it (the call itself, then every callback it scheduled: microtasks,
/// timers, futures completing), timed where it runs. Work in other
/// isolates (compute, the sync worker) is not counted; its result
/// arriving is, from the callback on.
final class UiWork {
  UiWork._(this.name);

  final String name;

  /// Time in the slices, all together.
  Duration total = Duration.zero;

  /// The longest slice: what could hold up one frame.
  Duration longest = Duration.zero;

  /// How many slices ran.
  int slices = 0;

  /// Statements run on the store's connection meanwhile.
  int statements = 0;

  /// The time from the start until the action's future completed.
  Duration elapsed = Duration.zero;

  /// Runs [action] (and what it schedules) in a zone that times every
  /// slice; done when its future completes.
  static Future<UiWork> measure(
    String name,
    MailStore store,
    FutureOr<void> Function() action,
  ) async {
    final work = UiWork._(name);
    var depth = 0;
    R timed<R>(R Function() f) {
      if (depth > 0) return f();
      depth++;
      final watch = Stopwatch()..start();
      try {
        return f();
      } finally {
        depth--;
        final e = watch.elapsed;
        work.slices++;
        work.total += e;
        if (e > work.longest) work.longest = e;
      }
    }

    final spec = ZoneSpecification(
      run: <R>(self, parent, zone, f) => timed(() => parent.run(zone, f)),
      runUnary: <R, T>(self, parent, zone, f, T arg) =>
          timed(() => parent.runUnary(zone, f, arg)),
      runBinary: <R, T1, T2>(self, parent, zone, f, T1 a, T2 b) =>
          timed(() => parent.runBinary(zone, f, a, b)),
    );
    final before = store.database.statementCount;
    final clock = Stopwatch()..start();
    await Zone.current.fork(specification: spec).run(() async {
      await action();
    });
    work.elapsed = clock.elapsed;
    work.statements = store.database.statementCount - before;
    return work;
  }

  static String _ms(Duration d) => (d.inMicroseconds / 1000).toStringAsFixed(1);

  /// Over a frame at 120 Hz (8 ms) or at 60 Hz (16 ms).
  String get budget => longest.inMicroseconds > 16000
      ? 'over 16 ms'
      : longest.inMicroseconds > 8000
      ? 'over 8 ms'
      : 'ok';

  @override
  String toString() =>
      '${name.padRight(44)} longest ${_ms(longest).padLeft(7)} ms, '
      'total ${_ms(total).padLeft(7)} ms in $slices slices, '
      '$statements statements ($budget)';
}
