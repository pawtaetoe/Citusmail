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

/// The most each text of a transfer may hold. Nothing in a message is
/// trusted: a text that is too long, of the wrong type or with line
/// breaks where none belong makes the whole message unreadable.
abstract final class TransferLimits {
  static const host = 253;
  static const email = 320;
  static const name = 200;
  static const password = 4096;
  static const provider = 32;
  static const tokens = 64 * 1024;
  static const client = 1024;
  static const ownClients = 8;
  static const ownClient = 4096;
  static const syncCode = 256;
  static const detail = 2000;
}

/// [json]'s text at [key], at most [max] characters long; null when
/// missing and [optional]. With [oneLine], control characters make it
/// unreadable. Throws [PairingFormatException] with [what].
String? _text(
  Map<Object?, Object?> json,
  String key,
  int max,
  String what, {
  bool optional = false,
  bool oneLine = true,
}) {
  final value = json[key];
  if (value == null && optional) return null;
  if (value is! String ||
      value.length > max ||
      (oneLine && value.contains(RegExp(r'[\x00-\x1F\x7F]')))) {
    throw PairingFormatException(what);
  }
  return value;
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
    if (json is! Map) throw const PairingFormatException('bad server');
    final host = _text(json, 'host', TransferLimits.host, 'bad server')!;
    final port = json['port'];
    if (host.isEmpty ||
        host.contains(' ') ||
        port is! int ||
        port < 1 ||
        port > 65535) {
      throw const PairingFormatException('bad server');
    }
    final security = json['security'];
    if (security != 'tls' && security != 'starttls') {
      throw const PairingFormatException('bad server security');
    }
    return TransferredServer(host, port, security as String);
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
    if (json is! Map) throw const PairingFormatException('bad account');
    const bad = 'bad account';
    final email = _text(json, 'email', TransferLimits.email, bad)!;
    final username = _text(json, 'username', TransferLimits.email, bad)!;
    final name = _text(json, 'name', TransferLimits.name, bad, optional: true);
    final TransferredSignIn signIn;
    final password = json['password'];
    final oauth = json['oauth'];
    const badSignIn = 'bad sign-in';
    if (password != null && oauth == null) {
      signIn = PasswordSignIn(
        // Passwords are taken as they are, whatever they hold.
        _text(
          json,
          'password',
          TransferLimits.password,
          badSignIn,
          oneLine: false,
        )!,
      );
    } else if (oauth is Map && password == null) {
      signIn = OAuthSignIn(
        _text(oauth, 'provider', TransferLimits.provider, badSignIn)!,
        tokens: _text(
          oauth,
          'tokens',
          TransferLimits.tokens,
          badSignIn,
          optional: true,
          oneLine: false,
        ),
        client: _text(
          oauth,
          'client',
          TransferLimits.client,
          badSignIn,
          optional: true,
        ),
      );
    } else {
      throw const PairingFormatException(badSignIn);
    }
    return TransferredAccount(
      email: email,
      displayName: name,
      username: username,
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
    if (clients is! Map ||
        clients.length > TransferLimits.ownClients ||
        clients.keys.any(
          (k) => k is! String || k.length > TransferLimits.provider,
        ) ||
        clients.values.any(
          (v) => v is! String || v.length > TransferLimits.ownClient,
        )) {
      throw const PairingFormatException('bad clients');
    }
    final sync = json['sync'];
    if (sync != null && sync is! Map) {
      throw const PairingFormatException('bad sync');
    }
    final syncCode = sync == null
        ? null
        : _text(sync as Map, 'code', TransferLimits.syncCode, 'bad sync');
    final syncAccount = sync == null
        ? null
        : _text(
            sync as Map,
            'account',
            TransferLimits.email,
            'bad sync',
            optional: true,
          );
    return AccountTransfer(
      accounts: [for (final a in list) TransferredAccount.fromJson(a)],
      ownClients: {
        for (final e in clients.entries) '${e.key}': e.value as String,
      },
      syncCode: syncCode,
      syncAccount: syncAccount,
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
    if (json is! Map) throw const PairingFormatException('bad result');
    const bad = 'bad result';
    final email = _text(json, 'email', TransferLimits.email, bad)!;
    final detail = _text(
      json,
      'detail',
      TransferLimits.detail,
      bad,
      optional: true,
      oneLine: false,
    );
    final outcome = TransferOutcome.values
        .where((o) => o.name == json['outcome'])
        .firstOrNull;
    if (outcome == null) throw const PairingFormatException('bad outcome');
    return TransferResult(email, outcome, detail: detail);
  }
}
