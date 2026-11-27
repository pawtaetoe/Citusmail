// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// A small random number generator (mulberry32) that gives the same
/// numbers for the same seed on every machine and Dart version, unlike
/// `dart:math`'s `Random`, whose sequence is not promised.
final class Rng {
  Rng(int seed) : _state = seed & 0xffffffff;

  int _state;

  /// The next 32 random bits.
  int next() {
    _state = (_state + 0x6d2b79f5) & 0xffffffff;
    var t = _state;
    t = _mul(t ^ (t >> 15), t | 1);
    t = ((t + _mul(t ^ (t >> 7), t | 61)) & 0xffffffff) ^ t;
    return (t ^ (t >> 14)) & 0xffffffff;
  }

  static int _mul(int a, int b) {
    // 32-bit multiply, as C does it.
    final lo = (a & 0xffff) * b;
    final hi = ((a >> 16) * b) & 0xffff;
    return (lo + (hi << 16)) & 0xffffffff;
  }

  /// A whole number from 0 up to, not including, [n].
  int below(int n) => next() % n;

  /// A whole number from [lo] to [hi], both included.
  int between(int lo, int hi) => lo + below(hi - lo + 1);

  /// A number from 0 up to 1.
  double unit() => next() / 4294967296.0;

  bool chance(double p) => unit() < p;

  T pick<T>(List<T> items) => items[below(items.length)];

  /// [items] in a random order (a new list).
  List<T> shuffled<T>(Iterable<T> items) {
    final list = [...items];
    for (var i = list.length - 1; i > 0; i--) {
      final j = below(i + 1);
      final t = list[i];
      list[i] = list[j];
      list[j] = t;
    }
    return list;
  }

  /// [n] different items of [items].
  List<T> some<T>(List<T> items, int n) => shuffled(items).take(n).toList();
}

/// e^[x] from additions, multiplications and one division only, so that
/// training gives the very same weights on every machine (`dart:math`'s
/// `exp` comes from the platform's C library).
double exactExp(double x) {
  if (x < -700) return 0;
  if (x > 700) x = 700;
  const ln2 = 0.6931471805599453;
  final k = (x / ln2).round();
  final r = x - k * ln2;
  // Taylor series on |r| <= ln 2 / 2: 14 terms are plenty for doubles.
  var term = 1.0;
  var sum = 1.0;
  for (var i = 1; i <= 14; i++) {
    term = term * r / i;
    sum += term;
  }
  var scale = 1.0;
  if (k > 0) {
    for (var i = 0; i < k; i++) {
      scale *= 2;
    }
  } else {
    for (var i = 0; i < -k; i++) {
      scale /= 2;
    }
  }
  return sum * scale;
}
