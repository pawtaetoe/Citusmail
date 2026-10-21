// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Hostile and broken input: the parser must never throw, never hang and
// never use unbounded memory or stack.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:test/test.dart';

const parser = MimeParser();

/// Evaluates values only for their side effect: lazily parsed fields are
/// parsed when read, which is what the robustness tests need to trigger.
void readAll(List<Object?> values) {}

/// Parses and reads everything a mail client would read.
void exercise(Uint8List bytes) {
  final m = parser.parse(bytes);
  readAll([
    m.subject,
    m.from,
    m.to,
    m.cc,
    m.replyTo,
    m.date,
    m.messageId,
    m.inReplyTo,
    m.references,
    m.textBody,
    m.htmlBody,
    m.attachments,
  ]);
  for (final part in m.root.allParts) {
    part.decodeText();
    readAll([part.filename, part.contentId, part.isAttachment]);
    final embedded = part.embeddedMessage;
    if (embedded != null) readAll([embedded.subject, embedded.from]);
  }
}

Uint8List bytesOf(String s) => Uint8List.fromList(utf8.encode(s));

void expectFast(
  void Function() body, {
  Duration limit = const Duration(seconds: 5),
}) {
  final watch = Stopwatch()..start();
  body();
  expect(watch.elapsed, lessThan(limit));
}

void main() {
  group('mutation fuzzing of real fixtures', () {
    final fixtures = Directory('../../test-data/mail')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.eml'))
        .map((f) => f.readAsBytesSync())
        .toList();

    // Fragments that tend to confuse mail parsers.
    final tokens = [
      '\r\n',
      '\n',
      '\r\n\r\n',
      '--',
      '\r\n--never-closed',
      '\r\n--mixed-1--',
      '=?',
      '?=',
      '=?utf-8?B?',
      '=?iso-2022-jp?B?GyRC?=',
      '"',
      '\\',
      '<',
      '>',
      '(',
      ')',
      ';',
      ':',
      ',',
      '@',
      '=',
      '=\r\n',
      '%',
      "*0*=utf-8''%",
      'Content-Type: multipart/mixed; boundary=x\r\n',
      'Content-Transfer-Encoding: base64\r\n',
      '\x00',
      '\xff\xfe',
      '\x1b\$B',
      ' \t',
    ].map(latin1.encode).toList();

    Uint8List mutate(Uint8List input, Random random) {
      final out = input.toList();
      final steps = 1 + random.nextInt(8);
      for (var s = 0; s < steps && out.isNotEmpty; s++) {
        final at = random.nextInt(out.length);
        switch (random.nextInt(6)) {
          case 0: // flip a bit
            out[at] ^= 1 << random.nextInt(8);
          case 1: // delete a run
            out.removeRange(at, min(out.length, at + random.nextInt(32)));
          case 2: // insert a tricky token
            out.insertAll(at, tokens[random.nextInt(tokens.length)]);
          case 3: // truncate
            out.length = at;
          case 4: // duplicate a run
            final end = min(out.length, at + random.nextInt(200));
            out.insertAll(at, out.sublist(at, end));
          case 5: // random bytes
            out.insertAll(
              at,
              List.generate(random.nextInt(16), (_) => random.nextInt(256)),
            );
        }
      }
      return Uint8List.fromList(out);
    }

    test('2000 mutated messages parse without throwing', () {
      final random = Random(20261021);
      for (var i = 0; i < 2000; i++) {
        final input = mutate(fixtures[random.nextInt(fixtures.length)], random);
        try {
          exercise(input);
        } catch (e, stack) {
          fail('mutation $i threw $e\n$stack\ninput: ${base64.encode(input)}');
        }
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('edge inputs', () {
    test('empty input and fragments', () {
      for (final s in [
        '',
        '\r\n',
        '\r\n\r\n',
        'no headers at all',
        'Subject: x',
        ':',
        ' : ',
        '--',
      ]) {
        expect(() => exercise(bytesOf(s)), returnsNormally, reason: s);
      }
    });

    test('control characters in structured headers do not hang the parser (regression)', () {
      // Found by the fuzzer: a 0x1F byte in From made the tokenizer stop in
      // place and loop forever.
      expectFast(() {
        final m = parser.parse(
          bytesOf(
            'From: Alice <alice@\x1F\x00x.example>\r\n'
            'Content-Type: text/plain; name=\x01\x02\r\nTo: \x7F\x1F, bob@x.example\r\n\r\n',
          ),
        );
        expect(m.from, hasLength(1));
        expect(m.to.map((a) => a.address), contains('bob@x.example'));
        readAll([m.root.filename]);
      }, limit: const Duration(seconds: 1));
      for (final c in [0x00, 0x01, 0x08, 0x0B, 0x0C, 0x1B, 0x1F, 0x7F]) {
        final value =
            'a${String.fromCharCode(c)}b <c${String.fromCharCode(c)}@d.example>';
        expect(
          const AddressParser().parse(value).mailboxes,
          hasLength(1),
          reason: 'char $c',
        );
      }
    });

    test('a boundary that is a prefix of another is not confused', () {
      final m = parser.parse(
        bytesOf(
          'Content-Type: multipart/mixed; boundary=a\r\n\r\n'
          '--a\r\nContent-Type: multipart/mixed; boundary=ab\r\n\r\n'
          '--ab\r\n\r\ninner one\r\n--ab\r\n\r\ninner two\r\n--ab--\r\n'
          '--a\r\n\r\nouter two\r\n--a--\r\n',
        ),
      );
      expect(m.root.children, hasLength(2));
      expect(m.root.children[0].children.map((p) => p.decodeText().text), [
        'inner one',
        'inner two',
      ]);
      expect(m.root.children[1].decodeText().text, 'outer two');
      expect(m.allDefects, isEmpty);
    });

    test('multipart without a boundary is shown as text', () {
      final m = parser.parse(
        bytesOf('Content-Type: multipart/mixed\r\n\r\nhello'),
      );
      expect(m.root.contentType.mimeType, 'text/plain');
      expect(m.root.decodeText().text, 'hello');
      expect(m.structureDefects.single.kind, MimeDefectKind.missingBoundary);
    });

    test('embedded message/rfc822 gets its own tree and sections', () {
      final m = parser.parse(
        bytesOf(
          'Content-Type: multipart/mixed; boundary=b\r\n\r\n'
          '--b\r\n\r\nintro\r\n'
          '--b\r\nContent-Type: message/rfc822\r\n\r\n'
          'Subject: inner\r\nContent-Type: multipart/alternative; boundary=c\r\n\r\n'
          '--c\r\n\r\nplain\r\n--c\r\nContent-Type: text/html\r\n\r\n<p>html</p>\r\n--c--\r\n'
          '--b--\r\n',
        ),
      );
      final inner = m.root.children[1].embeddedMessage!;
      expect(inner.subject, 'inner');
      expect(inner.root.children.map((p) => p.section), ['2.1', '2.2']);
      expect(inner.textBody!.decodeText().text, 'plain');
    });
  });

  group('resource limits', () {
    test('10,000 nested multiparts stop at the depth limit', () {
      final b = StringBuffer();
      for (var i = 0; i < 10000; i++) {
        b.write('Content-Type: multipart/mixed; boundary=b$i\r\n\r\n--b$i\r\n');
      }
      b.write('\r\ndeepest\r\n');
      expectFast(() {
        final m = parser.parse(bytesOf(b.toString()));
        expect(
          m.root.allParts.length,
          lessThanOrEqualTo(const MimeParserLimits().maxDepth + 1),
        );
        expect(
          m.structureDefects.map((d) => d.kind),
          contains(MimeDefectKind.nestingTooDeep),
        );
      });
    });

    test('a chain of embedded messages stops at the depth limit', () {
      var message = 'Subject: bottom\r\n\r\nbody';
      for (var i = 0; i < 200; i++) {
        message = 'Content-Type: message/rfc822\r\n\r\n$message';
      }
      expectFast(() {
        final m = parser.parse(bytesOf(message));
        expect(
          m.structureDefects.map((d) => d.kind),
          contains(MimeDefectKind.nestingTooDeep),
        );
      });
    });

    test('100,000 parts stop at the part limit', () {
      final b = StringBuffer(
        'Content-Type: multipart/mixed; boundary=x\r\n\r\n',
      );
      for (var i = 0; i < 100000; i++) {
        b.write('--x\r\n\r\n$i\r\n');
      }
      b.write('--x--\r\n');
      expectFast(() {
        final m = parser.parse(bytesOf(b.toString()));
        expect(
          m.root.children.length,
          lessThan(const MimeParserLimits().maxParts),
        );
        expect(
          m.structureDefects.map((d) => d.kind),
          contains(MimeDefectKind.tooManyParts),
        );
      });
    });

    test('a 10 MB header line is cut off but the body is still found', () {
      final huge =
          'X-Huge: ${'a' * (10 * 1024 * 1024)}\r\nSubject: after\r\n\r\nbody';
      expectFast(() {
        final m = parser.parse(bytesOf(huge));
        expect(
          m.structureDefects.map((d) => d.kind),
          contains(MimeDefectKind.headerSectionTooLarge),
        );
        expect(m.root.decodeText().text, 'body');
      });
    });

    test('many tiny header fields stop at the field limit', () {
      final b = StringBuffer();
      for (var i = 0; i < 200000; i++) {
        b.write('X:\r\n');
      }
      b.write('\r\nbody');
      expectFast(() {
        final m = parser.parse(bytesOf(b.toString()));
        expect(
          m.headers.fields.length,
          lessThanOrEqualTo(const HeaderLimits().maxFields),
        );
        expect(m.root.decodeText().text, 'body');
      });
    });

    test('huge address and reference lists stay fast', () {
      // 5,000 of each stays under the 256 KB header limit (which has its own
      // test above); far more than any real message.
      final to = List.generate(5000, (i) => 'user$i@x.example').join(', ');
      final refs = List.generate(5000, (i) => '<id$i@x.example>').join(' ');
      expectFast(() {
        final m = parser.parse(bytesOf('To: $to\r\nReferences: $refs\r\n\r\n'));
        expect(m.to, hasLength(5000));
        expect(m.references, hasLength(const MessageIds().maxIds));
      });
    });
  });
}
