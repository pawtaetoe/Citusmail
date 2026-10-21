// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Packs a WHATWG index (a list of code points or nulls) into a compact
/// string for embedding in Dart source.
///
/// Format, mirrored by `CodePointIndex.unpack` in mail_protocol:
/// 1. Each entry becomes one unsigned LEB128 varint: `0` for null, otherwise
///    `zigzag(codePoint - previousCodePoint) + 1`. `previousCodePoint`
///    starts at 0 and is updated only by non-null entries. Neighbouring
///    entries are usually close, so most varints are one byte.
/// 2. The bytes are zlib-compressed, then base64-encoded.
class IndexPacker {
  const IndexPacker();

  String pack(List<int?> entries) {
    final bytes = BytesBuilder(copy: false);
    var previous = 0;
    for (final entry in entries) {
      if (entry == null) {
        _writeVarint(bytes, 0);
        continue;
      }
      if (entry < 0 || entry > 0x10FFFF) {
        throw ArgumentError.value(entry, 'entry', 'not a Unicode code point');
      }
      _writeVarint(bytes, _zigzag(entry - previous) + 1);
      previous = entry;
    }
    final compressed = ZLibCodec(level: 9).encode(bytes.takeBytes());
    return base64.encode(compressed);
  }

  /// Reverses [pack]. Used by tests to prove the format round-trips.
  List<int?> unpack(String packed) {
    final bytes = ZLibCodec().decode(base64.decode(packed));
    final entries = <int?>[];
    var previous = 0;
    var i = 0;
    while (i < bytes.length) {
      var value = 0;
      var shift = 0;
      while (true) {
        final byte = bytes[i++];
        value |= (byte & 0x7F) << shift;
        if (byte < 0x80) break;
        shift += 7;
      }
      if (value == 0) {
        entries.add(null);
      } else {
        previous += _unzigzag(value - 1);
        entries.add(previous);
      }
    }
    return entries;
  }

  static int _zigzag(int n) => n >= 0 ? n << 1 : ((-n) << 1) - 1;

  static int _unzigzag(int n) => n.isEven ? n >> 1 : -((n + 1) >> 1);

  static void _writeVarint(BytesBuilder out, int value) {
    var v = value;
    while (v >= 0x80) {
      out.addByte((v & 0x7F) | 0x80);
      v >>= 7;
    }
    out.addByte(v);
  }
}
