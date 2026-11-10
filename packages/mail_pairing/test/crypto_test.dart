// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mail_appsync/mail_appsync.dart';
import 'package:mail_pairing/mail_pairing.dart';
import 'package:test/test.dart';

Uint8List hex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

String toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

AccountTransfer sampleTransfer() => AccountTransfer(
  accounts: [
    const TransferredAccount(
      email: 'alice@fastmail.example',
      displayName: 'Alice Martin',
      username: 'alice@fastmail.example',
      imap: TransferredServer('imap.fastmail.example', 993, 'tls'),
      smtp: TransferredServer('smtp.fastmail.example', 587, 'starttls'),
      signIn: PasswordSignIn('correct horse battery staple'),
    ),
  ],
);

void main() {
  group('X25519 (RFC 7748)', () {
    test('section 5.2 vector', () {
      expect(
        toHex(
          X25519.scalarMult(
            hex(
              'a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4',
            ),
            hex(
              'e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c',
            ),
          ),
        ),
        'c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552',
      );
    });

    test('section 6.1 Diffie-Hellman', () {
      final alice = hex(
        '77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a',
      );
      final bob = hex(
        '5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb',
      );
      expect(
        toHex(X25519.publicKey(alice)),
        '8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a',
      );
      expect(
        toHex(X25519.publicKey(bob)),
        'de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f',
      );
      const shared =
          '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742';
      expect(toHex(X25519.sharedSecret(alice, X25519.publicKey(bob))), shared);
      expect(toHex(X25519.sharedSecret(bob, X25519.publicKey(alice))), shared);
    });

    test('a small-order public key is refused', () {
      expect(
        () => X25519.sharedSecret(X25519.newPrivateKey(), Uint8List(32)),
        throwsArgumentError,
      );
    });
  });

  group('QR code', () {
    final offer = PairingOffer(
      addresses: [
        InternetAddress('192.168.1.20'),
        InternetAddress('fd12:3456:789a::5'),
      ],
      port: 50123,
      publicKey: List.filled(32, 7),
      token: List.generate(16, (i) => i),
    );

    test('encodes and decodes', () {
      final text = offer.encode();
      expect(text, startsWith('citusmail-pair:?v=1&a=192.168.1.20,'));
      final back = PairingOffer.decode(text)!;
      expect(back.addresses.map((a) => a.address), [
        '192.168.1.20',
        'fd12:3456:789a::5',
      ]);
      expect(back.port, 50123);
      expect(back.publicKey, offer.publicKey);
      expect(back.token, offer.token);
      expect(back.reachable, isTrue);
    });

    test('a computer without a local network: file route only', () {
      final fileOnly = PairingOffer(
        addresses: const [],
        port: 0,
        publicKey: List.filled(32, 7),
        token: List.filled(16, 1),
      );
      final back = PairingOffer.decode(fileOnly.encode())!;
      expect(back.reachable, isFalse);
    });

    test('other QR codes and public addresses are refused', () {
      expect(PairingOffer.decode('https://example.com/?v=1'), isNull);
      expect(PairingOffer.decode('WIFI:S:Home;T:WPA;P:secret;;'), isNull);
      expect(PairingOffer.decode('citusmail-pair:?v=2&a=192.168.1.2'), isNull);
      final public = offer.encode().replaceFirst('192.168.1.20', '8.8.8.8');
      expect(PairingOffer.decode(public), isNull);
      final shortKey = offer.encode().replaceFirst(
        RegExp('&k=[^&]+'),
        '&k=AAAA',
      );
      expect(PairingOffer.decode(shortKey), isNull);
      expect(
        PairingOffer.decode(offer.encode().replaceFirst('50123', '0')),
        isNull,
      );
    });

    test('local network ranges', () {
      bool local(String a) => LocalNetwork.isLocal(InternetAddress(a));
      expect(local('10.0.0.4'), isTrue);
      expect(local('172.16.0.1'), isTrue);
      expect(local('172.31.255.1'), isTrue);
      expect(local('172.32.0.1'), isFalse);
      expect(local('192.168.0.10'), isTrue);
      expect(local('169.254.3.3'), isTrue);
      expect(local('100.64.0.1'), isFalse);
      expect(local('93.184.216.34'), isFalse);
      expect(local('fd00::1'), isTrue);
      expect(local('2001:db8::1'), isFalse);
      expect(local('::ffff:192.168.1.1'), isTrue);
      expect(local('::ffff:8.8.8.8'), isFalse);
      expect(local('127.0.0.1'), isTrue);
    });
  });

  group('keys', () {
    test('both sides get the same keys and check code', () {
      final computer = X25519.newPrivateKey();
      final phone = X25519.newPrivateKey();
      final token = List.filled(16, 3);
      PairingKeys side(List<int> own, List<int> other) => PairingKeys.derive(
        sharedSecret: X25519.sharedSecret(own, X25519.publicKey(other)),
        token: token,
        computerKey: X25519.publicKey(computer),
        phoneKey: X25519.publicKey(phone),
      );
      final a = side(computer, phone);
      final b = side(phone, computer);
      expect(a.toComputer, b.toComputer);
      expect(a.toPhone, b.toPhone);
      expect(a.toPhone, isNot(a.toComputer));
      expect(a.checkCode, b.checkCode);
      expect(a.checkCode, matches(RegExp(r'^\d{3} \d{3}$')));
      final otherToken = PairingKeys.derive(
        sharedSecret: X25519.sharedSecret(computer, X25519.publicKey(phone)),
        token: List.filled(16, 4),
        computerKey: X25519.publicKey(computer),
        phoneKey: X25519.publicKey(phone),
      );
      expect(otherToken.toComputer, isNot(a.toComputer));
    });

    test('a replayed or reordered message fails to open', () {
      final key = Uint8List(32)..[0] = 1;
      final sender = SealedDirection(key);
      final receiver = SealedDirection(key);
      final first = sender.seal(1, {'n': 1});
      final second = sender.seal(1, {'n': 2});
      expect(receiver.open(1, first), {'n': 1});
      expect(
        () => receiver.open(1, first),
        throwsA(isA<AuthenticationFailed>()),
      );
      final fresh = SealedDirection(key);
      expect(() => fresh.open(1, second), throwsA(isA<AuthenticationFailed>()));
    });
  });

  group('file', () {
    final random = Random(1);
    final privateKey = X25519.newPrivateKey(random);
    final token = List.generate(16, (i) => 200 - i);
    final offer = PairingOffer(
      addresses: [InternetAddress('192.168.1.20')],
      port: 4000,
      publicKey: X25519.publicKey(privateKey),
      token: token,
    );

    test('round trip', () {
      final file = PairingFile.seal(offer, sampleTransfer());
      expect(String.fromCharCodes(file.sublist(0, 6)), 'CMPAIR');
      final back = PairingFile.open(file, privateKey: privateKey, token: token);
      final account = back.accounts.single;
      expect(account.email, 'alice@fastmail.example');
      expect(account.displayName, 'Alice Martin');
      expect(
        (account.signIn as PasswordSignIn).password,
        'correct horse battery staple',
      );
      expect(account.smtp.security, 'starttls');
      // The password is not readable in the file.
      expect(String.fromCharCodes(file).contains('horse'), isFalse);
    });

    test('another session key is refused', () {
      final file = PairingFile.seal(offer, sampleTransfer());
      expect(
        () => PairingFile.open(
          file,
          privateKey: X25519.newPrivateKey(),
          token: token,
        ),
        throwsA(
          isA<PairingFileException>().having(
            (e) => e.problem,
            'problem',
            PairingFileProblem.damaged,
          ),
        ),
      );
      expect(
        () => PairingFile.open(
          file,
          privateKey: privateKey,
          token: List.filled(16, 0),
        ),
        throwsA(
          isA<PairingFileException>().having(
            (e) => e.problem,
            'problem',
            PairingFileProblem.otherCode,
          ),
        ),
      );
    });

    test('a changed file is refused', () {
      final file = PairingFile.seal(offer, sampleTransfer());
      for (final at in [20, 50, file.length - 1, file.length - 30]) {
        final changed = Uint8List.fromList(file)..[at] ^= 1;
        expect(
          () => PairingFile.open(changed, privateKey: privateKey, token: token),
          throwsA(isA<PairingFileException>()),
          reason: 'byte $at',
        );
      }
      expect(
        () => PairingFile.open(
          Uint8List.fromList('not a file at all, just text'.codeUnits),
          privateKey: privateKey,
          token: token,
        ),
        throwsA(
          isA<PairingFileException>().having(
            (e) => e.problem,
            'problem',
            PairingFileProblem.notAFile,
          ),
        ),
      );
    });
  });

  group('transfer', () {
    test('JSON round trip of an OAuth account without tokens', () {
      final transfer = AccountTransfer(
        accounts: [
          const TransferredAccount(
            email: 'bob@outlook.example',
            username: 'bob@outlook.example',
            imap: TransferredServer('outlook.office365.com', 993, 'tls'),
            smtp: TransferredServer('smtp-mail.outlook.com', 587, 'starttls'),
            signIn: OAuthSignIn('microsoft'),
          ),
        ],
        ownClients: const {
          'google': '{"client":"1-a.apps.googleusercontent.com"}',
        },
        syncCode: 'ABCD',
        syncAccount: 'bob@outlook.example',
      );
      final back = AccountTransfer.fromJson(transfer.toJson());
      final signIn = back.accounts.single.signIn as OAuthSignIn;
      expect(signIn.provider, 'microsoft');
      expect(signIn.tokens, isNull);
      expect(back.ownClients.keys, ['google']);
      expect(back.syncCode, 'ABCD');
      expect(back.syncAccount, 'bob@outlook.example');
    });

    test('malformed accounts are refused', () {
      expect(
        () => AccountTransfer.fromJson({
          'accounts': [
            {'email': 'x@y.example', 'username': 'x'},
          ],
        }),
        throwsA(isA<PairingFormatException>()),
      );
      expect(
        () => TransferResult.fromJson({'email': 'x', 'outcome': 'nope'}),
        throwsA(isA<PairingFormatException>()),
      );
    });
  });
}
