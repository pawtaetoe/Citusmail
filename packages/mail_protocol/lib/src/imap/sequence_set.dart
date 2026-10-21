// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// An IMAP sequence set such as `1:3,5,9:*` (message numbers or UIDs).
///
/// Stored as sorted, merged ranges and never expanded implicitly, so a set
/// like `1:4294967295` from a server costs two numbers, not four billion.
final class SequenceSet {
  SequenceSet._(List<(int, int)> ranges)
    : _ranges = List.unmodifiable(_merge(ranges));

  /// A set of individual numbers.
  factory SequenceSet.of(Iterable<int> numbers) {
    final ranges = <(int, int)>[];
    for (final n in numbers) {
      if (n < 1) throw ArgumentError.value(n, 'numbers', 'must be at least 1');
      ranges.add((n, n));
    }
    return SequenceSet._(ranges);
  }

  /// `from:to`, or `from:*` when [to] is null.
  factory SequenceSet.range(int from, [int? to]) {
    if (from < 1 || (to != null && to < 1)) {
      throw ArgumentError('sequence numbers must be at least 1');
    }
    final end = to ?? _star;
    return SequenceSet._([from <= end ? (from, end) : (end, from)]);
  }

  /// Every message: `1:*`.
  factory SequenceSet.all() => SequenceSet.range(1);

  /// Parses a set sent by a server. Returns null if it is malformed.
  static SequenceSet? tryParse(String text) {
    if (text.isEmpty || text.length > 1000000) return null;
    final ranges = <(int, int)>[];
    for (final part in text.split(',')) {
      final bounds = part.split(':');
      if (bounds.length > 2) return null;
      final values = <int>[];
      for (final b in bounds) {
        final n = b == '*' ? _star : (b.length <= 19 ? int.tryParse(b) : null);
        if (n == null || n < 1) return null;
        values.add(n);
      }
      final a = values.first, z = values.last;
      ranges.add(a <= z ? (a, z) : (z, a));
    }
    return SequenceSet._(ranges);
  }

  /// Stands for "*" (the largest number in use).
  static const int _star = 0x7FFFFFFFFFFFFFFF;

  final List<(int, int)> _ranges;

  bool get isEmpty => _ranges.isEmpty;

  /// Whether the set ends with an open range (`n:*`).
  bool get hasStar => _ranges.isNotEmpty && _ranges.last.$2 == _star;

  /// Inclusive ranges, ascending.
  List<(int, int)> get ranges => _ranges;

  /// Number of members; open-ended ranges are not counted.
  int get length =>
      _ranges.fold(0, (sum, r) => r.$2 == _star ? sum : sum + r.$2 - r.$1 + 1);

  bool contains(int n) {
    var low = 0, high = _ranges.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final (a, b) = _ranges[mid];
      if (n < a) {
        high = mid - 1;
      } else if (n > b) {
        low = mid + 1;
      } else {
        return true;
      }
    }
    return false;
  }

  /// The members, refusing to expand more than [max] of them (protects
  /// against huge server-provided ranges).
  List<int> toList({int max = 1000000}) {
    if (hasStar) throw StateError('cannot list an open-ended set');
    if (length > max) {
      throw StateError('set has $length members, more than $max');
    }
    return [
      for (final (a, b) in _ranges)
        for (var n = a; n <= b; n++) n,
    ];
  }

  /// IMAP syntax, e.g. `1:3,5,9:*`.
  @override
  String toString() => _ranges
      .map((r) {
        final end = r.$2 == _star ? '*' : '${r.$2}';
        return r.$1 == r.$2 ? '${r.$1}' : '${r.$1}:$end';
      })
      .join(',');

  @override
  bool operator ==(Object other) =>
      other is SequenceSet && other.toString() == toString();

  @override
  int get hashCode => toString().hashCode;

  /// Sorts and merges overlapping or adjacent ranges.
  static List<(int, int)> _merge(List<(int, int)> ranges) {
    final sorted = [...ranges]..sort((x, y) => x.$1.compareTo(y.$1));
    final merged = <(int, int)>[];
    for (final r in sorted) {
      if (merged.isEmpty) {
        merged.add(r);
        continue;
      }
      final last = merged.last;
      final touches = last.$2 == _star || r.$1 <= last.$2 + 1;
      if (touches) {
        merged[merged.length - 1] = (last.$1, r.$2 > last.$2 ? r.$2 : last.$2);
      } else {
        merged.add(r);
      }
    }
    return merged;
  }
}
