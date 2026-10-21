// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'charset.dart';
import 'charsets.dart';
import 'simple_charsets.dart';

/// How a piece of text was decoded.
enum CharsetSource {
  /// The declared charset was used.
  declared,

  /// A byte order mark overrode the declared charset.
  byteOrderMark,

  /// No charset was declared, or it was unknown, so one was guessed:
  /// UTF-8 if the bytes are valid UTF-8, otherwise Windows-1252.
  guessed,
}

/// Decoded text plus how it was decoded.
final class DecodedText {
  const DecodedText(this.text, this.charset, this.source);

  final String text;
  final Charset charset;
  final CharsetSource source;
}

/// Decodes mail text from bytes using a declared charset label.
///
/// Never throws. Unknown or missing labels fall back to a guess, so a
/// message with a wrong `charset=` still shows readable text.
final class TextDecoder {
  const TextDecoder();

  DecodedText decode(
    List<int> bytes, {
    String? charsetLabel,
    int start = 0,
    int? end,
  }) {
    final stop = RangeError.checkValidRange(start, end, bytes.length);

    final bom = _sniffByteOrderMark(bytes, start, stop);
    if (bom != null) {
      final (charset, length) = bom;
      return DecodedText(
        charset.decode(bytes, start + length, stop),
        charset,
        CharsetSource.byteOrderMark,
      );
    }

    final declared = charsetLabel == null
        ? null
        : Charsets.forLabel(charsetLabel);
    if (declared != null) {
      return DecodedText(
        declared.decode(bytes, start, stop),
        declared,
        CharsetSource.declared,
      );
    }

    final guess = Utf8Charset.isValid(bytes, start, stop)
        ? Charsets.utf8
        : Charsets.windows1252;
    return DecodedText(
      guess.decode(bytes, start, stop),
      guess,
      CharsetSource.guessed,
    );
  }

  static (Charset, int)? _sniffByteOrderMark(List<int> b, int start, int end) {
    final n = end - start;
    if (n >= 3 &&
        b[start] == 0xEF &&
        b[start + 1] == 0xBB &&
        b[start + 2] == 0xBF) {
      return (Charsets.utf8, 3);
    }
    if (n >= 2 && b[start] == 0xFE && b[start + 1] == 0xFF) {
      return (Charsets.forName('utf-16be')!, 2);
    }
    if (n >= 2 && b[start] == 0xFF && b[start + 1] == 0xFE) {
      return (Charsets.forName('utf-16le')!, 2);
    }
    return null;
  }
}
