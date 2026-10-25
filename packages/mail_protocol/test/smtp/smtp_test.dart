// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:test/test.dart';

import '../imap/imap_parsing_test.dart' show MemorySource;
import '../support/fake_server.dart';

const alice = MailAddress(localPart: 'alice', domain: 'citusmail.test');
const bob = MailAddress(localPart: 'bob', domain: 'citusmail.test');

BuiltMessage message({List<MailAddress> to = const [bob]}) =>
    MessageBuilder().build(
      OutgoingMessage(from: alice, to: to, subject: 'Hi', textBody: 'Hello'),
    );

void main() {
  group('replies', () {
    test('multi-line EHLO reply with an enhanced code', () async {
      final reply = await SmtpReply.read(
        MemorySource('250-mail.example\r\n250-SIZE 1000\r\n250 STARTTLS\r\n'),
        timeout: Duration.zero,
      );
      expect(reply.code, 250);
      expect(reply.lines, ['mail.example', 'SIZE 1000', 'STARTTLS']);
      final rejected = await SmtpReply.read(
        MemorySource('550 5.7.1 Relaying denied\r\n'),
        timeout: Duration.zero,
      );
      expect(rejected.enhancedCode, '5.7.1');
      expect(rejected.isPermanentFailure, isTrue);
    });

    test('malformed replies are protocol errors', () async {
      for (final bad in ['hello\r\n', '250-a\r\n251 b\r\n', '25 short\r\n']) {
        expect(
          SmtpReply.read(MemorySource(bad), timeout: Duration.zero),
          throwsA(isA<MailProtocolException>()),
        );
      }
    });
  });

  group('dot-stuffing', () {
    String stuff(String s) => latin1.decode(
      SmtpClient.dotStuff(Uint8List.fromList(latin1.encode(s))),
    );

    test('a line of "." cannot end the message early', () {
      expect(stuff('a\r\n.\r\nb\r\n'), 'a\r\n..\r\nb\r\n');
      expect(stuff('.start\r\n'), '..start\r\n');
      expect(stuff('no.dot.at.start\r\n'), 'no.dot.at.start\r\n');
    });

    test('a final CRLF is added when missing', () {
      expect(stuff('end'), 'end\r\n');
    });
  });

  group('hostile servers', () {
    late FakeServer server;
    tearDown(() => server.close());

    ServerEndpoint startTls() => ServerEndpoint(
      'localhost',
      server.port,
      ConnectionSecurity.startTls,
      connectAddress: '127.0.0.1',
    );

    test('no STARTTLS offered: refused before anything else is sent', () async {
      server = await FakeServer.start(
        greeting: '220 fake ESMTP\r\n',
        onLine: (line) => line.startsWith('EHLO')
            ? '250-fake\r\n250 AUTH PLAIN\r\n'
            : '250 ok\r\n',
      );
      await expectLater(
        SmtpClient.connect(startTls()),
        throwsA(isA<MailSecurityException>()),
      );
      expect(server.received, ['EHLO [127.0.0.1]']);
    });

    test('STARTTLS injection closes the connection', () async {
      server = await FakeServer.start(
        greeting: '220 fake ESMTP\r\n',
        onLine: (line) {
          if (line.startsWith('EHLO')) return '250-fake\r\n250 STARTTLS\r\n';
          if (line == 'STARTTLS') {
            return '220 go ahead\r\n250-injected\r\n250 AUTH PLAIN\r\n';
          }
          return null;
        },
      );
      await expectLater(
        SmtpClient.connect(startTls()),
        throwsA(isA<MailSecurityException>()),
      );
      expect(server.received.any((l) => l.startsWith('AUTH')), isFalse);
    });

    test('the EHLO name reveals nothing about the device', () async {
      server = await FakeServer.start(
        greeting: '220 fake\r\n',
        onLine: (_) => '250 ok\r\n',
      );
      await expectLater(
        SmtpClient.connect(startTls()),
        throwsA(isA<MailSecurityException>()),
      );
      expect(server.received.first, 'EHLO [127.0.0.1]');
    });

    test('a 421 greeting is a refused connection', () async {
      server = await FakeServer.start(
        greeting: '421 too busy\r\n',
        onLine: (_) => null,
      );
      await expectLater(
        SmtpClient.connect(startTls()),
        throwsA(isA<MailConnectionException>()),
      );
    });
  });
}
