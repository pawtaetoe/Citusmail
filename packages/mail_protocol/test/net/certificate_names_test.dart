// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:test/test.dart';

/// One DER element (short or long length form).
List<int> tlv(int tag, List<int> content) => [
  tag,
  if (content.length < 0x80)
    content.length
  else ...[
    0x82,
    content.length >> 8,
    content.length & 0xFF,
  ],
  ...content,
];

List<int> seq(List<List<int>> items) =>
    tlv(0x30, [for (final i in items) ...i]);

/// The shape of a certificate, as far as the reader walks: the fields
/// before the extensions are placeholders, and nothing is signed.
Uint8List certificate({List<List<int>> extensions = const []}) {
  final tbs = seq([
    tlv(0xA0, tlv(0x02, [2])), // [0] version v3
    tlv(0x02, [1]), // serial
    seq([
      tlv(0x06, [0x2A]),
    ]), // algorithm
    seq([]), // issuer
    seq([]), // validity
    seq([]), // subject
    seq([]), // key
    if (extensions.isNotEmpty) tlv(0xA3, seq(extensions)),
  ]);
  return Uint8List.fromList(
    seq([
      tbs,
      seq([
        tlv(0x06, [0x2A]),
      ]),
      tlv(0x03, [0]),
    ]),
  );
}

List<int> san(List<List<int>> names) => seq([
  tlv(0x06, [0x55, 0x1D, 0x11]),
  tlv(0x04, seq(names)),
]);

List<int> dns(String name) => tlv(0x82, name.codeUnits);

void main() {
  group('CertificateNames.fromDer', () {
    test('reads the DNS names of the subject alternative names', () {
      final der = certificate(
        extensions: [
          seq([
            tlv(0x06, [0x55, 0x1D, 0x13]), // basic constraints
            tlv(0x01, [0xFF]), // critical
            tlv(0x04, seq([])),
          ]),
          san([
            dns('*.Web-Hosting.com'),
            tlv(0x87, [209, 74, 67, 125]), // an IP address: not a DNS name
            dns('web-hosting.com'),
          ]),
        ],
      );
      expect(CertificateNames.fromDer(der), [
        '*.web-hosting.com',
        'web-hosting.com',
      ]);
    });

    test('long lengths are read', () {
      final many = [for (var i = 0; i < 20; i++) dns('server$i.example.com')];
      final names = CertificateNames.fromDer(
        certificate(extensions: [san(many)]),
      );
      expect(names, hasLength(20));
      expect(names.last, 'server19.example.com');
    });

    test('no extension, or a broken certificate, gives no names', () {
      expect(CertificateNames.fromDer(certificate()), isEmpty);
      final der = certificate(
        extensions: [
          san([dns('a.example.com')]),
        ],
      );
      expect(
        CertificateNames.fromDer(Uint8List.sublistView(der, 0, 40)),
        isEmpty,
      );
      expect(CertificateNames.fromDer(Uint8List(0)), isEmpty);
      expect(
        CertificateNames.fromDer(Uint8List.fromList([0x30, 0x84])),
        isEmpty,
      );
    });

    // The certificates the local test servers use, when they are there.
    final crt = File('../../test-server/.generated/certs/mail.crt');
    test('a real certificate', () {
      final pem = crt.readAsStringSync();
      final body = pem.split('\n').where((l) => !l.startsWith('-----')).join();
      final der = Uint8List.fromList(base64Decode(body));
      expect(CertificateNames.fromDer(der), contains('mail.citusmail.test'));
    }, skip: crt.existsSync() ? false : 'no generated test certificates');
  });

  group('CertificateNames.covers', () {
    const wildcard = ['*.web-hosting.com'];

    test('a wildcard covers one whole left-most label', () {
      expect(
        CertificateNames.covers(wildcard, 'business905-5.web-hosting.com'),
        isTrue,
      );
      expect(
        CertificateNames.covers(wildcard, 'Business905-5.Web-Hosting.com.'),
        isTrue,
      );
    });

    test('but not two labels, the bare domain, or another domain', () {
      expect(CertificateNames.covers(wildcard, 'a.b.web-hosting.com'), isFalse);
      expect(CertificateNames.covers(wildcard, 'web-hosting.com'), isFalse);
      expect(CertificateNames.covers(wildcard, 'mail.tommykung.cc'), isFalse);
      expect(CertificateNames.covers(wildcard, 'evilweb-hosting.com'), isFalse);
      expect(
        CertificateNames.covers(wildcard, 'x.web-hosting.com.evil.example'),
        isFalse,
      );
    });

    test('exact names match exactly', () {
      const exact = ['server123.hostgator.com'];
      expect(CertificateNames.covers(exact, 'SERVER123.hostgator.com'), isTrue);
      expect(CertificateNames.covers(exact, 'server12.hostgator.com'), isFalse);
      expect(
        CertificateNames.covers(exact, 'x.server123.hostgator.com'),
        isFalse,
      );
    });

    test('partial and too-wide wildcards cover nothing', () {
      expect(
        CertificateNames.covers(['b*.example.com'], 'b1.example.com'),
        isFalse,
      );
      expect(CertificateNames.covers(['*.com'], 'example.com'), isFalse);
      expect(CertificateNames.covers(['*'], 'example'), isFalse);
      expect(
        CertificateNames.covers(['*.*.example.com'], 'a.b.example.com'),
        isFalse,
      );
    });

    test('IP addresses never match DNS names', () {
      expect(CertificateNames.covers(['*.67.125'], '209.74.67.125'), isFalse);
      expect(
        CertificateNames.covers(['209.74.67.125'], '209.74.67.125'),
        isFalse,
      );
    });
  });

  group('RejectedCertificate', () {
    RejectedCertificate cert(String subject, [List<String> dns = const []]) =>
        RejectedCertificate(
          subject: subject,
          issuer: '/CN=Sectigo',
          validFrom: DateTime.utc(2026),
          validUntil: DateTime.utc(2027),
          dnsNames: dns,
        );

    test('uses its DNS names, or its common name when it has none', () {
      final cn = cert('/CN=*.web-hosting.com');
      expect(cn.names, ['*.web-hosting.com']);
      expect(cn.covers('business905-5.web-hosting.com'), isTrue);

      final withSan = cert('/CN=web-hosting.com', [
        'web-hosting.com',
        '*.web-hosting.com',
      ]);
      expect(withSan.covers('business905-5.web-hosting.com'), isTrue);
      expect(withSan.covers('web-hosting.com'), isTrue);

      // The common name is ignored when there are DNS names.
      final other = cert('/CN=*.web-hosting.com', ['mail.example.com']);
      expect(other.covers('business905-5.web-hosting.com'), isFalse);

      expect(cert('/O=No Name').covers('a.example.com'), isFalse);
    });
  });
}
