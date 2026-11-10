// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mail_pairing/mail_pairing.dart';
import 'package:test/test.dart';

const _googleTokens =
    '{"access":"ya29.a0-access","expires":1893456000000,"refresh":"1//0g-refresh"}';

AccountTransfer twoAccounts() => AccountTransfer(
  accounts: [
    const TransferredAccount(
      email: 'alice@posteo.example',
      displayName: 'Alice',
      username: 'alice@posteo.example',
      imap: TransferredServer('posteo.example', 993, 'tls'),
      smtp: TransferredServer('posteo.example', 465, 'tls'),
      signIn: PasswordSignIn('p4ssw0rd!'),
    ),
    const TransferredAccount(
      email: 'alice@gmail.example',
      username: 'alice@gmail.example',
      imap: TransferredServer('imap.gmail.com', 993, 'tls'),
      smtp: TransferredServer('smtp.gmail.com', 587, 'starttls'),
      signIn: OAuthSignIn('google', tokens: _googleTokens),
    ),
  ],
  syncCode: '7KQ2-M9XD',
  syncAccount: 'alice@posteo.example',
);

void main() {
  final loopback = [InternetAddress.loopbackIPv4];
  final received = <AccountTransfer>[];

  Future<List<TransferResult>> receive(AccountTransfer t) async {
    received.add(t);
    return [
      TransferResult(t.accounts[0].email, TransferOutcome.added),
      TransferResult(
        t.accounts[1].email,
        TransferOutcome.failed,
        detail: 'Google didn\'t accept the sign-in.',
      ),
    ];
  }

  setUp(received.clear);

  Future<PairingHost> host({
    Duration networkWindow = const Duration(minutes: 5),
    Duration fileWindow = const Duration(minutes: 15),
  }) => PairingHost.start(
    computerName: 'alice-laptop',
    clients: const {'google': 'desktop-client.apps.googleusercontent.com'},
    receive: receive,
    addresses: loopback,
    networkWindow: networkWindow,
    fileWindow: fileWindow,
    handshakeTimeout: const Duration(seconds: 2),
  );

  test('transfers two accounts over the network, end to end', () async {
    final computer = await host();
    final states = <PairingHostState>[];
    final sub = computer.changes.listen(states.add);
    final offer = PairingOffer.decode(computer.offer.encode())!;
    final phone = await PairingClient.connect(offer, phoneName: 'Pixel 8');
    expect(phone.computerName, 'alice-laptop');
    expect(
      phone.clients['google'],
      'desktop-client.apps.googleusercontent.com',
    );
    await pumpEventQueue();
    final connected = computer.state as HostConnected;
    expect(connected.phoneName, 'Pixel 8');
    expect(connected.checkCode, phone.checkCode);

    final results = await phone.send(twoAccounts());
    expect(results.map((r) => r.outcome), [
      TransferOutcome.added,
      TransferOutcome.failed,
    ]);
    expect(results[1].detail, contains('Google'));
    final got = received.single;
    expect((got.accounts[0].signIn as PasswordSignIn).password, 'p4ssw0rd!');
    expect((got.accounts[1].signIn as OAuthSignIn).tokens, _googleTokens);
    expect(got.syncCode, '7KQ2-M9XD');
    await pumpEventQueue();
    expect(computer.state, isA<HostFinished>());
    expect(states.whereType<HostReceiving>().single.count, 2);
    expect(computer.isOver, isTrue);
    await sub.cancel();
  });

  test('one transfer only: a second phone can\'t connect', () async {
    final computer = await host();
    final offer = computer.offer;
    final first = await PairingClient.connect(offer, phoneName: 'A');
    await expectLater(
      PairingClient.connect(offer, phoneName: 'B'),
      throwsA(isA<PairingException>()),
    );
    await first.send(twoAccounts());
    await expectLater(
      PairingClient.connect(offer, phoneName: 'C'),
      throwsA(
        isA<PairingException>().having(
          (e) => e.problem,
          'problem',
          PairingProblem.unreachable,
        ),
      ),
    );
    await expectLater(
      computer.openFile(PairingFile.seal(offer, twoAccounts())),
      throwsA(isA<PairingFileException>()),
    );
    expect(received, hasLength(1));
  });

  test('a wrong token is refused, and the code stays open', () async {
    final computer = await host();
    final real = computer.offer;
    final wrongToken = PairingOffer(
      addresses: real.addresses,
      port: real.port,
      publicKey: real.publicKey,
      token: List.filled(16, 9),
    );
    await expectLater(
      PairingClient.connect(wrongToken, phoneName: 'Intruder'),
      throwsA(
        isA<PairingException>().having(
          (e) => e.problem,
          'problem',
          PairingProblem.refused,
        ),
      ),
    );
    expect(computer.state, isA<HostWaiting>());
    final phone = await PairingClient.connect(real, phoneName: 'Pixel');
    expect(phone.computerName, 'alice-laptop');
    await phone.cancel();
    await pumpEventQueue();
    expect((computer.state as HostFailed).problem, HostProblem.cancelled);
  });

  test('a wrong computer key is refused (nobody in the middle)', () async {
    final computer = await host();
    final real = computer.offer;
    final otherKey = PairingOffer(
      addresses: real.addresses,
      port: real.port,
      publicKey: X25519.publicKey(X25519.newPrivateKey()),
      token: real.token,
    );
    await expectLater(
      PairingClient.connect(otherKey, phoneName: 'Pixel'),
      throwsA(isA<PairingException>()),
    );
    expect(computer.state, isA<HostWaiting>());
    await computer.close();
  });

  test('too many wrong tries close the code', () async {
    final computer = await host();
    final real = computer.offer;
    for (var i = 0; i < PairingHost.maxFailedTries; i++) {
      await expectLater(
        PairingClient.connect(
          PairingOffer(
            addresses: real.addresses,
            port: real.port,
            publicKey: real.publicKey,
            token: List.filled(16, i),
          ),
          phoneName: 'Guess $i',
        ),
        throwsA(isA<PairingException>()),
      );
    }
    await pumpEventQueue();
    expect((computer.state as HostFailed).problem, HostProblem.tooManyTries);
    await expectLater(
      PairingClient.connect(real, phoneName: 'Pixel'),
      throwsA(isA<PairingException>()),
    );
  });

  test('a tampered message ends the connection', () async {
    final computer = await host();
    final offer = computer.offer;
    // A phone whose second message is changed on the way.
    final socket = await Socket.connect(offer.addresses.first, offer.port);
    final phoneKey = X25519.publicKey(X25519.newPrivateKey());
    void frame(List<int> bytes) {
      final n = bytes.length;
      socket.add([n >> 24 & 255, n >> 16 & 255, n >> 8 & 255, n & 255]);
      socket.add(bytes);
    }

    frame([...'CMPAIR'.codeUnits, 1, ...phoneKey]);
    frame(Uint8List(40)..[0] = 1);
    final closed = Completer<void>();
    socket.listen((_) {}, onDone: closed.complete);
    await closed.future.timeout(const Duration(seconds: 5));
    socket.destroy();
    expect(computer.state, isA<HostWaiting>());
    await computer.close();
  });

  test('the network part expires; then a file still opens', () async {
    final computer = await host(
      networkWindow: const Duration(milliseconds: 200),
    );
    final offer = computer.offer;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect((computer.state as HostWaiting).listening, isFalse);
    await expectLater(
      PairingClient.connect(offer, phoneName: 'Late'),
      throwsA(
        isA<PairingException>().having(
          (e) => e.problem,
          'problem',
          PairingProblem.unreachable,
        ),
      ),
    );
    final results = await computer.openFile(
      PairingFile.seal(offer, twoAccounts()),
    );
    expect(results, hasLength(2));
    expect((computer.state as HostFinished).fromFile, isTrue);
  });

  test('an expired code opens no file', () async {
    final computer = await host(
      networkWindow: const Duration(milliseconds: 100),
      fileWindow: const Duration(milliseconds: 200),
    );
    final file = PairingFile.seal(computer.offer, twoAccounts());
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(computer.state, isA<HostExpired>());
    await expectLater(
      computer.openFile(file),
      throwsA(
        isA<PairingFileException>().having(
          (e) => e.problem,
          'problem',
          PairingFileProblem.expired,
        ),
      ),
    );
    expect(received, isEmpty);
  });

  test('a damaged file leaves the code open for another try', () async {
    final computer = await host();
    final file = PairingFile.seal(computer.offer, twoAccounts());
    final damaged = Uint8List.fromList(file)..[file.length - 5] ^= 0x40;
    await expectLater(
      computer.openFile(damaged),
      throwsA(isA<PairingFileException>()),
    );
    expect(computer.state, isA<HostWaiting>());
    expect(await computer.openFile(file), hasLength(2));
  });

  test('a phone that can\'t reach the computer says so', () async {
    final computer = await host();
    final port = computer.offer.port;
    await computer.close();
    final offer = PairingOffer(
      addresses: loopback,
      port: port,
      publicKey: computer.offer.publicKey,
      token: computer.offer.token,
    );
    await expectLater(
      PairingClient.connect(offer, phoneName: 'Pixel'),
      throwsA(
        isA<PairingException>().having(
          (e) => e.problem,
          'problem',
          PairingProblem.unreachable,
        ),
      ),
    );
  });
}
