// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:citusmail/src/services/link_safety.dart';
import 'package:citusmail/src/services/secret_store.dart';
import 'package:citusmail/src/ui/link_opener.dart';
import 'package:citusmail/src/ui/settings_page.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

/// Google's API on 127.0.0.1, with one listed URL.
final class _Google {
  _Google._(this._socket);

  static Future<_Google> start() async =>
      _Google._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0))
        .._listen();

  final ServerSocket _socket;
  final paths = <String>[];

  static final listed = Uint8List.fromList(
    sha256.convert(utf8.encode('phish.example/')).bytes,
  );
  static final prefix = Uint8List.sublistView(listed, 0, 4);

  void _listen() => _socket.listen((client) {
    final got = BytesBuilder();
    client.listen((data) {
      got.add(data);
      final text = latin1.decode(got.toBytes());
      final end = text.indexOf('\r\n\r\n');
      if (end < 0) return;
      final length = int.parse(
        RegExp(r'Content-Length: (\d+)').firstMatch(text)!.group(1)!,
      );
      if (text.length < end + 4 + length) return;
      final path = text.split(' ')[1];
      paths.add(path);
      final answer = path.contains('threatListUpdates')
          ? {
              'listUpdateResponses': [
                {
                  'threatType': 'SOCIAL_ENGINEERING',
                  'responseType': 'FULL_UPDATE',
                  'additions': [
                    {
                      'rawHashes': {
                        'prefixSize': 4,
                        'rawHashes': base64.encode(prefix),
                      },
                    },
                  ],
                  'newClientState': 'czE=',
                  'checksum': {
                    'sha256': base64.encode(sha256.convert(prefix).bytes),
                  },
                },
              ],
              'minimumWaitDuration': '1800s',
            }
          : {
              'matches': [
                {
                  'threatType': 'SOCIAL_ENGINEERING',
                  'threat': {'hash': base64.encode(listed)},
                  'cacheDuration': '300s',
                },
              ],
            };
      final body = utf8.encode(jsonEncode(answer));
      client
        ..add(
          latin1.encode(
            'HTTP/1.1 200 OK\r\nContent-Length: ${body.length}\r\n\r\n',
          ),
        )
        ..add(body)
        ..close();
    });
  });

  WebClient get web => WebClient(
    resolver: (_) async => [InternetAddress('142.250.1.95')],
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
  late Directory dir;
  setUp(() async {
    app = await TestApp.create();
    dir = Directory.systemTemp.createTempSync('link_safety');
  });
  tearDown(() async {
    await app.dispose();
    dir.deleteSync(recursive: true);
  });

  test(
    'off by default; on with the user\'s own key; lists kept in a file',
    () async {
      final google = await _Google.start();
      addTearDown(google.close);
      final secrets = _Secrets();
      final file = File('${dir.path}/safebrowsing.bin');
      LinkSafety safety() => LinkSafety(
        app.store,
        secrets,
        google.web,
        listFile: file,
        builtInKey: '',
      );
      final s = safety();
      expect(s.enabled, isFalse);
      expect(await s.check(Uri.parse('http://phish.example/')), isNull);
      expect(google.paths, isEmpty, reason: 'nothing sent while off');

      expect(await s.enable(ownKey: 'short'), contains('API key'));
      expect(s.enabled, isFalse);

      const key = 'AIzaSyD-0123456789abcdefghijklmnopqrstu';
      expect(await s.enable(ownKey: key), isNull);
      expect(s.enabled, isTrue);
      expect(secrets.values[LinkSafety.keychainKey], key);
      expect(
        google.paths.single,
        startsWith('/v4/threatListUpdates:fetch?key='),
      );
      expect(file.existsSync(), isTrue);
      expect(s.status, startsWith('Lists updated'));

      // A fresh start reads the lists from the file.
      final again = safety();
      expect(
        (await again.check(Uri.parse('http://phish.example/')))?.threat,
        ThreatType.socialEngineering,
      );
      expect(
        (await again.check(Uri.parse('https://good.example/')))?.listed,
        isFalse,
      );
      s.stop();

      await again.disable();
      expect(again.enabled, isFalse);
      expect(file.existsSync(), isFalse);
    },
  );

  testWidgets('a listed link gets a danger warning before it opens', (
    tester,
  ) async {
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
            ),
            child: const Text('link'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('link'));
    await tester.pumpAndSettle();
    expect(find.text('Open this link anyway?'), findsOneWidget);
    expect(find.textContaining('deceptive (phishing)'), findsOneWidget);
    expect(find.text('Don\'t open'), findsOneWidget);
  });

  testWidgets('Settings asks before turning it on, and explains', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(services: app.services, isAndroid: false)),
    );
    expect(find.textContaining('checked on this device only'), findsOneWidget);
    await tester.tap(find.text('Check links with Google Safe Browsing'));
    await tester.pumpAndSettle();
    expect(find.text('Check links with Google Safe Browsing?'), findsOneWidget);
    expect(find.textContaining('the link itself never is'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(app.services.linkSafety.enabled, isFalse);
  });
}
