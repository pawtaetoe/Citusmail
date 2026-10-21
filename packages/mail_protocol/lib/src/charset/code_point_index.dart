// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'whatwg_data.g.dart';

/// A WHATWG index: maps a pointer to a code point.
///
/// Indexes are stored packed in `whatwg_data.g.dart` and unpacked on first
/// use, then cached for the life of the process.
final class CodePointIndex {
  CodePointIndex._(this._entries);

  /// Marks a pointer with no code point.
  static const int none = -1;

  static final Map<String, CodePointIndex> _cache = {};

  /// The index with the WHATWG [name], e.g. `jis0208`.
  factory CodePointIndex.named(String name) => _cache.putIfAbsent(name, () {
    final packed = whatwgPackedIndexes[name];
    if (packed == null) {
      throw ArgumentError.value(name, 'name', 'no such index');
    }
    return CodePointIndex._(unpack(packed));
  });

  final Int32List _entries;

  int get length => _entries.length;

  /// The code point for [pointer], or [none].
  int operator [](int pointer) =>
      pointer >= 0 && pointer < _entries.length ? _entries[pointer] : none;

  /// Unpacks the format written by the repository's IndexPacker:
  /// base64 → zlib → LEB128 varints, where 0 is "no code point" and any
  /// other value v encodes a delta of `unzigzag(v - 1)` from the previous
  /// code point.
  static Int32List unpack(String packed) {
    final bytes = ZLibCodec().decode(base64.decode(packed));
    final entries = <int>[];
    var previous = 0;
    var i = 0;
    while (i < bytes.length) {
      var value = 0;
      var shift = 0;
      while (true) {
        if (i >= bytes.length || shift > 28) {
          throw const FormatException('corrupt packed index');
        }
        final byte = bytes[i++];
        value |= (byte & 0x7F) << shift;
        if (byte < 0x80) break;
        shift += 7;
      }
      if (value == 0) {
        entries.add(none);
      } else {
        final delta = value - 1;
        previous += delta.isEven ? delta >> 1 : -((delta + 1) >> 1);
        entries.add(previous);
      }
    }
    return Int32List.fromList(entries);
  }
}
