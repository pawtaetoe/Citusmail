// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Verification and probing against the local test servers:
//   test-server/citusmailtest up
//   CITUSMAIL_INTEGRATION=1 dart test test/integration

import 'dart:io';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_setup/mail_setup.dart';
import 'package:test/test.dart';

void main() {
  if (Platform.environment['CITUSMAIL_INTEGRATION'] != '1') {
    test(
      'needs the local test servers',
      () {},
      skip:
          'run test-server/citusmailtest up, then set CITUSMAIL_INTEGRATION=1',
    );
    return;
  }

  final ports = <String, int>{
    for (final line in File('../../test-server/servers.env').readAsLinesSync())
      if (RegExp(r'^([A-Z_]+_PORT)=(\d+)$').firstMatch(line.trim())
          case final m?)
        m.group(1)!: int.parse(m.group(2)!),
  };
  final tls = TlsSettings.trustOnly(
    File('../../test-server/.generated/certs/ca.crt').readAsBytesSync(),
  );
  ServerEndpoint local(ServerCandidate c) =>
      ServerEndpoint(c.host, c.port, c.security, connectAddress: '127.0.0.1');
  final verifier = AccountVerifier(tls: tls, resolve: local);
  final prober = ServerProber(
    tls: tls,
    resolve: local,
    timeout: const Duration(seconds: 3),
  );

  DiscoveredSettings settings({
    String host = 'mail.citusmail.test',
    String imapPort = 'SECURE_IMAPS_PORT',
    ConnectionSecurity imapSecurity = ConnectionSecurity.implicitTls,
    String smtpPort = 'SECURE_SUBMISSIONS_PORT',
  }) => DiscoveredSettings(
    email: 'alice@citusmail.test',
    username: 'alice@citusmail.test',
    imap: ServerCandidate(host, ports[imapPort]!, imapSecurity),
    smtp: ServerCandidate(
      host,
      ports[smtpPort]!,
      ConnectionSecurity.implicitTls,
    ),
    source: DiscoverySource.manual,
  );

  test('correct settings and password verify', () async {
    expect(
      (await verifier.verify(settings(), 'alice-test-password')).succeeded,
      isTrue,
    );
  });

  test('STARTTLS settings verify too', () async {
    final result = await verifier.verify(
      settings(
        imapPort: 'SECURE_IMAP_PORT',
        imapSecurity: ConnectionSecurity.startTls,
      ),
      'alice-test-password',
    );
    expect(result.succeeded, isTrue);
  });

  test('a wrong password is a credentials problem on IMAP', () async {
    final result = await verifier.verify(settings(), 'wrong');
    expect(result.problem, VerificationProblem.credentials);
    expect(result.role, ServerRole.imap);
  });

  test('a server without encryption is a security problem', () async {
    final result = await verifier.verify(
      settings(
        imapPort: 'PLAIN_IMAP_PORT',
        imapSecurity: ConnectionSecurity.startTls,
      ),
      'alice-test-password',
    );
    expect(result.problem, VerificationProblem.security);
  });

  test('certificate problems carry what the server presented', () async {
    final mismatch = await verifier.verify(
      settings(host: 'other.citusmail.test'),
      'alice-test-password',
    );
    expect(mismatch.problem, VerificationProblem.certificate);
    expect(mismatch.tlsFailure, TlsFailure.hostnameMismatch);
    expect(mismatch.suggestedHost, 'mail.citusmail.test');

    final expired = await verifier.verify(
      settings(host: 'expired.citusmail.test'),
      'alice-test-password',
    );
    expect(expired.tlsFailure, TlsFailure.expired);
    expect(expired.certificate!.validUntil.year, 2021);

    final untrusted = await verifier.verify(
      settings(host: 'untrusted.citusmail.test'),
      'alice-test-password',
    );
    expect(untrusted.tlsFailure, TlsFailure.untrusted);
  });

  test('the prober accepts only servers with valid certificates, and logs in nowhere', () async {
    expect(
      await prober.imapAvailable(
        ServerCandidate(
          'mail.citusmail.test',
          ports['SECURE_IMAPS_PORT']!,
          ConnectionSecurity.implicitTls,
        ),
      ),
      isTrue,
    );
    expect(
      await prober.smtpAvailable(
        ServerCandidate(
          'mail.citusmail.test',
          ports['SECURE_SUBMISSION_PORT']!,
          ConnectionSecurity.startTls,
        ),
      ),
      isTrue,
    );
    expect(
      await prober.imapAvailable(
        ServerCandidate(
          'expired.citusmail.test',
          ports['SECURE_IMAPS_PORT']!,
          ConnectionSecurity.implicitTls,
        ),
      ),
      isFalse,
    );
    expect(
      await prober.imapAvailable(
        ServerCandidate(
          'mail.citusmail.test',
          ports['PLAIN_IMAP_PORT']!,
          ConnectionSecurity.startTls,
        ),
      ),
      isFalse,
    );
  });
}
