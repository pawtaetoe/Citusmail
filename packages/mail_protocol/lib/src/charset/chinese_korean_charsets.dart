// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Decoders for gb18030 (also used for GBK), Big5 and EUC-KR, following the
// WHATWG Encoding Standard algorithms step by step. "Prepend" in the spec
// (push bytes back to be read again) is done by moving the index back,
// which is valid because the pushed-back bytes are always the ones just read.

import 'charset.dart';
import 'code_point_index.dart';

const int _replacement = ByteDecoderCharset.replacement;

/// gb18030 and GBK (WHATWG decodes both with the gb18030 decoder).
final class Gb18030Charset extends ByteDecoderCharset {
  Gb18030Charset(super.name);

  late final CodePointIndex _index = CodePointIndex.named('gb18030');
  late final CodePointIndex _ranges = CodePointIndex.named('gb18030-ranges');

  @override
  void decodeInto(List<int> bytes, int start, int end, StringBuffer out) {
    var first = 0, second = 0, third = 0;
    var i = start;
    while (i < end) {
      final byte = bytes[i++];
      if (third != 0) {
        if (byte < 0x30 || byte > 0x39) {
          out.writeCharCode(_replacement);
          i -= 3; // prepend second, third, byte
          first = second = third = 0;
          continue;
        }
        final pointer =
            (first - 0x81) * (10 * 126 * 10) +
            (second - 0x30) * (10 * 126) +
            (third - 0x81) * 10 +
            byte -
            0x30;
        first = second = third = 0;
        final codePoint = _rangesCodePoint(pointer);
        out.writeCharCode(codePoint ?? _replacement);
        continue;
      }
      if (second != 0) {
        if (byte >= 0x81 && byte <= 0xFE) {
          third = byte;
          continue;
        }
        out.writeCharCode(_replacement);
        i -= 2; // prepend second, byte
        first = second = 0;
        continue;
      }
      if (first != 0) {
        if (byte >= 0x30 && byte <= 0x39) {
          second = byte;
          continue;
        }
        final lead = first;
        first = 0;
        final offset = byte < 0x7F ? 0x40 : 0x41;
        var codePoint = CodePointIndex.none;
        if ((byte >= 0x40 && byte <= 0x7E) || (byte >= 0x80 && byte <= 0xFE)) {
          codePoint = _index[(lead - 0x81) * 190 + (byte - offset)];
        }
        if (codePoint != CodePointIndex.none) {
          out.writeCharCode(codePoint);
          continue;
        }
        if (ByteDecoderCharset.isAscii(byte)) i--; // prepend byte
        out.writeCharCode(_replacement);
        continue;
      }
      if (ByteDecoderCharset.isAscii(byte)) {
        out.writeCharCode(byte);
      } else if (byte == 0x80) {
        out.writeCharCode(0x20AC);
      } else if (byte >= 0x81 && byte <= 0xFE) {
        first = byte;
      } else {
        out.writeCharCode(_replacement);
      }
    }
    if (first != 0 || second != 0 || third != 0) {
      out.writeCharCode(_replacement);
    }
  }

  /// WHATWG "index gb18030 ranges code point".
  int? _rangesCodePoint(int pointer) {
    if ((pointer > 39419 && pointer < 189000) || pointer > 1237575) return null;
    if (pointer == 7457) return 0xE7C7;
    // _ranges is flattened [pointer, codePoint, ...] sorted by pointer.
    var low = 0, high = _ranges.length ~/ 2 - 1, found = 0;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (_ranges[mid * 2] <= pointer) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return _ranges[found * 2 + 1] + pointer - _ranges[found * 2];
  }
}

/// Big5, including the HKSCS extensions in the WHATWG index.
final class Big5Charset extends ByteDecoderCharset {
  Big5Charset() : super('big5');

  late final CodePointIndex _index = CodePointIndex.named('big5');

  @override
  void decodeInto(List<int> bytes, int start, int end, StringBuffer out) {
    var lead = 0;
    var i = start;
    while (i < end) {
      final byte = bytes[i++];
      if (lead != 0) {
        final l = lead;
        lead = 0;
        final offset = byte < 0x7F ? 0x40 : 0x62;
        int? pointer;
        if ((byte >= 0x40 && byte <= 0x7E) || (byte >= 0xA1 && byte <= 0xFE)) {
          pointer = (l - 0x81) * 157 + (byte - offset);
        }
        switch (pointer) {
          // Four pointers decode to two code points each.
          case 1133:
            out
              ..writeCharCode(0x00CA)
              ..writeCharCode(0x0304);
            continue;
          case 1135:
            out
              ..writeCharCode(0x00CA)
              ..writeCharCode(0x030C);
            continue;
          case 1164:
            out
              ..writeCharCode(0x00EA)
              ..writeCharCode(0x0304);
            continue;
          case 1166:
            out
              ..writeCharCode(0x00EA)
              ..writeCharCode(0x030C);
            continue;
        }
        final codePoint = pointer == null
            ? CodePointIndex.none
            : _index[pointer];
        if (codePoint != CodePointIndex.none) {
          out.writeCharCode(codePoint);
          continue;
        }
        if (ByteDecoderCharset.isAscii(byte)) i--;
        out.writeCharCode(_replacement);
        continue;
      }
      if (ByteDecoderCharset.isAscii(byte)) {
        out.writeCharCode(byte);
      } else if (byte >= 0x81 && byte <= 0xFE) {
        lead = byte;
      } else {
        out.writeCharCode(_replacement);
      }
    }
    if (lead != 0) out.writeCharCode(_replacement);
  }
}

/// EUC-KR (the WHATWG index is the Windows-949 superset).
final class EucKrCharset extends ByteDecoderCharset {
  EucKrCharset() : super('euc-kr');

  late final CodePointIndex _index = CodePointIndex.named('euc-kr');

  @override
  void decodeInto(List<int> bytes, int start, int end, StringBuffer out) {
    var lead = 0;
    var i = start;
    while (i < end) {
      final byte = bytes[i++];
      if (lead != 0) {
        final l = lead;
        lead = 0;
        var codePoint = CodePointIndex.none;
        if (byte >= 0x41 && byte <= 0xFE) {
          codePoint = _index[(l - 0x81) * 190 + (byte - 0x41)];
        }
        if (codePoint != CodePointIndex.none) {
          out.writeCharCode(codePoint);
          continue;
        }
        if (ByteDecoderCharset.isAscii(byte)) i--;
        out.writeCharCode(_replacement);
        continue;
      }
      if (ByteDecoderCharset.isAscii(byte)) {
        out.writeCharCode(byte);
      } else if (byte >= 0x81 && byte <= 0xFE) {
        lead = byte;
      } else {
        out.writeCharCode(_replacement);
      }
    }
    if (lead != 0) out.writeCharCode(_replacement);
  }
}
