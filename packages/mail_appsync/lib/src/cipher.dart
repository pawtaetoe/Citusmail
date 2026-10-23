// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The data was changed, or encrypted with another key.
final class AuthenticationFailed implements Exception {
  const AuthenticationFailed();

  @override
  String toString() => 'AuthenticationFailed: wrong key or damaged data';
}

/// ChaCha20-Poly1305 (RFC 8439): encryption that also detects any change
/// to the data or to its associated data.
abstract final class ChaCha20Poly1305 {
  static const keyLength = 32;
  static const nonceLength = 12;
  static const tagLength = 16;

  /// [plaintext] encrypted, with the 16-byte tag appended.
  static Uint8List encrypt(
    List<int> key,
    List<int> nonce,
    List<int> plaintext, {
    List<int> aad = const [],
  }) {
    _checkSizes(key, nonce);
    final ciphertext = ChaCha20.apply(key, nonce, plaintext, counter: 1);
    final tag = _tag(key, nonce, aad, ciphertext);
    return Uint8List(ciphertext.length + tagLength)
      ..setRange(0, ciphertext.length, ciphertext)
      ..setRange(ciphertext.length, ciphertext.length + tagLength, tag);
  }

  /// The plaintext; throws [AuthenticationFailed] if [sealed] or [aad]
  /// was changed or the key is wrong. Nothing is decrypted before the tag
  /// is checked.
  static Uint8List decrypt(
    List<int> key,
    List<int> nonce,
    List<int> sealed, {
    List<int> aad = const [],
  }) {
    _checkSizes(key, nonce);
    if (sealed.length < tagLength) throw const AuthenticationFailed();
    final split = sealed.length - tagLength;
    final ciphertext = Uint8List.fromList(sealed.sublist(0, split));
    final expected = _tag(key, nonce, aad, ciphertext);
    var difference = 0;
    for (var i = 0; i < tagLength; i++) {
      difference |= expected[i] ^ sealed[split + i];
    }
    if (difference != 0) throw const AuthenticationFailed();
    return ChaCha20.apply(key, nonce, ciphertext, counter: 1);
  }

  static Uint8List _tag(
    List<int> key,
    List<int> nonce,
    List<int> aad,
    List<int> ciphertext,
  ) {
    final polyKey = ChaCha20.block(key, nonce, 0).sublist(0, 32);
    final data = BytesBuilder(copy: false)
      ..add(aad)
      ..add(Uint8List(_pad16(aad.length)))
      ..add(ciphertext)
      ..add(Uint8List(_pad16(ciphertext.length)))
      ..add(_le64(aad.length))
      ..add(_le64(ciphertext.length));
    return Poly1305.mac(polyKey, data.takeBytes());
  }

  static int _pad16(int length) => (16 - length % 16) % 16;

  static Uint8List _le64(int value) {
    final out = Uint8List(8);
    for (var i = 0; i < 8; i++) {
      out[i] = (value >> (8 * i)) & 0xFF;
    }
    return out;
  }

  static void _checkSizes(List<int> key, List<int> nonce) {
    if (key.length != keyLength) throw ArgumentError('key must be 32 bytes');
    if (nonce.length != nonceLength) {
      throw ArgumentError('nonce must be 12 bytes');
    }
  }
}

/// The ChaCha20 stream cipher (RFC 8439 section 2.4).
abstract final class ChaCha20 {
  static const _mask = 0xFFFFFFFF;

  /// XORs [data] with the key stream starting at block [counter].
  static Uint8List apply(
    List<int> key,
    List<int> nonce,
    List<int> data, {
    int counter = 0,
  }) {
    final out = Uint8List(data.length);
    for (var offset = 0, block = counter; offset < data.length; block++) {
      final stream = ChaCha20.block(key, nonce, block);
      final end = offset + 64 < data.length ? offset + 64 : data.length;
      for (var i = offset; i < end; i++) {
        out[i] = data[i] ^ stream[i - offset];
      }
      offset = end;
    }
    return out;
  }

  /// One 64-byte block of key stream (section 2.3).
  static Uint8List block(List<int> key, List<int> nonce, int counter) {
    final state = Uint32List(16)
      ..[0] = 0x61707865
      ..[1] = 0x3320646e
      ..[2] = 0x79622d32
      ..[3] = 0x6b206574;
    for (var i = 0; i < 8; i++) {
      state[4 + i] = _le32(key, i * 4);
    }
    state[12] = counter & _mask;
    for (var i = 0; i < 3; i++) {
      state[13 + i] = _le32(nonce, i * 4);
    }
    final x = Uint32List.fromList(state);
    for (var round = 0; round < 10; round++) {
      _quarter(x, 0, 4, 8, 12);
      _quarter(x, 1, 5, 9, 13);
      _quarter(x, 2, 6, 10, 14);
      _quarter(x, 3, 7, 11, 15);
      _quarter(x, 0, 5, 10, 15);
      _quarter(x, 1, 6, 11, 12);
      _quarter(x, 2, 7, 8, 13);
      _quarter(x, 3, 4, 9, 14);
    }
    final out = Uint8List(64);
    for (var i = 0; i < 16; i++) {
      final word = (x[i] + state[i]) & _mask;
      out[i * 4] = word & 0xFF;
      out[i * 4 + 1] = (word >> 8) & 0xFF;
      out[i * 4 + 2] = (word >> 16) & 0xFF;
      out[i * 4 + 3] = (word >> 24) & 0xFF;
    }
    return out;
  }

  static void _quarter(Uint32List x, int a, int b, int c, int d) {
    x[a] = (x[a] + x[b]) & _mask;
    x[d] = _rotate(x[d] ^ x[a], 16);
    x[c] = (x[c] + x[d]) & _mask;
    x[b] = _rotate(x[b] ^ x[c], 12);
    x[a] = (x[a] + x[b]) & _mask;
    x[d] = _rotate(x[d] ^ x[a], 8);
    x[c] = (x[c] + x[d]) & _mask;
    x[b] = _rotate(x[b] ^ x[c], 7);
  }

  static int _rotate(int v, int n) => ((v << n) | (v >> (32 - n))) & _mask;

  static int _le32(List<int> b, int i) =>
      b[i] | b[i + 1] << 8 | b[i + 2] << 16 | b[i + 3] << 24;
}

/// The Poly1305 authenticator (RFC 8439 section 2.5). Uses big integers:
/// slower than limb arithmetic, but the data here is small and the code
/// stays easy to check against the specification.
abstract final class Poly1305 {
  static final _p = (BigInt.one << 130) - BigInt.from(5);
  static final _clamp = BigInt.parse(
    '0ffffffc0ffffffc0ffffffc0fffffff',
    radix: 16,
  );
  static final _mod128 = (BigInt.one << 128) - BigInt.one;

  /// The 16-byte tag of [message] under the one-time [key] (32 bytes).
  static Uint8List mac(List<int> key, List<int> message) {
    final r = _leNumber(key.sublist(0, 16)) & _clamp;
    final s = _leNumber(key.sublist(16, 32));
    var accumulator = BigInt.zero;
    for (var i = 0; i < message.length; i += 16) {
      final end = i + 16 < message.length ? i + 16 : message.length;
      final chunk = [...message.sublist(i, end), 1];
      accumulator = ((accumulator + _leNumber(chunk)) * r) % _p;
    }
    final tag = (accumulator + s) & _mod128;
    final out = Uint8List(16);
    var value = tag;
    for (var i = 0; i < 16; i++) {
      out[i] = (value & BigInt.from(0xFF)).toInt();
      value >>= 8;
    }
    return out;
  }

  static BigInt _leNumber(List<int> bytes) {
    var value = BigInt.zero;
    for (var i = bytes.length - 1; i >= 0; i--) {
      value = (value << 8) | BigInt.from(bytes[i]);
    }
    return value;
  }
}

/// HKDF with HMAC-SHA256 (RFC 5869).
abstract final class Hkdf {
  static Uint8List derive(
    List<int> inputKey, {
    List<int> salt = const [],
    List<int> info = const [],
    int length = 32,
  }) {
    if (length > 255 * 32) throw ArgumentError('length too large');
    final prk = Hmac(
      sha256,
      salt.isEmpty ? Uint8List(32) : salt,
    ).convert(inputKey).bytes;
    final out = BytesBuilder(copy: false);
    var previous = <int>[];
    for (var i = 1; out.length < length; i++) {
      previous = Hmac(sha256, prk).convert([...previous, ...info, i]).bytes;
      out.add(previous);
    }
    return Uint8List.sublistView(out.takeBytes(), 0, length);
  }
}
