// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A stored PIN: PBKDF2-HMAC-SHA256 with a random salt. The PIN itself is
/// never stored.
final class PinHash {
  const PinHash(this.iterations, this.salt, this.hash);

  final int iterations;
  final Uint8List salt;
  final Uint8List hash;

  /// `pbkdf2-sha256$<iterations>$<salt>$<hash>` (base64).
  String encode() =>
      'pbkdf2-sha256\$$iterations\$${base64.encode(salt)}\$${base64.encode(hash)}';

  /// Null for anything that isn't a hash this app wrote.
  static PinHash? decode(String? text) {
    final parts = text?.split(r'$');
    if (parts == null || parts.length != 4 || parts[0] != 'pbkdf2-sha256') {
      return null;
    }
    final iterations = int.tryParse(parts[1]);
    if (iterations == null || iterations < 1 || iterations > 10000000) {
      return null;
    }
    try {
      return PinHash(
        iterations,
        base64.decode(parts[2]),
        base64.decode(parts[3]),
      );
    } on FormatException {
      return null;
    }
  }
}

/// Hashes and checks PINs. The work runs in a separate isolate, so the
/// screen stays smooth while it takes its (deliberate) fraction of a
/// second.
abstract final class PinHasher {
  /// PBKDF2 rounds for new PINs.
  static const iterations = 150000;

  static Future<PinHash> hash(String pin, {int rounds = iterations}) {
    final salt = _randomBytes(16);
    return Isolate.run(
      () => PinHash(rounds, salt, pbkdf2(utf8.encode(pin), salt, rounds, 32)),
    );
  }

  /// Whether [pin] matches [stored]; compares in constant time.
  static Future<bool> verify(String pin, PinHash stored) async {
    final candidate = await Isolate.run(
      () => pbkdf2(
        utf8.encode(pin),
        stored.salt,
        stored.iterations,
        stored.hash.length,
      ),
    );
    if (candidate.length != stored.hash.length) return false;
    var difference = 0;
    for (var i = 0; i < candidate.length; i++) {
      difference |= candidate[i] ^ stored.hash[i];
    }
    return difference == 0;
  }

  /// PBKDF2 with HMAC-SHA256 (RFC 8018).
  static Uint8List pbkdf2(
    List<int> password,
    List<int> salt,
    int rounds,
    int length,
  ) {
    final hmac = Hmac(sha256, password);
    final out = BytesBuilder(copy: false);
    for (var block = 1; out.length < length; block++) {
      var u = hmac.convert([
        ...salt,
        block >> 24 & 0xFF,
        block >> 16 & 0xFF,
        block >> 8 & 0xFF,
        block & 0xFF,
      ]).bytes;
      final t = Uint8List.fromList(u);
      for (var i = 1; i < rounds; i++) {
        u = hmac.convert(u).bytes;
        for (var j = 0; j < t.length; j++) {
          t[j] ^= u[j];
        }
      }
      out.add(t);
    }
    return Uint8List.sublistView(out.takeBytes(), 0, length);
  }

  static Uint8List _randomBytes(int count) {
    final random = Random.secure();
    return Uint8List.fromList([
      for (var i = 0; i < count; i++) random.nextInt(256),
    ]);
  }
}
