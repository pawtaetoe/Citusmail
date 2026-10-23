// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import 'package:mail_appsync/mail_appsync.dart';
import 'package:test/test.dart';

Uint8List _hex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

String _toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// (key, nonce, plaintext, aad, ciphertext+tag) made by an independent
/// implementation (Python `cryptography`), covering empty input, one
/// byte, and block boundaries (63, 64, 65 and 200 bytes).
const _reference = [
  (
    'd49bbb94598e380d7fc4d681a2cd461f47644d6ba93f239ed129f248d1ac09dd',
    'be1ab519f4bf02cf7a3b6d7f',
    '',
    '',
    'b48b059e0beda1c0452d58e1444bef16',
  ),
  (
    'b81d88208d6242809db2a357aa308bab0419b209ef8bf21b659e8426f80a46ce',
    'f8c85d64804d386c199ca1a1',
    '19',
    '52',
    '413e4fe21f449f0ca7bf4fef78f60d7542',
  ),
  (
    'd62f9f80cef5262b7b7387539719f9c9f971d0e327eb6f75f7a260ba0ed81ba8',
    '5676a0bc586c9bdeb6e52f36',
    '05625be6ede446f3e70696865e04efaca86c1a8832070e39f19a68320de9710fcc3edb1d1e608689b6b1d5cf03ad291191a6a43cab417cfd91e23f827f25d7',
    '9e66f7bb416d4d962adfe0c6',
    '631c5694b7aaf0c1b7d3f769f0060deccd92b7777c4a7808468e946106c78ffb55edbdc777d4ae1c13271add66db85b147bd6f6466e89c6f63e3a298cb7cb15551985db5e91480edd1de39a5422463',
  ),
  (
    '4e4954a2fc90d02178564d78daa4e241937cfd8061be033eabfc27dc2cc17c57',
    '24972593adeca44c4c889dc4',
    'a649df3583796e6dbddfc08a289dcf68a106121eb4fbced8849ae653d46d606ab96475c224e965b540f7e22c4378dfc974cdc1f8ab7aa7c56d58fc05f232d0f6',
    '325efe0f87f1426550834b123f',
    'cbb30b19b25b3bd5ba6ddf1e4dc15558858327da296e86610a31ff8c2febeaab97784f402886b64061478d9949e3054770ca26f7ac4061597d9a3568bc943a727ced44044cedad4cd6828aafcef8da59',
  ),
  (
    '95e11b2c97859fc186110f91241c8c96b3f66c3716bebef5e4a8fcbb70043ab2',
    '4cc33a2814c838ec4964e218',
    '8909363147f3709e999ba908df2dc401ec35a7a5eb1df92fef983e4e24a4134e6697d62b37c31cfad1d3867acf4271a976a2f1a16c3268ef6ae1dfbbdf1a653e7f',
    '02841a85b9dbc517070ca5a458b7',
    'b18f20fd5447d66e55c0a320a08b257bce375f04547d353e313b107504419b276290b9ae1135e49a991a532db2f37c82fe5155ba450ccf307e3df7662ca3f8e3f392d43589b5aeb337e38b5886369c61ef',
  ),
];

void main() {
  test('RFC 8439 2.4.2: ChaCha20 encryption', () {
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    final nonce = _hex('000000000000004a00000000');
    final out = ChaCha20.apply(
      key,
      nonce,
      utf8.encode(
        "Ladies and Gentlemen of the class of '99: If I could offer you only "
        'one tip for the future, sunscreen would be it.',
      ),
      counter: 1,
    );
    expect(_toHex(out).substring(0, 32), '6e2e359a2568f98041ba0728dd0d6981');
  });

  test('RFC 8439 2.5.2: Poly1305', () {
    final tag = Poly1305.mac(
      _hex('85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b'),
      utf8.encode('Cryptographic Forum Research Group'),
    );
    expect(_toHex(tag), 'a8061dc1305136c6c22b8baf0c0127a9');
  });

  test('RFC 8439 2.8.2: AEAD', () {
    final sealed = ChaCha20Poly1305.encrypt(
      Uint8List.fromList(List.generate(32, (i) => 0x80 + i)),
      _hex('070000004041424344454647'),
      utf8.encode(
        "Ladies and Gentlemen of the class of '99: If I could offer you only "
        'one tip for the future, sunscreen would be it.',
      ),
      aad: _hex('50515253c0c1c2c3c4c5c6c7'),
    );
    expect(_toHex(sealed.sublist(0, 16)), 'd31a8d34648e60db7b86afbc53ef7ec2');
    expect(
      _toHex(sealed.sublist(sealed.length - 16)),
      '1ae10b594f09e26a7e902ecbd0600691',
    );
  });

  test('agrees with an independent implementation', () {
    for (final (key, nonce, plain, aad, expected) in _reference) {
      final sealed = ChaCha20Poly1305.encrypt(
        _hex(key),
        _hex(nonce),
        _hex(plain),
        aad: _hex(aad),
      );
      expect(_toHex(sealed), expected, reason: 'length ${plain.length ~/ 2}');
      expect(
        _toHex(
          ChaCha20Poly1305.decrypt(
            _hex(key),
            _hex(nonce),
            sealed,
            aad: _hex(aad),
          ),
        ),
        plain,
      );
    }
  });

  test('any change, wrong key or wrong associated data is refused', () {
    final (key, nonce, plain, aad, expected) = _reference[3];
    final sealed = _hex(expected);
    for (var i = 0; i < sealed.length; i += 7) {
      final bent = Uint8List.fromList(sealed)..[i] ^= 1;
      expect(
        () => ChaCha20Poly1305.decrypt(
          _hex(key),
          _hex(nonce),
          bent,
          aad: _hex(aad),
        ),
        throwsA(isA<AuthenticationFailed>()),
        reason: 'byte $i',
      );
    }
    final otherKey = _hex(key)..[0] ^= 1;
    expect(
      () => ChaCha20Poly1305.decrypt(
        otherKey,
        _hex(nonce),
        sealed,
        aad: _hex(aad),
      ),
      throwsA(isA<AuthenticationFailed>()),
    );
    expect(
      () => ChaCha20Poly1305.decrypt(_hex(key), _hex(nonce), sealed, aad: [1]),
      throwsA(isA<AuthenticationFailed>()),
    );
    expect(
      () => ChaCha20Poly1305.decrypt(_hex(key), _hex(nonce), [1, 2, 3]),
      throwsA(isA<AuthenticationFailed>()),
    );
    expect(plain, isNotEmpty);
  });

  test('RFC 5869 test case 1: HKDF-SHA256', () {
    final okm = Hkdf.derive(
      _hex('0b' * 22),
      salt: _hex('000102030405060708090a0b0c'),
      info: _hex('f0f1f2f3f4f5f6f7f8f9'),
      length: 42,
    );
    expect(
      _toHex(okm),
      '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865',
    );
  });
}
