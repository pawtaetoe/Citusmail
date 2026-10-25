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

ServerEndpoint _endpoint(FakeServer s, ConnectionSecurity security) =>
    ServerEndpoint(
      'mail.fmail.test',
      s.port,
      security,
      connectAddress: '127.0.0.1',
    );

const _capabilities =
    '"IMPLEMENTATION" "Dovecot Pigeonhole"\r\n'
    '"SIEVE" "fileinto reject envelope mailbox comparator-i;unicode-casemap"\r\n'
    '"SASL" "PLAIN XOAUTH2"\r\n'
    '"VERSION" "1.0"\r\n'
    'OK "Ready."\r\n';

/// A Dovecot-like ManageSieve server over implicit TLS, holding scripts.
final class _Sieve {
  final scripts = <String, String>{};
  String? active;
  String? refuseScript;
  bool refuseLogin = false;

  /// Bytes of a client literal still to come, and the command it belongs to.
  int _literal = 0;
  String? _pending;
  final _body = StringBuffer();

  String? onLine(String line) {
    if (_pending != null) {
      // Lines arrive as latin1 (one char per byte). The literal's last
      // line ends with the CRLF that ends the command.
      _literal -= line.length;
      if (_literal <= 0) {
        _body.write(line);
        final command = _pending!;
        _pending = null;
        return _finish(command, utf8.decode(latin1.encode(_body.toString())));
      }
      _body.write('$line\r\n');
      _literal -= 2;
      return null;
    }
    final literal = RegExp(r'\{(\d+)\+\}$').firstMatch(line);
    if (literal != null) {
      _literal = int.parse(literal.group(1)!);
      _pending = line;
      _body.clear();
      return null;
    }
    final words = RegExp(r'"((?:[^"\\]|\\.)*)"')
        .allMatches(line)
        .map((m) => m.group(1)!.replaceAll(r'\"', '"').replaceAll(r'\\', r'\'));
    final args = words.toList();
    final command = line.split(' ').first.toUpperCase();
    switch (command) {
      case 'AUTHENTICATE':
        if (refuseLogin) {
          return args.first == 'XOAUTH2'
              ? '"eyJzdGF0dXMiOiI0MDEifQ=="\r\n'
              : 'NO "Authentication failed."\r\n';
        }
        return 'OK "Logged in."\r\n';
      case '"*"':
        return 'NO "Authentication aborted."\r\n';
      case 'LISTSCRIPTS':
        return [
          for (final name in scripts.keys)
            '"$name"${name == active ? ' ACTIVE' : ''}\r\n',
          'OK "Listscripts completed."\r\n',
        ].join();
      case 'GETSCRIPT':
        final script = scripts[args.first];
        if (script == null) {
          return 'NO (NONEXISTENT) "Script does not exist."\r\n';
        }
        return '{${utf8.encode(script).length}}\r\n$script\r\nOK "Getscript completed."\r\n';
      case 'SETACTIVE':
        active = args.first.isEmpty ? null : args.first;
        return 'OK\r\n';
      case 'DELETESCRIPT':
        if (args.first == active) return 'NO (ACTIVE) "Script is active."\r\n';
        scripts.remove(args.first);
        return 'OK\r\n';
      case 'LOGOUT':
        return 'OK "Logout completed."\r\n';
    }
    return 'NO "Unknown command."\r\n';
  }

  String _finish(String command, String body) {
    final script = body;
    if (refuseScript != null) {
      return 'NO "line 2: error: $refuseScript"\r\n';
    }
    if (command.startsWith('PUTSCRIPT')) {
      final name = RegExp(r'"([^"]*)"').firstMatch(command)!.group(1)!;
      scripts[name] = script;
      return script.contains('vacation')
          ? 'OK (WARNINGS) "line 1: unknown extension"\r\n'
          : 'OK\r\n';
    }
    return 'OK\r\n';
  }
}

void main() {
  group('ManageSieveClient', () {
    late FakeServer server;
    late _Sieve sieve;

    Future<ManageSieveClient> connect() async {
      sieve = _Sieve();
      server = await FakeServer.start(
        greeting: _capabilities,
        // FakeServer writes replies as latin1: hand it UTF-8 bytes.
        onLine: (line) => switch (sieve.onLine(line)) {
          final reply? => latin1.decode(utf8.encode(reply)),
          null => null,
        },
        tls: _serverTls(),
      );
      return ManageSieveClient.connect(
        _endpoint(server, ConnectionSecurity.implicitTls),
        tls: _clientTls(),
      );
    }

    tearDown(() => server.close());

    test('capabilities, login, and a script stored and activated', () async {
      final client = await connect();
      expect(client.capabilities.implementation, 'Dovecot Pigeonhole');
      expect(client.capabilities.extensions, contains('fileinto'));
      expect(
        client.capabilities.extensions,
        contains('comparator-i;unicode-casemap'),
      );
      expect(client.capabilities.sasl, {'PLAIN', 'XOAUTH2'});
      expect(client.capabilities.version, '1.0');

      await client.authenticate('alice@fmail.test', 'pw');
      expect(
        server.received.first,
        startsWith('AUTHENTICATE "PLAIN" "'),
        reason: 'initial response, one round trip',
      );

      const script =
          'require ["fileinto"];\r\n'
          'if header :contains "subject" "Prüfung \\"x\\"" {\r\n'
          '  fileinto "Ärger";\r\n'
          '}';
      expect(await client.putScript('citusmail', script), isNull);
      expect(sieve.scripts['citusmail'], script);
      await client.setActive('citusmail');
      expect(await client.listScripts(), [
        isA<SieveScriptInfo>()
            .having((s) => s.name, 'name', 'citusmail')
            .having((s) => s.active, 'active', isTrue),
      ]);
      expect(await client.getScript('citusmail'), script);
      await client.logout();
    });

    test('warnings come back; an invalid script is refused', () async {
      final client = await connect();
      await client.authenticate('alice@fmail.test', 'pw');
      expect(
        await client.putScript('x', 'require "vacation";'),
        contains('unknown extension'),
      );
      sieve.refuseScript = 'unknown test nonsense';
      await expectLater(
        client.putScript('x', 'if nonsense {}'),
        throwsA(
          isA<ManageSieveException>().having(
            (e) => e.text,
            'text',
            contains('nonsense'),
          ),
        ),
      );
      sieve.refuseScript = null;
      await expectLater(
        client.getScript('missing'),
        throwsA(
          isA<ManageSieveException>().having(
            (e) => e.code,
            'code',
            'NONEXISTENT',
          ),
        ),
      );
      await client.setActive('x');
      await expectLater(
        client.deleteScript('x'),
        throwsA(
          isA<ManageSieveException>().having((e) => e.code, 'code', 'ACTIVE'),
        ),
      );
      await client.setActive(null);
      expect(sieve.active, isNull);
      await client.deleteScript('x');
      expect(await client.listScripts(), isEmpty);
      await client.logout();
    });

    test('refused logins, also a refused OAuth token', () async {
      final client = await connect();
      sieve.refuseLogin = true;
      await expectLater(
        client.authenticate('alice@fmail.test', 'wrong'),
        throwsA(isA<ManageSieveAuthenticationException>()),
      );
      await expectLater(
        client.authenticateOAuth('alice@fmail.test', 'token'),
        throwsA(isA<ManageSieveAuthenticationException>()),
      );
      expect(server.received, contains('"*"'), reason: 'challenge cancelled');
      await client.logout();
    });
  }, skip: _haveCerts ? null : 'needs test-server certificates');

  test('a server without STARTTLS gets no credentials', () async {
    final server = await FakeServer.start(
      greeting: '"IMPLEMENTATION" "Old"\r\n"SASL" "PLAIN"\r\nOK\r\n',
      onLine: (_) => 'OK\r\n',
    );
    addTearDown(server.close);
    await expectLater(
      ManageSieveClient.connect(_endpoint(server, ConnectionSecurity.startTls)),
      throwsA(isA<MailSecurityException>()),
    );
    expect(server.received, isEmpty);
  });
}
