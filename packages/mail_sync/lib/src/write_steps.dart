// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:math' as math;

/// Store writes made in short transactions, sized by time, not count.
///
/// Every transaction holds the database's write lock, and the screen's own
/// writes (marking an email read, archiving) wait for it. How long a batch
/// takes depends on the device and on what else runs (each summary also
/// updates the search indexes), so a fixed count is too long on a slow
/// phone or a busy machine. Each transaction is measured and the next one
/// sized to take about [target]: halved (or less) when one took longer,
/// doubled when one took under half, between 1 and [max] items. With
/// [pause] between transactions, so a waiting write gets the lock.
final class WriteSteps {
  WriteSteps({
    int initial = 25,
    this.max = 100,
    this.target = const Duration(milliseconds: 8),
    this.pause = const Duration(milliseconds: 1),
  }) : _size = initial.clamp(1, max);

  /// The most items in one transaction.
  final int max;

  /// How long one transaction should take.
  final Duration target;

  /// The gap between two transactions.
  final Duration pause;

  int _size;

  /// How many items the next transaction takes.
  int get size => _size;

  /// Writes [items] with [write], a part at a time; each call of [write]
  /// is expected to be one transaction.
  Future<void> run<T>(List<T> items, void Function(List<T> part) write) async {
    final watch = Stopwatch();
    for (var i = 0; i < items.length;) {
      if (i > 0) await Future<void>.delayed(pause);
      final end = math.min(i + _size, items.length);
      watch
        ..reset()
        ..start();
      write(items.sublist(i, end));
      watch.stop();
      _adapt(watch.elapsed, end - i);
      i = end;
    }
  }

  void _adapt(Duration took, int count) {
    final targetUs = target.inMicroseconds;
    final tookUs = took.inMicroseconds;
    if (tookUs > targetUs) {
      // As many as would have fitted, at most half: a slow device or a
      // busy moment shrinks the next transaction at once.
      final fit = (count * targetUs / tookUs).floor();
      _size = math.max(1, math.min(fit, _size ~/ 2));
    } else if (tookUs * 2 < targetUs && count >= _size) {
      _size = math.min(max, _size * 2);
    }
  }
}
