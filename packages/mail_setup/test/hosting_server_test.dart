// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_setup/mail_setup.dart';
import 'package:test/test.dart';

/// [name] as DNS labels.
List<int> labels(String name) => [
  for (final label in name.split('.')) ...[label.length, ...label.codeUnits],
  0,
];

/// A reply to query [id] for [name] of [type], with [records] as
/// (type, data) answers whose owner points back at the question.
Uint8List reply(
  int id,
  String name,
  int type,
  List<(int, List<int>)> records, {
  int rcode = 0,
}) => Uint8List.fromList([
  id >> 8, id & 0xFF, 0x81, 0x80 | rcode, //
  0, 1, 0, records.length, 0, 0, 0, 0,
  ...labels(name), 0, type, 0, 1,
  for (final (rtype, data) in records) ...[
    0xC0, 12, 0, rtype, 0, 1, 0, 0, 0x0E, 0x10, //
    data.length >> 8, data.length & 0xFF, ...data,
  ],
]);

/// What Namecheap's shared hosting presents for every customer domain.
RejectedCertificate webHosting({List<String> dns = const []}) =>
    RejectedCertificate(
      subject: '/CN=*.web-hosting.com',
      issuer: '/C=GB/O=Sectigo Limited/CN=Sectigo RSA Domain Validation',
      validFrom: DateTime.utc(2026, 3),
      validUntil: DateTime.utc(2027, 3),
      dnsNames: dns,
    );

VerificationResult mismatch(
  RejectedCertificate certificate, {
  ServerRole role = ServerRole.imap,
}) => VerificationResult.failure(
  role,
  VerificationProblem.certificate,
  'TLS with mail.tommykung.cc failed: Hostname mismatch',
  tlsFailure: TlsFailure.hostnameMismatch,
  certificate: certificate,
);

DiscoveredSettings settings({
  String imap = 'mail.tommykung.cc',
  String smtp = 'mail.tommykung.cc',
}) => DiscoveredSettings(
  email: 'me@tommykung.cc',
  imap: ServerCandidate(imap, 993, ConnectionSecurity.implicitTls),
  smtp: ServerCandidate(smtp, 465, ConnectionSecurity.implicitTls),
  username: 'me@tommykung.cc',
  source: DiscoverySource.manual,
);

final namecheap = InternetAddress('209.74.67.125');

void main() {
  group('DnsMessage PTR and addresses', () {
    test('the reverse name of an address', () {
      expect(DnsMessage.reverseName(namecheap), '125.67.74.209.in-addr.arpa');
      expect(
        DnsMessage.reverseName(InternetAddress('2001:db8::567:89ab')),
        'b.a.9.8.7.6.5.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2'
        '.ip6.arpa',
      );
      // A query for it can be built.
      final query = DnsMessage.query(
        0x4242,
        DnsMessage.reverseName(namecheap),
        12,
      );
      expect(query.sublist(12, query.length - 4), [
        ...labels('125.67.74.209.in-addr.arpa'),
      ]);
      expect(query.sublist(query.length - 4), [0, 12, 0, 1]);
    });

    test('parses a PTR answer', () {
      const name = '125.67.74.209.in-addr.arpa';
      final data = reply(0x4242, name, 12, [
        (12, labels('business905-5.Web-Hosting.com')),
      ]);
      expect(DnsMessage.parsePtrAnswer(data, 0x4242, name), [
        'business905-5.web-hosting.com',
      ]);
      // Not ours, or for another address: rejected.
      expect(
        () => DnsMessage.parsePtrAnswer(data, 0x4243, name),
        throwsFormatException,
      );
      expect(
        () => DnsMessage.parsePtrAnswer(
          data,
          0x4242,
          '126.67.74.209.in-addr.arpa',
        ),
        throwsFormatException,
      );
      // No PTR record.
      expect(
        DnsMessage.parsePtrAnswer(
          reply(0x4242, name, 12, [], rcode: 3),
          0x4242,
          name,
        ),
        isEmpty,
      );
    });

    test('parses A and AAAA answers, after a CNAME', () {
      final data = reply(7, 'mail.tommykung.cc', 1, [
        (5, labels('tommykung.cc')), // CNAME
        (1, [209, 74, 67, 125]),
        (1, [1, 2, 3]), // malformed: skipped
      ]);
      expect(DnsMessage.parseAddressAnswer(data, 7, 'mail.tommykung.cc'), [
        namecheap,
      ]);
      final v6 = reply(8, 'mail.tommykung.cc', 28, [
        (28, InternetAddress('2001:db8::1').rawAddress),
      ]);
      expect(DnsMessage.parseAddressAnswer(v6, 8, 'mail.tommykung.cc'), [
        InternetAddress('2001:db8::1'),
      ]);
    });
  });

  group('HostingServerFinder', () {
    late _FakeResolver resolver;
    late _FakeProber prober;
    HostingServerFinder finder() =>
        HostingServerFinder(resolver: resolver, prober: prober);

    setUp(() {
      resolver = _FakeResolver(
        addresses: {
          'mail.tommykung.cc': [namecheap],
        },
        ptr: {
          namecheap: ['business905-5.web-hosting.com.'],
        },
      );
      prober = _FakeProber({'business905-5.web-hosting.com'});
    });

    test('offers the server\'s own name when the certificate covers it '
        'and it passes the check', () async {
      final name = await finder().find(settings(), mismatch(webHosting()));
      expect(name, 'business905-5.web-hosting.com');
      // Checked for both servers, since both move, at their own ports;
      // nothing else was connected to.
      expect(prober.checked, [
        ('imap', 'business905-5.web-hosting.com', 993),
        ('smtp', 'business905-5.web-hosting.com', 465),
      ]);
    });

    test('also with the names in the subject alternative names', () async {
      final name = await finder().find(
        settings(),
        mismatch(webHosting(dns: ['web-hosting.com', '*.web-hosting.com'])),
      );
      expect(name, 'business905-5.web-hosting.com');
    });

    test('for the outgoing server only, when only it fails', () async {
      resolver.addresses['smtp.tommykung.cc'] = [namecheap];
      final name = await finder().find(
        settings(imap: 'imap.provider.example', smtp: 'smtp.tommykung.cc'),
        mismatch(webHosting(), role: ServerRole.smtp),
      );
      expect(name, 'business905-5.web-hosting.com');
      expect(prober.checked, [('smtp', 'business905-5.web-hosting.com', 465)]);
    });

    test('nothing when the certificate doesn\'t cover the name', () async {
      resolver.ptr[namecheap] = ['server.other-host.example'];
      prober.available.add('server.other-host.example');
      expect(await finder().find(settings(), mismatch(webHosting())), isNull);
      // Two labels deep is not covered by the wildcard either.
      resolver.ptr[namecheap] = ['a.b.web-hosting.com'];
      prober.available.add('a.b.web-hosting.com');
      expect(await finder().find(settings(), mismatch(webHosting())), isNull);
      expect(prober.checked, isEmpty);
    });

    test('nothing when the name fails its own check', () async {
      prober.available.clear();
      expect(await finder().find(settings(), mismatch(webHosting())), isNull);
      expect(prober.checked, hasLength(1));
    });

    test(
      'nothing when the other server, which would move too, fails',
      () async {
        prober.smtpFails = true;
        expect(await finder().find(settings(), mismatch(webHosting())), isNull);
      },
    );

    test('nothing without a PTR record or an address', () async {
      resolver.ptr.clear();
      expect(await finder().find(settings(), mismatch(webHosting())), isNull);
      resolver.addresses.clear();
      expect(await finder().find(settings(), mismatch(webHosting())), isNull);
    });

    test('only for a host name mismatch with a certificate', () async {
      final expired = VerificationResult.failure(
        ServerRole.imap,
        VerificationProblem.certificate,
        'expired',
        tlsFailure: TlsFailure.expired,
        certificate: webHosting(),
      );
      expect(await finder().find(settings(), expired), isNull);
      const noCertificate = VerificationResult.failure(
        ServerRole.imap,
        VerificationProblem.certificate,
        'mismatch',
        tlsFailure: TlsFailure.hostnameMismatch,
      );
      expect(await finder().find(settings(), noCertificate), isNull);
      expect(resolver.looked, isEmpty);
    });

    test('a malformed name from DNS is ignored', () async {
      resolver.ptr[namecheap] = ['bad name.web-hosting.com'];
      prober.available.add('bad name.web-hosting.com');
      expect(await finder().find(settings(), mismatch(webHosting())), isNull);
    });
  });
}

final class _FakeResolver implements HostNameResolver {
  _FakeResolver({required this.addresses, required this.ptr});

  final Map<String, List<InternetAddress>> addresses;
  final Map<InternetAddress, List<String>> ptr;
  final looked = <String>[];

  @override
  Future<List<InternetAddress>> lookupAddresses(String host) async {
    looked.add(host);
    return addresses[host] ?? const [];
  }

  @override
  Future<List<String>> lookupPtr(InternetAddress address) async {
    looked.add(address.address);
    return ptr[address] ?? const [];
  }
}

final class _FakeProber implements ServerAvailability {
  _FakeProber(this.available);

  final Set<String> available;
  bool smtpFails = false;
  final checked = <(String, String, int)>[];

  @override
  Future<bool> imapAvailable(ServerCandidate c) async {
    checked.add(('imap', c.host, c.port));
    return available.contains(c.host);
  }

  @override
  Future<bool> smtpAvailable(ServerCandidate c) async {
    checked.add(('smtp', c.host, c.port));
    return !smtpFails && available.contains(c.host);
  }
}
