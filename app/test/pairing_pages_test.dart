// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';
import 'dart:typed_data';

import 'package:citusmail/src/pairing/account_import.dart';
import 'package:citusmail/src/pairing/qr_code.dart';
import 'package:citusmail/src/pairing/receive_accounts_page.dart';
import 'package:citusmail/src/pairing/send_accounts_page.dart';
import 'package:citusmail/src/setup/setup_controller.dart';
import 'package:citusmail/src/setup/setup_page.dart';
import 'package:citusmail/src/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_pairing/mail_pairing.dart';
import 'package:mail_setup/mail_setup.dart';

import 'pairing_accounts_test.dart' show addPhoneAccounts;
import 'support/test_app.dart';

/// A QR code drawn as camera brightness: 4 pixels a module, quiet zone.
LuminanceFrame frameOf(String text, {int scale = 4}) {
  final qr = QrModules.encode(text);
  final side = (qr.size + 8) * scale;
  final bytes = Uint8List(side * side)..fillRange(0, side * side, 255);
  for (var y = 0; y < qr.size; y++) {
    for (var x = 0; x < qr.size; x++) {
      if (!qr.isDark(x, y)) continue;
      for (var dy = 0; dy < scale; dy++) {
        for (var dx = 0; dx < scale; dx++) {
          bytes[((y + 4) * scale + dy) * side + (x + 4) * scale + dx] = 0;
        }
      }
    }
  }
  return LuminanceFrame(bytes, side, side, side);
}

void main() {
  late TestApp phone;
  late TestApp computer;
  setUp(() async {
    phone = await TestApp.create();
    computer = await TestApp.create();
    await addPhoneAccounts(phone);
  });
  tearDown(() async {
    await phone.dispose();
    await computer.dispose();
  });

  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(done(), isTrue, reason: 'timed out waiting');
  }

  AccountImport fakeImport() => AccountImport(
    computer.services,
    verify: (settings, password) async => const VerificationResult.success(),
    verifyOAuth: (settings, token) async => const VerificationResult.success(),
    refresh: (provider, refresh) async => throw const OAuthLikeFailure(),
  );

  test('the QR code the computer draws is read back from a camera frame', () {
    final offer = PairingOffer(
      addresses: [InternetAddress('192.168.1.20')],
      port: 50123,
      publicKey: List.filled(32, 5),
      token: List.filled(16, 6),
    ).encode();
    expect(decodeQrFrame(frameOf(offer)), offer);
    final blank = LuminanceFrame(Uint8List(100 * 100), 100, 100, 100);
    expect(decodeQrFrame(blank), isNull);
  });

  testWidgets('computer: QR code, check code once connected, results', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Listening in the real zone, so the sockets run while the test waits.
    AccountReceiver? toPage;
    final host = (await tester.runAsync(
      () => PairingHost.start(
        computerName: 'alice-laptop',
        receive: (t) => toPage!(t),
        addresses: [InternetAddress.loopbackIPv4],
      ),
    ))!;
    await tester.pumpWidget(
      MaterialApp(
        home: ReceiveAccountsPage(
          services: computer.services,
          importer: fakeImport,
          startHost: (receive) async {
            toPage = receive;
            return host;
          },
        ),
      ),
    );
    await until(
      tester,
      () => find.byKey(const Key('pairing-qr')).evaluate().isNotEmpty,
    );
    expect(
      find.textContaining('Settings → Send accounts to a computer'),
      findsOneWidget,
    );
    expect(find.text('Open a file from your phone'), findsOneWidget);

    final connection = (await tester.runAsync(
      () => PairingClient.connect(host.offer, phoneName: 'Pixel 8'),
    ))!;
    await until(
      tester,
      () => find.byKey(const Key('check-code')).evaluate().isNotEmpty,
    );
    expect(find.text('Connected to Pixel 8'), findsOneWidget);
    expect(find.text(connection.checkCode), findsOneWidget);

    final results = (await tester.runAsync(
      () => connection.send(
        AccountTransfer(
          accounts: const [
            TransferredAccount(
              email: 'carol@mailbox.example',
              username: 'carol@mailbox.example',
              imap: TransferredServer('imap.mailbox.example', 993, 'tls'),
              smtp: TransferredServer('smtp.mailbox.example', 465, 'tls'),
              signIn: PasswordSignIn('secret'),
            ),
            TransferredAccount(
              email: 'carol@outlook.example',
              username: 'carol@outlook.example',
              imap: TransferredServer('outlook.office365.com', 993, 'tls'),
              smtp: TransferredServer('smtp-mail.outlook.com', 587, 'starttls'),
              signIn: OAuthSignIn('microsoft'),
            ),
          ],
        ),
      ),
    ))!;
    expect(results.first.outcome, TransferOutcome.added);
    await until(
      tester,
      () => find.text('From your phone').evaluate().isNotEmpty,
    );
    expect(find.text('carol@mailbox.example'), findsOneWidget);
    expect(find.text('Added'), findsOneWidget);
    expect(find.text('Sign in with Microsoft'), findsOneWidget);
    expect(
      computer.store.accounts.all().map((a) => a.email),
      contains('carol@mailbox.example'),
    );
  });

  testWidgets('computer: opens a file from the phone', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    PairingHost? host;
    Uint8List? file;
    await tester.pumpWidget(
      MaterialApp(
        home: ReceiveAccountsPage(
          services: computer.services,
          importer: fakeImport,
          pickFile: () async => file,
          startHost: (receive) async => host = await PairingHost.start(
            computerName: 'alice-laptop',
            receive: receive,
            addresses: const [],
          ),
        ),
      ),
    );
    await until(
      tester,
      () => find.text('Open a file from your phone').evaluate().isNotEmpty,
    );
    expect(find.textContaining('isn\'t on a local network'), findsOneWidget);

    // A file for another code is refused; the code stays.
    final other = PairingOffer(
      addresses: const [],
      port: 0,
      publicKey: X25519.publicKey(X25519.newPrivateKey()),
      token: List.filled(16, 1),
    );
    final transfer = AccountTransfer(
      accounts: const [
        TransferredAccount(
          email: 'dan@mailbox.example',
          username: 'dan@mailbox.example',
          imap: TransferredServer('imap.mailbox.example', 993, 'tls'),
          smtp: TransferredServer('smtp.mailbox.example', 465, 'tls'),
          signIn: PasswordSignIn('pw'),
        ),
      ],
    );
    file = PairingFile.seal(other, transfer);
    await tester.tap(find.text('Open a file from your phone'));
    await until(
      tester,
      () => find.textContaining('another code').evaluate().isNotEmpty,
    );

    file = PairingFile.seal(host!.offer, transfer);
    await tester.tap(find.text('Open a file from your phone'));
    await until(
      tester,
      () => find.text('From your phone').evaluate().isNotEmpty,
    );
    expect(find.text('dan@mailbox.example'), findsOneWidget);
    expect(find.text('Added'), findsOneWidget);
  });

  void phoneSize(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('phone: scan, check code, choose accounts, confirm, send', (
    tester,
  ) async {
    phoneSize(tester);
    final received = <AccountTransfer>[];
    final host = (await tester.runAsync(
      () => PairingHost.start(
        computerName: 'alice-laptop',
        addresses: [InternetAddress.loopbackIPv4],
        receive: (t) async {
          received.add(t);
          return [
            for (final a in t.accounts)
              TransferResult(
                a.email,
                a.signIn is OAuthSignIn &&
                        (a.signIn as OAuthSignIn).tokens == null
                    ? TransferOutcome.signInOnComputer
                    : TransferOutcome.added,
              ),
          ];
        },
      ),
    ))!;
    await tester.pumpWidget(
      MaterialApp(
        home: SendAccountsPage(
          services: phone.services,
          phoneName: 'Pixel 8',
          scanner: (context, onCode) => TextButton(
            onPressed: () => onCode(host.offer.encode()),
            child: const Text('Fake scan'),
          ),
        ),
      ),
    );
    expect(find.textContaining('Point your camera'), findsOneWidget);
    await tester.tap(find.text('Fake scan'));
    await until(
      tester,
      () => find.byKey(const Key('check-code')).evaluate().isNotEmpty,
    );
    expect(find.text('Connected to alice-laptop'), findsOneWidget);
    final shown = tester.widget<Text>(find.byKey(const Key('check-code'))).data;
    expect(shown, (host.state as HostConnected).checkCode);
    // Microsoft signs in again on the computer.
    expect(find.text('You sign in again on the computer.'), findsOneWidget);
    expect(find.text('Send 4 accounts'), findsOneWidget);
    await tester.tap(find.text('Bob'));
    await tester.pump();
    expect(find.text('Send 3 accounts'), findsOneWidget);

    await tester.tap(find.text('Send 3 accounts'));
    await tester.pumpAndSettle();
    expect(find.text('Send 3 accounts to alice-laptop?'), findsOneWidget);
    await tester.tap(find.text('Send'));
    await until(
      tester,
      () => find.text('Sent to alice-laptop').evaluate().isNotEmpty,
    );
    expect(received.single.accounts.map((a) => a.email), [
      'alice@citusmail.test',
      'bob@gmail.example',
      'bob@outlook.example',
    ]);
    expect(find.text('Sign in on the computer to finish'), findsOneWidget);
    expect(find.text('Added'), findsNWidgets(2));
  });

  testWidgets('phone: can\'t reach the computer, sends a file instead', (
    tester,
  ) async {
    phoneSize(tester);
    final host = (await tester.runAsync(
      () => PairingHost.start(
        computerName: 'alice-laptop',
        addresses: [InternetAddress.loopbackIPv4],
        networkWindow: Duration.zero,
        receive: (t) async => [
          for (final a in t.accounts)
            TransferResult(a.email, TransferOutcome.added),
        ],
      ),
    ))!;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    Uint8List? shared;
    await tester.pumpWidget(
      MaterialApp(
        home: SendAccountsPage(
          services: phone.services,
          phoneName: 'Pixel 8',
          shareFile: (bytes) async {
            shared = bytes;
            return true;
          },
          scanner: (context, onCode) => TextButton(
            onPressed: () => onCode(host.offer.encode()),
            child: const Text('Fake scan'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Fake scan'));
    await until(
      tester,
      () => find.text('Send as a file instead').evaluate().isNotEmpty,
    );
    expect(
      find.text(
        'Your phone couldn\'t reach this computer. Put both on the same '
        'Wi-Fi and try again.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Send as a file instead'));
    await until(
      tester,
      () => find.text('Share the file').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('Share the file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send'));
    await until(
      tester,
      () => find
          .text(
            'Open this file on your computer while its QR code is still showing.',
          )
          .evaluate()
          .isNotEmpty,
    );
    final results = (await tester.runAsync(() => host.openFile(shared!)))!;
    expect(results, hasLength(4));
  });

  _entryPoints();

  testWidgets('settings: send on the phone, receive on the computer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final android in [true, false]) {
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsPage(
            key: ValueKey(android),
            services: phone.services,
            isAndroid: android,
          ),
        ),
      );
      await tester.pump();
      final send = find.text('Send accounts to a computer');
      final receive = find.text('Add accounts from your phone');
      expect(send, android ? findsOneWidget : findsNothing);
      expect(receive, android ? findsNothing : findsOneWidget);
    }
  });

  testWidgets('phone: another QR code is explained', (tester) async {
    phoneSize(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: SendAccountsPage(
          services: phone.services,
          scanner: (context, onCode) => TextButton(
            onPressed: () => onCode('https://example.com/menu'),
            child: const Text('Fake scan'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Fake scan'));
    await tester.pump();
    expect(find.textContaining('That isn\'t a Citusmail code'), findsOneWidget);
    expect(find.text('Send as a file instead'), findsNothing);
  });
}

void _entryPoints() {
  testWidgets('setup offers adding accounts from the phone on computers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SetupPage(
          controller: SetupController(
            discover: (email, {askMozillaConsent, onStep}) async =>
                const DiscoveryResult(null),
            verify: (s, p) async => const VerificationResult.success(),
            save: (s, p, {displayName}) async => throw UnimplementedError(),
          ),
          onDone: (_) {},
          onAddFromPhone: () => opened++,
        ),
      ),
    );
    expect(
      find.textContaining('Already use Citusmail on your phone'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('add-from-phone')));
    expect(opened, 1);
  });
}

final class OAuthLikeFailure implements Exception {
  const OAuthLikeFailure();
}
