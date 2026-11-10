// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// A message from the other device that doesn't follow the protocol.
final class PairingFormatException implements Exception {
  const PairingFormatException(this.message);

  final String message;

  @override
  String toString() => 'PairingFormatException: $message';
}

/// One server of an account. [security] is `tls` (TLS from the start) or
/// `starttls`.
final class TransferredServer {
  const TransferredServer(this.host, this.port, this.security);

  final String host;
  final int port;
  final String security;

  Map<String, Object?> toJson() => {
    'host': host,
    'port': port,
    'security': security,
  };

  static TransferredServer fromJson(Object? json) {
    if (json is! Map ||
        json['host'] is! String ||
        json['port'] is! int ||
        json['security'] is! String) {
      throw const PairingFormatException('bad server');
    }
    final security = json['security'] as String;
    if (security != 'tls' && security != 'starttls') {
      throw const PairingFormatException('bad server security');
    }
    return TransferredServer(
      json['host'] as String,
      json['port'] as int,
      security,
    );
  }
}

/// How an account signs in, as sent.
sealed class TransferredSignIn {
  const TransferredSignIn();
}

/// With a password (or an app password).
final class PasswordSignIn extends TransferredSignIn {
  const PasswordSignIn(this.password);

  final String password;
}

/// With an OAuth provider. [tokens] are the phone's stored tokens (their
/// JSON, opaque here), or null when they can't be used on the computer:
/// it then signs in with the provider itself.
final class OAuthSignIn extends TransferredSignIn {
  const OAuthSignIn(this.provider, {this.tokens, this.client});

  /// `google` or `microsoft`.
  final String provider;
  final String? tokens;

  /// The OAuth client id the tokens were issued to: a refresh token only
  /// works with that client, so the computer keeps them only if it renews
  /// with the same one.
  final String? client;
}

/// Everything needed to add one account without typing anything.
final class TransferredAccount {
  const TransferredAccount({
    required this.email,
    required this.username,
    required this.imap,
    required this.smtp,
    required this.signIn,
    this.displayName,
  });

  final String email;
  final String? displayName;
  final String username;
  final TransferredServer imap;
  final TransferredServer smtp;
  final TransferredSignIn signIn;

  Map<String, Object?> toJson() => {
    'email': email,
    'name': ?displayName,
    'username': username,
    'imap': imap.toJson(),
    'smtp': smtp.toJson(),
    ...switch (signIn) {
      PasswordSignIn(:final password) => {'password': password},
      OAuthSignIn(:final provider, :final tokens, :final client) => {
        'oauth': {'provider': provider, 'tokens': ?tokens, 'client': ?client},
      },
    },
  };

  static TransferredAccount fromJson(Object? json) {
    if (json is! Map ||
        json['email'] is! String ||
        json['username'] is! String ||
        (json['name'] != null && json['name'] is! String)) {
      throw const PairingFormatException('bad account');
    }
    final TransferredSignIn signIn;
    final password = json['password'];
    final oauth = json['oauth'];
    if (password is String && oauth == null) {
      signIn = PasswordSignIn(password);
    } else if (oauth is Map &&
        password == null &&
        oauth['provider'] is String &&
        (oauth['tokens'] == null || oauth['tokens'] is String) &&
        (oauth['client'] == null || oauth['client'] is String)) {
      signIn = OAuthSignIn(
        oauth['provider'] as String,
        tokens: oauth['tokens'] as String?,
        client: oauth['client'] as String?,
      );
    } else {
      throw const PairingFormatException('bad sign-in');
    }
    return TransferredAccount(
      email: json['email'] as String,
      displayName: json['name'] as String?,
      username: json['username'] as String,
      imap: TransferredServer.fromJson(json['imap']),
      smtp: TransferredServer.fromJson(json['smtp']),
      signIn: signIn,
    );
  }
}

/// What the phone sends: the chosen accounts, the user's own OAuth app
/// registrations (provider id to their JSON), and optionally the code of
/// "Sync between devices" with the account that carries it.
final class AccountTransfer {
  AccountTransfer({
    required List<TransferredAccount> accounts,
    Map<String, String> ownClients = const {},
    this.syncCode,
    this.syncAccount,
  }) : accounts = List.unmodifiable(accounts),
       ownClients = Map.unmodifiable(ownClients) {
    if (this.accounts.length > maxAccounts) {
      throw ArgumentError('too many accounts');
    }
  }

  static const maxAccounts = 50;

  final List<TransferredAccount> accounts;
  final Map<String, String> ownClients;
  final String? syncCode;

  /// The email of the account whose mailbox carries the synced data.
  final String? syncAccount;

  Map<String, Object?> toJson() => {
    'accounts': [for (final a in accounts) a.toJson()],
    if (ownClients.isNotEmpty) 'clients': ownClients,
    if (syncCode case final code?)
      'sync': {'code': code, 'account': ?syncAccount},
  };

  static AccountTransfer fromJson(Object? json) {
    if (json is! Map || json['accounts'] is! List) {
      throw const PairingFormatException('bad transfer');
    }
    final list = json['accounts'] as List;
    if (list.length > maxAccounts) {
      throw const PairingFormatException('too many accounts');
    }
    final clients = json['clients'] ?? const <String, Object?>{};
    if (clients is! Map || clients.values.any((v) => v is! String)) {
      throw const PairingFormatException('bad clients');
    }
    final sync = json['sync'];
    if (sync != null &&
        (sync is! Map ||
            sync['code'] is! String ||
            (sync['account'] != null && sync['account'] is! String))) {
      throw const PairingFormatException('bad sync');
    }
    return AccountTransfer(
      accounts: [for (final a in list) TransferredAccount.fromJson(a)],
      ownClients: {
        for (final e in clients.entries) '${e.key}': e.value as String,
      },
      syncCode: (sync as Map?)?['code'] as String?,
      syncAccount: sync?['account'] as String?,
    );
  }
}

/// What happened to one account on the computer.
enum TransferOutcome {
  /// Added and checked with a real sign-in.
  added,

  /// The computer has it already (same address and server).
  alreadyThere,

  /// The computer must sign in with the provider itself.
  signInOnComputer,

  /// Couldn't be added (see the detail).
  failed,
}

final class TransferResult {
  const TransferResult(this.email, this.outcome, {this.detail});

  final String email;
  final TransferOutcome outcome;

  /// Why it failed, in words for the user.
  final String? detail;

  Map<String, Object?> toJson() => {
    'email': email,
    'outcome': outcome.name,
    'detail': ?detail,
  };

  static TransferResult fromJson(Object? json) {
    if (json is! Map ||
        json['email'] is! String ||
        json['outcome'] is! String ||
        (json['detail'] != null && json['detail'] is! String)) {
      throw const PairingFormatException('bad result');
    }
    final outcome = TransferOutcome.values
        .where((o) => o.name == json['outcome'])
        .firstOrNull;
    if (outcome == null) throw const PairingFormatException('bad outcome');
    return TransferResult(
      json['email'] as String,
      outcome,
      detail: json['detail'] as String?,
    );
  }
}
