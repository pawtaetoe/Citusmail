// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/core/state/validation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

/// The value of [v], failing the test when it is invalid.
T valid<T>(Validated<T> v) => switch (v) {
  Valid(:final value) => value,
  Invalid(:final reason) => fail('expected valid, got "$reason"'),
};

/// The reason of [v], failing the test when it is valid.
String invalid(Validated<Object?> v) => switch (v) {
  Valid(:final value) => fail('expected invalid, got $value'),
  Invalid(:final reason) => reason,
};

final huge = 'x' * 2000000;

void main() {
  group('Validated', () {
    test('map and then pass a value on and keep a reason', () {
      const Validated<int> five = Valid(5);
      expect(five.map((v) => v * 2), const Valid(10));
      expect(five.then((v) => Invalid('no $v')), const Invalid('no 5'));
      const Validated<int> none = Invalid('why');
      expect(none.map((v) => v * 2), const Invalid('why'));
      expect(none.valueOrNull, isNull);
      expect(none.reason, 'why');
      expect(five.isValid, isTrue);
      expect(none.isValid, isFalse);
    });

    test('a form field gets the reason, or null', () {
      expect(const Port().field('993'), isNull);
      expect(const Port().field(null), 'Enter a port number');
    });
  });

  group('ControlCharacters', () {
    test('finds line breaks, C1 controls and Unicode separators', () {
      for (final s in ['a\rb', 'a\nb', 'a\x00b', 'a\x1Bb', 'a\u0085b', 'a b']) {
        expect(ControlCharacters.inLine(s), isTrue, reason: s);
        expect(ControlCharacters.toSpaces(s), 'a b');
      }
      expect(ControlCharacters.inLine('Grüße, 東京 🍋'), isFalse);
      expect(ControlCharacters.inText('line one\nline two\ttab'), isFalse);
      expect(ControlCharacters.inText('bell\x07'), isTrue);
    });
  });

  group('TextInput', () {
    const name = TextInput(empty: 'Enter a name.', maxLength: 10);

    test('trims, and keeps Unicode', () {
      expect(valid(name('  Ré 東京 ')), 'Ré 東京');
      expect(
        valid(name('🍋' * 10)),
        '🍋' * 10,
        reason: 'characters, not units',
      );
    });

    test('empty, too long, or on two lines', () {
      expect(invalid(name('   ')), 'Enter a name.');
      expect(invalid(name('x' * 11)), 'Use at most 10 characters.');
      expect(invalid(name(huge)), 'Use at most 10 characters.');
      expect(invalid(name('a\r\nBcc: x')), 'Keep it on one line.');
      expect(
        invalid(name('a\x00b')),
        'Remove the invisible control characters.',
      );
      expect(valid(const TextInput()('')), '', reason: 'optional');
    });

    test('multiline keeps line breaks, as \\n', () {
      const text = TextInput(multiline: true, maxLength: 100);
      expect(valid(text('Best,\r\nAnn\rB')), 'Best,\nAnn\nB');
      expect(
        invalid(text('a\x07')),
        'Remove the invisible control characters.',
      );
      const indented = TextInput(multiline: true, keepIndent: true);
      expect(valid(indented('  Ann\n  ')), '  Ann');
      expect(valid(indented('   ')), '');
    });
  });

  group('WholeNumber', () {
    const days = WholeNumber(min: 1, max: 365);

    test('plain digits in range', () {
      expect(valid(days(' 30 ')), 30);
      expect(valid(days('1')), 1);
      expect(valid(days('365')), 365);
    });

    test('out of range, or not plain digits', () {
      for (final bad in [
        '0',
        '366',
        '-1',
        '+5',
        '0x10',
        '1e2',
        '3.5',
        '',
        'ten',
        '٣',
        '9' * 40,
        huge,
      ]) {
        expect(
          invalid(days(bad)),
          'Enter a whole number from 1 to 365.',
          reason: bad,
        );
      }
    });
  });

  group('Port', () {
    test('1 to 65535', () {
      expect(valid(const Port()('993')), 993);
      expect(valid(const Port()('65535')), 65535);
      for (final bad in [
        '0',
        '65536',
        '-993',
        '99\n3',
        'imap',
        '99999999999999999999',
      ]) {
        expect(invalid(const Port()(bad)), 'Enter a port number', reason: bad);
      }
    });
  });

  group('Amount', () {
    const dollars = Amount(max: 1000);

    test('dollars and cents, with a point or a comma', () {
      expect(valid(dollars('5')), 5);
      expect(valid(dollars(' 0.25 ')), 0.25);
      expect(valid(dollars('0,25')), 0.25);
      expect(valid(dollars(r'$12')), 12);
      expect(valid(dollars('.5')), 0.5);
      expect(valid(dollars('5.')), 5);
      expect(valid(dollars('0')), 0);
    });

    test('never NaN, infinite, exponents or negative', () {
      for (final bad in [
        'NaN',
        'nan',
        'Infinity',
        '-Infinity',
        '1e3',
        '-1',
        '',
        '.',
        'five',
        huge,
      ]) {
        expect(
          invalid(dollars(bad)),
          'Enter an amount such as 5 or 0.25.',
          reason: bad,
        );
      }
      expect(invalid(dollars('1000.01')), 'Enter an amount up to 1000.');
    });
  });

  group('EmailAddress', () {
    const email = EmailAddress();

    test('plain addresses, IDN domains and plus tags', () {
      expect(valid(email(' Ann@Example.com ')).address, 'Ann@Example.com');
      expect(valid(email('ann+news@mail.example.co.uk')).localPart, 'ann+news');
      final idn = valid(email('jürgen@münchen.de'.replaceFirst('jü', 'ju')));
      expect(idn.domain, 'münchen.de');
      expect(valid(email('a@xn--mnchen-3ya.de')).domain, 'xn--mnchen-3ya.de');
    });

    test('not an address', () {
      for (final bad in [
        '',
        'ann',
        'ann@',
        '@example.com',
        'ann@@example.com',
        'a@b@c.example',
        'ann example@x.example',
        'Ann <ann@x.example>',
        'a@x.example, b@x.example',
        'x' * 250 + '@example.com',
        huge,
      ]) {
        expect(invalid(email(bad)), email.reason, reason: bad);
      }
    });

    test('no header injection through an address', () {
      for (final bad in [
        'ann@x.example\r\nBcc: eve@evil.example',
        'ann@x.example\nBcc: eve@evil.example',
        'ann\r@x.example',
        'ann@x.ex\u0085ample',
      ]) {
        expect(email(bad).isValid, isFalse, reason: bad);
      }
    });

    test('addresses mail can\'t be sent to yet, and why', () {
      expect(
        invalid(email('jürgen@example.com')),
        contains('before the @'),
        reason: 'SMTPUTF8 local parts are not supported',
      );
      expect(invalid(email('"a,b"@example.com')), contains('before the @'));
      expect(invalid(email('a..b@example.com')), contains('before the @'));
      expect(
        invalid(email('ann@-x.example')),
        'The part after the @ isn\'t a domain.',
      );
      // Reading is fine with them: only sending refuses.
      expect(
        const EmailAddress(sendable: false)('jürgen@example.com').isValid,
        isTrue,
      );
    });

    test('sendProblem agrees with the message builder', () {
      const ok = MailAddress(localPart: 'ann', domain: 'münchen.de');
      expect(EmailAddress.sendProblem(ok), isNull);
      const bad = MailAddress(localPart: 'a b', domain: 'x.example');
      expect(EmailAddress.sendProblem(bad), isNotNull);
    });
  });

  group('HostName', () {
    const host = HostName();

    test('a name in two or more parts, in lower case', () {
      expect(valid(host(' IMAP.Example.com ')), 'imap.example.com');
      expect(valid(host('mail-1.x.example')), 'mail-1.x.example');
      expect(valid(host('192.168.1.5')), '192.168.1.5');
    });

    test('anything else', () {
      for (final bad in [
        '',
        'localhost',
        'imap.example.com.',
        '-imap.example.com',
        'imap_x.example.com',
        'imap.example.com:993',
        'imap example.com',
        'imap.example.com\r\nEHLO evil',
        'mail.münchen.de',
        '${'a' * 64}.example.com',
        '${'abc.' * 70}com',
        huge,
      ]) {
        expect(invalid(host(bad)), 'Enter a server name', reason: bad);
      }
      expect(
        invalid(host('https://imap.example.com')),
        'Enter only the server name, without http:// or /',
      );
    });
  });

  group('WebAddress', () {
    const endpoint = WebAddress(httpOnLocalNetwork: true);
    const secure = WebAddress();

    test('https anywhere; http on this computer or network', () {
      expect(
        valid(endpoint('https://openrouter.ai/api/v1')).host,
        'openrouter.ai',
      );
      expect(valid(endpoint('http://localhost:11434/v1')).port, 11434);
      expect(valid(endpoint('http://127.0.0.1:1234/v1')).host, '127.0.0.1');
      expect(
        valid(endpoint('http://192.168.1.20:8080/v1')).host,
        '192.168.1.20',
      );
      expect(valid(endpoint('http://[::1]:11434/v1')).host, '::1');
      expect(
        valid(endpoint('http://ollama.home.arpa/v1')).host,
        'ollama.home.arpa',
      );
      expect(valid(secure('https://example.com')).scheme, 'https');
    });

    test('plain http to a public address is refused', () {
      expect(invalid(endpoint('http://8.8.8.8/v1')), contains('Use https://'));
      expect(
        invalid(endpoint('http://[2606:4700::1111]/v1')),
        contains('Use https://'),
      );
      expect(invalid(secure('http://localhost/')), contains('https://'));
    });

    test('only http and https', () {
      for (final bad in [
        'file:///etc/passwd',
        'javascript:alert(1)',
        'ftp://example.com/',
        'data:text/html,hi',
        'content://x/y',
      ]) {
        expect(
          invalid(endpoint(bad)),
          'Use an address that starts with https://.',
          reason: bad,
        );
      }
    });

    test('a host, no credentials, one line, not huge', () {
      expect(invalid(endpoint('https:///v1')), endpoint.reason);
      expect(invalid(endpoint('openrouter.ai/api')), endpoint.reason);
      expect(invalid(endpoint('')), endpoint.reason);
      expect(
        invalid(endpoint('https://user:secret@openrouter.ai/api/v1')),
        'Leave the user name and password out of the address.',
      );
      expect(
        invalid(endpoint('https://x.example/v1\r\nHost: evil')),
        endpoint.reason,
      );
      expect(invalid(endpoint('https://x.example/a b')), endpoint.reason);
      expect(
        invalid(endpoint('https://x.example/$huge')),
        'That address is too long.',
      );
    });

    test('isPublicAddress judges IP addresses only', () {
      expect(WebAddress.isPublicAddress('1.1.1.1'), isTrue);
      expect(WebAddress.isPublicAddress('10.0.0.1'), isFalse);
      expect(WebAddress.isPublicAddress('100.64.0.1'), isFalse);
      expect(WebAddress.isPublicAddress('fd00::1'), isFalse);
      expect(WebAddress.isPublicAddress('example.com'), isFalse);
    });
  });

  group('FolderName', () {
    StoredMailbox box(
      String name, {
      String? delimiter = '/',
      bool inbox = false,
    }) => StoredMailbox(
      id: name.hashCode,
      accountId: 1,
      name: name,
      encodedName: name,
      delimiter: delimiter,
      selectable: true,
      syncState: const MailboxSyncState(),
    );

    final slash = FolderName([box('INBOX', inbox: true), box('Archive')]);
    final dot = FolderName([box('INBOX', delimiter: '.', inbox: true)]);

    test('names, subfolders and Unicode', () {
      expect(valid(slash(' Receipts ')), 'Receipts');
      expect(valid(slash('Projects/2026')), 'Projects/2026');
      expect(valid(slash('Café & Co 東京')), 'Café & Co 東京');
      expect(valid(slash('x' * 100)), 'x' * 100);
    });

    test('each problem has its reason', () {
      expect(invalid(slash('  ')), 'Enter a name.');
      expect(invalid(slash('a//b')), 'Give each folder between two / a name.');
      expect(invalid(slash('x' * 101)), contains('at most 100'));
      expect(invalid(slash(huge)), contains('at most 100'));
      expect(invalid(slash('star*')), contains('can\'t contain %'));
      expect(invalid(slash('100%')), contains('can\'t contain %'));
      expect(invalid(slash('say "hi"')), contains('can\'t contain %'));
      expect(invalid(slash(r'back\slash')), contains('can\'t contain %'));
      expect(invalid(slash('a\r\nb')), contains('line breaks'));
      expect(invalid(slash('inbox')), 'Inbox already exists.');
      expect(invalid(slash('Projects/..')), 'That can\'t be a folder name.');
      expect(
        invalid(dot('with.dot')),
        'Folder names can\'t contain "." on this server.',
      );
      expect(valid(slash('with.dot')), 'with.dot');
    });
  });

  group('SearchText', () {
    const search = SearchText();

    test('controls become spaces, empty is fine', () {
      expect(valid(search(' invoice\r\nmarch\t')), 'invoice  march');
      expect(valid(search('')), '');
      expect(valid(search('會議')), '會議');
      expect(valid(search('"quoted" OR NEAR*')), '"quoted" OR NEAR*');
    });

    test('at most 200 characters', () {
      expect(valid(search('x' * 200)), 'x' * 200);
      expect(invalid(search('x' * 201)), 'Search for at most 200 characters.');
      expect(invalid(search(huge)), 'Search for at most 200 characters.');
    });
  });

  group('ApiKey', () {
    const key = ApiKey(empty: 'Paste your key first.');

    test('trimmed, printable, of a key\'s length', () {
      expect(
        valid(key('  sk-ant-api03-abcdefgh  \n')),
        'sk-ant-api03-abcdefgh',
      );
      expect(valid(const ApiKey()('')), '', reason: 'optional');
    });

    test('spaces, line breaks, odd letters, too short or long', () {
      expect(invalid(key('')), 'Paste your key first.');
      for (final bad in [
        'sk-abc def-ghij',
        'sk-abc\r\nX-Evil: 1',
        'sk-ключ-12345',
        'sk​abcdefgh',
      ]) {
        expect(
          invalid(key(bad)),
          contains('no spaces or line breaks'),
          reason: bad,
        );
      }
      expect(invalid(key('short')), 'That is shorter than an API key.');
      expect(invalid(key('k' * 513)), contains('longer than an API key'));
      expect(invalid(key(huge)), contains('longer than an API key'));
    });
  });

  group('MatchingText', () {
    test('the whole trimmed text must match', () {
      const hex = MatchingText('[0-9a-f]{4}', 'Four hex digits.');
      expect(valid(hex(' beef ')), 'beef');
      for (final bad in ['bee', 'beef0', 'xbeef', 'be\nef', '', huge]) {
        expect(invalid(hex(bad)), 'Four hex digits.', reason: bad);
      }
    });
  });

  group('ModelId', () {
    test('ids as providers write them', () {
      for (final id in [
        'gpt-4o-mini',
        'meta-llama/Llama-3.3-70B-Instruct',
        'llama3.2:3b',
        'models/gemini-2.5-flash',
      ]) {
        expect(valid(const ModelId()(' $id ')), id);
      }
    });

    test('empty, spaces, line breaks or too long', () {
      expect(invalid(const ModelId()('')), 'Choose or type a model.');
      expect(
        invalid(const ModelId()('my model')),
        'A model\'s name has no spaces.',
      );
      expect(
        invalid(const ModelId()('gpt\r\n4')),
        'A model\'s name has no spaces.',
      );
      expect(invalid(const ModelId()('m' * 201)), contains('longer'));
    });
  });
}
