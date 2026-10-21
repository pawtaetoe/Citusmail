// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:test/test.dart';

Uint8List ascii(String s) => Uint8List.fromList(latin1.encode(s));

void main() {
  group('Base64Decoder', () {
    const decoder = Base64Decoder();

    test('decodes with line breaks', () {
      final r = decoder.decode(ascii('SGVsbG8s\r\nIHdvcmxk'));
      expect(utf8.decode(r.bytes), 'Hello, world');
      expect(r.defects, isEmpty);
    });

    test('skips invalid characters and reports them', () {
      final r = decoder.decode(ascii('SGVs*bG8='));
      expect(utf8.decode(r.bytes), 'Hello');
      expect(r.defects.single.kind, MimeDefectKind.invalidBase64);
    });

    test('reports a truncated final group', () {
      final r = decoder.decode(ascii('SGVsbG8gV'));
      expect(utf8.decode(r.bytes), 'Hello ');
      expect(r.defects.map((d) => d.detail), contains('truncated'));
    });

    test('keeps decoding after padding (concatenated blocks)', () {
      final r = decoder.decode(ascii('SGk=SGk='));
      expect(utf8.decode(r.bytes), 'HiHi');
    });
  });

  group('QuotedPrintableDecoder', () {
    const decoder = QuotedPrintableDecoder();

    String decode(String s) => latin1.decode(decoder.decode(ascii(s)).bytes);

    test('decodes escapes in either case and soft line breaks', () {
      expect(decode('caf=C3=a9 =\r\nau lait'), 'cafÃ© au lait');
    });

    test('soft break with transport padding after "="', () {
      expect(decode('abc=  \r\ndef'), 'abcdef');
    });

    test('removes trailing whitespace but keeps hard line breaks', () {
      expect(
        decode('line one   \r\nline two\t\nend'),
        'line one\r\nline two\nend',
      );
    });

    test('keeps a stray "=" and reports it', () {
      final r = decoder.decode(ascii('100=ZZ % =4'));
      expect(latin1.decode(r.bytes), '100=ZZ % =4');
      expect(r.defects.single.kind, MimeDefectKind.invalidQuotedPrintable);
    });

    test('encoded trailing space is kept', () {
      expect(decode('a=20\r\nb'), 'a \r\nb');
    });
  });

  group('HeaderParser', () {
    const parser = HeaderParser();

    test('reads fields, unfolds continuations and finds the body', () {
      final r = parser.parse(
        ascii('Subject: one\r\n two\r\nX-A: 1\r\n\r\nBody'),
      );
      expect(r.headers.value('subject'), 'one two');
      expect(r.headers.value('x-a'), '1');
      expect(
        ascii('Subject: one\r\n two\r\nX-A: 1\r\n\r\nBody')
            .sublist(r.bodyStart),
        ascii('Body'),
      );
      expect(r.defects, isEmpty);
    });

    test('accepts bare LF line endings', () {
      final r = parser.parse(ascii('A: 1\nB: 2\n\nbody'));
      expect(r.headers.fields.map((f) => f.name), ['A', 'B']);
    });

    test(
      'keeps repeated fields in order and matches names case-insensitively',
      () {
        final r = parser.parse(ascii('Received: a\r\nRECEIVED: b\r\n\r\n'));
        expect(r.headers.all('received').map((f) => f.value), ['a', 'b']);
      },
    );

    test('a non-header line ends the header section (missing blank line)', () {
      final bytes = ascii('Subject: x\r\nthis is body text\r\n');
      final r = parser.parse(bytes);
      expect(r.headers.fields, hasLength(1));
      expect(
        latin1.decode(bytes.sublist(r.bodyStart)),
        'this is body text\r\n',
      );
      expect(r.defects.single.kind, MimeDefectKind.missingHeaderBodySeparator);
    });

    test('skips an mbox "From " line at the start', () {
      final r = parser.parse(
        ascii('From bob@x Mon Oct 12 2026\r\nSubject: hi\r\n\r\n'),
      );
      expect(r.headers.value('subject'), 'hi');
    });

    test('accepts whitespace before the colon (obsolete syntax)', () {
      expect(
        parser.parse(ascii('Subject : old\r\n\r\n')).headers.value('subject'),
        'old',
      );
    });

    test('raw UTF-8 values decode as UTF-8, other 8-bit as Windows-1252', () {
      final utf = Uint8List.fromList([
        ...ascii('S: '),
        ...utf8.encode('Café'),
        ...ascii('\r\n\r\n'),
      ]);
      expect(parser.parse(utf).headers.value('s'), 'Café');
      final win = Uint8List.fromList([
        ...ascii('S: '),
        0x93,
        0x41,
        0x94,
        ...ascii('\r\n\r\n'),
      ]);
      expect(parser.parse(win).headers.value('s'), '“A”');
    });

    test('stops collecting past the field limit but still finds the body', () {
      final text =
          '${List.generate(20, (i) => 'X-$i: v').join('\r\n')}\r\n\r\nbody';
      final r = const HeaderParser(limits: HeaderLimits(maxFields: 5))
          .parse(ascii(text));
      expect(r.headers.fields, hasLength(5));
      expect(latin1.decode(ascii(text).sublist(r.bodyStart)), 'body');
      expect(r.defects.single.kind, MimeDefectKind.tooManyHeaderFields);
    });
  });

  group('EncodedWordDecoder', () {
    const decoder = EncodedWordDecoder();
    String d(String s) => decoder.decode(s).text;

    test('B and Q encodings', () {
      expect(d('=?UTF-8?B?w6l0w6k=?='), 'été');
      expect(
        d('=?iso-8859-1?q?Gr=FC=DFe_aus_M=FCnchen?='),
        'Grüße aus München',
      );
    });

    test('whitespace between adjacent encoded words is removed', () {
      expect(
        d('=?utf-8?Q?Adjacent?= =?utf-8?Q?_words_join?='),
        'Adjacent words join',
      );
      expect(d('=?utf-8?Q?a?=\r\n =?utf-8?Q?b?='), 'ab');
    });

    test('whitespace between an encoded word and text is kept', () {
      expect(d('Re: =?utf-8?Q?caf=C3=A9?= time'), 'Re: café time');
    });

    test('a UTF-8 character split across two words still decodes', () {
      // "é" is C3 A9; split between the two words.
      expect(d('=?utf-8?Q?caf=C3?= =?utf-8?Q?=A9?='), 'café');
    });

    test('ISO-2022-JP encoded words', () {
      expect(d('=?ISO-2022-JP?B?GyRCMnE1RCRON28bKEI=?='), '会議の件');
    });

    test('RFC 2231 language suffix in the charset', () {
      expect(d('=?utf-8*en?Q?hello?='), 'hello');
    });

    test('unknown charset falls back and reports', () {
      final r = decoder.decode('=?x-unknown?Q?plain_text?=');
      expect(r.text, 'plain text');
      expect(r.defects.single.kind, MimeDefectKind.unknownCharset);
    });

    test('a broken encoded word is left as text and reported', () {
      final r = decoder.decode('=?utf-8?Q?broken and more');
      expect(r.text, '=?utf-8?Q?broken and more');
      expect(r.defects.single.kind, MimeDefectKind.invalidEncodedWord);
    });

    test(
      'CR and LF hidden in an encoded word become spaces (no header injection)',
      () {
        expect(d('=?utf-8?Q?a=0D=0ABcc:_evil@x?='), 'a  Bcc: evil@x');
      },
    );

    test('many "=?" are handled in linear time', () {
      final hostile = '=?' * 100000;
      final watch = Stopwatch()..start();
      decoder.decode(hostile);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });

  group('AddressParser', () {
    const parser = AddressParser();
    List<MailAddress> p(String s) => parser.parse(s).mailboxes;

    test('name-addr and addr-spec', () {
      final r = p('Alice Example <alice@example.com>, bob@example.com');
      expect(r[0].displayName, 'Alice Example');
      expect(r[0].address, 'alice@example.com');
      expect(r[1].displayName, isNull);
      expect(r[1].address, 'bob@example.com');
    });

    test('quoted display names with commas and escaped quotes', () {
      final r = p(
        r'"Smith, Eve (Events)" <eve@x.example>, "Bob \"B\" E" <bob@x.example>',
      );
      expect(r[0].displayName, 'Smith, Eve (Events)');
      expect(r[1].displayName, 'Bob "B" E');
    });

    test('groups, including empty ones', () {
      final result = parser.parse(
        'Team: a@x.example, b@x.example;, undisclosed-recipients:;',
      );
      expect(result.entries, hasLength(2));
      final team = result.entries[0] as AddressGroup;
      expect(team.name, 'Team');
      expect(team.members.map((m) => m.address), [
        'a@x.example',
        'b@x.example',
      ]);
      expect((result.entries[1] as AddressGroup).members, isEmpty);
    });

    test('old-style comment name', () {
      expect(p('dana@friends.example (Dana)').single.displayName, 'Dana');
    });

    test('encoded words in display names, even inside quotes', () {
      expect(
        p('=?iso-8859-1?q?J=FCrgen?= <j@x.example>').single.displayName,
        'Jürgen',
      );
      expect(
        p('"=?utf-8?Q?Quoted_=C3=A9ncoded?=" <q@x.example>').single.displayName,
        'Quoted éncoded',
      );
    });

    test(
      'a display name that looks like an address stays the display name',
      () {
        final r = p('paypal@paypal.com <attacker@evil.example>').single;
        expect(r.displayName, 'paypal@paypal.com');
        expect(r.address, 'attacker@evil.example');
      },
    );

    test('missing closing ">" is tolerated and reported', () {
      final result = parser.parse('Bob <bob@x.example');
      expect(result.mailboxes.single.address, 'bob@x.example');
      expect(result.defects.single.kind, MimeDefectKind.invalidAddress);
    });

    test('obsolete source routes are removed', () {
      expect(
        p('<@relay.example:user@host.example>').single.address,
        'user@host.example',
      );
    });

    test('quoted local parts are kept and re-quoted', () {
      final r = p('"john doe"@example.com').single;
      expect(r.localPart, 'john doe');
      expect(r.address, '"john doe"@example.com');
    });

    test('raw UTF-8 (SMTPUTF8) addresses', () {
      final r = p('Zoë Café <zoe@café.example>').single;
      expect(r.displayName, 'Zoë Café');
      expect(r.domain, 'café.example');
    });

    test('entries without "@" are skipped and reported, without looping', () {
      final result = parser.parse('alice, ; ; ,, bob@x.example');
      expect(result.mailboxes.single.address, 'bob@x.example');
      expect(result.defects, isNotEmpty);
    });

    test('normalised address lowercases only the domain', () {
      expect(p('Bob@EXAMPLE.Com').single.normalizedAddress, 'Bob@example.com');
    });

    test('many "@" characters are handled in linear time', () {
      final hostile = '${'@' * 50000} <a@b.example>';
      final watch = Stopwatch()..start();
      parser.parse(hostile);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });

  group('MimeFieldParser', () {
    const parser = MimeFieldParser();

    test('content type with parameters', () {
      final ct = parser
          .parseContentType('Multipart/Mixed; boundary="a;b"; charset=UTF-8')
          .value!;
      expect(ct.mimeType, 'multipart/mixed');
      expect(ct.boundary, 'a;b');
      expect(ct.charset, 'UTF-8');
    });

    test('invalid content types give null and a defect', () {
      for (final value in ['text', '/plain', 'text/', 'te xt/plain']) {
        final r = parser.parseContentType(value);
        expect(r.value, isNull, reason: value);
        expect(r.defects.single.kind, MimeDefectKind.invalidContentType);
      }
    });

    test('RFC 2231 continuations with percent encoding', () {
      final cd = parser
          .parseContentDisposition(
            "attachment; filename*0*=UTF-8''%E2%80%9CQuarterly%20; filename*1*=report%E2%80%9D%20%E2%82%AC.txt",
          )
          .value!;
      expect(cd.filename, '“Quarterly report” €.txt');
    });

    test(
      'RFC 2231 value wins over the plain one; quoted encoded value accepted',
      () {
        final cd = parser
            .parseContentDisposition(
              'attachment; filename="fallback.txt"; filename*="utf-8\'\'%E2%82%AC.txt"',
            )
            .value!;
        expect(cd.filename, '€.txt');
      },
    );

    test('plain continuation sections join', () {
      final ct = parser
          .parseContentType('text/plain; name*0="long "; name*1="name.txt"')
          .value!;
      expect(ct.parameters['name'], 'long name.txt');
    });

    test('the first of duplicate parameters wins', () {
      final r = parser.parseContentType(
        'multipart/mixed; boundary=one; boundary=two',
      );
      expect(r.value!.boundary, 'one');
      expect(r.defects.single.kind, MimeDefectKind.invalidParameter);
    });

    test('unquoted values with spaces (lenient)', () {
      final cd = parser
          .parseContentDisposition('attachment; filename=my report.pdf')
          .value!;
      expect(cd.filename, 'my report.pdf');
    });

    test('encoded-word filenames are decoded by decodeFilename', () {
      expect(
        MimeFieldParser.decodeFilename('=?UTF-8?B?w6l0w6kucGRm?='),
        'été.pdf',
      );
    });
  });

  group('MailDateParser', () {
    const parser = MailDateParser();
    DateTime? utc(String s) => parser.parse(s)?.utc;

    test('RFC 5322 dates with offsets', () {
      expect(
        utc('Mon, 12 Oct 2026 09:15:00 +0800'),
        DateTime.utc(2026, 10, 12, 1, 15),
      );
      expect(
        parser.parse('Mon, 12 Oct 2026 09:15:00 +0800')!.offset,
        const Duration(hours: 8),
      );
      expect(
        utc('12 Oct 2026 09:15 -0500'),
        DateTime.utc(2026, 10, 12, 14, 15),
      );
    });

    test('obsolete forms: named zones, 2-digit years, comments', () {
      expect(
        utc('Tue, 13 Oct 26 10:00:00 EST'),
        DateTime.utc(2026, 10, 13, 15),
      );
      expect(
        utc('Sun, 18 Oct 2026 12:00:00 +0000 (UTC)'),
        DateTime.utc(2026, 10, 18, 12),
      );
      expect(utc('1 Jan 99 00:00:00 GMT'), DateTime.utc(1999));
    });

    test('missing zone assumes UTC and says so', () {
      final d = parser.parse('Mon, 12 Oct 2026 09:15:00')!;
      expect(d.utc, DateTime.utc(2026, 10, 12, 9, 15));
      expect(d.zoneKnown, isFalse);
    });

    test('ISO 8601 fallback', () {
      expect(utc('2026-10-12T09:15:00Z'), DateTime.utc(2026, 10, 12, 9, 15));
    });

    test('invalid dates give null', () {
      for (final s in [
        '',
        'yesterday',
        '31 Feb 2026 10:00:00 +0000',
        '12 Oct 2026 25:00:00 +0000',
      ]) {
        expect(parser.parse(s), isNull, reason: s);
      }
    });

    test('format writes UTC by default (no location hint)', () {
      expect(
        MailDate.format(DateTime.utc(2026, 10, 21, 12, 51)),
        'Wed, 21 Oct 2026 12:51:00 +0000',
      );
      expect(
        MailDate.format(
          DateTime.utc(2026, 10, 21, 12, 51),
          offset: const Duration(hours: 8),
        ),
        'Wed, 21 Oct 2026 20:51:00 +0800',
      );
    });
  });

  group('MessageIds', () {
    const ids = MessageIds();

    test('lists without brackets, in order, without duplicates', () {
      expect(ids.parseList('<a@x> <b@x>\r\n <a@x>'), ['a@x', 'b@x']);
    });

    test('IDs without brackets (lenient)', () {
      expect(ids.parseList('a@x b@x'), ['a@x', 'b@x']);
    });

    test('generated IDs are random and use the given domain', () {
      final a = MessageIds.generate('example.com');
      final b = MessageIds.generate('example.com');
      expect(a, matches(RegExp(r'^[0-9a-f]{32}@example\.com$')));
      expect(a, isNot(b));
    });
  });
}
