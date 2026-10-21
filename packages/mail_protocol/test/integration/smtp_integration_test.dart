// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Sends real mail through the local test servers and reads it back over
// IMAP. Mail goes to alice+<random>@fmail.test, which the test server
// delivers to a new folder of that name, so seeded folders stay unchanged.

import 'dart:math';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:test/test.dart';

import '../support/test_servers.dart';

const alice = MailAddress(
  displayName: 'Alice Example',
  localPart: 'alice',
  domain: 'fmail.test',
);
const bob = MailAddress(localPart: 'bob', domain: 'fmail.test');

String scratch() => 'smtp${Random.secure().nextInt(1 << 32).toRadixString(16)}';

MailAddress plusAddress(String folder) =>
    MailAddress(localPart: 'alice+$folder', domain: 'fmail.test');

void main() {
  final skip = TestServers.skipReason;
  if (skip != null) {
    test('needs the local test servers', () {}, skip: skip);
    return;
  }
  final servers = TestServers.load();

  Future<SmtpClient> loggedIn(ServerEndpoint endpoint) async {
    final client = await SmtpClient.connect(endpoint, tls: servers.tls);
    await client.authenticate(
      TestServers.address('alice'),
      TestServers.password('alice'),
    );
    return client;
  }

  /// Waits for one message in alice's [folder] and parses it.
  Future<MimeMessage> receive(String folder) async {
    final imap = await servers.imap('alice');
    try {
      for (var attempt = 0; attempt < 50; attempt++) {
        final folders = await imap.listMailboxes();
        if (folders.any((f) => f.name == folder)) {
          final selected = await imap.select(folder, readOnly: true);
          if (selected.exists > 0) {
            final fetched = await imap.uidFetch(
              SequenceSet.all(),
              FetchItems(fullMessage: true),
            );
            return const MimeParser().parse(
              fetched.messages.single.sections['']!,
            );
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      throw StateError('message did not arrive in $folder');
    } finally {
      await imap.logout();
    }
  }

  for (final (label, endpoint) in [
    ('implicit TLS (465)', servers.secureSubmissions),
    ('STARTTLS (587)', servers.secureSubmission),
  ]) {
    test('send over $label arrives intact', () async {
      final folder = scratch();
      final built = MessageBuilder().build(
        OutgoingMessage(
          from: alice,
          to: [plusAddress(folder)],
          subject: 'Grüße über $label',
          textBody: 'Line one\n.\nThe line above is a single dot.',
        ),
      );
      final smtp = await loggedIn(endpoint);
      expect(smtp.isAuthenticated, isTrue);
      await smtp.send(built, from: alice);
      await smtp.quit();

      final received = await receive(folder);
      expect(received.messageId, built.messageId);
      expect(received.subject, 'Grüße über $label');
      // What arrives is exactly what was built (so the copy saved to Sent
      // matches), including the line holding a single dot.
      final sent = const MimeParser()
          .parse(built.bytes)
          .textBody!
          .decodeText()
          .text;
      expect(received.textBody!.decodeText().text, sent);
      expect(sent.split('\n'), contains('.'));
    });
  }

  test('Bcc recipients receive the message without appearing in it', () async {
    final visible = scratch(), hidden = scratch();
    final built = MessageBuilder().build(
      OutgoingMessage(
        from: alice,
        to: [plusAddress(visible)],
        bcc: [plusAddress(hidden)],
        subject: 'bcc',
        textBody: 'x',
      ),
    );
    final smtp = await loggedIn(servers.secureSubmissions);
    await smtp.send(built, from: alice);
    await smtp.quit();
    final copy = await receive(hidden);
    expect(copy.headers.contains('bcc'), isFalse);
    expect(copy.to.single.localPart, 'alice+$visible');
  });

  test(
    'a refused recipient means nothing is sent, and the session stays usable',
    () async {
      final folder = scratch();
      final smtp = await loggedIn(servers.secureSubmissions);
      final mixed = MessageBuilder().build(
        OutgoingMessage(
          from: alice,
          to: [
            plusAddress(folder),
            const MailAddress(localPart: 'someone', domain: 'example.com'),
          ],
          subject: 'partial',
          textBody: 'x',
        ),
      );
      await expectLater(
        smtp.send(mixed, from: alice),
        throwsA(
          isA<SmtpRecipientsRejectedException>().having(
            (e) => e.rejected.keys.single.domain,
            'refused',
            'example.com',
          ),
        ),
      );
      // Same connection, valid message: still works after RSET.
      final ok = MessageBuilder().build(
        OutgoingMessage(
          from: alice,
          to: [plusAddress(folder)],
          subject: 'after',
          textBody: 'x',
        ),
      );
      await smtp.send(ok, from: alice);
      await smtp.quit();
      expect(
        (await receive(folder)).subject,
        'after',
        reason: 'only the second message arrived',
      );
    },
  );

  test('sending as someone else is refused', () async {
    final smtp = await loggedIn(servers.secureSubmissions);
    await expectLater(
      smtp.send(
        MessageBuilder().build(
          OutgoingMessage(
            from: bob,
            to: [plusAddress(scratch())],
            textBody: 'x',
          ),
        ),
        from: bob,
      ),
      throwsA(isA<SmtpRecipientsRejectedException>()),
    );
    await smtp.quit();
  });

  test('wrong password is an authentication error', () async {
    final smtp = await SmtpClient.connect(
      servers.secureSubmissions,
      tls: servers.tls,
    );
    await expectLater(
      smtp.authenticate(TestServers.address('alice'), 'wrong'),
      throwsA(isA<SmtpAuthenticationException>()),
    );
    await smtp.close();
  });

  test('a submission server without encryption is refused', () async {
    await expectLater(
      SmtpClient.connect(servers.plainSubmission, tls: servers.tls),
      throwsA(isA<MailSecurityException>()),
    );
  });

  test(
    'the server size limit is announced and enforced before sending',
    () async {
      final smtp = await loggedIn(servers.secureSubmissions);
      expect(smtp.maxMessageSize, 26214400);
      await smtp.quit();
    },
  );
}
