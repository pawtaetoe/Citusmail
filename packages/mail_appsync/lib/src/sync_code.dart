// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'cipher.dart';

/// The secret shared by the user's devices: 128 random bits, written as
/// 27 characters for typing (`7KQ2-M9XD-...`). The last character is a
/// check, so most typing mistakes are caught before anything is tried.
///
/// Characters are Crockford base32: no I, L, O or U, and reading is
/// forgiving (lower case, `o` for 0, `i`/`l` for 1, any spaces or dashes).
final class SyncCode {
  SyncCode._(this.bytes);

  /// A new random code.
  factory SyncCode.generate([Random? random]) {
    final r = random ?? Random.secure();
    return SyncCode._(
      Uint8List.fromList([for (var i = 0; i < 16; i++) r.nextInt(256)]),
    );
  }

  /// The code in [text], or null if it isn't one (wrong length or check).
  static SyncCode? parse(String text) {
    final clean = text
        .toUpperCase()
        .replaceAll(RegExp(r'[\s-]'), '')
        .replaceAll('O', '0')
        .replaceAll(RegExp('[IL]'), '1');
    if (clean.length != 27) return null;
    final values = <int>[];
    for (final ch in clean.split('')) {
      final v = _alphabet.indexOf(ch);
      if (v < 0) return null;
      values.add(v);
    }
    // 26 characters carry 130 bits: 128 of code and 2 zero bits.
    var number = BigInt.zero;
    for (final v in values.take(26)) {
      number = (number << 5) | BigInt.from(v);
    }
    if (number >> 128 != BigInt.zero) return null;
    final bytes = Uint8List(16);
    for (var i = 15; i >= 0; i--) {
      bytes[i] = (number & BigInt.from(0xFF)).toInt();
      number >>= 8;
    }
    final code = SyncCode._(bytes);
    return code._check == values.last ? code : null;
  }

  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  /// The 16 secret bytes.
  final Uint8List bytes;

  int get _check => sha256.convert(bytes).bytes.first & 0x1F;

  /// `XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXX`.
  @override
  String toString() {
    var number = BigInt.zero;
    for (final b in bytes) {
      number = (number << 8) | BigInt.from(b);
    }
    final chars = <String>[];
    for (var i = 0; i < 26; i++) {
      chars.insert(0, _alphabet[(number & BigInt.from(0x1F)).toInt()]);
      number >>= 5;
    }
    chars.add(_alphabet[_check]);
    final groups = <String>[];
    for (var i = 0; i < chars.length; i += 4) {
      groups.add(chars.sublist(i, min(i + 4, chars.length)).join());
    }
    return groups.join('-');
  }

  /// The keys derived from this code.
  SyncKeys get keys => SyncKeys._(
    Hkdf.derive(
      bytes,
      salt: utf8.encode('citusmail-sync'),
      info: utf8.encode('encryption v1'),
    ),
    _hex(
      Hkdf.derive(
        bytes,
        salt: utf8.encode('citusmail-sync'),
        info: utf8.encode('id v1'),
        length: 16,
      ),
    ),
  );

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  @override
  bool operator ==(Object other) {
    if (other is! SyncCode || other.bytes.length != bytes.length) return false;
    for (var i = 0; i < bytes.length; i++) {
      if (other.bytes[i] != bytes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(bytes);
}

/// What the code gives: the key that encrypts the data, and a public id
/// that tells which stored data belongs to this code (not secret: it
/// reveals nothing about the key).
final class SyncKeys {
  SyncKeys._(this.encryptionKey, this.syncId);

  final Uint8List encryptionKey;

  /// 32 hex characters.
  final String syncId;
}
