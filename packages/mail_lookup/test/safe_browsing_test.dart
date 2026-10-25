// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:mail_lookup/mail_lookup.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_web/mail_web.dart';
import 'package:test/test.dart';

/// A Safe Browsing API on 127.0.0.1: answers each POST with [answer].
final class _Api {
  _Api._(this._socket);

  static Future<_Api> start() async =>
      _Api._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0))
        .._listen();

  final ServerSocket _socket;
  final requests = <(String, Map<String, Object?>)>[];
  late Map<String, Object?> Function(String path, Map<String, Object?> body)
  answer;
  int status = 200;

  void _listen() => _socket.listen((client) {
    final got = BytesBuilder();
    client.listen((data) {
      got.add(data);
      final text = latin1.decode(got.toBytes());
      final end = text.indexOf('\r\n\r\n');
      if (end < 0) return;
      final length = int.parse(
        RegExp(r'Content-Length: (\d+)').firstMatch(text)!.group(1)!,
      );
      if (text.length < end + 4 + length) return;
      final path = text.split(' ')[1];
      final body = jsonDecode(
        utf8.decode(latin1.encode(text.substring(end + 4))),
      ) as Map<String, Object?>;
      requests.add((path, body));
      final reply = utf8.encode(jsonEncode(answer(path, body)));
      client
        ..add(
          latin1.encode(
            'HTTP/1.1 $status X\r\nContent-Type: application/json\r\n'
            'Content-Length: ${reply.length}\r\n\r\n',
          ),
        )
        ..add(reply)
        ..close();
    });
  });

  WebClient get web => WebClient(
    resolver: (_) async => [InternetAddress('142.250.1.95')],
    connector: (host, address, port, timeout) => MailSocket.connect(
      ServerEndpoint(
        host,
        _socket.port,
        ConnectionSecurity.startTls,
        connectAddress: '127.0.0.1',
      ),
    ),
  );

  Future<void> close() => _socket.close();
}

/// Two 4-byte prefixes, concatenated in byte order.
List<int> _inOrder(List<int> a, List<int> b) {
  for (var i = 0; i < 4; i++) {
    if (a[i] != b[i]) return a[i] < b[i] ? [...a, ...b] : [...b, ...a];
  }
  return [...a, ...b];
}

Uint8List _sha(String text) =>
    Uint8List.fromList(sha256.convert(utf8.encode(text)).bytes);

void main() {
  group('canonical URLs (Google\'s examples)', () {
    const cases = {
      'http://host/%25%32%35': 'http://host/%25',
      'http://host/%25%32%35%25%32%35': 'http://host/%25%25',
      'http://host/%2525252525252525': 'http://host/%25',
      'http://host/asdf%25%32%35asd': 'http://host/asdf%25asd',
      'http://host/%%%25%32%35asd%%': 'http://host/%25%25%25asd%25%25',
      'http://www.google.com/': 'http://www.google.com/',
      'http://%31%36%38%2e%31%38%38%2e%39%39%2e%32%36/%2E%73%65%63%75%72%65/%77%77%77%2E%65%62%61%79%2E%63%6F%6D/':
          'http://168.188.99.26/.secure/www.ebay.com/',
      'http://195.127.0.11/uploads/%20%20%20%20/.verify/.eBayVerify/eBayVerify/': 'http://195.127.0.11/uploads/%20%20%20%20/.verify/.eBayVerify/eBayVerify/',
      'http://host%23.com/%257Ea%2521b%2540c%2523d%2524e%25f%255E00%252611%252A22%252833%252944_55%252B':
          'http://host%23.com/~a!b@c%23d\$e%25f^00&11*22(33)44_55+',
      'http://3279880203/blah': 'http://195.127.0.11/blah',
      'http://www.google.com/blah/..': 'http://www.google.com/',
      'www.google.com/': 'http://www.google.com/',
      'www.google.com': 'http://www.google.com/',
      'http://www.evil.com/blah#frag': 'http://www.evil.com/blah',
      'http://www.GOOgle.com/': 'http://www.google.com/',
      'http://www.google.com.../': 'http://www.google.com/',
      'http://www.google.com/foo\tbar\rbaz\n2':
          'http://www.google.com/foobarbaz2',
      'http://www.google.com/q?': 'http://www.google.com/q?',
      'http://www.google.com/q?r?': 'http://www.google.com/q?r?',
      'http://www.google.com/q?r?s': 'http://www.google.com/q?r?s',
      'http://evil.com/foo#bar#baz': 'http://evil.com/foo',
      'http://evil.com/foo;': 'http://evil.com/foo;',
      'http://evil.com/foo?bar;': 'http://evil.com/foo?bar;',
      'http://notrailingslash.com': 'http://notrailingslash.com/',
      'http://www.gotaport.com:1234/': 'http://www.gotaport.com/',
      '  http://www.google.com/  ': 'http://www.google.com/',
      'http:// leadingspace.com/': 'http://%20leadingspace.com/',
      'http://%20leadingspace.com/': 'http://%20leadingspace.com/',
      '%20leadingspace.com/': 'http://%20leadingspace.com/',
      'https://www.securesite.com/': 'https://www.securesite.com/',
      'http://host.com/ab%23cd': 'http://host.com/ab%23cd',
      'http://host.com//twoslashes?more//slashes':
          'http://host.com/twoslashes?more//slashes',
    };
    for (final MapEntry(key: input, value: expected) in cases.entries) {
      test(input.replaceAll(RegExp(r'\s'), '_'), () {
        expect(SafeBrowsingUrl.canonicalize(input), expected);
      });
    }
    test('no host, no check', () {
      expect(SafeBrowsingUrl.canonicalize('http:///path'), isNull);
      expect(SafeBrowsingUrl.hashes('http://...'), isEmpty);
    });
  });

  group('lookup expressions (Google\'s examples)', () {
    test('host suffixes and path prefixes', () {
      expect(
        SafeBrowsingUrl.expressions('http://a.b.c/1/2.html?param=1'),
        unorderedEquals([
          'a.b.c/1/2.html?param=1',
          'a.b.c/1/2.html',
          'a.b.c/',
          'a.b.c/1/',
          'b.c/1/2.html?param=1',
          'b.c/1/2.html',
          'b.c/',
          'b.c/1/',
        ]),
      );
      expect(
        SafeBrowsingUrl.expressions('http://a.b.c.d.e.f.g/1.html'),
        unorderedEquals([
          'a.b.c.d.e.f.g/1.html',
          'a.b.c.d.e.f.g/',
          'c.d.e.f.g/1.html',
          'c.d.e.f.g/',
          'd.e.f.g/1.html',
          'd.e.f.g/',
          'e.f.g/1.html',
          'e.f.g/',
          'f.g/1.html',
          'f.g/',
        ]),
      );
      expect(
        SafeBrowsingUrl.expressions('http://1.2.3.4/1/'),
        unorderedEquals(['1.2.3.4/1/', '1.2.3.4/']),
      );
      expect(
        SafeBrowsingUrl.expressions('http://a.b/x/y/z/w/v/u.html').length,
        lessThanOrEqualTo(30),
      );
    });
  });

  group('PrefixList', () {
    Uint8List b(List<int> bytes) => Uint8List.fromList(bytes);

    test('updates keep byte order; removals use the old order', () {
      final list = PrefixList()
        ..apply(
          removals: const [],
          additions: [
            b([9, 9, 9, 9]),
            b([1, 2, 3, 4, 5]),
            b([1, 2, 3, 4]),
            b([0, 0, 0, 1]),
          ],
        );
      expect(list.ordered.toList(), [
        b([0, 0, 0, 1]),
        b([1, 2, 3, 4]),
        b([1, 2, 3, 4, 5]),
        b([9, 9, 9, 9]),
      ]);
      // Remove the second and third (the 4- and 5-byte 1.2.3.4).
      list.apply(
        removals: const [1, 2],
        additions: [
          b([5, 5, 5, 5]),
        ],
      );
      expect(list.ordered.toList(), [
        b([0, 0, 0, 1]),
        b([5, 5, 5, 5]),
        b([9, 9, 9, 9]),
      ]);
      expect(
        base64.encode(list.checksum()),
        base64.encode(
          sha256.convert([0, 0, 0, 1, 5, 5, 5, 5, 9, 9, 9, 9]).bytes,
        ),
      );
    });

    test('matches by prefix', () {
      final hash = _sha('evil.example/');
      final list = PrefixList()
        ..apply(
          removals: const [],
          additions: [
            Uint8List.sublistView(hash, 0, 4),
            b([7, 7, 7, 7]),
          ],
        );
      expect(list.match(hash), Uint8List.sublistView(hash, 0, 4));
      expect(list.match(_sha('good.example/')), isNull);
    });

    test('the database survives a save and a reload', () {
      final db = SafeBrowsingDatabase(
        nextUpdate: DateTime.utc(2026, 10, 25, 12),
      );
      db.lists[ThreatType.malware]!
        ..state = 'c3RhdGU='
        ..apply(
          removals: const [],
          additions: [
            b([1, 2, 3, 4]),
            b([1, 2, 3, 4, 5, 6]),
          ],
        );
      final back = SafeBrowsingDatabase.decode(db.encode())!;
      expect(back.nextUpdate, DateTime.utc(2026, 10, 25, 12));
      expect(back.lists[ThreatType.malware]!.state, 'c3RhdGU=');
      expect(
        back.lists[ThreatType.malware]!.ordered.toList(),
        db.lists[ThreatType.malware]!.ordered.toList(),
      );
      expect(back.lists[ThreatType.socialEngineering]!.length, 0);
      expect(
        SafeBrowsingDatabase.decode(Uint8List.fromList([1, 2, 3])),
        isNull,
      );
    });
  });

  group('SafeBrowsingClient', () {
    late _Api api;
    late DateTime now;
    setUp(() async {
      api = await _Api.start();
      now = DateTime.utc(2026, 10, 25, 12);
    });
    tearDown(() => api.close());

    final phish = _sha('phish.example/login');
    final prefix = Uint8List.sublistView(phish, 0, 4);

    Map<String, Object?> listUpdate() => {
      'listUpdateResponses': [
        {
          'threatType': 'SOCIAL_ENGINEERING',
          'threatEntryType': 'URL',
          'platformType': 'ANY_PLATFORM',
          'responseType': 'FULL_UPDATE',
          'additions': [
            {
              'compressionType': 'RAW',
              'rawHashes': {
                'prefixSize': 4,
                'rawHashes': base64.encode([...prefix, 1, 1, 1, 1]),
              },
            },
          ],
          'newClientState': 'bmV3',
          'checksum': {
            'sha256': base64.encode(
              sha256.convert(_inOrder([1, 1, 1, 1], prefix)).bytes,
            ),
          },
        },
      ],
      'minimumWaitDuration': '1800.5s',
    };

    test('downloads the lists, then checks links on the device', () async {
      final db = SafeBrowsingDatabase();
      final client = SafeBrowsingClient(api.web, 'KEY', db, now: () => now);
      expect(client.updateDue, isTrue);
      api.answer = (path, body) => listUpdate();
      await client.update();
      final (path, body) = api.requests.single;
      expect(path, '/v4/threatListUpdates:fetch?key=KEY');
      expect(
        (body['listUpdateRequests']! as List).map((r) => (r as Map)['state']),
        ['', '', ''],
      );
      expect(db.lists[ThreatType.socialEngineering]!.state, 'bmV3');
      expect(db.lists[ThreatType.socialEngineering]!.length, 2);
      expect(
        db.nextUpdate,
        now.add(const Duration(seconds: 1800, milliseconds: 500)),
      );
      expect(client.updateDue, isFalse);

      // A link with no matching prefix: nothing is sent.
      expect((await client.check('https://good.example/')).listed, isFalse);
      expect(api.requests, hasLength(1));

      // A matching prefix: only that prefix is sent, and Google confirms.
      api.answer = (path, body) => {
        'matches': [
          {
            'threatType': 'SOCIAL_ENGINEERING',
            'platformType': 'ANY_PLATFORM',
            'threatEntryType': 'URL',
            'threat': {'hash': base64.encode(phish)},
            'cacheDuration': '300s',
          },
        ],
        'negativeCacheDuration': '300s',
      };
      final verdict = await client.check('http://Phish.example/login#x');
      expect(verdict.threat, ThreatType.socialEngineering);
      final (findPath, find) = api.requests.last;
      expect(findPath, '/v4/fullHashes:find?key=KEY');
      final sent = jsonEncode(find);
      expect(sent, contains(base64.encode(prefix)));
      expect(sent, isNot(contains('phish.example')), reason: 'never the URL');
      expect(
        sent,
        isNot(contains(base64.encode(phish))),
        reason: 'nor a full hash',
      );

      // Cached: no new request.
      expect((await client.check('http://phish.example/login')).listed, isTrue);
      expect(api.requests, hasLength(2));
    });

    test('a prefix Google doesn\'t confirm is safe, and cached', () async {
      final db = SafeBrowsingDatabase();
      db.lists[ThreatType.malware]!.apply(
        removals: const [],
        additions: [prefix],
      );
      final client = SafeBrowsingClient(api.web, 'KEY', db, now: () => now);
      api.answer = (path, body) => {'negativeCacheDuration': '600s'};
      expect(
        (await client.check('http://phish.example/login')).listed,
        isFalse,
      );
      expect(
        (await client.check('http://phish.example/login')).listed,
        isFalse,
      );
      expect(api.requests, hasLength(1));
    });

    test('a wrong checksum empties the list for a fresh download', () async {
      final db = SafeBrowsingDatabase();
      final client = SafeBrowsingClient(api.web, 'KEY', db, now: () => now);
      api.answer = (path, body) {
        final update = listUpdate();
        ((update['listUpdateResponses']! as List).first as Map)['checksum'] = {
          'sha256': base64.encode(List.filled(32, 0)),
        };
        return update;
      };
      await client.update();
      expect(db.lists[ThreatType.socialEngineering]!.length, 0);
      expect(db.lists[ThreatType.socialEngineering]!.state, '');
    });

    test('a refused key is reported', () async {
      final client = SafeBrowsingClient(
        api.web,
        'BAD',
        SafeBrowsingDatabase(),
        now: () => now,
      );
      api
        ..status = 400
        ..answer = (path, body) => {
          'error': {'code': 400, 'message': 'API key not valid.'},
        };
      await expectLater(
        client.update(),
        throwsA(
          isA<WebException>().having(
            (e) => e.message,
            'message',
            contains('API key not valid'),
          ),
        ),
      );
    });
  });
}
