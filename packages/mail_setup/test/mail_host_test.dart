// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:mail_setup/mail_setup.dart';
import 'package:test/test.dart';

/// A DNS reply to query 0x4242 for "example.com" MX, with the given
/// records (preference, exchange labels).
Uint8List _mxReply(List<(int, List<String>)> records, {int flags = 0x8180}) {
  List<int> name(List<String> labels) => [
    for (final l in labels) ...[l.length, ...l.codeUnits],
    0,
  ];
  final out = BytesBuilder()
    ..add([0x42, 0x42, flags >> 8, flags & 0xFF, 0, 1, 0, records.length])
    ..add([0, 0, 0, 0])
    // Question at offset 12: example.com MX IN.
    ..add(name(['example', 'com']))
    ..add([0, 15, 0, 1]);
  for (final (preference, labels) in records) {
    final rdata = [preference >> 8, preference & 0xFF, ...name(labels)];
    out
      ..add([0xC0, 12]) // the question's name
      ..add([0, 15, 0, 1, 0, 0, 0x0E, 0x10])
      ..add([rdata.length >> 8, rdata.length & 0xFF])
      ..add(rdata);
  }
  return out.takeBytes();
}

final class _Dns implements SrvResolver, MxResolver {
  _Dns(this.mx);

  final List<MxRecord> mx;
  final asked = <String>[];

  @override
  Future<List<SrvRecord>> lookup(String name) async => const [];

  @override
  Future<List<MxRecord>> lookupMx(String domain) async {
    asked.add(domain);
    return mx;
  }
}

final class _Files implements SettingsFetcher {
  _Files([this.files = const {}]);

  final Map<String, String> files;

  @override
  Future<String?> fetch(Uri uri) async => files[uri.toString()];
}

final class _NoServers implements ServerAvailability {
  @override
  Future<bool> imapAvailable(ServerCandidate candidate) async => false;

  @override
  Future<bool> smtpAvailable(ServerCandidate candidate) async => false;
}

void main() {
  test('MX answers are parsed; a null MX is left out', () {
    final records = DnsMessage.parseMxAnswer(
      _mxReply([
        (10, ['alt1', 'aspmx', 'l', 'google', 'com']),
        (1, ['ASPMX', 'L', 'Google', 'com']),
        (0, []),
      ]),
      0x4242,
      'example.com',
    );
    expect(records.map((r) => (r.preference, r.exchange)), [
      (10, 'alt1.aspmx.l.google.com'),
      (1, 'aspmx.l.google.com'),
    ]);
    expect(
      DnsMessage.parseMxAnswer(
        _mxReply([], flags: 0x8183),
        0x4242,
        'example.com',
      ),
      isEmpty,
      reason: 'NXDOMAIN',
    );
    expect(
      () => DnsMessage.parseMxAnswer(_mxReply([]), 0x4242, 'other.com'),
      throwsFormatException,
    );
  });

  test('the host is read from the most preferred records', () {
    MailHost? host(List<(int, String)> mx) =>
        MailHost.fromMx([for (final (p, e) in mx) MxRecord(p, e)]);
    expect(
      host([(1, 'aspmx.l.google.com'), (5, 'alt1.aspmx.l.google.com')]),
      MailHost.google,
    );
    expect(host([(1, 'smtp.google.com')]), MailHost.google);
    expect(
      host([(0, 'contoso-com.mail.protection.outlook.com')]),
      MailHost.microsoft365,
    );
    expect(
      host([(0, 'contoso-com.l-v1.mx.microsoft.')]),
      MailHost.microsoft365,
    );
    // Own server first, Google only as backup: not hosted at Google.
    expect(host([(1, 'mx.example.com'), (10, 'aspmx.l.google.com')]), isNull);
    // Lookalikes and mixes are not.
    expect(host([(1, 'google.com.evil.example')]), isNull);
    expect(host([(1, 'notgoogle.com')]), isNull);
    expect(host([(1, 'aspmx.l.google.com'), (1, 'mx.example.com')]), isNull);
    expect(host([]), isNull);
  });

  group('discovery', () {
    test('a Google Workspace domain gets Gmail\'s servers', () async {
      final dns = _Dns(const [MxRecord(1, 'aspmx.l.google.com')]);
      final result = await AccountDiscovery(
        fetcher: _Files(),
        srv: dns,
        prober: _NoServers(),
      ).discover('ana@company.example');
      expect(dns.asked, ['company.example']);
      expect(result.host, MailHost.google);
      final s = result.settings!;
      expect(s.imap.host, 'imap.gmail.com');
      expect(s.smtp.host, 'smtp.gmail.com');
      expect(s.username, 'ana@company.example');
      expect(s.source, DiscoverySource.mailHost);
      expect(s.needsConfirmation, isFalse);
      expect(KnownProvider.forImapHost(s.imap.host)?.needsAppPassword, isTrue);
    });

    test('a Microsoft 365 domain gets no settings: it signs in', () async {
      final result = await AccountDiscovery(
        fetcher: _Files(),
        srv: _Dns(const [
          MxRecord(0, 'company-example.mail.protection.outlook.com'),
        ]),
        prober: _NoServers(),
      ).discover('ana@company.example');
      expect(result.host, MailHost.microsoft365);
      expect(result.settings, isNull);
    });

    test('the provider\'s own settings file still comes first', () async {
      final dns = _Dns(const [MxRecord(1, 'aspmx.l.google.com')]);
      final result = await AccountDiscovery(
        fetcher: _Files({
          'https://autoconfig.company.example/mail/config-v1.1.xml': '''
<clientConfig version="1.1"><emailProvider id="x">
  <incomingServer type="imap"><hostname>imap.company.example</hostname><port>993</port><socketType>SSL</socketType><authentication>password-cleartext</authentication><username>%EMAILADDRESS%</username></incomingServer>
  <outgoingServer type="smtp"><hostname>smtp.company.example</hostname><port>465</port><socketType>SSL</socketType><authentication>password-cleartext</authentication></outgoingServer>
</emailProvider></clientConfig>''',
        }),
        srv: dns,
        prober: _NoServers(),
      ).discover('ana@company.example');
      expect(result.settings!.imap.host, 'imap.company.example');
      expect(dns.asked, isEmpty);
    });
  });
}
