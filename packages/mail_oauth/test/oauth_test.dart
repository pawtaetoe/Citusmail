// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mail_oauth/mail_oauth.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_web/mail_web.dart';
import 'package:test/test.dart';

const _provider = OAuthProvider(
  id: 'test',
  name: 'Test',
  authorizationUrl: 'https://login.example.com/authorize',
  tokenUrl: 'https://login.example.com/token',
  scopes: ['mail.read', 'offline_access'],
  clientId: 'client-123',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

/// A token endpoint on 127.0.0.1 answering every POST with [reply].
final class _TokenServer {
  _TokenServer._(this._socket);

  static Future<_TokenServer> start() async =>
      _TokenServer._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0))
        .._listen();

  final ServerSocket _socket;
  final bodies = <Map<String, String>>[];
  int status = 200;
  String reply = '{}';

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
      bodies.add(Uri.splitQueryString(text.substring(end + 4)));
      final body = utf8.encode(reply);
      client
        ..add(
          latin1.encode(
            'HTTP/1.1 $status X\r\nContent-Type: application/json\r\n'
            'Content-Length: ${body.length}\r\n\r\n',
          ),
        )
        ..add(body)
        ..close();
    });
  });

  WebClient get web => WebClient(
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
  test('PKCE: the RFC 7636 example, and fresh verifiers', () {
    expect(
      Pkce.challengeFor('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
      'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    );
    final a = Pkce.generate(), b = Pkce.generate();
    expect(a.verifier, hasLength(64));
    expect(a.verifier, isNot(b.verifier));
    expect(a.verifier, matches(RegExp(r'^[A-Za-z0-9\-._~]+$')));
  });

  test('providers by id, and with a client id given at run time', () {
    expect(OAuthProvider.byId('microsoft'), same(OAuthProvider.microsoft));
    expect(OAuthProvider.byId('nobody'), isNull);
    final custom = OAuthProvider.microsoft.withClientId('abc-123');
    expect(custom.configured, isTrue);
    expect(custom.clientId, 'abc-123');
    expect(custom.id, 'microsoft');
    expect(custom.scopes, OAuthProvider.microsoft.scopes);
    expect(custom.imapHost, OAuthProvider.microsoft.imapHost);
    expect(custom.smtpPort, OAuthProvider.microsoft.smtpPort);
    expect(custom.extraParameters, OAuthProvider.microsoft.extraParameters);
  });

  group('AuthorizationRequest', () {
    final redirect = Uri.parse('http://127.0.0.1:5555/');

    test('the sign-in address carries what the provider needs', () {
      final r = AuthorizationRequest.start(
        _provider,
        redirectUri: redirect,
        loginHint: 'me@example.com',
        random: Random(1),
      );
      final q = r.url.queryParameters;
      expect(
        r.url.toString(),
        startsWith('https://login.example.com/authorize?'),
      );
      expect(q['client_id'], 'client-123');
      expect(q['response_type'], 'code');
      expect(q['redirect_uri'], 'http://127.0.0.1:5555/');
      expect(q['scope'], 'mail.read offline_access');
      expect(q['code_challenge'], r.pkce.challenge);
      expect(q['code_challenge_method'], 'S256');
      expect(q['state'], r.state);
      expect(q['login_hint'], 'me@example.com');
      expect(r.url.toString(), isNot(contains(r.pkce.verifier)));
    });

    test('an unconfigured provider can\'t start', () {
      const none = OAuthProvider(
        id: 'x',
        name: 'X',
        authorizationUrl: 'https://a.example/',
        tokenUrl: 'https://a.example/t',
        scopes: [],
        clientId: '',
        imapHost: 'i',
        smtpHost: 's',
      );
      expect(
        () => AuthorizationRequest.start(none, redirectUri: redirect),
        throwsStateError,
      );
    });

    test('answers: right one, forged, refused, cancelled, misdirected', () {
      final r = AuthorizationRequest.start(_provider, redirectUri: redirect);
      Uri answer(
        Map<String, String> q, {
        String base = 'http://127.0.0.1:5555/',
      }) => Uri.parse(base).replace(queryParameters: q);
      expect(r.codeFrom(answer({'code': 'abc', 'state': r.state})), 'abc');

      Matcher problem(OAuthProblem p) =>
          throwsA(isA<OAuthException>().having((e) => e.problem, 'problem', p));
      expect(
        () => r.codeFrom(answer({'code': 'abc', 'state': 'forged'})),
        problem(OAuthProblem.invalidAnswer),
      );
      expect(
        () => r.codeFrom(answer({'code': 'abc'})),
        problem(OAuthProblem.invalidAnswer),
      );
      expect(
        () => r.codeFrom(answer({'error': 'access_denied', 'state': r.state})),
        problem(OAuthProblem.cancelled),
      );
      expect(
        () => r.codeFrom(
          answer({'error': 'unauthorized_client', 'state': r.state}),
        ),
        problem(OAuthProblem.refused),
      );
      expect(
        () => r.codeFrom(
          answer({
            'code': 'abc',
            'state': r.state,
          }, base: 'http://127.0.0.1:6666/'),
        ),
        problem(OAuthProblem.invalidAnswer),
      );
    });
  });

  group('TokenClient', () {
    late _TokenServer server;
    setUp(() async => server = await _TokenServer.start());
    tearDown(() => server.close());
    final now = DateTime.utc(2026, 10, 24, 12);

    test('exchange: the code and verifier go out, tokens come back', () async {
      server.reply = jsonEncode({
        'token_type': 'Bearer',
        'access_token': 'AT-1',
        'refresh_token': 'RT-1',
        'expires_in': 3599,
      });
      final request = AuthorizationRequest.start(
        _provider,
        redirectUri: Uri.parse('http://127.0.0.1:5555/'),
      );
      final tokens = await TokenClient(
        server.web,
        now: () => now,
      ).exchange(request, 'CODE');
      expect(tokens.accessToken, 'AT-1');
      expect(tokens.refreshToken, 'RT-1');
      expect(tokens.expiresAt, now.add(const Duration(seconds: 3599)));
      final sent = server.bodies.single;
      expect(sent['grant_type'], 'authorization_code');
      expect(sent['code'], 'CODE');
      expect(sent['code_verifier'], request.pkce.verifier);
      expect(sent['client_id'], 'client-123');
      expect(
        sent.containsKey('client_secret'),
        isFalse,
        reason: 'public client',
      );
    });

    test('refresh keeps the old refresh token when none comes back', () async {
      server.reply = jsonEncode({'access_token': 'AT-2', 'expires_in': '600'});
      final tokens = await TokenClient(
        server.web,
        now: () => now,
      ).refresh(_provider, 'RT-1');
      expect(tokens.accessToken, 'AT-2');
      expect(tokens.refreshToken, 'RT-1');
      expect(server.bodies.single['grant_type'], 'refresh_token');
    });

    test('a revoked sign-in asks to sign in again; junk is refused', () async {
      server
        ..status = 400
        ..reply = jsonEncode({
          'error': 'invalid_grant',
          'error_description':
              'AADSTS70000: The grant is expired.\nTrace ID: x',
        });
      await expectLater(
        TokenClient(server.web).refresh(_provider, 'RT-1'),
        throwsA(
          isA<OAuthException>()
              .having((e) => e.problem, 'problem', OAuthProblem.signInAgain)
              .having(
                (e) => e.message,
                'message',
                'AADSTS70000: The grant is expired.',
              ),
        ),
      );
      server
        ..status = 200
        ..reply = 'not json';
      await expectLater(
        TokenClient(server.web).refresh(_provider, 'RT-1'),
        throwsA(
          isA<OAuthException>().having(
            (e) => e.problem,
            'problem',
            OAuthProblem.invalidAnswer,
          ),
        ),
      );
      server.reply = jsonEncode({'token_type': 'mac', 'access_token': 'x'});
      await expectLater(
        TokenClient(server.web).refresh(_provider, 'RT-1'),
        throwsA(isA<OAuthException>()),
      );
    });

    test('unreachable: a network problem', () async {
      final offline = WebClient(
        resolver: (_) async => throw const SocketException('offline'),
      );
      await expectLater(
        TokenClient(offline).refresh(_provider, 'RT-1'),
        throwsA(
          isA<OAuthException>().having(
            (e) => e.problem,
            'problem',
            OAuthProblem.network,
          ),
        ),
      );
    });
  });

  test('tokens: stored form and when to renew', () {
    final t = OAuthTokens(
      accessToken: 'AT',
      expiresAt: DateTime.utc(2026, 10, 24, 13),
      refreshToken: 'RT',
    );
    final back = OAuthTokens.fromJson(t.toJson())!;
    expect(
      (back.accessToken, back.refreshToken, back.expiresAt),
      ('AT', 'RT', t.expiresAt),
    );
    expect(t.needsRefresh(now: DateTime.utc(2026, 10, 24, 12)), isFalse);
    expect(t.needsRefresh(now: DateTime.utc(2026, 10, 24, 12, 56)), isTrue);
    for (final junk in [null, '', 'x', '{}', '{"access":1,"expires":2}']) {
      expect(OAuthTokens.fromJson(junk), isNull, reason: junk);
    }
  });

  test('which domains need Microsoft sign-in', () {
    expect(
      OAuthProvider.forDomain('Outlook.com'),
      same(OAuthProvider.microsoft),
    );
    expect(
      OAuthProvider.forDomain('hotmail.co.uk'),
      same(OAuthProvider.microsoft),
    );
    expect(OAuthProvider.forDomain('tommykung.cc'), isNull);
    expect(OAuthProvider.microsoft.scopes, contains('offline_access'));
  });

  group('LoopbackReceiver', () {
    Future<int> get(Uri uri) async {
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(uri)).close();
        await response.drain<void>();
        return response.statusCode;
      } finally {
        client.close(force: true);
      }
    }

    test('takes the one right answer, ignores others, then closes', () async {
      final receiver = await LoopbackReceiver.start();
      final base = receiver.redirectUri;
      expect(base.host, '127.0.0.1');
      final answer = receiver.answer(
        (uri) => uri.queryParameters['state'] == 'S',
      );
      expect(await get(base.resolve('/favicon.ico')), 404);
      expect(
        await get(
          base.replace(queryParameters: {'state': 'forged', 'code': 'x'}),
        ),
        404,
      );
      expect(
        await get(base.replace(queryParameters: {'state': 'S', 'code': 'abc'})),
        200,
      );
      final got = await answer;
      expect(got.queryParameters['code'], 'abc');
      await expectLater(
        get(base),
        throwsA(isA<SocketException>()),
        reason: 'closed',
      );
    });

    test('gives up after its time', () async {
      final receiver = await LoopbackReceiver.start(
        timeout: const Duration(milliseconds: 200),
      );
      await expectLater(
        receiver.answer((_) => true),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}
