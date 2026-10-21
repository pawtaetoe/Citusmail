// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

/// IMAP "modified UTF-7" mailbox names (RFC 3501 5.1.3): printable ASCII
/// stays as is, "&" is written "&-", and other text is UTF-16 in a
/// base64 variant (with "," instead of "/") between "&" and "-".
abstract final class MailboxNameCodec {
  static String encode(String name) {
    final out = StringBuffer();
    final pending = <int>[];

    void flush() {
      if (pending.isEmpty) return;
      final utf16 = Uint8List(pending.length * 2);
      for (var i = 0; i < pending.length; i++) {
        utf16[i * 2] = pending[i] >> 8;
        utf16[i * 2 + 1] = pending[i] & 0xFF;
      }
      final b64 = base64.encode(utf16).replaceAll('=', '').replaceAll('/', ',');
      out.write('&$b64-');
      pending.clear();
    }

    for (final unit in name.codeUnits) {
      if (unit >= 0x20 && unit <= 0x7E) {
        flush();
        out.write(unit == 0x26 ? '&-' : String.fromCharCode(unit));
      } else {
        pending.add(unit);
      }
    }
    flush();
    return out.toString();
  }

  /// Decodes a name from the server. Returns the input unchanged if it is
  /// not valid modified UTF-7 (some servers send raw UTF-8 instead).
  static String decode(String encoded) {
    if (!encoded.contains('&')) return encoded;
    final out = StringBuffer();
    var i = 0;
    while (i < encoded.length) {
      final c = encoded[i];
      if (c != '&') {
        out.write(c);
        i++;
        continue;
      }
      final end = encoded.indexOf('-', i + 1);
      if (end < 0) return encoded;
      if (end == i + 1) {
        out.write('&');
        i = end + 1;
        continue;
      }
      final b64 = encoded.substring(i + 1, end).replaceAll(',', '/');
      if (!RegExp(r'^[A-Za-z0-9+/]+$').hasMatch(b64)) return encoded;
      final padded = b64.padRight((b64.length + 3) ~/ 4 * 4, '=');
      final Uint8List bytes;
      try {
        bytes = base64.decode(padded);
      } on FormatException {
        return encoded;
      }
      if (bytes.length.isOdd) return encoded;
      final units = [
        for (var k = 0; k < bytes.length; k += 2)
          (bytes[k] << 8) | bytes[k + 1],
      ];
      out.write(String.fromCharCodes(units));
      i = end + 1;
    }
    return out.toString();
  }
}
