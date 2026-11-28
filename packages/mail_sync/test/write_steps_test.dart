// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

/// Busy for [d] on this isolate, like a store write.
void _busy(Duration d) {
  final watch = Stopwatch()..start();
  while (watch.elapsed < d) {}
}

void main() {
  test('every item is written once, in order', () async {
    final steps = WriteSteps(initial: 7);
    final seen = <int>[];
    await steps.run(List.generate(100, (i) => i), seen.addAll);
    expect(seen, List.generate(100, (i) => i));
  });

  test('a slow device gets short transactions at once', () async {
    // 2 ms per item: 25 would hold the lock for 50 ms.
    final steps = WriteSteps(target: const Duration(milliseconds: 8));
    final sizes = <int>[];
    var longest = Duration.zero;
    await steps.run(List.generate(300, (i) => i), (part) {
      sizes.add(part.length);
      final watch = Stopwatch()..start();
      _busy(Duration(milliseconds: 2 * part.length));
      if (watch.elapsed > longest) longest = watch.elapsed;
    });
    expect(sizes.first, 25, reason: 'it starts at the given size');
    // After the first, every transaction fits the target (4 items).
    expect(sizes.skip(1).every((n) => n <= 4), isTrue, reason: '$sizes');
    expect(steps.size, lessThanOrEqualTo(4));
  });

  test('a busy moment shrinks it; a fast device grows it back', () async {
    final steps = WriteSteps(initial: 16, max: 64);
    var slow = true;
    await steps.run(List.generate(16, (i) => i), (part) {
      if (slow) _busy(const Duration(milliseconds: 40));
      slow = false;
    });
    expect(steps.size, lessThan(16));
    await steps.run(List.generate(400, (i) => i), (_) {});
    expect(steps.size, 64, reason: 'cheap writes grow up to max');
  });

  test('never below one item, never above max', () async {
    final steps = WriteSteps(initial: 500, max: 50);
    expect(steps.size, 50);
    await steps.run([1, 2, 3], (_) => _busy(const Duration(milliseconds: 30)));
    expect(steps.size, 1);
  });
}
