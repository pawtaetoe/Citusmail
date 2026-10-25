// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mail_lookup/mail_lookup.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_web/mail_web.dart';
import 'package:test/test.dart';

/// VirusTotal's API on 127.0.0.1: answers each GET with [status]/[body].
final class _VirusTotal {
  _VirusTotal._(this._socket);

  static Future<_VirusTotal> start() async =>
      _VirusTotal._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0))
        .._listen();

  final ServerSocket _socket;
  final requests = <String>[];
  int status = 200;
  String body = '{}';

  void _listen() => _socket.listen((client) {
    final got = BytesBuilder();
    client.listen((data) {
      got.add(data);
      final text = latin1.decode(got.toBytes());
      if (!text.contains('\r\n\r\n')) return;
      requests.add(text);
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
  late _VirusTotal vt;
  setUp(() async => vt = await _VirusTotal.start());
  tearDown(() => vt.close());

  final invoice = Uint8List.fromList(utf8.encode('MZ not really a program'));

  test('a file is looked up by its SHA-256 only', () async {
    vt.body = jsonEncode({
      'data': {
        'id': VirusTotalClient.fileId(invoice),
        'type': 'file',
        'attributes': {
          'last_analysis_date': 1761300000,
          'last_analysis_stats': {
            'malicious': 52,
            'suspicious': 1,
            'undetected': 18,
            'harmless': 0,
            'timeout': 2,
          },
        },
      },
    });
    final report = await VirusTotalClient(vt.web, 'KEY').file(invoice);
    expect(report.known, isTrue);
    expect(report.flagged, isTrue);
    expect(report.malicious, 52);
    expect(report.engines, 71);
    expect(report.analysedAt, DateTime.utc(2025, 10, 24, 10, 0));
    final request = vt.requests.single;
    expect(
      request,
      startsWith(
        'GET /api/v3/files/${VirusTotalClient.fileId(invoice)} HTTP/1.1\r\n'
        'Host: www.virustotal.com\r\n',
      ),
    );
    expect(request, contains('x-apikey: KEY\r\n'));
    expect(request, isNot(contains('MZ not really')), reason: 'no upload');
  });

  test('unknown files, refused keys and quotas', () async {
    final client = VirusTotalClient(vt.web, 'KEY');
    vt
      ..status = 404
      ..body = '{"error":{"code":"NotFoundError"}}';
    final unknown = await client.file(invoice);
    expect(unknown.known, isFalse);
    expect(unknown.flagged, isFalse);

    for (final (status, problem) in [
      (401, VirusTotalProblem.badKey),
      (429, VirusTotalProblem.quota),
      (500, VirusTotalProblem.unavailable),
    ]) {
      vt.status = status;
      await expectLater(
        client.file(invoice),
        throwsA(
          isA<VirusTotalException>().having(
            (e) => e.problem,
            'problem',
            problem,
          ),
        ),
      );
    }
    await expectLater(
      VirusTotalClient(vt.web, 'two words').file(invoice),
      throwsA(isA<VirusTotalException>()),
    );
  });

  test('a link is looked up by VirusTotal\'s id for it', () async {
    final link = Uri.parse('http://phish.example/login?x=1');
    vt.body = jsonEncode({
      'data': {
        'attributes': {
          'last_analysis_stats': {'malicious': 0, 'harmless': 70},
        },
      },
    });
    final report = await VirusTotalClient(vt.web, 'KEY').url(link);
    expect(report.flagged, isFalse);
    expect(report.engines, 70);
    final id = VirusTotalClient.urlId(link);
    expect(id, isNot(contains('=')));
    expect(utf8.decode(base64Url.decode(base64Url.normalize(id))), '$link');
    expect(vt.requests.single, startsWith('GET /api/v3/urls/$id HTTP/1.1'));
  });
}
