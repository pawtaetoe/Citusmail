// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_web/mail_web.dart';
import 'package:test/test.dart';

/// A plain TCP server on 127.0.0.1 that records each request and answers
/// with [reply], or with [routes] by request line ("GET /a").
final class _Server {
  _Server._(this._socket, this.reply, this.routes);

  static Future<_Server> start(
    String reply, {
    Map<String, String> routes = const {},
  }) async => _Server._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    reply,
    routes,
  ).._listen();

  final ServerSocket _socket;
  final String reply;
  final Map<String, String> routes;
  final requests = <String>[];

  int get port => _socket.port;

  void _listen() {
    _socket.listen((client) {
      final received = BytesBuilder();
      client.listen((data) {
        received.add(data);
        final text = latin1.decode(received.toBytes());
        final end = text.indexOf('\r\n\r\n');
        if (end < 0) return;
        final length = RegExp(r'Content-Length: (\d+)')
            .firstMatch(text)
            ?.group(1);
        if (text.length < end + 4 + int.parse(length ?? '0')) return;
        requests.add(text);
        final line = text.split(' HTTP/1.1').first;
        client
          ..add(latin1.encode(routes[line] ?? reply))
          ..close();
      }, onError: (_) {});
    });
  }

  Future<void> close() => _socket.close();
}

/// Lets tests talk to the local server: every name resolves to a public
/// looking address, and the connector opens a plain connection to the
/// test server instead (TLS is tested separately below).
WebClient _client(_Server server, {List<InternetAddress>? addresses}) =>
    WebClient(
      resolver: (_) async => addresses ?? [InternetAddress('93.184.216.34')],
      connector: (host, address, port, timeout) => MailSocket.connect(
        ServerEndpoint(
          host,
          server.port,
          ConnectionSecurity.startTls, // stays plain: never upgraded here
          connectAddress: '127.0.0.1',
        ),
      ),
      limits: const WebLimits(timeout: Duration(seconds: 3)),
    );

void main() {
  group('PublicAddressPolicy', () {
    const policy = PublicAddressPolicy();
    bool allows(String a) => policy.allows(InternetAddress(a));

    test('public addresses pass', () {
      for (final a in ['93.184.216.34', '1.1.1.1', '2606:4700::1111']) {
        expect(allows(a), isTrue, reason: a);
      }
    });

    test('local, private and special addresses are refused', () {
      for (final a in [
        '127.0.0.1',
        '10.1.2.3',
        '172.16.0.1',
        '172.31.255.255',
        '192.168.1.1',
        '169.254.169.254', // cloud metadata
        '100.64.0.1',
        '0.0.0.0',
        '224.0.0.1',
        '255.255.255.255',
        '192.0.2.1',
        '::1',
        '::',
        'fe80::1',
        'fd00::1',
        'ff02::1',
        '::ffff:192.168.1.1',
        '::ffff:127.0.0.1',
        '64:ff9b::a00:1', // NAT64 of 10.0.0.1
        '2002:c0a8:101::1', // 6to4 of 192.168.1.1
        '2001:db8::1',
      ]) {
        expect(allows(a), isFalse, reason: a);
      }
    });

    test('mapped public IPv4 passes', () {
      expect(allows('::ffff:93.184.216.34'), isTrue);
    });
  });

  group('WebClient', () {
    late _Server server;
    tearDown(() => server.close());

    test('sends a minimal POST and reads the status', () async {
      server = await _Server.start(
        'HTTP/1.1 202 Accepted\r\nX-Thing: 1\r\nSet-Cookie: a=b\r\n\r\nbody',
      );
      final response = await _client(server).post(
        Uri.parse('https://shop.example.com/unsub/abc?u=alice'),
        body: utf8.encode('List-Unsubscribe=One-Click'),
        contentType: 'application/x-www-form-urlencoded',
      );
      expect(response.statusCode, 202);
      expect(response.ok, isTrue);
      expect(response.headers['x-thing'], ['1']);

      final request = server.requests.single;
      expect(
        request,
        'POST /unsub/abc?u=alice HTTP/1.1\r\n'
        'Host: shop.example.com\r\n'
        'User-Agent: Mozilla/5.0\r\n'
        'Accept: */*\r\n'
        'Content-Type: application/x-www-form-urlencoded\r\n'
        'Content-Length: 26\r\n'
        'Connection: close\r\n'
        '\r\n'
        'List-Unsubscribe=One-Click',
      );
    });

    test('a POST can read the answer, also an error answer', () async {
      server = await _Server.start(
        'HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n'
        'Content-Length: 25\r\n\r\n{"error":"invalid_grant"}',
      );
      final response = await _client(server).post(
        Uri.parse('https://login.example.com/token'),
        body: utf8.encode('grant_type=refresh_token'),
        contentType: 'application/x-www-form-urlencoded',
        maxAnswer: 1000,
      );
      expect(response.statusCode, 400);
      expect(utf8.decode(response.body!), '{"error":"invalid_grant"}');
    });

    test('an API GET sends one key header and reads any answer', () async {
      server = await _Server.start(
        'HTTP/1.1 404 Not Found\r\nContent-Length: 18\r\n\r\n{"error":"absent"}',
      );
      final response = await _client(server).getApi(
        Uri.parse('https://www.virustotal.example/api/v3/files/abc'),
        apiKeyHeader: 'x-apikey',
        apiKey: 'k3y-123',
        maxAnswer: 1000,
      );
      expect(response.statusCode, 404);
      expect(utf8.decode(response.body!), '{"error":"absent"}');
      expect(
        server.requests.single,
        'GET /api/v3/files/abc HTTP/1.1\r\n'
        'Host: www.virustotal.example\r\n'
        'User-Agent: Mozilla/5.0\r\n'
        'Accept: */*\r\n'
        'x-apikey: k3y-123\r\n'
        'Connection: close\r\n'
        '\r\n',
      );
      for (final (header, key) in [
        ('Cookie', 'k'),
        ('x-apikey', 'two\r\nCookie: a=b'),
        ('x-apikey', ''),
        ('Authorization', 'k'),
      ]) {
        expect(
          () => _client(server).getApi(
            Uri.parse('https://a.example.com/'),
            apiKeyHeader: header,
            apiKey: key,
            maxAnswer: 10,
          ),
          throwsArgumentError,
          reason: '$header: $key',
        );
      }
    });

    test('redirects are reported, not followed', () async {
      server = await _Server.start(
        'HTTP/1.1 302 Found\r\nLocation: https://elsewhere.example.com/\r\n\r\n',
      );
      final response = await _client(
        server,
      ).post(Uri.parse('https://a.example.com/'), body: [], contentType: 'x/y');
      expect(response.statusCode, 302);
      expect(response.ok, isFalse);
      expect(server.requests, hasLength(1));
    });

    test('garbage answers are refused', () async {
      server = await _Server.start('SSH-2.0-OpenSSH\r\n\r\n');
      await expectLater(
        _client(server).post(
          Uri.parse('https://a.example.com/'),
          body: [],
          contentType: 'x/y',
        ),
        throwsA(
          isA<WebException>().having(
            (e) => e.problem,
            'problem',
            WebProblem.badResponse,
          ),
        ),
      );
    });

    test('a name pointing into a private network is never contacted', () async {
      server = await _Server.start('HTTP/1.1 200 OK\r\n\r\n');
      for (final addresses in [
        [InternetAddress('192.168.1.1')],
        [InternetAddress('93.184.216.34'), InternetAddress('127.0.0.1')],
      ]) {
        await expectLater(
          _client(server, addresses: addresses).post(
            Uri.parse('https://router.example.com/'),
            body: [],
            contentType: 'x/y',
          ),
          throwsA(
            isA<WebException>().having(
              (e) => e.problem,
              'problem',
              WebProblem.privateAddress,
            ),
          ),
        );
      }
      expect(server.requests, isEmpty);
    });

    test('unsafe addresses are refused before any lookup', () async {
      var lookups = 0;
      final client = WebClient(
        resolver: (_) async {
          lookups++;
          return [InternetAddress('93.184.216.34')];
        },
      );
      for (final url in [
        'http://shop.example.com/',
        'https://user:pw@shop.example.com/',
        'https://shop.example.com:8443/',
        'https://192.168.1.1/',
        'https://3232235777/',
        'https://[::1]/',
        'https://localhost/',
        'https://аpple.example.com/',
        'ftp://shop.example.com/',
        'https://shop.example.com/${'a' * 5000}',
      ]) {
        await expectLater(
          client.post(Uri.parse(url), body: [], contentType: 'x/y'),
          throwsA(
            isA<WebException>().having(
              (e) => e.problem,
              'problem',
              WebProblem.unsafeUrl,
            ),
          ),
          reason: url,
        );
      }
      expect(lookups, 0);
    });

    test('a server that never answers times out', () async {
      final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      silent.listen((_) {});
      addTearDown(silent.close);
      server = await _Server.start('');
      final client = WebClient(
        resolver: (_) async => [InternetAddress('93.184.216.34')],
        connector: (host, address, port, timeout) => MailSocket.connect(
          ServerEndpoint(
            host,
            silent.port,
            ConnectionSecurity.startTls,
            connectAddress: '127.0.0.1',
          ),
        ),
        limits: const WebLimits(timeout: Duration(milliseconds: 300)),
      );
      await expectLater(
        client.post(
          Uri.parse('https://slow.example.com/'),
          body: [],
          contentType: 'x/y',
        ),
        throwsA(
          isA<WebException>().having(
            (e) => e.problem,
            'problem',
            WebProblem.timeout,
          ),
        ),
      );
    });
  });

  group('downloads', () {
    late _Server server;
    tearDown(() => server.close());

    Future<WebDownload> get(
      String reply, {
      Map<String, String> routes = const {},
      int maxBytes = 1000,
      bool Function(Uri)? allow,
      List<InternetAddress>? addresses,
    }) async {
      server = await _Server.start(reply, routes: routes);
      return _client(server, addresses: addresses).get(
        Uri.parse('https://cdn.example.com/a.png'),
        maxBytes: maxBytes,
        allow: allow,
      );
    }

    Matcher fails(WebProblem problem) => throwsA(
      isA<WebException>().having((e) => e.problem, 'problem', problem),
    );

    test('a body by Content-Length', () async {
      final d = await get(
        'HTTP/1.1 200 OK\r\nContent-Type: image/PNG; x=y\r\n'
        'Content-Length: 5\r\n\r\nhello',
      );
      expect(utf8.decode(d.bytes), 'hello');
      expect(d.contentType, 'image/png');
      expect(server.requests.single, startsWith('GET /a.png HTTP/1.1\r\n'));
      expect(server.requests.single, isNot(contains('Content-Length')));
    });

    test('a chunked body', () async {
      final d = await get(
        'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
        '3\r\nhel\r\n2;ext=1\r\nlo\r\n0\r\n\r\n',
      );
      expect(utf8.decode(d.bytes), 'hello');
    });

    test('too large, compressed, without a length, or missing', () async {
      await expectLater(
        get('HTTP/1.1 200 OK\r\nContent-Length: 5000\r\n\r\n'),
        fails(WebProblem.tooLarge),
      );
      await server.close();
      await expectLater(
        get(
          'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
          '400\r\n${'x' * 1024}\r\n0\r\n\r\n',
        ),
        fails(WebProblem.tooLarge),
      );
      await server.close();
      await expectLater(
        get(
          'HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n'
          'Content-Length: 1\r\n\r\nx',
        ),
        fails(WebProblem.badResponse),
      );
      await server.close();
      await expectLater(
        get('HTTP/1.1 200 OK\r\n\r\nbody until close'),
        fails(WebProblem.badResponse),
      );
      await server.close();
      await expectLater(
        get('HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n'),
        fails(WebProblem.notAvailable),
      );
    });

    test('redirects are followed, each checked again', () async {
      final d = await get(
        'HTTP/1.1 500 X\r\n\r\n',
        routes: {
          'GET /a.png': 'HTTP/1.1 302 Found\r\nLocation: /b.png\r\nContent-Length: 0\r\n\r\n',
          'GET /b.png': 'HTTP/1.1 301 Moved\r\nLocation: https://img.example.com/c.png\r\n\r\n',
          'GET /c.png': 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok',
        },
      );
      expect(utf8.decode(d.bytes), 'ok');
      expect(d.url.toString(), 'https://img.example.com/c.png');
      expect(server.requests, hasLength(3));
      expect(server.requests.last, contains('Host: img.example.com\r\n'));
    });

    test('a redirect to plain http, a tracker or a loop is refused', () async {
      await expectLater(
        get('HTTP/1.1 302 Found\r\nLocation: http://cdn.example.com/x\r\n\r\n'),
        fails(WebProblem.unsafeUrl),
      );
      await server.close();
      await expectLater(
        get(
          'HTTP/1.1 302 Found\r\nLocation: https://track.example.com/open\r\n\r\n',
          allow: (u) => u.host != 'track.example.com',
        ),
        fails(WebProblem.unsafeUrl),
      );
      await server.close();
      await expectLater(
        get('HTTP/1.1 302 Found\r\nLocation: /a.png\r\n\r\n'),
        fails(WebProblem.badResponse),
      );
      expect(server.requests, hasLength(4), reason: 'first + 3 redirects');
    });

    test('a private address is refused for downloads too', () async {
      await expectLater(
        get(
          'HTTP/1.1 200 OK\r\n\r\n',
          addresses: [InternetAddress('10.0.0.5')],
        ),
        fails(WebProblem.privateAddress),
      );
      expect(server.requests, isEmpty);
    });
  });

  group('TLS', () {
    final certs = Directory('../../test-server/.generated/certs');
    final available = File('${certs.path}/mail.crt').existsSync();

    test(
      'checks the certificate against the name, not the address',
      () async {
        final context = SecurityContext()
          ..useCertificateChain('${certs.path}/mail.crt')
          ..usePrivateKey('${certs.path}/mail.key');
        final tlsServer = await SecureServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
          context,
        );
        addTearDown(tlsServer.close);
        tlsServer.listen(
          (client) {
            client.listen((_) {
              client
                ..write('HTTP/1.1 204 No Content\r\n\r\n')
                ..close();
            });
          },
          onError: (_) {}, // a refused handshake
        );
        final tls = TlsSettings.trustOnly(
          File('${certs.path}/ca.crt').readAsBytesSync(),
        );
        WebClient client() => WebClient(
          resolver: (_) async => [InternetAddress('93.184.216.34')],
          connector: (host, address, port, timeout) => MailSocket.connect(
            ServerEndpoint(
              host,
              tlsServer.port,
              ConnectionSecurity.implicitTls,
              connectAddress: '127.0.0.1',
            ),
            tls: tls,
          ),
        );

        final ok = await client().post(
          Uri.parse('https://mail.fmail.test/x'),
          body: [],
          contentType: 'x/y',
        );
        expect(ok.statusCode, 204);

        await expectLater(
          client().post(
            Uri.parse('https://other.fmail.test/x'),
            body: [],
            contentType: 'x/y',
          ),
          throwsA(
            isA<WebException>().having(
              (e) => e.problem,
              'problem',
              WebProblem.insecure,
            ),
          ),
        );
      },
      skip: available
          ? null
          : 'needs test-server certificates: run test-server/fmailtest up once',
    );
  });
}
