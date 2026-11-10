// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math';
import 'dart:typed_data';

/// X25519 key agreement (RFC 7748 section 5), with big integers like
/// `Poly1305` in mail_appsync: slower than limb arithmetic and not
/// constant-time, which is acceptable here because every key is used for
/// one pairing only and lives a few minutes in memory. Checked against the
/// RFC's test vectors.
abstract final class X25519 {
  static const keyLength = 32;

  static final _p = (BigInt.one << 255) - BigInt.from(19);
  static final _a24 = BigInt.from(121665);
  static final _basePoint = Uint8List(32)..[0] = 9;

  /// A new random private key.
  static Uint8List newPrivateKey([Random? random]) {
    final r = random ?? Random.secure();
    return Uint8List.fromList([for (var i = 0; i < 32; i++) r.nextInt(256)]);
  }

  /// The public key of [privateKey].
  static Uint8List publicKey(List<int> privateKey) =>
      scalarMult(privateKey, _basePoint);

  /// The shared secret of [privateKey] and the other side's [publicKey].
  /// Throws [ArgumentError] for a public key that gives the all-zero
  /// result (a small-order point: someone is interfering).
  static Uint8List sharedSecret(List<int> privateKey, List<int> publicKey) {
    final shared = scalarMult(privateKey, publicKey);
    if (shared.every((b) => b == 0)) {
      throw ArgumentError('unusable public key');
    }
    return shared;
  }

  /// The X25519 function: scalar [k] times the point with u-coordinate [u].
  static Uint8List scalarMult(List<int> k, List<int> u) {
    if (k.length != 32 || u.length != 32) {
      throw ArgumentError('keys are 32 bytes');
    }
    final scalarBytes = Uint8List.fromList(k);
    scalarBytes[0] &= 248;
    scalarBytes[31] &= 127;
    scalarBytes[31] |= 64;
    final scalar = _decode(scalarBytes);
    final uBytes = Uint8List.fromList(u);
    uBytes[31] &= 127;
    final x1 = _decode(uBytes) % _p;

    var x2 = BigInt.one;
    var z2 = BigInt.zero;
    var x3 = x1;
    var z3 = BigInt.one;
    var swap = 0;
    for (var t = 254; t >= 0; t--) {
      final bit = ((scalar >> t) & BigInt.one).toInt();
      swap ^= bit;
      if (swap == 1) {
        (x2, x3) = (x3, x2);
        (z2, z3) = (z3, z2);
      }
      swap = bit;
      final a = (x2 + z2) % _p;
      final aa = (a * a) % _p;
      final b = (x2 - z2) % _p;
      final bb = (b * b) % _p;
      final e = (aa - bb) % _p;
      final c = (x3 + z3) % _p;
      final d = (x3 - z3) % _p;
      final da = (d * a) % _p;
      final cb = (c * b) % _p;
      final sum = (da + cb) % _p;
      final difference = (da - cb) % _p;
      x3 = (sum * sum) % _p;
      z3 = (x1 * difference * difference) % _p;
      x2 = (aa * bb) % _p;
      z2 = (e * (aa + _a24 * e)) % _p;
    }
    if (swap == 1) {
      (x2, x3) = (x3, x2);
      (z2, z3) = (z3, z2);
    }
    return _encode((x2 * z2.modPow(_p - BigInt.two, _p)) % _p);
  }

  static BigInt _decode(List<int> bytes) {
    var value = BigInt.zero;
    for (var i = bytes.length - 1; i >= 0; i--) {
      value = (value << 8) | BigInt.from(bytes[i]);
    }
    return value;
  }

  static Uint8List _encode(BigInt value) {
    final out = Uint8List(32);
    var v = value;
    for (var i = 0; i < 32; i++) {
      out[i] = (v & BigInt.from(0xFF)).toInt();
      v >>= 8;
    }
    return out;
  }
}
