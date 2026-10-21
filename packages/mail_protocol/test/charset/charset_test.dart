// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:test/test.dart';

const fffd = '�';

String decode(String label, List<int> bytes) =>
    Charsets.forLabel(label)!.decode(bytes);

void main() {
  group('valid text decodes like the reference encoders', () {
    // Byte sequences produced by Python's codecs, where Python and the
    // WHATWG agree.
    final cases = <(String, String, List<int>)>[
      (
        'big5',
        '中文電子郵件',
        [
          0xA4,
          0xA4,
          0xA4,
          0xE5,
          0xB9,
          0x71,
          0xA4,
          0x6C,
          0xB6,
          0x6C,
          0xA5,
          0xF3,
        ],
      ),
      (
        'gbk',
        '简体中文邮件',
        [
          0xBC,
          0xF2,
          0xCC,
          0xE5,
          0xD6,
          0xD0,
          0xCE,
          0xC4,
          0xD3,
          0xCA,
          0xBC,
          0xFE,
        ],
      ),
      ('gb18030', '€𠀀中', [0xA2, 0xE3, 0x95, 0x32, 0x82, 0x36, 0xD6, 0xD0]),
      (
        'euc-kr',
        '한국어 메일',
        [0xC7, 0xD1, 0xB1, 0xB9, 0xBE, 0xEE, 0x20, 0xB8, 0xDE, 0xC0, 0xCF],
      ),
      (
        'shift_jis',
        '日本語のメール ｶﾀｶﾅ',
        [
          0x93,
          0xFA,
          0x96,
          0x7B,
          0x8C,
          0xEA,
          0x82,
          0xCC,
          0x83,
          0x81,
          0x81,
          0x5B,
          0x83,
          0x8B,
          0x20,
          0xB6,
          0xC0,
          0xB6,
          0xC5,
        ],
      ),
      (
        'euc-jp',
        '日本語のメール',
        [
          0xC6,
          0xFC,
          0xCB,
          0xDC,
          0xB8,
          0xEC,
          0xA4,
          0xCE,
          0xA5,
          0xE1,
          0xA1,
          0xBC,
          0xA5,
          0xEB,
        ],
      ),
      (
        'iso-2022-jp',
        '会議の件 abc',
        [
          0x1B,
          0x24,
          0x42,
          0x32,
          0x71,
          0x35,
          0x44,
          0x24,
          0x4E,
          0x37,
          0x6F,
          0x1B,
          0x28,
          0x42,
          0x20,
          0x61,
          0x62,
          0x63,
        ],
      ),
      ('koi8-r', 'Привет', [0xF0, 0xD2, 0xC9, 0xD7, 0xC5, 0xD4]),
      ('windows-1251', 'Привет', [0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2]),
      (
        'iso-8859-7',
        'Καλημέρα',
        [0xCA, 0xE1, 0xEB, 0xE7, 0xEC, 0xDD, 0xF1, 0xE1],
      ),
      (
        'iso-8859-2',
        'Zażółć gęślą jaźń',
        [
          0x5A,
          0x61,
          0xBF,
          0xF3,
          0xB3,
          0xE6,
          0x20,
          0x67,
          0xEA,
          0xB6,
          0x6C,
          0xB1,
          0x20,
          0x6A,
          0x61,
          0xBC,
          0xF1,
        ],
      ),
      (
        'windows-1252',
        '“€5” – ok',
        [0x93, 0x80, 0x35, 0x94, 0x20, 0x96, 0x20, 0x6F, 0x6B],
      ),
      ('utf-16le', 'a😀b', [0x61, 0x00, 0x3D, 0xD8, 0x00, 0xDE, 0x62, 0x00]),
      ('utf-16be', 'a😀b', [0x00, 0x61, 0xD8, 0x3D, 0xDE, 0x00, 0x00, 0x62]),
      (
        'utf-8',
        'héllo 😀',
        [0x68, 0xC3, 0xA9, 0x6C, 0x6C, 0x6F, 0x20, 0xF0, 0x9F, 0x98, 0x80],
      ),
    ];
    for (final (label, text, bytes) in cases) {
      test(label, () => expect(decode(label, bytes), text));
    }

    test('decodes a sub-range only', () {
      expect(Charsets.utf8.decode([0x41, 0x42, 0x43, 0x44], 1, 3), 'BC');
      expect(
        Charsets.forLabel('big5')!.decode([0x41, 0xA4, 0xA4, 0x42], 1, 3),
        '中',
      );
    });
  });

  group('invalid input follows the WHATWG error rules', () {
    test('Big5 pointers that decode to two code points', () {
      expect(decode('big5', [0x88, 0x62]), 'Ê̄');
      expect(decode('big5', [0x88, 0x64]), 'Ê̌');
    });

    test('a bad trail byte that is ASCII is kept', () {
      expect(decode('shift_jis', [0x81, 0x20, 0x41]), '$fffd A');
      expect(decode('big5', [0xA4, 0x0A]), '$fffd\n');
      expect(decode('euc-kr', [0xB0, 0x20]), '$fffd ');
      expect(decode('gbk', [0xB0, 0x20]), '$fffd ');
    });

    test('a truncated character at the end is one replacement', () {
      // A lead byte for each charset (0xB0 is a whole character in Shift_JIS).
      const leads = {
        'big5': 0xB0,
        'gbk': 0xB0,
        'gb18030': 0xB0,
        'euc-kr': 0xB0,
        'shift_jis': 0x81,
        'euc-jp': 0xB0,
      };
      for (final MapEntry(key: label, value: lead) in leads.entries) {
        expect(decode(label, [0x41, lead]), 'A$fffd', reason: label);
      }
      expect(decode('gb18030', [0x81, 0x30]), fffd);
      expect(decode('gb18030', [0x81, 0x30, 0x81]), fffd);
      expect(decode('utf-16le', [0x41, 0x00, 0x42]), 'A$fffd');
      expect(decode('utf-16le', [0x3D, 0xD8]), fffd);
    });

    test('gb18030 four-byte sequence with a bad last byte is reprocessed', () {
      // 0x81 0x30 0x81 then 'A': error; then "0" is read again, and
      // 0x81 0x41 is read again as the GBK character U+4E04.
      expect(decode('gb18030', [0x81, 0x30, 0x81, 0x41]), '${fffd}0丄');
    });

    test('gb18030 single byte 0x80 is the euro sign', () {
      expect(decode('gb18030', [0x80]), '€');
    });

    test('unpaired UTF-16 surrogates become replacements', () {
      expect(decode('utf-16le', [0x00, 0xDC, 0x41, 0x00]), '${fffd}A');
      expect(decode('utf-16le', [0x3D, 0xD8, 0x41, 0x00]), '${fffd}A');
    });

    test('ISO-2022-JP: two escapes in a row are an error', () {
      expect(
        decode('iso-2022-jp', [0x1B, 0x28, 0x42, 0x1B, 0x28, 0x42, 0x61]),
        '${fffd}a',
      );
    });

    test('ISO-2022-JP: half-width katakana and Roman modes', () {
      expect(decode('iso-2022-jp', [0x1B, 0x28, 0x49, 0x36, 0x40]), 'ｶﾀ');
      expect(decode('iso-2022-jp', [0x1B, 0x28, 0x4A, 0x5C, 0x7E]), '¥‾');
    });

    test('ISO-2022-JP: unknown escape sequences are errors, text survives', () {
      expect(decode('iso-2022-jp', [0x1B, 0x41, 0x42]), '${fffd}AB');
      expect(decode('iso-2022-jp', [0x1B, 0x24, 0x41, 0x42]), '$fffd\$AB');
      expect(decode('iso-2022-jp', [0x41, 0x1B]), 'A$fffd');
      expect(decode('iso-2022-jp', [0x41, 0x1B, 0x24]), 'A$fffd\$');
    });

    test('invalid UTF-8 becomes replacements', () {
      expect(decode('utf-8', [0x61, 0xFF, 0x62]), 'a${fffd}b');
    });

    test('the replacement encoding hides unsafe input entirely', () {
      expect(decode('iso-2022-kr', [0x41, 0x42]), fffd);
      expect(decode('iso-2022-kr', []), '');
    });
  });

  group('labels', () {
    test('match WHATWG labels case-insensitively, ignoring whitespace', () {
      expect(Charsets.forLabel(' UTF8 ')!.name, 'utf-8');
      expect(Charsets.forLabel('x-sjis')!.name, 'shift_jis');
      expect(Charsets.forLabel('ks_c_5601-1987')!.name, 'euc-kr');
      expect(Charsets.forLabel('GB2312')!.name, 'gbk');
      expect(Charsets.forLabel('big5-hkscs')!.name, 'big5');
      expect(Charsets.forLabel('cp1252')!.name, 'windows-1252');
    });

    test('Latin-1 and ASCII labels decode as Windows-1252', () {
      expect(Charsets.forLabel('iso-8859-1')!.name, 'windows-1252');
      expect(Charsets.forLabel('us-ascii')!.name, 'windows-1252');
    });

    test('unknown labels return null', () {
      expect(Charsets.forLabel('x-unknown-charset'), isNull);
      expect(Charsets.forLabel(''), isNull);
      expect(Charsets.forLabel('utf-7'), isNull);
    });

    test('every WHATWG encoding name can be created', () {
      for (final label in [
        'ibm866',
        'iso-8859-8-i',
        'macintosh',
        'x-mac-cyrillic',
        'windows-874',
        'koi8-u',
        'x-user-defined',
        'utf-16be',
      ]) {
        expect(Charsets.forLabel(label), isNotNull, reason: label);
      }
    });
  });

  group('TextDecoder', () {
    const decoder = TextDecoder();

    test('uses the declared charset', () {
      final result = decoder.decode([0xCF, 0xF0], charsetLabel: 'windows-1251');
      expect(result.text, 'Пр');
      expect(result.source, CharsetSource.declared);
    });

    test('a byte order mark overrides the declared charset', () {
      final result = decoder.decode([
        0xEF,
        0xBB,
        0xBF,
        0xC3,
        0xA9,
      ], charsetLabel: 'big5');
      expect(result.text, 'é');
      expect(result.source, CharsetSource.byteOrderMark);
    });

    test('unknown labels guess UTF-8 when the bytes are valid UTF-8', () {
      final result = decoder.decode([0xC3, 0xA9], charsetLabel: 'x-unknown');
      expect(result.text, 'é');
      expect(result.charset.name, 'utf-8');
      expect(result.source, CharsetSource.guessed);
    });

    test('otherwise guess Windows-1252', () {
      final result = decoder.decode([0x93, 0x41, 0x94]);
      expect(result.text, '“A”');
      expect(result.charset.name, 'windows-1252');
    });
  });

  group('robustness', () {
    test('random bytes never throw and always terminate, in every charset', () {
      final random = Random(42);
      final labels = [
        'utf-8',
        'utf-16le',
        'utf-16be',
        'big5',
        'gbk',
        'gb18030',
        'euc-kr',
        'shift_jis',
        'euc-jp',
        'iso-2022-jp',
        'windows-1252',
        'koi8-r',
      ];
      for (var round = 0; round < 300; round++) {
        final bytes = List<int>.generate(
          random.nextInt(64),
          (_) => random.nextInt(256),
        );
        for (final label in labels) {
          expect(
            () => decode(label, bytes),
            returnsNormally,
            reason: '$label $bytes',
          );
        }
      }
    });

    test('decoding is roughly linear (no pathological slowdown)', () {
      final big = List<int>.filled(1 << 20, 0x81); // 1 MiB of lead bytes
      final watch = Stopwatch()..start();
      for (final label in [
        'big5',
        'gb18030',
        'shift_jis',
        'euc-jp',
        'iso-2022-jp',
      ]) {
        decode(label, big);
      }
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });
}
