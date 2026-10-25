// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:citusmail/src/security/pin_hasher.dart';
import 'package:flutter_test/flutter_test.dart';

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('PBKDF2-HMAC-SHA256 published test vectors', () {
    String derive(String password, String salt, int rounds, int length) => _hex(
      PinHasher.pbkdf2(
        utf8.encode(password),
        utf8.encode(salt),
        rounds,
        length,
      ),
    );

    test('1, 2 and 4096 rounds', () {
      expect(
        derive('password', 'salt', 1, 32),
        '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
      );
      expect(
        derive('password', 'salt', 2, 32),
        'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43',
      );
      expect(
        derive('password', 'salt', 4096, 32),
        'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a',
      );
    });

    test('RFC 7914 section 11: more than one block', () {
      expect(
        derive('passwd', 'salt', 1, 64),
        '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc'
        '49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783',
      );
    });
  });

  test('hash and verify; a different PIN or salt never matches', () async {
    final a = await PinHasher.hash('482910', rounds: 1000);
    final b = await PinHasher.hash('482910', rounds: 1000);
    expect(a.salt, isNot(b.salt), reason: 'random salt');
    expect(await PinHasher.verify('482910', a), isTrue);
    expect(await PinHasher.verify('482911', a), isFalse);
    expect(await PinHasher.verify('', a), isFalse);

    final round = PinHash.decode(a.encode())!;
    expect(round.iterations, 1000);
    expect(await PinHasher.verify('482910', round), isTrue);
  });

  test('new PINs use the full number of rounds', () {
    expect(PinHasher.iterations, greaterThanOrEqualTo(100000));
  });

  test('stored values that are not ours are refused', () {
    for (final text in [
      null,
      '',
      'plain-1234',
      r'pbkdf2-sha256$0$AAAA$AAAA',
      r'pbkdf2-sha256$999999999$AAAA$AAAA',
      r'pbkdf2-sha256$1000$not base64!$AAAA',
      r'md5$1$AAAA$AAAA',
    ]) {
      expect(PinHash.decode(text), isNull, reason: '$text');
    }
  });
}
