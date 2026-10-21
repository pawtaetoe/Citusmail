// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:test/test.dart';

/// Serves response bytes from memory, like a socket.
final class MemorySource implements LineSource {
  MemorySource(String data) : _data = Uint8List.fromList(utf8.encode(data));
  MemorySource.bytes(this._data);

  final Uint8List _data;
  int _pos = 0;

  @override
  Future<Uint8List> readLine({Duration timeout = Duration.zero}) async {
    final end = _data.indexOf(0x0A, _pos);
    if (end < 0) throw const MailConnectionException('end of data');
    final contentEnd = end > _pos && _data[end - 1] == 0x0D ? end - 1 : end;
    final line = _data.sublist(_pos, contentEnd);
    _pos = end + 1;
    return line;
  }

  @override
  Future<Uint8List> readBytes(
    int length, {
    Duration timeout = Duration.zero,
  }) async {
    if (_pos + length > _data.length) {
      throw const MailConnectionException('end of data');
    }
    final bytes = _data.sublist(_pos, _pos + length);
    _pos += length;
    return bytes;
  }
}

Future<ImapResponse> parse(
  String data, {
  ImapResponseLimits limits = const ImapResponseLimits(),
}) => ImapResponseReader(MemorySource(data), limits: limits).next();

void main() {
  group('response reader', () {
    test('tagged response with a code', () async {
      final r = await parse(
        'F1 OK [READ-WRITE] SELECT completed\r\n',
      ) as ImapTaggedResponse;
      expect(r.tag, 'F1');
      expect(r.status, ImapStatus.ok);
      expect(r.code!.name, 'READ-WRITE');
      expect(r.text, 'SELECT completed');
    });

    test('untagged status with arguments in the code', () async {
      final r = await parse(
        '* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n',
      ) as ImapUntaggedStatus;
      expect(r.code!.name, 'PERMANENTFLAGS');
      expect((r.code!.arguments.first as ImapList).items.map((v) => v.asText), [
        r'\Deleted',
        r'\Seen',
        r'\*',
      ]);
    });

    test('message data with a number', () async {
      final r = await parse('* 23 EXISTS\r\n') as ImapUntaggedData;
      expect(r.number, 23);
      expect(r.keyword, 'EXISTS');
    });

    test('LIST with quoted delimiter and NIL', () async {
      final r = await parse(
        '* LIST (\\HasNoChildren \\Sent) "/" Sent\r\n',
      ) as ImapUntaggedData;
      final info = ImapMailboxInfo.fromResponse(r)!;
      expect(info.name, 'Sent');
      expect(info.delimiter, '/');
      expect(info.specialUse, SpecialUse.sent);
      final flat = ImapMailboxInfo.fromResponse(
        await parse('* LIST () NIL INBOX\r\n') as ImapUntaggedData,
      )!;
      expect(flat.delimiter, isNull);
      expect(flat.isInbox, isTrue);
    });

    test('literals in the middle of a response', () async {
      final r = await parse(
        '* 12 FETCH (UID 7 BODY[HEADER] {16}\r\nSubject: hello\r\n FLAGS (\\Seen))\r\n',
      ) as ImapUntaggedData;
      final m = FetchedMessage.fromResponse(r);
      expect(m.uid, 7);
      expect(utf8.decode(m.sections['HEADER']!), 'Subject: hello\r\n');
      expect(m.hasFlag(r'\seen'), isTrue);
    });

    test(
      'literal containing parentheses, quotes and CRLF is not parsed as syntax',
      () async {
        const body = 'a ) ( "x" \r\n* 1 BYE fake\r\nF9 OK fake\r\n';
        final r = await parse(
          '* 1 FETCH (BODY[] {${body.length}}\r\n$body UID 3)\r\n',
        ) as ImapUntaggedData;
        final m = FetchedMessage.fromResponse(r);
        expect(utf8.decode(m.sections['']!), body);
        expect(m.uid, 3);
      },
    );

    test('continuation requests', () async {
      expect(
        await parse('+ Ready for literal data\r\n'),
        isA<ImapContinuation>(),
      );
      expect(await parse('+\r\n'), isA<ImapContinuation>());
    });

    test('quoted strings with escapes', () async {
      final r =
          await parse('* LIST () "\\\\" "a \\"b\\" c"\r\n') as ImapUntaggedData;
      expect(r.values[1].asText, r'\');
      expect(r.values[2].asText, 'a "b" c');
    });

    test('section atoms with spaces inside brackets', () async {
      final r = await parse(
        '* 1 FETCH (BODY[HEADER.FIELDS (FROM TO)] {4}\r\nab\r\n)\r\n',
      ) as ImapUntaggedData;
      expect(FetchedMessage.fromResponse(r).sections.keys, [
        'HEADER.FIELDS (FROM TO)',
      ]);
    });

    group('limits and malformed input', () {
      test(
        'literal larger than the limit is refused before reading it',
        () async {
          expect(
            parse(
              '* 1 FETCH (BODY[] {999999999}\r\n',
              limits: const ImapResponseLimits(maxLiteralBytes: 1000),
            ),
            throwsA(isA<MailProtocolException>()),
          );
        },
      );

      test('deep nesting is refused', () async {
        expect(
          parse('* X ${'(' * 100}${')' * 100}\r\n'),
          throwsA(isA<MailProtocolException>()),
        );
      });

      test('unbalanced and unterminated input is refused', () async {
        expect(parse('* X (a b\r\n'), throwsA(isA<MailProtocolException>()));
        expect(parse('* X "open\r\n'), throwsA(isA<MailProtocolException>()));
        expect(parse('* X {abc}\r\n'), throwsA(isA<MailProtocolException>()));
        expect(
          parse('F1 MAYBE done\r\n'),
          throwsA(isA<MailProtocolException>()),
        );
      });

      test('random garbage only ever throws MailException', () async {
        final random = Random(5);
        for (var i = 0; i < 2000; i++) {
          final bytes = List<int>.generate(
            random.nextInt(80),
            (_) => const [
              0x2A,
              0x20,
              0x28,
              0x29,
              0x22,
              0x5C,
              0x7B,
              0x7D,
              0x5B,
              0x5D,
              0x31,
              0x41,
              0x2B,
              0x0D,
            ][random.nextInt(14)],
          );
          final data = Uint8List.fromList([
            ...bytes,
            0x0D,
            0x0A,
            ...bytes,
            0x0D,
            0x0A,
          ]);
          try {
            await ImapResponseReader(MemorySource.bytes(data)).next();
          } on MailException {
            // expected for garbage
          }
        }
      });
    });
  });

  group('typed results', () {
    test('ENVELOPE (RFC 3501 example) with encoded subject', () async {
      final r = await parse(
        '* 12 FETCH (ENVELOPE ("Wed, 17 Jul 1996 02:23:25 -0700 (PDT)" '
        '"=?utf-8?Q?caf=C3=A9?=" (("Terry Gray" NIL "gray" "cac.washington.edu")) '
        '(("Terry Gray" NIL "gray" "cac.washington.edu")) NIL '
        '((NIL NIL "imap" "cac.washington.edu")) '
        '((NIL NIL "minutes" "CNRI.Reston.VA.US") ("John Klensin" NIL "KLENSIN" "MIT.EDU")) '
        'NIL NIL "<B27397-0100000@cac.washington.edu>"))\r\n',
      ) as ImapUntaggedData;
      final e = FetchedMessage.fromResponse(r).envelope!;
      expect(e.subject, 'café');
      expect(e.date!.utc, DateTime.utc(1996, 7, 17, 9, 23, 25));
      expect(e.from.single.displayName, 'Terry Gray');
      expect(e.from.single.address, 'gray@cac.washington.edu');
      expect(e.cc.map((a) => a.address), [
        'minutes@CNRI.Reston.VA.US',
        'KLENSIN@MIT.EDU',
      ]);
      expect(e.messageId, 'B27397-0100000@cac.washington.edu');
      expect(e.replyTo, isEmpty);
    });

    test('ENVELOPE groups are flattened', () async {
      final r = await parse(
        '* 1 FETCH (ENVELOPE (NIL NIL NIL NIL NIL '
        '((NIL NIL "team" NIL) (NIL NIL "a" "x.example") (NIL NIL NIL NIL)) NIL NIL NIL NIL))\r\n',
      ) as ImapUntaggedData;
      expect(
        FetchedMessage.fromResponse(r).envelope!.to.map((a) => a.address),
        ['a@x.example'],
      );
    });

    test(
      'BODYSTRUCTURE: nested multipart with sections and attachment',
      () async {
        final r = await parse(
          '* 1 FETCH (BODYSTRUCTURE ('
          '(("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 20 1 NIL NIL NIL NIL)'
          '("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "QUOTED-PRINTABLE" 40 2 NIL NIL NIL NIL) "ALTERNATIVE" ("BOUNDARY" "a") NIL NIL NIL)'
          '("APPLICATION" "PDF" ("NAME" "r.pdf") NIL NIL "BASE64" 1000 NIL ("ATTACHMENT" ("FILENAME*" "utf-8\'\'%E2%82%AC.pdf")) NIL NIL)'
          ' "MIXED" ("BOUNDARY" "b") NIL NIL NIL))\r\n',
        ) as ImapUntaggedData;
        final body = FetchedMessage.fromResponse(r).bodyStructure!;
        expect(
          {for (final p in body.allParts) p.section: p.contentType.mimeType},
          {
            '': 'multipart/mixed',
            '1': 'multipart/alternative',
            '1.1': 'text/plain',
            '1.2': 'text/html',
            '2': 'application/pdf',
          },
        );
        final pdf = body.children[1];
        expect(pdf.isAttachment, isTrue);
        expect(pdf.filename, '€.pdf');
        expect(pdf.size, 1000);
        expect(body.children[0].children[0].lines, 1);
      },
    );

    test('BODYSTRUCTURE: single-part message is section 1; embedded message parts are N.1', () async {
      final single = await parse(
        '* 1 FETCH (BODYSTRUCTURE ("TEXT" "PLAIN" NIL NIL NIL "7BIT" 5 1))\r\n',
      ) as ImapUntaggedData;
      expect(FetchedMessage.fromResponse(single).bodyStructure!.section, '1');

      final embedded = await parse(
        '* 1 FETCH (BODYSTRUCTURE ('
        '("TEXT" "PLAIN" NIL NIL NIL "7BIT" 5 1)'
        '("MESSAGE" "RFC822" NIL NIL NIL "7BIT" 100 (NIL "inner" NIL NIL NIL NIL NIL NIL NIL NIL) '
        '("TEXT" "PLAIN" NIL NIL NIL "7BIT" 10 1) 5)'
        ' "MIXED"))\r\n',
      ) as ImapUntaggedData;
      final rfc822 = FetchedMessage.fromResponse(embedded)
          .bodyStructure!
          .children[1];
      expect(rfc822.section, '2');
      expect(rfc822.embeddedEnvelope!.subject, 'inner');
      expect(rfc822.embeddedBody!.section, '2.1');
      expect(rfc822.isAttachment, isFalse);
    });

    test('INTERNALDATE, MODSEQ and STATUS', () async {
      final r = await parse(
        '* 3 FETCH (UID 9 INTERNALDATE " 7-Jul-2026 02:44:25 -0700" MODSEQ (12345) RFC822.SIZE 44)\r\n',
      ) as ImapUntaggedData;
      final m = FetchedMessage.fromResponse(r);
      expect(m.internalDate, DateTime.utc(2026, 7, 7, 9, 44, 25));
      expect(m.modSeq, 12345);
      expect(m.size, 44);
      final s = await parse(
        '* STATUS INBOX (MESSAGES 22 UIDNEXT 23 UIDVALIDITY 99 UNSEEN 5 HIGHESTMODSEQ 1000)\r\n',
      ) as ImapUntaggedData;
      final status = MailboxStatus.fromValues(s.values[1].asList!);
      expect(
        [
          status.messages,
          status.uidNext,
          status.uidValidity,
          status.unseen,
          status.highestModSeq,
        ],
        [22, 23, 99, 5, 1000],
      );
    });

    test('APPENDUID and COPYUID codes', () {
      final append = UidMapping.fromCode(
        ImapResponseCode('APPENDUID', [
          const ImapAtom('38505'),
          const ImapAtom('3955'),
        ]),
      )!;
      expect(append.uidValidity, 38505);
      expect(append.destinationUids.toList(), [3955]);
      final copy = UidMapping.fromCode(
        ImapResponseCode('COPYUID', [
          const ImapAtom('38505'),
          const ImapAtom('304,319:320'),
          const ImapAtom('3956:3958'),
        ]),
      )!;
      expect(copy.sourceUids!.toList(), [304, 319, 320]);
      expect(copy.destinationUids.toList(), [3956, 3957, 3958]);
    });
  });

  group('MailboxNameCodec', () {
    test('RFC 3501 example and round trips', () {
      expect(
        MailboxNameCodec.encode('~peter/mail/台北/日本語'),
        '~peter/mail/&U,BTFw-/&ZeVnLIqe-',
      );
      expect(
        MailboxNameCodec.decode('~peter/mail/&U,BTFw-/&ZeVnLIqe-'),
        '~peter/mail/台北/日本語',
      );
      for (final name in [
        'A&B',
        'Ünïcode',
        'emoji 😀',
        '&',
        'plain',
        'Отправленные',
      ]) {
        expect(MailboxNameCodec.decode(MailboxNameCodec.encode(name)), name);
      }
    });

    test('invalid input is returned unchanged', () {
      expect(MailboxNameCodec.decode('a&b'), 'a&b');
      expect(MailboxNameCodec.decode('&***-'), '&***-');
    });
  });

  group('SequenceSet', () {
    test('merges, formats and parses', () {
      expect(SequenceSet.of([5, 1, 2, 3, 9, 10]).toString(), '1:3,5,9:10');
      expect(SequenceSet.range(4).toString(), '4:*');
      expect(SequenceSet.tryParse('3:1,7,5:6')!.toString(), '1:3,5:7');
      expect(SequenceSet.tryParse('1:*')!.hasStar, isTrue);
      for (final bad in ['', '0', 'a', '1::2', '1,,2', '-1']) {
        expect(SequenceSet.tryParse(bad), isNull, reason: bad);
      }
    });

    test('huge server ranges are never expanded by accident', () {
      final set = SequenceSet.tryParse('1:4294967295')!;
      expect(set.length, 4294967295);
      expect(set.contains(4000000000), isTrue);
      expect(() => set.toList(), throwsStateError);
    });
  });

  group('ImapCommand', () {
    String text(ImapCommand c) =>
        c.build().whereType<TextPart>().map((p) => p.text).join('|');

    test('quotes short ASCII strings and escapes them', () {
      expect(
        text(
          ImapCommand('LOGIN')
            ..string('me@x.example')
            ..string(r'p"a\ss'),
        ),
        r'LOGIN "me@x.example" "p\"a\\ss"',
      );
    });

    test(
      'CR/LF or non-ASCII in a string becomes a literal, never inline text',
      () {
        final command = ImapCommand('SEARCH')
          ..atom('SUBJECT')
          ..string('x\r\nF2 DELETE INBOX');
        final parts = command.build();
        expect(parts.whereType<LiteralPart>(), hasLength(1));
        expect(
          parts.whereType<TextPart>().any((p) => p.text.contains('\r')),
          isFalse,
        );
      },
    );

    test('atoms and flags are validated', () {
      expect(() => ImapCommand('NOOP').atom('A B'), throwsArgumentError);
      expect(() => ImapCommand('NOOP').atom('A\r\nB'), throwsArgumentError);
      expect(
        () => ImapCommand('STORE').flag(r'\Seen) (x'),
        throwsArgumentError,
      );
      expect(() => ImapCommand('STORE').flag(r'\'), throwsArgumentError);
      expect(() => ImapCommand('NOOP').raw('ok\r\nbad'), throwsArgumentError);
      expect(
        () => ImapCommand('NOOP').string('nul\u0000'),
        throwsArgumentError,
      );
    });

    test('lists and literals are spaced correctly', () {
      final command = ImapCommand('APPEND')
        ..string('Sent')
        ..openList()
        ..flag(r'\Seen')
        ..flag(r'\Draft')
        ..closeList()
        ..literal(utf8.encode('body'));
      final parts = command.build();
      expect((parts[0] as TextPart).text, r'APPEND "Sent" (\Seen \Draft) ');
      expect(parts[1], isA<LiteralPart>());
    });

    test('mailbox names are encoded', () {
      expect(
        text(ImapCommand('SELECT')..mailbox('日本語')),
        'SELECT "&ZeVnLIqe-"',
      );
    });

    test('redacted commands hide secrets in descriptions', () {
      final command = ImapCommand('LOGIN')
        ..string('u')
        ..string('secret')
        ..redacted = 'LOGIN [redacted]';
      expect(command.describe(), isNot(contains('secret')));
    });
  });

  test('FetchItems builds safe syntax and rejects bad sections', () {
    expect(
      FetchItems(flags: true, sections: ['1.2', '2.HEADER']).toSyntax(),
      '(UID FLAGS BODY.PEEK[1.2] BODY.PEEK[2.HEADER])',
    );
    expect(() => FetchItems(sections: ['1] BODY[']), throwsArgumentError);
  });
}
