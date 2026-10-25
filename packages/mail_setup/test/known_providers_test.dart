// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_setup/mail_setup.dart';
import 'package:test/test.dart';

final _certs = Directory('../../test-server/.generated/certs');
final _haveCerts = File('${_certs.path}/mail.crt').existsSync();

void main() {
  group('KnownProvider', () {
    test('Gmail addresses, any case', () {
      expect(KnownProvider.forEmail('me@gmail.com'), KnownProvider.gmail);
      expect(
        KnownProvider.forEmail(' Me@GoogleMail.com '),
        KnownProvider.gmail,
      );
      expect(KnownProvider.forEmail('me@gmail.com.evil.example'), isNull);
      expect(KnownProvider.forEmail('me@example.org'), isNull);
      expect(KnownProvider.forEmail('nope'), isNull);
      expect(KnownProvider.forImapHost('IMAP.gmail.com'), KnownProvider.gmail);
      expect(KnownProvider.forImapHost('imap.example.org'), isNull);
    });

    test('built-in settings are trusted, even outside the domain', () {
      final s = KnownProvider.gmail.settingsFor('me@googlemail.com');
      expect(s.imap, KnownProvider.gmail.imap);
      expect(s.smtp.port, 465);
      expect(s.smtp.security, ConnectionSecurity.implicitTls);
      expect(s.username, 'me@googlemail.com');
      expect(s.source, DiscoverySource.builtIn);
      expect(s.needsConfirmation, isFalse);
    });

    test('app passwords lose the spaces they are shown with', () {
      const gmail = KnownProvider.gmail;
      expect(
        gmail.normalizePassword('abcd efgh ijkl mnop'),
        'abcdefghijklmnop',
      );
      expect(
        gmail.normalizePassword(' abcd efgh ijkl mnop '),
        'abcdefghijklmnop',
      );
      expect(gmail.normalizePassword('abcdefghijklmnop'), 'abcdefghijklmnop');
      // Anything else could be a real password: kept exactly.
      expect(gmail.normalizePassword('my pass word here'), 'my pass word here');
      expect(
        gmail.normalizePassword('abc1 efgh ijkl mnop'),
        'abc1 efgh ijkl mnop',
      );
    });

    test('discovery answers Gmail without asking anyone', () async {
      final fetcher = _NoNetwork();
      final steps = <DiscoveryStep>[];
      final result = await AccountDiscovery(
        fetcher: fetcher,
        srv: const NoSrvResolver(),
        prober: _NoProbes(),
      ).discover('me@gmail.com', onStep: steps.add);
      expect(result.settings!.source, DiscoverySource.builtIn);
      expect(result.settings!.imap.host, 'imap.gmail.com');
      expect(steps, isEmpty);
    });
  });

  group('AccountVerifier and app passwords', () {
    late List<_FakeServer> servers;
    final tls = _haveCerts
        ? TlsSettings.trustOnly(File('${_certs.path}/ca.crt').readAsBytesSync())
        : const TlsSettings();
    ServerEndpoint local(ServerCandidate c) =>
        ServerEndpoint(c.host, c.port, c.security, connectAddress: '127.0.0.1');

    setUp(() => servers = []);
    tearDown(() async {
      for (final s in servers) {
        await s.close();
      }
    });

    Future<_FakeServer> imap(String loginReply) async {
      final server = await _FakeServer.start(
        greeting: '* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN SASL-IR] ready\r\n',
        onLine: (line) {
          final tag = line.split(' ').first;
          if (line.contains(' AUTHENTICATE PLAIN ')) {
            return '$tag $loginReply\r\n';
          }
          if (line.contains(' LOGOUT')) return '* BYE\r\n$tag OK bye\r\n';
          if (line.contains(' CAPABILITY')) {
            return '* CAPABILITY IMAP4rev1 AUTH=PLAIN SASL-IR\r\n$tag OK\r\n';
          }
          return '$tag BAD unexpected\r\n';
        },
      );
      servers.add(server);
      return server;
    }

    Future<_FakeServer> smtp(String authReply) async {
      final server = await _FakeServer.start(
        greeting: '220 smtp.fmail.test ready\r\n',
        onLine: (line) {
          if (line.startsWith('EHLO')) {
            return '250-smtp.fmail.test\r\n250 AUTH PLAIN LOGIN\r\n';
          }
          if (line.startsWith('AUTH')) return authReply;
          if (line.startsWith('QUIT')) return '221 bye\r\n';
          return '500 unexpected\r\n';
        },
      );
      servers.add(server);
      return server;
    }

    DiscoveredSettings settings(int imapPort, int smtpPort) =>
        DiscoveredSettings(
          email: 'me@gmail.com',
          username: 'me@gmail.com',
          imap: ServerCandidate(
            'mail.fmail.test',
            imapPort,
            ConnectionSecurity.implicitTls,
          ),
          smtp: ServerCandidate(
            'mail.fmail.test',
            smtpPort,
            ConnectionSecurity.implicitTls,
          ),
          source: DiscoverySource.manual,
        );

    test("IMAP: Google's refusal of an account password", () async {
      final i = await imap(
        'NO [ALERT] Application-specific password required: '
        'https://support.google.com/accounts/answer/185833 (Failure)',
      );
      final result = await AccountVerifier(
        tls: tls,
        resolve: local,
      ).verify(settings(i.port, 1), 'my-google-password');
      expect(result.role, ServerRole.imap);
      expect(result.problem, VerificationProblem.appPasswordRequired);
    });

    test('IMAP: a wrong app password is a credentials problem', () async {
      final i = await imap(
        'NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)',
      );
      final result = await AccountVerifier(
        tls: tls,
        resolve: local,
      ).verify(settings(i.port, 1), 'abcdefghijklmnop');
      expect(result.problem, VerificationProblem.credentials);
    });

    test('SMTP: 534 5.7.9 asks for an app password', () async {
      final i = await imap('OK logged in');
      final s = await smtp(
        '534-5.7.9 Application-specific password required. Learn more at\r\n'
        '534 5.7.9  https://support.google.com/mail/?p=InvalidSecondFactor\r\n',
      );
      final result = await AccountVerifier(
        tls: tls,
        resolve: local,
      ).verify(settings(i.port, s.port), 'my-google-password');
      expect(result.role, ServerRole.smtp);
      expect(result.problem, VerificationProblem.appPasswordRequired);
    });

    test('SMTP: an ordinary refusal is a credentials problem', () async {
      final i = await imap('OK logged in');
      final s = await smtp('535 5.7.8 Username and Password not accepted\r\n');
      final result = await AccountVerifier(
        tls: tls,
        resolve: local,
      ).verify(settings(i.port, s.port), 'wrong');
      expect(result.problem, VerificationProblem.credentials);
    });
  }, skip: _haveCerts ? null : 'needs test-server certificates');
}

final class _NoNetwork implements SettingsFetcher {
  @override
  Future<String?> fetch(Uri uri) => fail('fetched $uri');
}

final class _NoProbes implements ServerAvailability {
  @override
  Future<bool> imapAvailable(ServerCandidate candidate) =>
      fail('probed $candidate');

  @override
  Future<bool> smtpAvailable(ServerCandidate candidate) =>
      fail('probed $candidate');
}

/// A scripted TLS server on 127.0.0.1 with the test certificate.
final class _FakeServer {
  _FakeServer._(this._server);

  static Future<_FakeServer> start({
    required String greeting,
    required String? Function(String line) onLine,
  }) async {
    final context = SecurityContext()
      ..useCertificateChain('${_certs.path}/mail.crt')
      ..usePrivateKey('${_certs.path}/mail.key');
    final server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    server.listen((socket) {
      socket.add(utf8.encode(greeting));
      var buffer = '';
      socket.listen(
        (data) {
          buffer += latin1.decode(data);
          while (buffer.contains('\n')) {
            final index = buffer.indexOf('\n');
            final line = buffer.substring(0, index).replaceAll('\r', '');
            buffer = buffer.substring(index + 1);
            final reply = onLine(line);
            if (reply != null) socket.add(latin1.encode(reply));
          }
        },
        onError: (_) {},
        onDone: () => socket.destroy(),
      );
    }, onError: (Object _) {});
    return _FakeServer._(server);
  }

  final SecureServerSocket _server;

  int get port => _server.port;

  Future<void> close() => _server.close();
}
