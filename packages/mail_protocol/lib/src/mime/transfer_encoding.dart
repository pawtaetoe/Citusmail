// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'mime_defect.dart';

/// Content-Transfer-Encoding (RFC 2045, section 6).
enum TransferEncoding {
  sevenBit('7bit'),
  eightBit('8bit'),
  binary('binary'),
  quotedPrintable('quoted-printable'),
  base64('base64');

  const TransferEncoding(this.token);

  /// The header value, e.g. `quoted-printable`.
  final String token;

  /// Parses a header value. Returns null for unknown values, which callers
  /// treat as 7bit (no decoding) plus a defect, as RFC 2045 suggests.
  static TransferEncoding? parse(String value) {
    final normalized = value.trim().toLowerCase();
    for (final encoding in values) {
      if (encoding.token == normalized) return encoding;
    }
    return null;
  }

  /// Decodes a body in this encoding. Never throws.
  DecodedBytes decode(List<int> bytes, [int start = 0, int? end]) =>
      switch (this) {
        base64 => const Base64Decoder().decode(bytes, start, end),
        quotedPrintable => const QuotedPrintableDecoder().decode(
          bytes,
          start,
          end,
        ),
        _ => DecodedBytes(_view(bytes, start, end)),
      };

  /// A view of the bytes without copying when they are already a Uint8List.
  static Uint8List _view(List<int> bytes, int start, int? end) {
    final stop = RangeError.checkValidRange(start, end, bytes.length);
    return bytes is Uint8List
        ? Uint8List.sublistView(bytes, start, stop)
        : Uint8List.fromList(bytes.sublist(start, stop));
  }
}

/// Decoded bytes plus anything that was wrong with the input.
final class DecodedBytes {
  DecodedBytes(this.bytes, [List<MimeDefect> defects = const []])
    : defects = List.unmodifiable(defects);

  final Uint8List bytes;
  final List<MimeDefect> defects;
}

/// Lenient base64 decoder (RFC 2045, section 6.8).
///
/// Characters outside the base64 alphabet are skipped (the RFC says to
/// ignore them), decoding stops at padding, and a dangling partial group is
/// dropped. Anything unusual is reported as a defect.
final class Base64Decoder {
  const Base64Decoder();

  static final Int8List _values = () {
    final table = Int8List(256)..fillRange(0, 256, -1);
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    for (var i = 0; i < alphabet.length; i++) {
      table[alphabet.codeUnitAt(i)] = i;
    }
    return table;
  }();

  DecodedBytes decode(List<int> input, [int start = 0, int? end]) {
    final stop = RangeError.checkValidRange(start, end, input.length);
    final out = Uint8List(((stop - start) * 3) ~/ 4 + 3);
    var length = 0;
    var buffer = 0;
    var bits = 0;
    var sawGarbage = false;
    var sawPadding = false;
    var dataAfterPadding = false;

    for (var i = start; i < stop; i++) {
      final c = input[i];
      if (c == 0x3D) {
        sawPadding = true;
        continue;
      }
      final value = _values[c & 0xFF];
      if (value < 0) {
        if (!_isWhitespace(c)) sawGarbage = true;
        continue;
      }
      if (sawPadding) {
        // Some broken mailers concatenate base64 blocks; keep decoding,
        // but realign to a fresh group.
        dataAfterPadding = true;
        sawPadding = false;
        buffer = 0;
        bits = 0;
      }
      buffer = (buffer << 6) | value;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out[length++] = (buffer >> bits) & 0xFF;
        buffer &= (1 << bits) - 1;
      }
    }

    final defects = <MimeDefect>[
      if (sawGarbage)
        const MimeDefect(MimeDefectKind.invalidBase64, 'invalid characters'),
      if (dataAfterPadding)
        const MimeDefect(MimeDefectKind.invalidBase64, 'data after padding'),
      // 6 leftover bits means one dangling character: a truncated group.
      if (bits >= 6)
        const MimeDefect(MimeDefectKind.invalidBase64, 'truncated'),
    ];
    return DecodedBytes(Uint8List.sublistView(out, 0, length), defects);
  }

  static bool _isWhitespace(int c) =>
      c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A;
}

/// Lenient quoted-printable decoder (RFC 2045, section 6.7).
///
/// - `=XX` (hex, either case) becomes one byte.
/// - `=` at the end of a line (optionally followed by spaces) is a soft line
///   break and is removed with the line ending.
/// - Trailing spaces and tabs before a line ending are removed.
/// - Any other `=` is kept as-is and reported.
/// Line endings (CRLF or LF) are preserved as they appear.
final class QuotedPrintableDecoder {
  const QuotedPrintableDecoder();

  DecodedBytes decode(List<int> input, [int start = 0, int? end]) {
    final stop = RangeError.checkValidRange(start, end, input.length);
    final out = BytesBuilder(copy: false);
    final line = <int>[];
    var invalid = false;

    var i = start;
    while (i < stop) {
      // Find the end of this line and the length of its line ending.
      var lineEnd = i;
      while (lineEnd < stop && input[lineEnd] != 0x0A) {
        lineEnd++;
      }
      var contentEnd = lineEnd;
      if (contentEnd > i && lineEnd < stop && input[contentEnd - 1] == 0x0D) {
        contentEnd--;
      }
      final hasLineEnding = lineEnd < stop;

      // Rule 3: trailing whitespace is padding added in transit.
      var trimmedEnd = contentEnd;
      while (trimmedEnd > i && _isSpaceOrTab(input[trimmedEnd - 1])) {
        trimmedEnd--;
      }

      line.clear();
      var softBreak = false;
      for (var j = i; j < trimmedEnd; j++) {
        final c = input[j];
        if (c != 0x3D) {
          line.add(c);
          continue;
        }
        if (j == trimmedEnd - 1) {
          softBreak = true; // "=" at end of line
          break;
        }
        if (j + 2 < trimmedEnd) {
          final hi = _hexValue(input[j + 1]);
          final lo = _hexValue(input[j + 2]);
          if (hi >= 0 && lo >= 0) {
            line.add((hi << 4) | lo);
            j += 2;
            continue;
          }
        }
        invalid = true;
        line.add(c);
      }
      out.add(line);

      if (hasLineEnding && !softBreak) {
        // Keep the original line ending (CRLF or LF).
        if (contentEnd < lineEnd) out.addByte(0x0D);
        out.addByte(0x0A);
      }
      i = hasLineEnding ? lineEnd + 1 : stop;
    }

    return DecodedBytes(out.takeBytes(), [
      if (invalid) const MimeDefect(MimeDefectKind.invalidQuotedPrintable),
    ]);
  }

  static bool _isSpaceOrTab(int c) => c == 0x20 || c == 0x09;

  static int _hexValue(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30;
    if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
    return -1;
  }
}
