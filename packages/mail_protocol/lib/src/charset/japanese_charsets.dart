// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Decoders for Shift_JIS, EUC-JP and ISO-2022-JP, following the WHATWG
// Encoding Standard algorithms step by step.

import 'charset.dart';
import 'code_point_index.dart';

const int _replacement = ByteDecoderCharset.replacement;

final class ShiftJisCharset extends ByteDecoderCharset {
  ShiftJisCharset() : super('shift_jis');

  late final CodePointIndex _jis0208 = CodePointIndex.named('jis0208');

  @override
  void decodeInto(List<int> bytes, int start, int end, StringBuffer out) {
    var lead = 0;
    var i = start;
    while (i < end) {
      final byte = bytes[i++];
      if (lead != 0) {
        final l = lead;
        lead = 0;
        final offset = byte < 0x7F ? 0x40 : 0x41;
        final leadOffset = l < 0xA0 ? 0x81 : 0xC1;
        int? pointer;
        if ((byte >= 0x40 && byte <= 0x7E) || (byte >= 0x80 && byte <= 0xFC)) {
          pointer = (l - leadOffset) * 188 + byte - offset;
        }
        if (pointer != null && pointer >= 8836 && pointer <= 10715) {
          out.writeCharCode(0xE000 - 8836 + pointer); // private use area
          continue;
        }
        final codePoint = pointer == null
            ? CodePointIndex.none
            : _jis0208[pointer];
        if (codePoint != CodePointIndex.none) {
          out.writeCharCode(codePoint);
          continue;
        }
        if (ByteDecoderCharset.isAscii(byte)) i--;
        out.writeCharCode(_replacement);
        continue;
      }
      if (ByteDecoderCharset.isAscii(byte) || byte == 0x80) {
        out.writeCharCode(byte);
      } else if (byte >= 0xA1 && byte <= 0xDF) {
        out.writeCharCode(0xFF61 - 0xA1 + byte); // half-width katakana
      } else if ((byte >= 0x81 && byte <= 0x9F) ||
          (byte >= 0xE0 && byte <= 0xFC)) {
        lead = byte;
      } else {
        out.writeCharCode(_replacement);
      }
    }
    if (lead != 0) out.writeCharCode(_replacement);
  }
}

final class EucJpCharset extends ByteDecoderCharset {
  EucJpCharset() : super('euc-jp');

  late final CodePointIndex _jis0208 = CodePointIndex.named('jis0208');
  late final CodePointIndex _jis0212 = CodePointIndex.named('jis0212');

  @override
  void decodeInto(List<int> bytes, int start, int end, StringBuffer out) {
    var lead = 0;
    var useJis0212 = false;
    var i = start;
    while (i < end) {
      final byte = bytes[i++];
      if (lead == 0x8E && byte >= 0xA1 && byte <= 0xDF) {
        lead = 0;
        out.writeCharCode(0xFF61 - 0xA1 + byte);
        continue;
      }
      if (lead == 0x8F && byte >= 0xA1 && byte <= 0xFE) {
        useJis0212 = true;
        lead = byte;
        continue;
      }
      if (lead != 0) {
        final l = lead;
        lead = 0;
        var codePoint = CodePointIndex.none;
        if (l >= 0xA1 && l <= 0xFE && byte >= 0xA1 && byte <= 0xFE) {
          final index = useJis0212 ? _jis0212 : _jis0208;
          codePoint = index[(l - 0xA1) * 94 + byte - 0xA1];
        }
        useJis0212 = false;
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
      } else if (byte == 0x8E ||
          byte == 0x8F ||
          (byte >= 0xA1 && byte <= 0xFE)) {
        lead = byte;
      } else {
        out.writeCharCode(_replacement);
      }
    }
    if (lead != 0) out.writeCharCode(_replacement);
  }
}

enum _Iso2022JpState {
  ascii,
  roman,
  katakana,
  leadByte,
  trailByte,
  escapeStart,
  escape,
}

/// ISO-2022-JP: a stateful 7-bit encoding switched by escape sequences.
/// Common in Japanese mail, including RFC 2047 encoded words.
final class Iso2022JpCharset extends ByteDecoderCharset {
  Iso2022JpCharset() : super('iso-2022-jp');

  late final CodePointIndex _jis0208 = CodePointIndex.named('jis0208');

  @override
  void decodeInto(List<int> bytes, int start, int end, StringBuffer out) {
    var state = _Iso2022JpState.ascii;
    var outputState = _Iso2022JpState.ascii;
    var lead = 0;
    // True right after an escape sequence; two escapes in a row with no
    // output between them are an error (WHATWG "output flag").
    var outputFlag = false;
    var i = start;

    void error() => out.writeCharCode(_replacement);

    while (i < end) {
      final byte = bytes[i++];
      switch (state) {
        case _Iso2022JpState.ascii:
          if (byte == 0x1B) {
            state = _Iso2022JpState.escapeStart;
          } else if (byte <= 0x7F && byte != 0x0E && byte != 0x0F) {
            outputFlag = false;
            out.writeCharCode(byte);
          } else {
            outputFlag = false;
            error();
          }
        case _Iso2022JpState.roman:
          if (byte == 0x1B) {
            state = _Iso2022JpState.escapeStart;
          } else if (byte == 0x5C) {
            outputFlag = false;
            out.writeCharCode(0x00A5);
          } else if (byte == 0x7E) {
            outputFlag = false;
            out.writeCharCode(0x203E);
          } else if (byte <= 0x7F && byte != 0x0E && byte != 0x0F) {
            outputFlag = false;
            out.writeCharCode(byte);
          } else {
            outputFlag = false;
            error();
          }
        case _Iso2022JpState.katakana:
          if (byte == 0x1B) {
            state = _Iso2022JpState.escapeStart;
          } else if (byte >= 0x21 && byte <= 0x5F) {
            outputFlag = false;
            out.writeCharCode(0xFF61 - 0x21 + byte);
          } else {
            outputFlag = false;
            error();
          }
        case _Iso2022JpState.leadByte:
          if (byte == 0x1B) {
            state = _Iso2022JpState.escapeStart;
          } else if (byte >= 0x21 && byte <= 0x7E) {
            outputFlag = false;
            lead = byte;
            state = _Iso2022JpState.trailByte;
          } else {
            outputFlag = false;
            error();
          }
        case _Iso2022JpState.trailByte:
          if (byte == 0x1B) {
            state = _Iso2022JpState.escapeStart;
            error();
          } else if (byte >= 0x21 && byte <= 0x7E) {
            state = _Iso2022JpState.leadByte;
            final codePoint = _jis0208[(lead - 0x21) * 94 + byte - 0x21];
            if (codePoint == CodePointIndex.none) {
              error();
            } else {
              out.writeCharCode(codePoint);
            }
          } else {
            state = _Iso2022JpState.leadByte;
            error();
          }
        case _Iso2022JpState.escapeStart:
          if (byte == 0x24 || byte == 0x28) {
            lead = byte;
            state = _Iso2022JpState.escape;
          } else {
            i--; // prepend byte
            outputFlag = false;
            state = outputState;
            error();
          }
        case _Iso2022JpState.escape:
          final l = lead;
          lead = 0;
          final next = switch ((l, byte)) {
            (0x28, 0x42) => _Iso2022JpState.ascii,
            (0x28, 0x4A) => _Iso2022JpState.roman,
            (0x28, 0x49) => _Iso2022JpState.katakana,
            (0x24, 0x40) || (0x24, 0x42) => _Iso2022JpState.leadByte,
            _ => null,
          };
          if (next != null) {
            state = outputState = next;
            final hadOutputFlag = outputFlag;
            outputFlag = true;
            if (hadOutputFlag) error();
          } else {
            i -= 2; // prepend lead and byte
            outputFlag = false;
            state = outputState;
            error();
          }
      }
    }
    // End of input inside a sequence.
    switch (state) {
      case _Iso2022JpState.trailByte:
      case _Iso2022JpState.escapeStart:
        error();
      case _Iso2022JpState.escape:
        // WHATWG: error, then the pushed-back lead byte (0x24 or 0x28) is
        // read again in the output state before the input ends.
        error();
        switch (outputState) {
          case _Iso2022JpState.ascii || _Iso2022JpState.roman:
            out.writeCharCode(lead);
          case _Iso2022JpState.katakana:
            out.writeCharCode(0xFF61 - 0x21 + lead);
          case _Iso2022JpState.leadByte:
            error(); // becomes a lead byte, then input ends in trail state
          default:
            break;
        }
      default:
        break;
    }
  }
}
