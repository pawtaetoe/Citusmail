// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Attacks and broken servers, played by a scripted fake server. These
// run without the test mail servers.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:test/test.dart';

import '../support/fake_server.dart';

void main() {
  late FakeServer server;
  tearDown(() => server.close());

  ServerEndpoint startTlsEndpoint() => ServerEndpoint(
    'localhost',
    server.port,
    ConnectionSecurity.startTls,
    connectAddress: '127.0.0.1',
  );

  bool sentCredentials() => server.received.any(
    (l) => l.contains('LOGIN') || l.contains('AUTHENTICATE'),
  );

  test(
    'STARTTLS injection: plain data after "OK begin TLS" closes the connection',
    () async {
      server = await FakeServer.start(
        greeting: '* OK [CAPABILITY IMAP4rev1 STARTTLS] ready\r\n',
        onLine: (line) {
          final tag = line.split(' ').first;
          // The attacker appends a fake untagged response to the OK, in the
          // same packet, hoping the client treats it as coming over TLS.
          if (line.endsWith('STARTTLS')) {
            return '$tag OK Begin TLS\r\n* CAPABILITY IMAP4rev1 AUTH=PLAIN\r\n';
          }
          return null;
        },
      );
      await expectLater(
        ImapClient.connect(startTlsEndpoint()),
        throwsA(isA<MailSecurityException>()),
      );
      expect(sentCredentials(), isFalse);
    },
  );

  test(
    'a server that does not offer STARTTLS is refused (no downgrade)',
    () async {
      server = await FakeServer.start(
        greeting: '* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN] ready\r\n',
        onLine: (line) => '${line.split(' ').first} OK done\r\n',
      );
      await expectLater(
        ImapClient.connect(startTlsEndpoint()),
        throwsA(isA<MailSecurityException>()),
      );
      expect(sentCredentials(), isFalse);
    },
  );

  test(
    'PREAUTH on a plain connection is refused (would skip STARTTLS)',
    () async {
      server = await FakeServer.start(
        greeting: '* PREAUTH [CAPABILITY IMAP4rev1] welcome\r\n',
        onLine: (_) => null,
      );
      await expectLater(
        ImapClient.connect(startTlsEndpoint()),
        throwsA(isA<MailSecurityException>()),
      );
    },
  );

  test('a server refusing STARTTLS stops the connection', () async {
    server = await FakeServer.start(
      greeting: '* OK [CAPABILITY IMAP4rev1 STARTTLS] ready\r\n',
      onLine: (line) => '${line.split(' ').first} NO not today\r\n',
    );
    await expectLater(
      ImapClient.connect(startTlsEndpoint()),
      throwsA(isA<MailException>()),
    );
    expect(sentCredentials(), isFalse);
  });

  test(
    'implicit TLS to a plain-text server fails before anything is sent',
    () async {
      server = await FakeServer.start(
        greeting: '* OK plain text greeting\r\n',
        onLine: (_) => null,
      );
      final endpoint = ServerEndpoint(
        'localhost',
        server.port,
        ConnectionSecurity.implicitTls,
        connectAddress: '127.0.0.1',
      );
      await expectLater(
        ImapClient.connect(endpoint),
        throwsA(isA<MailTlsException>()),
      );
      // Only the TLS handshake (record type 0x16) was sent: no IMAP command,
      // and certainly no credentials.
      expect(server.received.first.codeUnitAt(0), 0x16);
      expect(
        server.received.any((l) => RegExp(r'^F\d+ ').hasMatch(l)),
        isFalse,
      );
      expect(sentCredentials(), isFalse);
    },
  );

  test('a BYE greeting is reported as a refused connection', () async {
    server = await FakeServer.start(
      greeting: '* BYE too many connections\r\n',
      onLine: (_) => null,
    );
    await expectLater(
      ImapClient.connect(startTlsEndpoint()),
      throwsA(isA<MailConnectionException>()),
    );
  });

  test('a silent server times out instead of hanging', () async {
    server = await FakeServer.start(greeting: '', onLine: (_) => null);
    await expectLater(
      ImapClient.connect(
        startTlsEndpoint(),
        timeouts: const ImapTimeouts(command: Duration(milliseconds: 300)),
      ),
      throwsA(isA<MailTimeoutException>()),
    );
  });
}
