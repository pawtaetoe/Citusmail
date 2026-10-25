// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmail/src/services/secret_store.dart';
import 'package:fmail/src/services/virus_total_checks.dart';
import 'package:fmail/src/ui/link_opener.dart';
import 'package:fmail/src/ui/settings_page.dart';
import 'package:fmail/src/ui/virus_total_check.dart';
import 'package:mail_lookup/mail_lookup.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_web/mail_web.dart';

import 'support/test_app.dart';

final class _Secrets implements SecretStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// VirusTotal on 127.0.0.1: 401 for the wrong key, 404 for the empty
/// file, a flagged report for anything else.
final class _VirusTotal {
  _VirusTotal._(this._socket);

  static Future<_VirusTotal> start() async =>
      _VirusTotal._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0))
        .._listen();

  final ServerSocket _socket;
  final requests = <String>[];
  static final goodKey = 'a' * 64;

  void _listen() => _socket.listen((client) {
    final got = BytesBuilder();
    client.listen((data) {
      got.add(data);
      final text = latin1.decode(got.toBytes());
      if (!text.contains('\r\n\r\n')) return;
      requests.add(text);
      final (status, body) = !text.contains('x-apikey: $goodKey')
          ? (401, '{}')
          : text.contains('/files/e3b0c442')
          ? (404, '{}')
          : (
              200,
              jsonEncode({
                'data': {
                  'attributes': {
                    'last_analysis_stats': {'malicious': 40, 'undetected': 30},
                  },
                },
              }),
            );
      final reply = utf8.encode(body);
      client
        ..add(
          latin1.encode(
            'HTTP/1.1 $status X\r\nContent-Length: ${reply.length}\r\n\r\n',
          ),
        )
        ..add(reply)
        ..close();
    });
  });

  WebClient get web => WebClient(
    resolver: (_) async => [InternetAddress('74.125.34.46')],
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
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  test('off by default; on only with a key VirusTotal accepts', () async {
    final vt = await _VirusTotal.start();
    addTearDown(vt.close);
    final secrets = _Secrets();
    final checks = VirusTotalChecks(app.store, secrets, vt.web);
    expect(checks.enabled, isFalse);
    await expectLater(
      checks.file([1, 2, 3]),
      throwsA(isA<VirusTotalException>()),
    );
    expect(vt.requests, isEmpty, reason: 'nothing sent while off');

    expect(await checks.enable('not a key'), contains('64 letters'));
    expect(await checks.enable('b' * 64), contains('didn\'t accept'));
    expect(checks.enabled, isFalse);
    expect(secrets.values, isEmpty);

    expect(await checks.enable(_VirusTotal.goodKey), isNull);
    expect(checks.enabled, isTrue);
    final report = await checks.file(utf8.encode('invoice.exe bytes'));
    expect(report.malicious, 40);
    expect(
      vt.requests.last,
      isNot(contains('invoice.exe bytes')),
      reason: 'only the hash',
    );

    await checks.disable();
    expect(checks.enabled, isFalse);
    expect(secrets.values, isEmpty, reason: 'the key is forgotten');
  });

  test('results in words', () {
    expect(
      VirusTotalCheck.describe(const VirusTotalReport(known: false), 'file'),
      contains('hasn\'t seen this file'),
    );
    expect(
      VirusTotalCheck.describe(
        const VirusTotalReport(known: true, malicious: 3, undetected: 60),
        'file',
      ),
      '3 of 63 security vendors on VirusTotal flag this file as dangerous.',
    );
    expect(
      VirusTotalCheck.describe(
        const VirusTotalReport(known: true, harmless: 70),
        'link',
      ),
      contains('None of 70'),
    );
  });

  testWidgets('a flagged link offers VirusTotal; it asks only when tapped', (
    tester,
  ) async {
    var asked = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => LinkOpener.open(
              context,
              Uri.parse('https://phish.example/login'),
              onMailto: (_) {},
              safety: (_) async =>
                  const SafeBrowsingVerdict(ThreatType.socialEngineering),
              virusTotal: (_) async {
                asked++;
                return const VirusTotalReport(known: true, malicious: 9);
              },
            ),
            child: const Text('link'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('link'));
    await tester.pumpAndSettle();
    expect(find.text('Check with VirusTotal'), findsOneWidget);
    expect(asked, 0);
    await tester.tap(find.text('Check with VirusTotal'));
    await tester.pumpAndSettle();
    expect(asked, 1);
    expect(find.textContaining('9 of 9 security vendors'), findsOneWidget);
  });

  testWidgets('Settings asks for the key and explains what is sent', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(services: app.services, isAndroid: false)),
    );
    await tester.tap(find.text('Ask VirusTotal about flagged files and links'));
    await tester.pumpAndSettle();
    expect(find.text('Ask VirusTotal?'), findsOneWidget);
    expect(find.textContaining('the file never is'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'API key'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(app.services.virusTotal.enabled, isFalse);
  });
}
