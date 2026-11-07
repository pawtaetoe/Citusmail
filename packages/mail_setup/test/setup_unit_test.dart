// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_setup/mail_setup.dart';
import 'package:test/test.dart';

/// What cPanel served for tommykung.cc (over plain HTTP only).
const cpanelXml = '''<?xml version="1.0"?>
<clientConfig version="1.1">
    <emailProvider id="tommykung.cc">
        <domain>tommykung.cc</domain>
        <displayName>me@tommykung.cc</displayName>
        <incomingServer type="imap">
            <hostname>tommykung.cc</hostname>
            <port>993</port>
            <socketType>SSL</socketType>
            <authentication>password-cleartext</authentication>
            <username>me@tommykung.cc</username>
        </incomingServer>
        <outgoingServer type="smtp">
            <hostname>tommykung.cc</hostname>
            <port>465</port>
            <socketType>SSL</socketType>
            <authentication>password-cleartext</authentication>
            <username>me@tommykung.cc</username>
        </outgoingServer>
    </emailProvider>
</clientConfig>''';

String providerXml({
  String imapSocket = 'STARTTLS',
  String auth = 'password-cleartext',
  String extra = '',
}) =>
    '''
<clientConfig version="1.1"><emailProvider id="x">
  <incomingServer type="pop3"><hostname>pop.%EMAILDOMAIN%</hostname><port>995</port><socketType>SSL</socketType></incomingServer>
  <incomingServer type="imap"><hostname>imap.%EMAILDOMAIN%</hostname><port>143</port><socketType>$imapSocket</socketType><authentication>$auth</authentication><username>%EMAILLOCALPART%</username></incomingServer>
  $extra
  <outgoingServer type="smtp"><hostname>smtp.%EMAILDOMAIN%</hostname><port>587</port><socketType>STARTTLS</socketType><authentication>$auth</authentication></outgoingServer>
</emailProvider></clientConfig>''';

void main() {
  group('MiniXml', () {
    const xml = MiniXml();

    test('elements, attributes, entities, CDATA and comments', () {
      final root = xml.parse(
        '<?xml version="1.0"?><!-- c --><a x="1 &amp; 2"><b>t&lt;&#65;&#x42;</b><![CDATA[<raw>]]><c/></a>',
      );
      expect(root.name, 'a');
      expect(root.attributes['x'], '1 & 2');
      expect(root.childText('b'), 't<AB');
      expect(root.text, '<raw>');
      expect(root.first('c'), isNotNull);
    });

    test('refuses DOCTYPE, so no XXE and no entity expansion attacks', () {
      const xxe =
          '<?xml version="1.0"?><!DOCTYPE a [<!ENTITY x SYSTEM "file:///etc/passwd">]><a>&x;</a>';
      const laughs =
          '<!DOCTYPE a [<!ENTITY l "lol"><!ENTITY l2 "&l;&l;&l;&l;">]><a>&l2;</a>';
      expect(() => xml.parse(xxe), throwsFormatException);
      expect(() => xml.parse(laughs), throwsFormatException);
      expect(() => xml.parse('<a>&undefined;</a>'), throwsFormatException);
    });

    test('rejects malformed and oversized documents', () {
      for (final bad in [
        '',
        '<a>',
        '<a></b>',
        '<a/><b/>',
        'text<a/>',
        '<a x="1></a>',
        '<a>&</a>',
        '<1a/>',
      ]) {
        expect(() => xml.parse(bad), throwsFormatException, reason: bad);
      }
      expect(
        () => xml.parse('${'<a>' * 100}${'</a>' * 100}'),
        throwsFormatException,
      );
      expect(
        () => const MiniXml(maxLength: 100).parse('<a>${'x' * 200}</a>'),
        throwsFormatException,
      );
      expect(
        () => const MiniXml(maxElements: 10).parse('<a>${'<b/>' * 20}</a>'),
        throwsFormatException,
      );
    });
  });

  group('AutoconfigParser', () {
    const parser = AutoconfigParser();

    test('the real cPanel file for tommykung.cc', () {
      final (s, problem) = parser.parse(
        cpanelXml,
        'me@tommykung.cc',
        DiscoverySource.httpAutoconfig,
      );
      expect(problem, isNull);
      expect(
        s!.imap,
        const ServerCandidate(
          'tommykung.cc',
          993,
          ConnectionSecurity.implicitTls,
        ),
      );
      expect(
        s.smtp,
        const ServerCandidate(
          'tommykung.cc',
          465,
          ConnectionSecurity.implicitTls,
        ),
      );
      expect(s.username, 'me@tommykung.cc');
      expect(s.warnings, [
        SetupWarning.unauthenticatedSource,
      ], reason: 'came over HTTP; servers are inside the domain');
    });

    test('placeholders, POP3 ignored, implicit TLS preferred', () {
      final xml = providerXml(
        extra: '<incomingServer type="imap"><hostname>secure.%EMAILDOMAIN%</hostname><port>993</port><socketType>SSL</socketType></incomingServer>',
      );
      final (s, _) = parser.parse(
        xml,
        'ana@x.example',
        DiscoverySource.httpsAutoconfig,
      );
      expect(
        s!.imap,
        const ServerCandidate(
          'secure.x.example',
          993,
          ConnectionSecurity.implicitTls,
        ),
      );
      expect(s.smtp.security, ConnectionSecurity.startTls);
      expect(
        s.username,
        'ana@x.example',
        reason: 'username of the chosen server (default: the address)',
      );
      expect(s.warnings, isEmpty);
    });

    test('plain-text servers are never used', () {
      final (s, problem) = parser.parse(
        providerXml(imapSocket: 'plain'),
        'ana@x.example',
        DiscoverySource.httpsAutoconfig,
      );
      expect(s, isNull);
      expect(problem, AutoconfigProblem.noSecureServers);
    });

    test('OAuth2-only providers are reported as such', () {
      final (s, problem) = parser.parse(
        providerXml(auth: 'OAuth2'),
        'ana@x.example',
        DiscoverySource.mozillaDatabase,
      );
      expect(s, isNull);
      expect(problem, AutoconfigProblem.oauthOnly);
    });

    test('invalid files are rejected', () {
      for (final bad in ['<html>404</html>', 'not xml', '<clientConfig/>']) {
        expect(
          parser.parse(bad, 'a@x.example', DiscoverySource.httpsAutoconfig).$2,
          AutoconfigProblem.invalid,
        );
      }
      final badHost = cpanelXml.replaceAll(
        '<hostname>tommykung.cc</hostname>',
        '<hostname>evil host</hostname>',
      );
      expect(
        parser
            .parse(badHost, 'me@tommykung.cc', DiscoverySource.httpAutoconfig)
            .$1,
        isNull,
      );
    });

    test('servers outside the domain are flagged', () {
      final (s, _) = parser.parse(
        providerXml(),
        'ana@other.example'.replaceAll('other', 'x'),
        DiscoverySource.httpAutoconfig,
      );
      expect(s!.warnings, isNot(contains(SetupWarning.serverOutsideDomain)));
      final outside = cpanelXml.replaceAll(
        '<hostname>tommykung.cc</hostname>',
        '<hostname>attacker.example</hostname>',
      );
      expect(
        parser
            .parse(outside, 'me@tommykung.cc', DiscoverySource.httpAutoconfig)
            .$1!
            .warnings,
        containsAll([
          SetupWarning.unauthenticatedSource,
          SetupWarning.serverOutsideDomain,
        ]),
      );
      expect(
        DiscoveredSettings.isWithinDomain('mail.tommykung.cc', 'tommykung.cc'),
        isTrue,
      );
      expect(
        DiscoveredSettings.isWithinDomain('nottommykung.cc', 'tommykung.cc'),
        isFalse,
      );
    });
  });

  group('DnsMessage', () {
    Uint8List answer({
      int id = 0x1234,
      int flags = 0x8180,
      int answers = 1,
      List<int>? rdata,
    }) {
      final name = [
        6,
        ...'_imaps'.codeUnits,
        4,
        ...'_tcp'.codeUnits,
        7,
        ...'example'.codeUnits,
        3,
        ...'com'.codeUnits,
        0,
      ];
      final target =
          rdata ??
          [
            0,
            10,
            0,
            5,
            0x03,
            0xE1,
            4,
            ...'mail'.codeUnits,
            0xC0,
            24,
          ]; // pointer to "example.com": header 12 + "_imaps" 7 + "_tcp" 5
      return Uint8List.fromList([
        id >> 8,
        id & 0xFF,
        flags >> 8,
        flags & 0xFF,
        0,
        1,
        0,
        answers,
        0,
        0,
        0,
        0,
        ...name,
        0,
        33,
        0,
        1,
        if (answers > 0) ...[
          0xC0,
          12,
          0,
          33,
          0,
          1,
          0,
          0,
          0,
          60,
          0,
          target.length,
          ...target,
        ],
      ]);
    }

    test('encodes a query', () {
      final q = DnsMessage.query(0xABCD, '_imaps._tcp.example.com', 33);
      expect(q.sublist(0, 2), [0xAB, 0xCD]);
      expect(q.sublist(q.length - 4), [0, 33, 0, 1]);
      expect(
        () => DnsMessage.query(1, 'bad name!.com', 33),
        throwsArgumentError,
      );
    });

    test('parses an SRV answer with name compression', () {
      final records = DnsMessage.parseSrvAnswer(
        answer(),
        0x1234,
        '_imaps._tcp.example.com',
      );
      expect(records.single.target, 'mail.example.com');
      expect(records.single.port, 993);
      expect(records.single.priority, 10);
    });

    test(
      'NXDOMAIN is no records; mismatched or malformed replies are rejected',
      () {
        expect(
          DnsMessage.parseSrvAnswer(
            answer(flags: 0x8183, answers: 0),
            0x1234,
            '_imaps._tcp.example.com',
          ),
          isEmpty,
        );
        expect(
          () => DnsMessage.parseSrvAnswer(
            answer(),
            0x9999,
            '_imaps._tcp.example.com',
          ),
          throwsFormatException,
        );
        expect(
          () => DnsMessage.parseSrvAnswer(
            answer(),
            0x1234,
            '_imaps._tcp.other.com',
          ),
          throwsFormatException,
        );
        expect(
          () => DnsMessage.parseSrvAnswer(
            answer(flags: 0x0100),
            0x1234,
            '_imaps._tcp.example.com',
          ),
          throwsFormatException,
        );
        expect(
          () => DnsMessage.parseSrvAnswer(Uint8List(5), 0, 'x'),
          throwsFormatException,
        );
        final loop = answer(rdata: [0, 1, 0, 1, 0x03, 0xE1, 0xC0, 50]);
        loop[50] = 0xC0;
        loop[51] = 50; // pointer to itself
        expect(
          () => DnsMessage.parseSrvAnswer(
            loop,
            0x1234,
            '_imaps._tcp.example.com',
          ),
          throwsFormatException,
        );
      },
    );
  });

  group('AccountDiscovery', () {
    test(
      'tries sources in order; the address goes only to the domain',
      () async {
        final fetcher = _FakeFetcher({
          'http://autoconfig.tommykung.cc/mail/config-v1.1.xml': cpanelXml,
        });
        final prober = _FakeProber(available: {'tommykung.cc'});
        final steps = <DiscoveryStep>[];
        final result =
            await AccountDiscovery(
              fetcher: fetcher,
              srv: const NoSrvResolver(),
              prober: prober,
            ).discover(
              'me@tommykung.cc',
              askMozillaConsent: (d) async => true,
              onStep: steps.add,
            );
        expect(result.settings!.source, DiscoverySource.httpAutoconfig);
        expect(result.settings!.imap.host, 'tommykung.cc');
        expect(steps, [
          DiscoveryStep.providerFileSecure,
          DiscoveryStep.mozillaDatabase,
          DiscoveryStep.dnsRecords,
          DiscoveryStep.providerFileUnencrypted,
        ]);
        expect(fetcher.requested.map((u) => u.toString()), [
          'https://autoconfig.tommykung.cc/mail/config-v1.1.xml?emailaddress=me%40tommykung.cc',
          'https://tommykung.cc/.well-known/autoconfig/mail/config-v1.1.xml',
          'https://autoconfig.thunderbird.net/v1.1/tommykung.cc',
          'http://autoconfig.tommykung.cc/mail/config-v1.1.xml',
        ]);
        // The address only over HTTPS, and only to the domain itself.
        for (final uri in fetcher.requested) {
          final carriesAddress = uri.toString().contains('me%40tommykung.cc');
          if (uri.host.endsWith('tommykung.cc') && uri.scheme == 'https') {
            continue;
          }
          expect(carriesAddress, isFalse, reason: uri.toString());
          expect(uri.query, isEmpty, reason: uri.toString());
        }
      },
    );

    test('the whole order, when nothing answers', () async {
      final fetcher = _FakeFetcher({});
      final steps = <DiscoveryStep>[];
      final result =
          await AccountDiscovery(
            fetcher: fetcher,
            srv: const NoSrvResolver(),
            mx: _FakeMx({
              'shop.co.uk': [const MxRecord(10, 'mx1.privateemail.example.')],
            }),
            prober: _FakeProber(),
          ).discover(
            'me@shop.co.uk',
            askMozillaConsent: (d) async => true,
            onStep: steps.add,
          );
      expect(result.settings, isNull);
      expect(steps, [
        DiscoveryStep.providerFileSecure,
        DiscoveryStep.mozillaDatabase,
        DiscoveryStep.dnsRecords,
        DiscoveryStep.mailHostProviderFile,
        DiscoveryStep.mozillaDatabase,
        DiscoveryStep.providerFileUnencrypted,
        DiscoveryStep.dnsService,
        DiscoveryStep.probing,
      ]);
      expect(fetcher.requested.map((u) => u.toString()), [
        'https://autoconfig.shop.co.uk/mail/config-v1.1.xml?emailaddress=me%40shop.co.uk',
        'https://shop.co.uk/.well-known/autoconfig/mail/config-v1.1.xml',
        'https://autoconfig.thunderbird.net/v1.1/shop.co.uk',
        'https://autoconfig.privateemail.example/mail/config-v1.1.xml?emailaddress=me%40shop.co.uk',
        'https://privateemail.example/.well-known/autoconfig/mail/config-v1.1.xml',
        'https://autoconfig.thunderbird.net/v1.1/privateemail.example',
        'http://autoconfig.shop.co.uk/mail/config-v1.1.xml',
      ]);
      // The address went only to the domain and its mail host, over HTTPS.
      final allowed = {'shop.co.uk', 'privateemail.example'};
      for (final uri in fetcher.requested) {
        final text = uri.toString();
        final base = uri.host.split('.').length > 2
            ? uri.host.substring(uri.host.indexOf('.') + 1)
            : uri.host;
        if (text.contains('me%40') || text.contains('me@')) {
          expect(uri.scheme, 'https', reason: text);
          expect(allowed, contains(base), reason: text);
        }
      }
    });

    test('a custom domain is answered by its mail host\'s settings', () async {
      // shop.co.uk is hosted at privateemail.example: its MX says so, and
      // the hoster's settings file (fetched for the hoster's base domain)
      // names the hoster's servers, which are then not "outside".
      final hosterXml = providerXml().replaceAll(
        '%EMAILDOMAIN%',
        'privateemail.example',
      );
      final fetcher = _FakeFetcher({
        'https://autoconfig.privateemail.example/mail/config-v1.1.xml?emailaddress=me%40shop.co.uk':
            hosterXml,
      });
      final result = await AccountDiscovery(
        fetcher: fetcher,
        srv: const NoSrvResolver(),
        mx: _FakeMx({
          'shop.co.uk': [
            const MxRecord(20, 'mx2.privateemail.example.'),
            const MxRecord(10, 'mx1.privateemail.example.'),
          ],
        }),
        prober: _FakeProber(),
      ).discover('me@shop.co.uk');
      final s = result.settings!;
      expect(s.source, DiscoverySource.httpsAutoconfig);
      expect(s.imap.host, 'imap.privateemail.example');
      expect(s.smtp.host, 'smtp.privateemail.example');
      expect(s.mailHostDomain, 'privateemail.example');
      expect(s.warnings, isEmpty, reason: 'the MX names that host');
      expect(s.needsConfirmation, isFalse);
    });

    test('the mail host\'s base domain follows the public suffix list', () {
      expect(
        AccountDiscovery.mailHostDomain('shop.co.uk', [
          const MxRecord(10, 'mx.mailhost.co.uk.'),
        ]),
        'mailhost.co.uk',
        reason: 'co.uk is a suffix, not a domain',
      );
      expect(
        AccountDiscovery.mailHostDomain('shop.co.uk', [
          const MxRecord(10, 'mail.shop.co.uk'),
        ]),
        isNull,
        reason: 'handled within the domain itself',
      );
      expect(
        AccountDiscovery.mailHostDomain('x.example', [
          const MxRecord(10, 'MX1.PrivateEmail.Example.'),
        ]),
        'privateemail.example',
      );
      expect(AccountDiscovery.mailHostDomain('x.example', const []), isNull);
    });

    test('Mozilla is asked before DNS, once, and only with consent', () async {
      final fetcher = _FakeFetcher({
        'https://autoconfig.thunderbird.net/v1.1/privateemail.example':
            providerXml().replaceAll('%EMAILDOMAIN%', 'privateemail.example'),
      });
      final mx = _FakeMx({
        'shop.co.uk': [const MxRecord(10, 'mx1.privateemail.example.')],
      });
      var asked = 0;
      final declined =
          await AccountDiscovery(
            fetcher: fetcher,
            srv: const NoSrvResolver(),
            mx: mx,
            prober: _FakeProber(),
          ).discover(
            'me@shop.co.uk',
            askMozillaConsent: (d) async {
              asked++;
              return false;
            },
          );
      expect(declined.settings, isNull);
      expect(asked, 1, reason: 'not asked again for the mail host');
      expect(
        fetcher.requested.any((u) => u.host == 'autoconfig.thunderbird.net'),
        isFalse,
      );

      fetcher.requested.clear();
      String? askedFor;
      final allowed =
          await AccountDiscovery(
            fetcher: fetcher,
            srv: const NoSrvResolver(),
            mx: mx,
            prober: _FakeProber(),
          ).discover(
            'me@shop.co.uk',
            askMozillaConsent: (d) async {
              askedFor = d;
              return true;
            },
          );
      expect(askedFor, 'shop.co.uk');
      expect(allowed.settings!.source, DiscoverySource.mozillaDatabase);
      expect(allowed.settings!.imap.host, 'imap.privateemail.example');
      expect(allowed.settings!.warnings, isEmpty);
      // Mozilla saw the domains only.
      for (final uri in fetcher.requested.where(
        (u) => u.host == 'autoconfig.thunderbird.net',
      )) {
        expect(uri.query, isEmpty);
        expect(uri.path, isNot(contains('@')));
      }
    });

    test('rejects addresses it cannot handle', () {
      final discovery = AccountDiscovery(
        fetcher: _FakeFetcher({}),
        srv: const NoSrvResolver(),
        prober: _FakeProber(),
      );
      for (final bad in ['nope', 'a@b', 'a@exa mple.com', 'a@café.example']) {
        expect(() => discovery.discover(bad), throwsArgumentError, reason: bad);
      }
    });
  });

  test(
    'VerificationResult suggests a concrete certificate name, never a wildcard',
    () {
      VerificationResult mismatch(String cn) => VerificationResult.failure(
        ServerRole.imap,
        VerificationProblem.certificate,
        'x',
        tlsFailure: TlsFailure.hostnameMismatch,
        certificate: RejectedCertificate(
          subject: '/CN=$cn',
          issuer: '',
          validFrom: DateTime(2026),
          validUntil: DateTime(2027),
        ),
      );
      expect(
        mismatch('business905.web-hosting.com').suggestedHost,
        'business905.web-hosting.com',
      );
      expect(mismatch('*.web-hosting.com').suggestedHost, isNull);
    },
  );
}

final class _FakeFetcher implements SettingsFetcher {
  _FakeFetcher(this.files);

  /// Files by URL (the URL as requested, query included).
  final Map<String, String> files;
  final requested = <Uri>[];

  @override
  Future<String?> fetch(Uri uri) async {
    requested.add(uri);
    return files[uri.toString()];
  }
}

final class _FakeMx implements MxResolver {
  _FakeMx(this.records);

  final Map<String, List<MxRecord>> records;

  @override
  Future<List<MxRecord>> lookupMx(String domain) async =>
      records[domain] ?? const [];
}

final class _FakeProber implements ServerAvailability {
  _FakeProber({this.available = const {}});

  final Set<String> available;

  @override
  Future<bool> imapAvailable(ServerCandidate c) async =>
      available.contains(c.host) &&
      c.security == ConnectionSecurity.implicitTls;

  @override
  Future<bool> smtpAvailable(ServerCandidate c) async =>
      available.contains(c.host) &&
      c.security == ConnectionSecurity.implicitTls;
}
