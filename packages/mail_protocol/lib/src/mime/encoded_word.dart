// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import '../charset/charsets.dart';
import '../charset/text_decoder.dart';
import 'mime_defect.dart';
import 'transfer_encoding.dart';

/// Text decoded from a header, plus anything that was wrong with it.
final class DecodedHeaderText {
  DecodedHeaderText(this.text, [List<MimeDefect> defects = const []])
    : defects = List.unmodifiable(defects);

  final String text;
  final List<MimeDefect> defects;
}

/// Decodes RFC 2047 encoded words (`=?charset?B|Q?data?=`) in header text.
///
/// Lenient in the ways common mail clients are:
/// - whitespace between adjacent encoded words is removed (RFC 2047 6.2);
/// - adjacent words in the same charset are joined as bytes before
///   decoding, so a character split across two words still decodes;
/// - words touching other text are decoded too;
/// - unknown charsets fall back to UTF-8 or Windows-1252.
///
/// Control characters in the result (including CR and LF hidden inside an
/// encoded word) become spaces, so decoded text can never inject a header
/// line when it is reused, for example in a reply subject.
final class EncodedWordDecoder {
  const EncodedWordDecoder();

  static final _encodedWord = RegExp(r'=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?=');
  static final _onlyWhitespace = RegExp(r'^[ \t\r\n]*$');

  DecodedHeaderText decode(String input) {
    final defects = <MimeDefect>[];
    final out = StringBuffer();

    // Pending run of adjacent encoded words in one charset.
    String? runCharset;
    final runBytes = BytesBuilder(copy: false);

    void flushRun() {
      final label = runCharset;
      if (label == null) return;
      final bytes = runBytes.takeBytes();
      final charset = Charsets.forLabel(label);
      if (charset == null) {
        defects.add(
          const MimeDefect(MimeDefectKind.unknownCharset, 'encoded word'),
        );
        out.write(const TextDecoder().decode(bytes).text);
      } else {
        out.write(charset.decode(bytes));
      }
      runCharset = null;
    }

    final matches = _encodedWord.allMatches(input).toList();
    var position = 0;
    for (final match in matches) {
      if (!_isAscii(match.group(0)!)) {
        // Encoded words must be ASCII; leave a broken one as literal text.
        defects.add(
          const MimeDefect(MimeDefectKind.invalidEncodedWord, 'not ASCII'),
        );
        continue;
      }
      final between = input.substring(position, match.start);
      final continuesRun =
          runCharset != null && _onlyWhitespace.hasMatch(between);
      if (!continuesRun) {
        flushRun();
        out.write(between);
      }

      // RFC 2231 allows a language suffix: charset*lang.
      final label = match.group(1)!.split('*').first;
      final payload = match.group(3)!;
      final decoded = match.group(2)!.toUpperCase() == 'B'
          ? _decodeB(payload, defects)
          : _decodeQ(payload, defects);

      if (runCharset != null &&
          runCharset!.toLowerCase() != label.toLowerCase()) {
        flushRun();
      }
      runCharset = label;
      runBytes.add(decoded);
      position = match.end;
    }
    flushRun();
    final rest = input.substring(position);
    out.write(rest);

    if (_hasUnmatchedStart(input, matches)) {
      defects.add(const MimeDefect(MimeDefectKind.invalidEncodedWord));
    }
    return DecodedHeaderText(_replaceControls(out.toString()), defects);
  }

  /// Whether some "=?" is not the start of, or inside, a valid encoded
  /// word. One pass over the input and the (sorted) matches.
  static bool _hasUnmatchedStart(String input, List<RegExpMatch> matches) {
    var next = 0; // first match that may contain or follow index
    var index = input.indexOf('=?');
    while (index >= 0) {
      while (next < matches.length && matches[next].end <= index) {
        next++;
      }
      final covered = next < matches.length && matches[next].start <= index;
      if (!covered) return true;
      index = input.indexOf('=?', index + 1);
    }
    return false;
  }

  static bool _isAscii(String s) => s.codeUnits.every((c) => c < 0x80);

  static Uint8List _decodeB(String payload, List<MimeDefect> defects) {
    final result = const Base64Decoder().decode(payload.codeUnits);
    if (result.defects.isNotEmpty) {
      defects.add(
        const MimeDefect(MimeDefectKind.invalidEncodedWord, 'base64'),
      );
    }
    return result.bytes;
  }

  /// "Q" encoding: like quoted-printable, but "_" means space.
  static Uint8List _decodeQ(String payload, List<MimeDefect> defects) {
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < payload.length; i++) {
      final c = payload.codeUnitAt(i);
      if (c == 0x5F) {
        out.addByte(0x20);
      } else if (c == 0x3D) {
        final hi = i + 2 < payload.length
            ? _hex(payload.codeUnitAt(i + 1))
            : -1;
        final lo = i + 2 < payload.length
            ? _hex(payload.codeUnitAt(i + 2))
            : -1;
        if (hi >= 0 && lo >= 0) {
          out.addByte((hi << 4) | lo);
          i += 2;
        } else {
          defects.add(const MimeDefect(MimeDefectKind.invalidEncodedWord, 'Q'));
          out.addByte(c);
        }
      } else {
        out.addByte(c); // ASCII, checked by the caller
      }
    }
    return out.takeBytes();
  }

  static int _hex(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30;
    if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
    return -1;
  }

  static String _replaceControls(String s) =>
      s.replaceAll(RegExp(r'[\x00-\x08\x0A-\x1F\x7F]'), ' ');
}
