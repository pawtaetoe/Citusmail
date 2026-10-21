// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import '../transfer_encoding.dart';

/// An encoded body: the bytes to write and the encoding used.
final class EncodedBody {
  const EncodedBody(this.bytes, this.encoding);

  final List<int> bytes;
  final TransferEncoding encoding;
}

/// Encodes bodies for sending. Output always uses CRLF and keeps lines
/// short enough for every mail server (RFC 5322 2.1.1).
final class BodyEncoder {
  const BodyEncoder();

  static const int maxLineLength = 76;

  /// Text as UTF-8: 7bit when it is plain short-lined ASCII, otherwise
  /// quoted-printable (mostly Latin text) or base64 (mostly other scripts).
  EncodedBody encodeText(String text) {
    final normalized = normalizeLineEndings(text);
    final bytes = utf8.encode(normalized);
    final nonAscii = bytes.where((b) => b >= 0x80).length;
    if (nonAscii == 0 &&
        _linesFit(normalized, 998) &&
        !normalized.contains('\r\nFrom ') &&
        !normalized.startsWith('From ')) {
      return EncodedBody(bytes, TransferEncoding.sevenBit);
    }
    if (nonAscii * 3 > bytes.length) {
      return EncodedBody(encodeBase64(bytes), TransferEncoding.base64);
    }
    return EncodedBody(
      encodeQuotedPrintable(bytes),
      TransferEncoding.quotedPrintable,
    );
  }

  /// Converts every line ending (CRLF, LF or a lone CR) to CRLF.
  static String normalizeLineEndings(String text) => text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\n', '\r\n');

  /// Base64 in lines of 76 characters.
  static List<int> encodeBase64(List<int> bytes) {
    final encoded = base64.encode(bytes);
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < encoded.length; i += maxLineLength) {
      final end = i + maxLineLength < encoded.length
          ? i + maxLineLength
          : encoded.length;
      out
        ..add(ascii.encode(encoded.substring(i, end)))
        ..add(const [0x0D, 0x0A]);
    }
    return out.takeBytes();
  }

  /// Quoted-printable (RFC 2045 6.7) for CRLF text. Lines stay within 76
  /// characters using soft breaks; an escape is never split; trailing
  /// whitespace is escaped; "From " at a line start is escaped so mbox
  /// tools cannot mangle it.
  static List<int> encodeQuotedPrintable(List<int> bytes) {
    final out = BytesBuilder(copy: false);
    var lineStart = 0;
    for (var i = 0; i <= bytes.length; i++) {
      final atEnd = i == bytes.length;
      if (atEnd ||
          (bytes[i] == 0x0D && i + 1 < bytes.length && bytes[i + 1] == 0x0A)) {
        _encodeQpLine(bytes, lineStart, i, out);
        if (!atEnd) {
          out.add(const [0x0D, 0x0A]);
          i++; // skip LF
          lineStart = i + 1;
        }
      }
    }
    return out.takeBytes();
  }

  static void _encodeQpLine(
    List<int> bytes,
    int start,
    int end,
    BytesBuilder out,
  ) {
    var column = 0;
    for (var i = start; i < end; i++) {
      final b = bytes[i];
      final isLast = i == end - 1;
      final fromAtStart =
          i == start && b == 0x46 && _startsWith(bytes, i, end, 'From ');
      final literal =
          !fromAtStart &&
          ((b >= 0x21 && b <= 0x7E && b != 0x3D) ||
              ((b == 0x20 || b == 0x09) && !isLast));
      final token = literal
          ? [b]
          : ascii.encode(
              '=${b.toRadixString(16).toUpperCase().padLeft(2, '0')}',
            );
      // Keep room for the "=" of a soft break unless this is the last token.
      final limit = isLast ? maxLineLength : maxLineLength - 1;
      if (column + token.length > limit) {
        out.add(const [0x3D, 0x0D, 0x0A]);
        column = 0;
      }
      out.add(token);
      column += token.length;
    }
  }

  static bool _startsWith(List<int> bytes, int i, int end, String prefix) {
    if (end - i < prefix.length) return false;
    for (var k = 0; k < prefix.length; k++) {
      if (bytes[i + k] != prefix.codeUnitAt(k)) return false;
    }
    return true;
  }

  static bool _linesFit(String crlfText, int max) =>
      crlfText.split('\r\n').every((line) => line.length <= max);
}
