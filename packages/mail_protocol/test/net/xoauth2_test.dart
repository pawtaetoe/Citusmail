// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:test/test.dart';

import '../support/fake_server.dart';

final _certs = Directory('../../test-server/.generated/certs');
final _haveCerts = File('${_certs.path}/mail.crt').existsSync();

SecurityContext _serverTls() => SecurityContext()
  ..useCertificateChain('${_certs.path}/mail.crt')
  ..usePrivateKey('${_certs.path}/mail.key');

TlsSettings _clientTls() =>
    TlsSettings.trustOnly(File('${_certs.path}/ca.crt').readAsBytesSync());

ServerEndpoint _endpoint(FakeServer s) => ServerEndpoint(
  'mail.citusmail.test',
  s.port,
  ConnectionSecurity.implicitTls,
  connectAddress: '127.0.0.1',
);

final _expected = base64.encode(
  utf8.encode('user=me@outlook.example\u0001auth=Bearer tok.en-1\u0001\u0001'),
);

/// What a provider sends back for a refused token.
const _challenge = '+ eyJzdGF0dXMiOiI0MDEifQ==\r\n';

void main() {
  test('the initial response, and what it refuses', () {
    expect(
      XOAuth2.initialResponse('me@outlook.example', 'tok.en-1'),
      _expected,
    );
    for (final (user, token) in [
      ('', 't'),
      ('a b@x', 't'),
      ('a@x', ''),
      ('a@x', 'to\u0001ken'),
      ('a@x', 'tok\r\nA1 LOGOUT'),
    ]) {
      expect(() => XOAuth2.initialResponse(user, token), throwsArgumentError);
    }
  });

  group('IMAP', () {
    late FakeServer server;
    tearDown(() => server.close());

    /// An Outlook-like server; the client's command tags are remembered,
    /// since the client picks them.
    Future<FakeServer> imap({required bool saslIr, required bool accept}) {
      var authTag = '';
      final caps = saslIr ? 'SASL-IR AUTH=XOAUTH2' : 'AUTH=XOAUTH2';
      return FakeServer.start(
        tls: _serverTls(),
        greeting: '* OK [CAPABILITY IMAP4rev1 $caps] ready\r\n',
        onLine: (line) {
          final tag = line.split(' ').first;
          if (line.contains('AUTHENTICATE XOAUTH2')) {
            authTag = tag;
            if (!saslIr) return '+ \r\n';
            return accept ? '$tag OK done\r\n' : _challenge;
          }
          if (line == _expected) {
            return accept ? '$authTag OK done\r\n' : _challenge;
          }
          if (line.isEmpty) {
            return '$authTag NO [AUTHENTICATIONFAILED] invalid token\r\n';
          }
          if (line.contains('CAPABILITY')) {
            return '* CAPABILITY IMAP4rev1 IDLE\r\n$tag OK\r\n';
          }
          return '$tag OK\r\n';
        },
      );
    }

    test('with SASL-IR: one line, accepted', () async {
      server = await imap(saslIr: true, accept: true);
      final client = await ImapClient.connect(
        _endpoint(server),
        tls: _clientTls(),
      );
      await client.loginOAuth('me@outlook.example', 'tok.en-1');
      expect(
        server.received.first,
        matches(
          RegExp(
            '^[A-Z0-9]+ AUTHENTICATE XOAUTH2 ${RegExp.escape(_expected)}\$',
          ),
        ),
      );
    });

    test('with SASL-IR, a refused token ends cleanly', () async {
      server = await imap(saslIr: true, accept: false);
      final client = await ImapClient.connect(
        _endpoint(server),
        tls: _clientTls(),
      );
      await expectLater(
        client.loginOAuth('me@outlook.example', 'tok.en-1'),
        throwsA(isA<ImapAuthenticationException>()),
      );
      expect(server.received.last, '', reason: 'the challenge was answered');
    });

    test('without SASL-IR, a refused token ends cleanly', () async {
      server = await imap(saslIr: false, accept: false);
      final client = await ImapClient.connect(
        _endpoint(server),
        tls: _clientTls(),
      );
      await expectLater(
        client.loginOAuth('me@outlook.example', 'tok.en-1'),
        throwsA(isA<ImapAuthenticationException>()),
      );
      expect(server.received, hasLength(3));
      expect(server.received.first, endsWith(' AUTHENTICATE XOAUTH2'));
      expect(server.received.sublist(1), [_expected, '']);
    });

    test('a server without XOAUTH2 is told nothing', () async {
      server = await FakeServer.start(
        tls: _serverTls(),
        greeting: '* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN] ready\r\n',
        onLine: (_) => null,
      );
      final client = await ImapClient.connect(
        _endpoint(server),
        tls: _clientTls(),
      );
      await expectLater(
        client.loginOAuth('me@outlook.example', 'tok.en-1'),
        throwsA(isA<ImapAuthenticationException>()),
      );
      expect(server.received, isEmpty);
    });
  }, skip: _haveCerts ? null : 'needs test-server certificates');

  group('SMTP', () {
    late FakeServer server;
    tearDown(() => server.close());

    Future<FakeServer> smtp({required bool accept}) => FakeServer.start(
      tls: _serverTls(),
      greeting: '220 fake ESMTP\r\n',
      onLine: (line) {
        if (line.startsWith('EHLO')) {
          return '250-fake\r\n250 AUTH LOGIN PLAIN XOAUTH2\r\n';
        }
        if (line == 'AUTH XOAUTH2 $_expected') {
          return accept
              ? '235 2.7.0 Authentication successful\r\n'
              : '334 eyJzdGF0dXMiOiI0MDEifQ==\r\n';
        }
        if (line.isEmpty) return '535 5.7.3 Authentication unsuccessful\r\n';
        return '250 ok\r\n';
      },
    );

    test('accepted', () async {
      server = await smtp(accept: true);
      final client = await SmtpClient.connect(
        _endpoint(server),
        tls: _clientTls(),
      );
      await client.authenticateOAuth('me@outlook.example', 'tok.en-1');
      expect(server.received.last, 'AUTH XOAUTH2 $_expected');
    });

    test('refused: the challenge is answered with an empty line', () async {
      server = await smtp(accept: false);
      final client = await SmtpClient.connect(
        _endpoint(server),
        tls: _clientTls(),
      );
      await expectLater(
        client.authenticateOAuth('me@outlook.example', 'tok.en-1'),
        throwsA(isA<SmtpAuthenticationException>()),
      );
      expect(server.received.sublist(server.received.length - 2), [
        'AUTH XOAUTH2 $_expected',
        '',
      ]);
    });
  }, skip: _haveCerts ? null : 'needs test-server certificates');
}
