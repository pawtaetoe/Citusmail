// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';

/// Where and how to reach one server. Validated on construction.
final class ServerSettings {
  ServerSettings({
    required this.host,
    required this.port,
    required this.security,
  }) {
    if (!_hostname.hasMatch(host) || host.length > 253) {
      throw ArgumentError.value(host, 'host', 'not a valid host name');
    }
    if (port < 1 || port > 65535) {
      throw ArgumentError.value(port, 'port', 'not a valid port');
    }
  }

  static final _hostname = RegExp(
    r'^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$',
  );

  final String host;
  final int port;
  final ConnectionSecurity security;

  ServerEndpoint get endpoint => ServerEndpoint(host, port, security);

  @override
  bool operator ==(Object other) =>
      other is ServerSettings &&
      other.host == host &&
      other.port == port &&
      other.security == security;

  @override
  int get hashCode => Object.hash(host, port, security);
}

/// What is needed to add an account. The password goes to the keychain,
/// never here.
final class NewAccount {
  NewAccount({
    required this.email,
    required this.username,
    required this.imap,
    required this.smtp,
    this.displayName,
    this.oauthProvider,
  }) {
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      throw ArgumentError.value(email, 'email', 'not an email address');
    }
    if (username.isEmpty) {
      throw ArgumentError.value(username, 'username', 'must not be empty');
    }
  }

  final String email;
  final String? displayName;

  /// Login name; usually the email address.
  final String username;
  final ServerSettings imap;
  final ServerSettings smtp;

  /// The OAuth provider it signs in with (`microsoft`), or null for a
  /// password.
  final String? oauthProvider;
}

/// A stored account.
final class Account {
  const Account({
    required this.id,
    required this.email,
    required this.username,
    required this.imap,
    required this.smtp,
    required this.sortOrder,
    required this.createdAt,
    this.displayName,
    this.oauthProvider,
  });

  final int id;
  final String email;
  final String? displayName;
  final String username;
  final ServerSettings imap;
  final ServerSettings smtp;
  final int sortOrder;
  final DateTime createdAt;

  /// The OAuth provider it signs in with (`microsoft`), or null when it
  /// uses a password.
  final String? oauthProvider;

  bool get usesOAuth => oauthProvider != null;

  /// Name of this account's keychain entry: its password, or its OAuth
  /// tokens.
  String get keychainKey => 'account-$id';

  @override
  String toString() => 'Account($id, $email)';
}
