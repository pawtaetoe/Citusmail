// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:mail_protocol/mail_protocol.dart';

/// The local test mail servers from test-server/ (see its README).
///
/// Integration tests run only when CITUSMAIL_INTEGRATION=1, after
/// `test-server/citusmailtest up`.
final class TestServers {
  TestServers._(this._ports, this.tls);

  static TestServers load() {
    final env = File('../../test-server/servers.env');
    final ports = <String, int>{};
    for (final line in env.readAsLinesSync()) {
      final match = RegExp(r'^([A-Z_]+_PORT)=(\d+)$').firstMatch(line.trim());
      if (match != null) ports[match.group(1)!] = int.parse(match.group(2)!);
    }
    final ca = File('../../test-server/.generated/certs/ca.crt');
    return TestServers._(ports, TlsSettings.trustOnly(ca.readAsBytesSync()));
  }

  /// Why integration tests are skipped, or null when they should run.
  static String? get skipReason =>
      Platform.environment['CITUSMAIL_INTEGRATION'] == '1'
      ? null
      : 'integration tests: run test-server/citusmailtest up, then set CITUSMAIL_INTEGRATION=1';

  final Map<String, int> _ports;

  /// Trusts only the local test CA.
  final TlsSettings tls;

  int port(String name) =>
      _ports[name] ?? (throw StateError('$name missing from servers.env'));

  /// An endpoint that connects to 127.0.0.1 but checks the certificate
  /// for [tlsName], exactly as a real connection would.
  ServerEndpoint endpoint(
    String portName,
    ConnectionSecurity security, {
    String tlsName = 'mail.citusmail.test',
  }) => ServerEndpoint(
    tlsName,
    port(portName),
    security,
    connectAddress: '127.0.0.1',
  );

  ServerEndpoint get secureImaps =>
      endpoint('SECURE_IMAPS_PORT', ConnectionSecurity.implicitTls);
  ServerEndpoint get secureImapStartTls =>
      endpoint('SECURE_IMAP_PORT', ConnectionSecurity.startTls);
  ServerEndpoint get limitedImaps =>
      endpoint('LIMITED_IMAPS_PORT', ConnectionSecurity.implicitTls);
  ServerEndpoint get plainImap =>
      endpoint('PLAIN_IMAP_PORT', ConnectionSecurity.startTls);
  ServerEndpoint get secureSubmissions =>
      endpoint('SECURE_SUBMISSIONS_PORT', ConnectionSecurity.implicitTls);
  ServerEndpoint get secureSubmission =>
      endpoint('SECURE_SUBMISSION_PORT', ConnectionSecurity.startTls);
  ServerEndpoint get plainSubmission =>
      endpoint('PLAIN_SUBMISSION_PORT', ConnectionSecurity.startTls);

  static String address(String user) => '$user@citusmail.test';
  static String password(String user) => '$user-test-password';

  /// A logged-in IMAP client for a test user.
  Future<ImapClient> imap(String user, {ServerEndpoint? endpoint}) async {
    final client = await ImapClient.connect(endpoint ?? secureImaps, tls: tls);
    await client.login(address(user), password(user));
    return client;
  }
}
