// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_oauth/mail_oauth.dart';
import 'package:mail_pairing/mail_pairing.dart';
import 'package:mail_protocol/mail_protocol.dart' show ConnectionSecurity;
import 'package:mail_store/mail_store.dart';

import '../services/app_services.dart';
import '../services/secret_store.dart';

/// Whether an account's OAuth sign-in can be handed to a computer, or the
/// computer must sign in with the provider itself.
///
/// - Google gives one refresh token per client and keeps it when it is
///   used (no rotation), so two devices can share it, if the computer
///   renews with the same client: the user's own client (carried with the
///   tokens), or a build with the same built-in client id. Android and
///   desktop builds use the same Google "Desktop app" client (see
///   packaging/README.md), so tokens normally carry over.
/// - Microsoft replaces the refresh token on every renewal. Two devices
///   renewing one sign-in would retire each other's token and both would
///   be asked to sign in again, so its tokens are never sent: the
///   computer signs in itself.
bool tokensPortable(
  String providerId,
  OAuthTokens tokens, {
  Map<String, String>? computerClients,
}) {
  if (providerId != OAuthProvider.google.id) return false;
  if (tokens.registration != null) return true;
  // The file route doesn't know the computer's clients: it decides.
  if (computerClients == null) return true;
  final ours = OAuthProvider.google.clientId;
  return ours.isNotEmpty && computerClients[providerId] == ours;
}

/// The client id [tokens] of [provider] were issued to.
String? issuedTo(OAuthProvider? provider, OAuthTokens tokens) =>
    tokens.registration?.clientId ??
    (provider == null || !provider.configured ? null : provider.clientId);

/// This build's OAuth client ids, for the phone to compare.
Map<String, String> builtInClients() => {
  for (final p in OAuthProvider.all)
    if (p.configured) p.id: p.clientId,
};

/// Reads the chosen accounts with their sign-ins from the store and the
/// keychain, ready to send.
final class AccountExport {
  AccountExport(this._services);

  final AppServices _services;

  static String _security(ConnectionSecurity s) => switch (s) {
    ConnectionSecurity.implicitTls => 'tls',
    ConnectionSecurity.startTls => 'starttls',
  };

  static TransferredServer _server(ServerSettings s) =>
      TransferredServer(s.host, s.port, _security(s.security));

  /// The transfer for [accounts]. [computerClients] are the computer's
  /// client ids (null on the file route); [withSync] adds the code of
  /// Sync between devices, when it is on here.
  Future<AccountTransfer> build(
    List<Account> accounts, {
    Map<String, String>? computerClients,
    bool withSync = false,
  }) async {
    final secrets = _services.secrets;
    final out = <TransferredAccount>[];
    for (final account in accounts) {
      final stored = await secrets.read(account.keychainKey);
      final TransferredSignIn signIn;
      if (account.oauthProvider case final providerId?) {
        final tokens = OAuthTokens.fromJson(stored);
        final provider = OAuthProvider.byId(providerId);
        final portable =
            tokens != null &&
            tokensPortable(
              providerId,
              tokens,
              computerClients: computerClients,
            );
        signIn = OAuthSignIn(
          providerId,
          tokens: portable ? stored : null,
          client: portable ? issuedTo(provider, tokens) : null,
        );
      } else {
        if (stored == null || stored.isEmpty) continue;
        signIn = PasswordSignIn(stored);
      }
      out.add(
        TransferredAccount(
          email: account.email,
          displayName: account.displayName,
          username: account.username,
          imap: _server(account.imap),
          smtp: _server(account.smtp),
          signIn: signIn,
        ),
      );
    }
    final own = OwnOAuthClients(secrets);
    final clients = <String, String>{
      for (final p in OAuthProvider.all)
        if (await own.read(p.id) case final r?) p.id: r.toJson(),
    };
    final code = withSync ? await _services.deviceSync.code() : null;
    return AccountTransfer(
      accounts: out,
      ownClients: clients,
      syncCode: code?.toString(),
      syncAccount: code == null ? null : _services.deviceSync.account?.email,
    );
  }

  /// Whether [account] arrives signed in, or the computer must sign in
  /// itself (shown on the phone before sending).
  Future<bool> arrivesSignedIn(
    Account account, {
    Map<String, String>? computerClients,
  }) async {
    final providerId = account.oauthProvider;
    if (providerId == null) return true;
    final tokens = OAuthTokens.fromJson(
      await _services.secrets.read(account.keychainKey),
    );
    return tokens != null &&
        tokensPortable(providerId, tokens, computerClients: computerClients);
  }
}
