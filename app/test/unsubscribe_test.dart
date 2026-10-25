// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmail/src/ui/fmail_theme.dart';
import 'package:fmail/src/ui/mail_shell.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_web/mail_web.dart';

import 'support/test_app.dart';

/// Stands in for a newsletter's unsubscribe server: plain TCP on
/// 127.0.0.1, answering every request with [reply].
final class _UnsubscribeServer {
  _UnsubscribeServer._(this._socket);

  static Future<_UnsubscribeServer> start() async => _UnsubscribeServer._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
  ).._listen();

  final ServerSocket _socket;
  final requests = <String>[];
  String reply = 'HTTP/1.1 200 OK\r\n\r\n';

  void _listen() => _socket.listen((client) {
    final got = BytesBuilder();
    client.listen((data) {
      got.add(data);
      final text = latin1.decode(got.toBytes());
      if (!text.endsWith('List-Unsubscribe=One-Click')) return;
      requests.add(text);
      client
        ..write(reply)
        ..close();
    });
  });

  /// Every name looks public; connections go to this server, unencrypted.
  WebClient get client => WebClient(
    resolver: (_) async => [InternetAddress('93.184.216.34')],
    connector: (host, address, port, timeout) => MailSocket.connect(
      ServerEndpoint(
        host,
        _socket.port,
        ConnectionSecurity.startTls,
        connectAddress: '127.0.0.1',
      ),
    ),
  );

  Future<void> close() => _socket.close();
}

void main() {
  late _UnsubscribeServer server;
  late TestApp app;

  setUp(() async {
    server = await _UnsubscribeServer.start();
    app = await TestApp.create(web: server.client);
  });

  tearDown(() async {
    await app.dispose();
    await server.close();
  });

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: FmailTheme.light(),
        home: MailShell(
          notifications: false,
          services: app.services,
          onAddAccount: () {},
          onAccountsChanged: () {},
        ),
      ),
    );
    await tester.pump();
  }

  /// Lets real I/O (isolates, sockets) finish.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }

  /// Real sockets complete in steps, each needing a real wait and a pump.
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 40 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(done(), isTrue, reason: 'timed out waiting');
  }

  Future<void> open(WidgetTester tester, String subject) async {
    await tester.tap(find.text(subject).first);
    await settle(tester);
  }

  // The newsletter's own body also has an "Unsubscribe" link; the app's
  // button is the TextButton.
  int accountId() => app.store.accounts.all().single.id;

  testWidgets('verified one-click unsubscribes and archives the list', (
    tester,
  ) async {
    app.seedFixture(
      'newsletters/one-click-unsubscribe.eml',
      subject: '50% off everything this week',
      uid: 70,
    );
    await show(tester);
    await open(tester, '50% off everything this week');

    await tester.tap(find.widgetWithText(TextButton, 'Unsubscribe'));
    await tester.pumpAndSettle();
    expect(find.text('Unsubscribe from Shop Weekly?'), findsOneWidget);
    expect(find.textContaining('asks shop.example to stop'), findsOneWidget);
    await tester.tap(find.text('Also archive this message'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Unsubscribe'));
    await until(
      tester,
      () => find.text('Unsubscribe from Shop Weekly?').evaluate().isEmpty,
    );

    expect(server.requests.single, startsWith('POST /unsub/abc123?u=alice '));
    final record = app.store.unsubscriptions.find(
      accountId(),
      'list:weekly.shop.example',
    );
    expect(record?.kind, UnsubscribeKind.oneClick);
    expect(record?.listName, 'Shop Weekly');
    expect(
      find.text('Unsubscribed from Shop Weekly. Archived 1.'),
      findsOneWidget,
    );
    expect(find.text('Unsubscribe from Shop Weekly?'), findsNothing);
  });

  testWidgets('when one-click fails, an unsubscribe email is offered', (
    tester,
  ) async {
    server.reply = 'HTTP/1.1 500 Server Error\r\n\r\n';
    app.seedFixture(
      'newsletters/one-click-unsubscribe.eml',
      subject: '50% off everything this week',
      uid: 70,
    );
    await show(tester);
    await open(tester, '50% off everything this week');
    await tester.tap(find.widgetWithText(TextButton, 'Unsubscribe'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Unsubscribe'));
    await until(
      tester,
      () => find.textContaining('error 500').evaluate().isNotEmpty,
    );
    expect(
      find.textContaining('send an unsubscribe email instead'),
      findsOneWidget,
    );
    expect(find.textContaining('unsubscribe@shop.example'), findsOneWidget);
    await tester.tap(find.text('Send email'));
    await settle(tester);

    final send = app.store.outbox
        .all(accountId())
        .map((e) => e.action)
        .whereType<SendAction>()
        .single;
    expect(send.recipients, ['unsubscribe@shop.example']);
    expect(
      app.store.unsubscriptions
          .find(accountId(), 'list:weekly.shop.example')
          ?.kind,
      UnsubscribeKind.email,
    );
    expect(
      find.text('Unsubscribe email to Shop Weekly is on its way'),
      findsOneWidget,
    );
  });

  testWidgets('without a verified signature, email is the first choice', (
    tester,
  ) async {
    app.seedFixture(
      'newsletters/one-click-dkim-fail.eml',
      subject: 'Last chance: 50% off',
      uid: 71,
    );
    await show(tester);
    await open(tester, 'Last chance: 50% off');
    await tester.tap(find.widgetWithText(TextButton, 'Unsubscribe'));
    await tester.pumpAndSettle();
    expect(find.textContaining('sends an unsubscribe email'), findsOneWidget);
    expect(find.textContaining('couldn\'t be fully checked'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(server.requests, isEmpty);
  });

  testWidgets('a list still sending after unsubscribing is pointed out', (
    tester,
  ) async {
    app.store.unsubscriptions.record(
      accountId: accountId(),
      listKey: 'list:weekly.shop.example',
      listName: 'Shop Weekly',
      kind: UnsubscribeKind.oneClick,
      now: DateTime.utc(2026, 10, 1),
    );
    app.seedFixture(
      'newsletters/one-click-unsubscribe.eml',
      subject: '50% off everything this week',
      uid: 70,
      receivedAt: DateTime.utc(2026, 10, 21),
    );
    await show(tester);
    await open(tester, '50% off everything this week');
    expect(find.textContaining('Shop Weekly is still sending'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Unsubscribe'), findsNothing);
  });

  testWidgets('an unverified sender: offered, with a warning to confirm', (
    tester,
  ) async {
    app.seedFixture(
      'newsletters/forwarded-unverified.eml',
      subject: 'What developers route to this week',
      uid: 73,
    );
    await show(tester);
    await open(tester, 'What developers route to this week');
    expect(find.text('This message may be a scam'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Unsubscribe'));
    await tester.pumpAndSettle();
    expect(find.textContaining('couldn\'t verify the sender'), findsOneWidget);
    expect(find.textContaining('news.example'), findsWidgets);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('a scam with an unsubscribe header says why it isn\'t offered', (
    tester,
  ) async {
    app.seedFixture(
      'security/scam-with-unsubscribe.eml',
      subject: 'Your account is on hold',
      uid: 74,
    );
    await show(tester);
    await open(tester, 'Your account is on hold');
    expect(find.widgetWithText(TextButton, 'Unsubscribe'), findsNothing);
    expect(
      find.textContaining(
        'Unsubscribe isn\'t offered. This message may be a scam',
      ),
      findsOneWidget,
    );
  });

  testWidgets('scam mail and ordinary mail offer no unsubscribe', (
    tester,
  ) async {
    app.seedFixture(
      'security/phishing-link-mismatch.eml',
      subject: 'Your account has been limited',
      uid: 72,
    );
    await show(tester);
    await open(tester, 'Your account has been limited');
    expect(find.widgetWithText(TextButton, 'Unsubscribe'), findsNothing);
    await open(tester, 'Hello there');
    expect(find.widgetWithText(TextButton, 'Unsubscribe'), findsNothing);
  });
}
