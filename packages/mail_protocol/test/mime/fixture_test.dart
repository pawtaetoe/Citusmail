// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Parses every sample in test-data/mail and checks what the app relies on.

import 'dart:convert';
import 'dart:io';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:test/test.dart';

final fixtureDir = Directory('../../test-data/mail');

MimeMessage load(String name) => const MimeParser().parse(
  File('${fixtureDir.path}/$name').readAsBytesSync(),
);

String text(MimePart? part) => part!.decodeText().text;

Iterable<MimeDefectKind> kinds(Iterable<MimeDefect> defects) =>
    defects.map((d) => d.kind);

void main() {
  test('fixture directory is present', () {
    expect(
      fixtureDir.existsSync(),
      isTrue,
      reason: 'run tests from packages/mail_protocol',
    );
  });

  group('people', () {
    test('plain-text', () {
      final m = load('people/plain-text.eml');
      expect(m.subject, 'Lunch on Friday?');
      expect(
        m.from.single,
        const MailAddress(
          displayName: 'Bob Example',
          localPart: 'bob',
          domain: 'citusmail.test',
        ),
      );
      expect(m.to.single.address, 'alice@citusmail.test');
      expect(m.date!.utc, DateTime.utc(2026, 10, 12, 1, 15));
      expect(m.messageId, 'lunch-1@citusmail.test');
      expect(m.root.section, '1');
      expect(text(m.textBody), startsWith('Hi Alice,\n\nAre you free'));
      expect(m.htmlBody, isNull);
      expect(m.attachments, isEmpty);
      expect(m.allDefects, isEmpty);
    });

    test('thread-reply', () {
      final m = load('people/thread-reply.eml');
      expect(m.inReplyTo, ['lunch-2@citusmail.test']);
      expect(m.references, [
        'lunch-1@citusmail.test',
        'lunch-2@citusmail.test',
      ]);
    });

    test('html-alternative: quoted-printable soft breaks', () {
      final m = load('people/html-alternative.eml');
      expect(m.root.contentType.mimeType, 'multipart/alternative');
      expect(m.root.children.map((p) => p.section), ['1', '2']);
      expect(text(m.textBody), contains('the view from the top was amazing'));
      expect(
        text(m.htmlBody),
        contains(
          '<a href="https://photos.friends.example/album/42">shared album</a>',
        ),
      );
      expect(m.allDefects, isEmpty);
    });

    test('attachment-inline-image: nested structure and IMAP sections', () {
      final m = load('people/attachment-inline-image.eml');
      final sections = {
        for (final p in m.root.allParts) p.section: p.contentType.mimeType,
      };
      expect(sections, {
        '': 'multipart/mixed',
        '1': 'multipart/alternative',
        '1.1': 'text/plain',
        '1.2': 'multipart/related',
        '1.2.1': 'text/html',
        '1.2.2': 'image/png',
        '2': 'application/pdf',
      });
      expect(m.attachments.single.filename, 'invoice-2026-10.pdf');
      expect(
        utf8.decode(m.attachments.single.decodeBody().bytes.sublist(0, 8)),
        '%PDF-1.4',
      );
      final logo = m.root.allParts.firstWhere(
        (p) => p.contentType.mimeType == 'image/png',
      );
      expect(logo.contentId, 'logo-1@citusmail.test');
      expect(
        logo.isAttachment,
        isFalse,
        reason: 'inline image, shown in the HTML',
      );
      expect(logo.decodeBody().bytes.sublist(1, 4), utf8.encode('PNG'));
      expect(m.allDefects, isEmpty);
    });

    test('latin1-quoted-printable', () {
      final m = load('people/latin1-quoted-printable.eml');
      expect(m.subject, 'Grüße aus München');
      expect(m.from.single.displayName, 'Jürgen Müller');
      final body = m.textBody!.decodeText();
      expect(
        body.text,
        contains('viele Grüße aus München! Das Wetter ist schön.'),
      );
      expect(
        body.charset,
        'windows-1252',
        reason: 'WHATWG reads ISO-8859-1 as windows-1252',
      );
    });

    test('japanese-iso-2022-jp', () {
      final m = load('people/japanese-iso-2022-jp.eml');
      expect(m.subject, '会議の件');
      expect(m.from.single.displayName, '山田太郎');
      expect(text(m.textBody), contains('明日の会議は10時からです。'));
    });

    test('windows-1252-8bit', () {
      expect(
        text(load('people/windows-1252-8bit.eml').textBody),
        '“Smart quotes” cost €5 – that’s the price.\n',
      );
    });

    test('rfc2231-filename', () {
      final attachment = load('people/rfc2231-filename.eml').attachments.single;
      expect(attachment.filename, '“Quarterly report” €.txt');
      expect(text(attachment), 'Revenue: up.\n');
    });

    test('read-receipt-requested', () {
      final m = load('people/read-receipt-requested.eml');
      expect(
        m.headers.value('disposition-notification-to'),
        'Bob Example <bob@citusmail.test>',
      );
    });

    test('folded-headers-groups', () {
      final m = load('people/folded-headers-groups.eml');
      expect(
        m.subject,
        'This is a deliberately long subject line that is folded across '
        'several header lines to test unfolding of long headers in the parser',
      );
      expect(m.from.single.displayName, 'Smith, Eve (Events)');
      expect(m.to.map((a) => a.address), [
        'alice@citusmail.test',
        'bob@citusmail.test',
      ]);
      expect(m.to[1].displayName, 'Bob "The Builder" Example');
      expect(m.cc.map((a) => a.address), [
        'dana@friends.example',
        'frank@friends.example',
        'grace@friends.example',
      ]);
      expect(m.cc.first.displayName, 'Dana');
      expect(m.headers.all('received'), hasLength(2));
      expect(m.root.contentType.charset, 'utf-8');
    });
  });

  group('receipts and newsletters', () {
    test('mdn-displayed: the report part is readable', () {
      final m = load('receipts/mdn-displayed.eml');
      expect(m.root.contentType.mimeType, 'multipart/report');
      expect(
        m.root.contentType.parameters['report-type'],
        'disposition-notification',
      );
      final report = m.root.children[1];
      expect(report.contentType.mimeType, 'message/disposition-notification');
      expect(
        text(report),
        contains('Original-Message-ID: <alice-report-1@citusmail.test>'),
      );
    });

    test('one-click-unsubscribe: list headers and the tracking pixel survive parsing', () {
      final m = load('newsletters/one-click-unsubscribe.eml');
      expect(
        m.headers.value('list-unsubscribe-post'),
        'List-Unsubscribe=One-Click',
      );
      expect(
        m.headers.value('list-unsubscribe'),
        contains('<https://shop.example/unsub/abc123?u=alice>'),
      );
      expect(
        text(m.htmlBody),
        contains('https://track.shop.example/open/abc123.gif'),
      );
      expect(
        text(m.htmlBody),
        contains('utm_source=newsletter&amp;utm_medium=email'),
      );
    });

    test('github notification', () {
      final m = load('notifications/github.eml');
      expect(m.from.single.address, 'notifications@github.com');
      expect(m.headers.value('list-id'), 'owner/repo <repo.owner.github.com>');
      expect(m.messageId, 'owner/repo/pull/12/c100@github.com');
    });
  });

  group('security', () {
    test(
      'phishing-link-mismatch: display name and real domain are separate',
      () {
        final from = load('security/phishing-link-mismatch.eml').from.single;
        expect(from.displayName, 'PayPal');
        expect(from.normalizedDomain, 'mailbox.example');
      },
    );

    test('punycode-lookalike keeps the raw domain', () {
      expect(
        load('security/punycode-lookalike.eml').from.single.domain,
        'xn--pple-43d.example',
      );
    });

    test('risky-attachments: every attachment is found', () {
      expect(
        load('security/risky-attachments.eml').attachments
            .map((a) => a.filename),
        ['invoice.html', 'invoice.pdf.exe', 'terms.docm'],
      );
    });

    test('hostile-html: parsed as-is (sanitising is the renderer\'s job)', () {
      expect(
        text(load('security/hostile-html.eml').htmlBody),
        contains('<script>'),
      );
    });
  });

  group('malformed', () {
    test('missing-date-unknown-charset', () {
      final m = load('malformed/missing-date-unknown-charset.eml');
      expect(m.date, isNull);
      final body = m.textBody!.decodeText();
      expect(body.text, startsWith('Body text in an unknown charset'));
      expect(body.source, CharsetSource.guessed);
      expect(kinds(body.defects), contains(MimeDefectKind.unknownCharset));
    });

    test('unterminated-multipart', () {
      final m = load('malformed/unterminated-multipart.eml');
      expect(m.root.children, hasLength(2));
      expect(
        text(m.root.children[1]),
        'Second part has no closing boundary.\n',
      );
      expect(kinds(m.structureDefects), [
        MimeDefectKind.missingClosingBoundary,
      ]);
    });

    test('raw-utf8-headers', () {
      final m = load('malformed/raw-utf8-headers.eml');
      expect(m.subject, 'Raw UTF-8 in headers ☕ (SMTPUTF8 style)');
      expect(m.from.single.displayName, 'Zoë Café');
      expect(m.from.single.domain, 'café.example');
      expect(text(m.textBody), 'Ça marche ? 👍\n');
    });

    test('deep-nesting: six levels with correct section numbers', () {
      final m = load('malformed/deep-nesting.eml');
      final parts = m.root.allParts.toList();
      expect(parts, hasLength(13));
      final deepest = parts.last;
      expect(deepest.section, '2.2.2.2.2.2');
      expect(text(deepest), 'Deepest part.\n');
      expect(m.allDefects, isEmpty);
    });

    test('bad-base64: decodes what it can and reports', () {
      final body = load('malformed/bad-base64.eml').textBody!.decodeText();
      expect(body.text, startsWith('Hello world'));
      expect(kinds(body.defects), contains(MimeDefectKind.invalidBase64));
    });

    test('encoded-word-edge-cases', () {
      final m = load('malformed/encoded-word-edge-cases.eml');
      expect(
        m.subject,
        'Adjacent words join | =?utf-8?Q?broken | unknown charset | été',
      );
      expect(m.from.single.displayName, 'Quoted éncoded');
      expect(
        kinds(m.fieldDefects),
        containsAll([
          MimeDefectKind.invalidEncodedWord,
          MimeDefectKind.unknownCharset,
        ]),
      );
    });
  });

  test('every fixture parses and every part decodes without throwing', () {
    final files = fixtureDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.eml'));
    expect(files, hasLength(37));
    for (final file in files) {
      final m = const MimeParser().parse(file.readAsBytesSync());
      expect(m.headers.fields, isNotEmpty, reason: file.path);
      // Read every lazily parsed field and decode every part.
      final values = [
        m.subject,
        m.from,
        m.to,
        m.cc,
        m.date,
        m.messageId,
        m.references,
        m.attachments,
      ];
      expect(values, hasLength(8));
      for (final part in m.root.allParts) {
        part.decodeText();
        expect(() => part.filename, returnsNormally);
      }
    }
  });
}
