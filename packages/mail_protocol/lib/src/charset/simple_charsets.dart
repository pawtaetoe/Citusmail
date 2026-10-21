// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert' as convert;

import 'charset.dart';
import 'code_point_index.dart';

/// UTF-8, decoded with Dart's built-in decoder (invalid bytes become U+FFFD).
final class Utf8Charset extends Charset {
  const Utf8Charset() : super('utf-8');

  static const _decoder = convert.Utf8Decoder(allowMalformed: true);

  @override
  String decode(List<int> bytes, [int start = 0, int? end]) {
    final stop = RangeError.checkValidRange(start, end, bytes.length);
    return _decoder.convert(bytes, start, stop);
  }

  /// True if `bytes[start, end)` is valid UTF-8.
  static bool isValid(List<int> bytes, [int start = 0, int? end]) {
    final stop = RangeError.checkValidRange(start, end, bytes.length);
    try {
      const convert.Utf8Decoder().convert(bytes, start, stop);
      return true;
    } on FormatException {
      return false;
    }
  }
}

/// UTF-16 little or big endian (WHATWG "shared UTF-16 decoder").
final class Utf16Charset extends ByteDecoderCharset {
  const Utf16Charset.littleEndian() : bigEndian = false, super('utf-16le');

  const Utf16Charset.bigEndian() : bigEndian = true, super('utf-16be');

  final bool bigEndian;

  @override
  void decodeInto(List<int> bytes, int start, int end, StringBuffer out) {
    int? leadSurrogate;
    var i = start;
    for (; i + 1 < end; i += 2) {
      final unit = bigEndian
          ? (bytes[i] << 8) | bytes[i + 1]
          : bytes[i] | (bytes[i + 1] << 8);
      final lead = leadSurrogate;
      if (lead != null) {
        leadSurrogate = null;
        if (unit >= 0xDC00 && unit <= 0xDFFF) {
          out.writeCharCode(
            0x10000 + ((lead - 0xD800) << 10) + (unit - 0xDC00),
          );
          continue;
        }
        // Unpaired lead surrogate: error, then reprocess this unit.
        out.writeCharCode(ByteDecoderCharset.replacement);
      }
      if (unit >= 0xD800 && unit <= 0xDBFF) {
        leadSurrogate = unit;
      } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
        out.writeCharCode(ByteDecoderCharset.replacement);
      } else {
        out.writeCharCode(unit);
      }
    }
    // A dangling lead surrogate or odd byte at the end is one error.
    if (leadSurrogate != null || i < end) {
      out.writeCharCode(ByteDecoderCharset.replacement);
    }
  }
}

/// The legacy single-byte encodings (ISO-8859-x, windows-125x, KOI8, ...):
/// bytes below 0x80 are ASCII, the rest come from a 128-entry index.
final class SingleByteCharset extends ByteDecoderCharset {
  SingleByteCharset(super.name, this.indexName);

  final String indexName;
  late final CodePointIndex _index = CodePointIndex.named(indexName);

  @override
  void decodeInto(List<int> bytes, int start, int end, StringBuffer out) {
    for (var i = start; i < end; i++) {
      final byte = bytes[i];
      if (byte < 0x80) {
        out.writeCharCode(byte);
      } else {
        final codePoint = _index[byte - 0x80];
        out.writeCharCode(
          codePoint == CodePointIndex.none
              ? ByteDecoderCharset.replacement
              : codePoint,
        );
      }
    }
  }
}

/// x-user-defined: high bytes map to the private use area U+F780..U+F7FF.
final class UserDefinedCharset extends ByteDecoderCharset {
  const UserDefinedCharset() : super('x-user-defined');

  @override
  void decodeInto(List<int> bytes, int start, int end, StringBuffer out) {
    for (var i = start; i < end; i++) {
      final byte = bytes[i];
      out.writeCharCode(byte < 0x80 ? byte : 0xF780 + byte - 0x80);
    }
  }
}

/// The "replacement" encoding: labels for encodings that are unsafe to
/// decode (ISO-2022-KR, HZ, ...). Any input decodes to a single U+FFFD.
final class ReplacementCharset extends ByteDecoderCharset {
  const ReplacementCharset() : super('replacement');

  @override
  void decodeInto(List<int> bytes, int start, int end, StringBuffer out) {
    if (end > start) out.writeCharCode(ByteDecoderCharset.replacement);
  }
}
