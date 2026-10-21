// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:test/test.dart';

const alice = MailAddress(
  displayName: 'Alice Example',
  localPart: 'alice',
  domain: 'fmail.test',
);
const bob = MailAddress(localPart: 'bob', domain: 'fmail.test');
const carol = MailAddress(
  displayName: 'Carol',
  localPart: 'carol',
  domain: 'fmail.test',
);

final builder = MessageBuilder(random: Random(7));
final fixedDate = DateTime.utc(2026, 10, 21, 12, 30);

BuiltMessage build(OutgoingMessage message) => builder.build(message);

MimeMessage roundTrip(OutgoingMessage message) =>
    const MimeParser().parse(build(message).bytes);

String raw(OutgoingMessage message) => latin1.decode(build(message).bytes);

/// The header section only (up to the first empty line).
String headerSection(String message) =>
    message.substring(0, message.indexOf('\r\n\r\n') + 2);

void main() {
  group('headers', () {
    test('basic fields round-trip', () {
      final m = roundTrip(
        OutgoingMessage(
          from: alice,
          to: [bob],
          cc: [carol],
          subject: 'Lunch on Friday?',
          textBody: 'Hi Bob',
          date: fixedDate,
          inReplyTo: 'lunch-1@fmail.test',
          references: ['lunch-0@fmail.test', 'lunch-1@fmail.test'],
        ),
      );
      expect(m.from.single, alice);
      expect(m.to.single, bob);
      expect(m.cc.single, carol);
      expect(m.subject, 'Lunch on Friday?');
      expect(m.date!.utc, fixedDate);
      expect(m.inReplyTo, ['lunch-1@fmail.test']);
      expect(m.references, ['lunch-0@fmail.test', 'lunch-1@fmail.test']);
      expect(m.textBody!.decodeText().text, 'Hi Bob');
      expect(m.allDefects, isEmpty);
    });

    test('non-ASCII subjects and names are encoded and decode back exactly', () {
      const subject =
          '會議通知：明天上午十點 — Grüße 😀 with a long tail to force several encoded words';
      const name = '山田 太郎';
      final message = OutgoingMessage(
        from: const MailAddress(
          displayName: name,
          localPart: 'yamada',
          domain: 'kaisha.example',
        ),
        to: [bob],
        subject: subject,
        textBody: 'x',
      );
      final m = roundTrip(message);
      expect(m.subject, subject);
      expect(m.from.single.displayName, name);
      final headers = headerSection(raw(message));
      expect(headers, isNot(contains('會')), reason: 'headers must be 7-bit');
    });

    test('display names with specials are quoted', () {
      final m = roundTrip(
        OutgoingMessage(
          from: const MailAddress(
            displayName: 'Smith, Eve "Events"',
            localPart: 'eve',
            domain: 'x.example',
          ),
          to: [bob],
          textBody: 'x',
        ),
      );
      expect(m.from.single.displayName, 'Smith, Eve "Events"');
    });

    test('subject spacing is preserved exactly, even when folded', () {
      final subject = 'a  b   c ${'word ' * 30}end';
      expect(
        roundTrip(
          OutgoingMessage(
            from: alice,
            to: [bob],
            subject: subject,
            textBody: 'x',
          ),
        ).subject,
        subject.trim(),
      );
    });

    test('text that looks like an encoded word is encoded, not misread', () {
      const subject = 'literal =?utf-8?Q?not_encoded?= text';
      expect(
        roundTrip(
          OutgoingMessage(
            from: alice,
            to: [bob],
            subject: subject,
            textBody: 'x',
          ),
        ).subject,
        subject,
      );
    });

    test('every header line is at most 78 characters and 7-bit', () {
      final message = OutgoingMessage(
        from: alice,
        to: List.generate(
          30,
          (i) => MailAddress(
            displayName: 'Person Number $i',
            localPart: 'p$i',
            domain: 'x.example',
          ),
        ),
        subject: 'Ünïcödé ${'long subject ' * 20}',
        textBody: 'x',
        references: List.generate(20, (i) => 'ref-$i@fmail.test'),
      );
      for (final line in headerSection(raw(message)).split('\r\n')) {
        expect(line.length, lessThanOrEqualTo(78), reason: line);
        expect(line.codeUnits.every((c) => c < 0x80), isTrue, reason: line);
        expect(
          line.trim().isEmpty && line.isNotEmpty,
          isFalse,
          reason: 'whitespace-only line',
        );
      }
      expect(const MimeParser().parse(build(message).bytes).to, hasLength(30));
    });
  });

  group('security and privacy', () {
    test('CR/LF in a subject cannot inject a header', () {
      final message = OutgoingMessage(
        from: alice,
        to: [bob],
        subject: 'Hi\r\nBcc: evil@x.example',
        textBody: 'x',
      );
      final m = roundTrip(message);
      expect(m.bcc, isEmpty);
      expect(m.headers.all('bcc'), isEmpty);
      expect(m.subject, 'Hi  Bcc: evil@x.example');
    });

    test('CR/LF in a display name cannot inject a header', () {
      final m = roundTrip(
        OutgoingMessage(
          from: const MailAddress(
            displayName: 'Eve\r\nBcc: evil@x.example',
            localPart: 'eve',
            domain: 'x.example',
          ),
          to: [bob],
          textBody: 'x',
        ),
      );
      expect(m.headers.all('bcc'), isEmpty);
    });

    test('addresses with control characters or bad syntax are rejected', () {
      for (final bad in [
        const MailAddress(localPart: 'bob\r\nBcc: x', domain: 'x.example'),
        const MailAddress(localPart: 'bob', domain: 'x.example>\r\nBcc: y@z'),
        const MailAddress(localPart: 'bob', domain: 'not a domain'),
        const MailAddress(localPart: '.bob', domain: 'x.example'),
        const MailAddress(localPart: 'bob', domain: 'café.example'),
      ]) {
        expect(
          () => build(OutgoingMessage(from: alice, to: [bad], textBody: 'x')),
          throwsA(isA<MessageBuildException>()),
          reason: bad.toString(),
        );
      }
    });

    test('Bcc recipients get the message but are not in the headers', () {
      final built = build(
        OutgoingMessage(
          from: alice,
          to: [bob],
          bcc: [carol],
          textBody: 'secret',
        ),
      );
      expect(built.recipients, [bob, carol]);
      expect(
        latin1.decode(built.bytes).toLowerCase(),
        isNot(contains('carol')),
      );
    });

    test('no client-identifying headers; Date in UTC; random Message-ID on own domain', () {
      final message = OutgoingMessage(
        from: alice,
        to: [bob],
        textBody: 'x',
        date: fixedDate,
      );
      final headers = headerSection(raw(message)).toLowerCase();
      for (final field in [
        'user-agent',
        'x-mailer',
        'x-originating-ip',
        'organization',
      ]) {
        expect(headers, isNot(contains('$field:')));
      }
      expect(headers, contains('date: wed, 21 oct 2026 12:30:00 +0000'));
      final id = build(message).messageId;
      expect(id, matches(RegExp(r'^[0-9a-f]{32}@fmail\.test$')));
      expect(build(message).messageId, isNot(id));
    });

    test(
      'attachment filenames lose directory parts and control characters',
      () {
        final m = roundTrip(
          OutgoingMessage(
            from: alice,
            to: [bob],
            textBody: 'x',
            attachments: [
              OutgoingAttachment(
                filename: '../../etc/passwd\r\n',
                mimeType: 'text/plain',
                bytes: Uint8List(1),
              ),
              OutgoingAttachment(
                filename: r'C:\Users\x\..',
                mimeType: 'text/plain',
                bytes: Uint8List(1),
              ),
            ],
          ),
        );
        expect(m.attachments.map((a) => a.filename), ['passwd', 'attachment']);
      },
    );

    test('invalid attachment types and missing recipients are rejected', () {
      expect(
        () => build(
          OutgoingMessage(
            from: alice,
            to: [bob],
            attachments: [
              OutgoingAttachment(
                filename: 'a',
                mimeType: 'text/plain\r\nX: y',
                bytes: Uint8List(0),
              ),
            ],
          ),
        ),
        throwsA(isA<MessageBuildException>()),
      );
      expect(
        () => build(OutgoingMessage(from: alice)),
        throwsA(isA<MessageBuildException>()),
      );
    });
  });

  group('bodies', () {
    test('plain ASCII is sent as 7bit', () {
      final m = roundTrip(
        OutgoingMessage(from: alice, to: [bob], textBody: 'Hello\nthere'),
      );
      expect(m.textBody!.transferEncoding, TransferEncoding.sevenBit);
      expect(m.textBody!.decodeText().text, 'Hello\nthere');
    });

    test('mostly-Latin text uses quoted-printable; CJK uses base64; both exact', () {
      const latin =
          'Grüße aus München — schönes Wetter.\nZweite Zeile   \nFrom here on';
      const cjk = '明日の会議は10時からです。よろしくお願いします。';
      final a = roundTrip(
        OutgoingMessage(from: alice, to: [bob], textBody: latin),
      );
      expect(a.textBody!.transferEncoding, TransferEncoding.quotedPrintable);
      expect(a.textBody!.decodeText().text, latin);
      final b = roundTrip(
        OutgoingMessage(from: alice, to: [bob], textBody: cjk),
      );
      expect(b.textBody!.transferEncoding, TransferEncoding.base64);
      expect(b.textBody!.decodeText().text, cjk);
    });

    test('long lines are wrapped with soft breaks and restored exactly', () {
      final long = '${'é' * 200} ${'x' * 300}=end';
      final message = OutgoingMessage(from: alice, to: [bob], textBody: long);
      final text = raw(message);
      for (final line
          in text.substring(text.indexOf('\r\n\r\n') + 4).split('\r\n')) {
        expect(line.length, lessThanOrEqualTo(76));
      }
      expect(roundTrip(message).textBody!.decodeText().text, long);
    });

    test('"From " at a line start is escaped in quoted-printable', () {
      final message = OutgoingMessage(
        from: alice,
        to: [bob],
        textBody: 'é\nFrom the start',
      );
      expect(raw(message), contains('=46rom the start'));
      expect(
        roundTrip(message).textBody!.decodeText().text,
        'é\nFrom the start',
      );
    });

    test('line endings are normalised to CRLF', () {
      final message = OutgoingMessage(
        from: alice,
        to: [bob],
        textBody: 'a\nb\r\nc\rd',
      );
      final bytes = build(message).bytes;
      for (var i = 0; i < bytes.length; i++) {
        if (bytes[i] == 0x0A) {
          expect(bytes[i - 1], 0x0D, reason: 'bare LF at $i');
        }
        if (bytes[i] == 0x0D) {
          expect(bytes[i + 1], 0x0A, reason: 'bare CR at $i');
        }
      }
      expect(roundTrip(message).textBody!.decodeText().text, 'a\nb\nc\nd');
    });

    test('text + HTML + inline image + attachments: full structure', () {
      final pdf = Uint8List.fromList(utf8.encode('%PDF-1.4 test'));
      final png = Uint8List.fromList(List.generate(300, (i) => i % 256));
      final m = roundTrip(
        OutgoingMessage(
          from: alice,
          to: [bob],
          subject: 'Files',
          textBody: 'See the logo.',
          htmlBody: '<p>See <img src="cid:logo@fmail.test"></p>',
          attachments: [
            OutgoingAttachment(
              filename: 'logo.png',
              mimeType: 'image/png',
              bytes: png,
              contentId: 'logo@fmail.test',
            ),
            OutgoingAttachment(
              filename: '“Quarterly report” € ${'long ' * 10}.pdf',
              mimeType: 'application/pdf',
              bytes: pdf,
            ),
          ],
        ),
      );
      final types = {
        for (final p in m.root.allParts) p.section: p.contentType.mimeType,
      };
      expect(types, {
        '': 'multipart/mixed',
        '1': 'multipart/related',
        '1.1': 'multipart/alternative',
        '1.1.1': 'text/plain',
        '1.1.2': 'text/html',
        '1.2': 'image/png',
        '2': 'application/pdf',
      });
      expect(
        m.root.children[0].contentType.parameters['type'],
        'multipart/alternative',
      );
      final logo = m.root.allParts.firstWhere(
        (p) => p.contentId == 'logo@fmail.test',
      );
      expect(logo.decodeBody().bytes, png);
      expect(logo.isAttachment, isFalse);
      final attachment = m.attachments.single;
      expect(attachment.filename, '“Quarterly report” € ${'long ' * 10}.pdf');
      expect(attachment.decodeBody().bytes, pdf);
      expect(m.allDefects, isEmpty);
    });

    test('inline images without HTML become regular attachments', () {
      final m = roundTrip(
        OutgoingMessage(
          from: alice,
          to: [bob],
          textBody: 'x',
          attachments: [
            OutgoingAttachment(
              filename: 'a.png',
              mimeType: 'image/png',
              bytes: Uint8List(3),
              contentId: 'a@x',
            ),
          ],
        ),
      );
      expect(m.root.contentType.mimeType, 'multipart/mixed');
    });

    test('boundaries never appear in the content', () {
      // Content containing many boundary-like strings.
      final tricky = List.generate(50, (i) => '--=_${'0' * 32}').join('\n');
      final m = roundTrip(
        OutgoingMessage(
          from: alice,
          to: [bob],
          textBody: tricky,
          htmlBody: '<pre>$tricky</pre>',
        ),
      );
      expect(m.textBody!.decodeText().text, tricky);
      expect(m.allDefects, isEmpty);
    });
  });

  test('random messages always round-trip', () {
    final random = Random(99);
    const alphabet = 'abc XYZ 012 éüß 中文 😀 \n\t=?_"<>@,;:\\';
    String randomText(int max) => String.fromCharCodes(
      List.generate(
        random.nextInt(max),
        (_) => alphabet.runes.elementAt(random.nextInt(alphabet.runes.length)),
      ),
    );
    for (var i = 0; i < 300; i++) {
      final subject = randomText(120).replaceAll(RegExp(r'[\n\t]'), ' ').trim();
      final name = randomText(30).replaceAll(RegExp(r'[\n\t]'), ' ').trim();
      final body = randomText(400);
      final message = OutgoingMessage(
        from: MailAddress(
          displayName: name.isEmpty ? null : name,
          localPart: 'a$i',
          domain: 'x.example',
        ),
        to: [bob],
        subject: subject,
        textBody: body,
      );
      final m = roundTrip(message);
      expect(m.subject, subject, reason: 'subject #$i');
      expect(
        m.from.single.displayName,
        name.isEmpty ? null : name,
        reason: 'name #$i',
      );
      expect(
        m.textBody!.decodeText().text,
        body.replaceAll('\r', '\n'),
        reason: 'body #$i',
      );
      expect(m.allDefects, isEmpty, reason: '#$i');
    }
  });
}
