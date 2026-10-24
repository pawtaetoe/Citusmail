// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

/// Supplies an account's password. The app reads it from the platform
/// keychain; it is never stored anywhere else.
abstract interface class CredentialProvider {
  /// The secret an account logs in with: its password, or for an OAuth
  /// account a current access token (renewed by the provider as needed).
  Future<String> passwordFor(Account account);
}

/// Opens logged-in connections for an account.
abstract interface class MailConnector {
  /// A logged-in IMAP connection, with QRESYNC enabled when available.
  Future<ImapClient> imap(Account account);

  /// A logged-in SMTP connection.
  Future<SmtpClient> smtp(Account account);
}

/// Connects with the account's server settings and the system trust store.
final class DefaultMailConnector implements MailConnector {
  DefaultMailConnector(
    this._credentials, {
    this.tls = const TlsSettings(),
    this.useQresync = true,
    ServerEndpoint Function(ServerSettings settings)? endpointFor,
  }) : _endpointFor = endpointFor ?? ((s) => s.endpoint);

  final CredentialProvider _credentials;
  final TlsSettings tls;

  /// Turn off to use CONDSTORE only (tests; troubleshooting a server).
  final bool useQresync;

  /// Turns stored settings into an endpoint (tests point it at 127.0.0.1).
  final ServerEndpoint Function(ServerSettings settings) _endpointFor;

  @override
  Future<ImapClient> imap(Account account) async {
    final client = await ImapClient.connect(
      _endpointFor(account.imap),
      tls: tls,
    );
    try {
      final secret = await _credentials.passwordFor(account);
      if (account.usesOAuth) {
        await client.loginOAuth(account.username, secret);
      } else {
        await client.login(account.username, secret);
      }
      if (useQresync) await client.enable(['QRESYNC']);
      return client;
    } on Object {
      await client.close();
      rethrow;
    }
  }

  @override
  Future<SmtpClient> smtp(Account account) async {
    final client = await SmtpClient.connect(
      _endpointFor(account.smtp),
      tls: tls,
    );
    try {
      final secret = await _credentials.passwordFor(account);
      if (account.usesOAuth) {
        await client.authenticateOAuth(account.username, secret);
      } else {
        await client.authenticate(account.username, secret);
      }
      return client;
    } on Object {
      await client.close();
      rethrow;
    }
  }
}
