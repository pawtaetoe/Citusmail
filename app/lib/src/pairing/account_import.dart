// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_oauth/mail_oauth.dart';
import 'package:mail_pairing/mail_pairing.dart';
import 'package:mail_protocol/mail_protocol.dart' show ConnectionSecurity;
import 'package:mail_setup/mail_setup.dart';
import 'package:mail_web/mail_web.dart';

import '../services/app_services.dart';
import '../services/secret_store.dart';
import '../setup/setup_controller.dart';

/// Renews an access token with a refresh token.
typedef RefreshFn = Future<OAuthTokens> Function(
  OAuthProvider provider,
  String refreshToken,
);

/// An account the computer must sign in to itself (Microsoft, or tokens
/// for another client).
final class SignInNeeded {
  const SignInNeeded(this.provider, this.email, this.displayName);

  final OAuthProvider provider;
  final String email;
  final String? displayName;
}

/// Adds the accounts from the phone on the computer, each checked with a
/// real sign-in first, as in normal setup.
final class AccountImport {
  AccountImport(
    this._services, {
    VerifyFn? verify,
    VerifyOAuthFn? verifyOAuth,
    RefreshFn? refresh,
    Map<String, String>? clients,
  }) : _verify = verify ?? const AccountVerifier().verify,
       _verifyOAuth =
           verifyOAuth ??
           ((settings, token) =>
               const AccountVerifier().verify(settings, token, oauth: true)),
       _refresh = refresh ?? TokenClient(WebClient()).refresh,
       _clients =
           clients ??
           {
             for (final p in OAuthProvider.all)
               if (p.configured) p.id: p.clientId,
           };

  final AppServices _services;
  final VerifyFn _verify;
  final VerifyOAuthFn _verifyOAuth;
  final RefreshFn _refresh;

  /// This build's client ids by provider.
  final Map<String, String> _clients;

  /// Accounts to sign in to here, after [receive].
  final signInNeeded = <SignInNeeded>[];

  /// Whether Sync between devices was turned on with the phone's code.
  bool syncTurnedOn = false;

  static ConnectionSecurity? _security(String s) => switch (s) {
    'tls' => ConnectionSecurity.implicitTls,
    'starttls' => ConnectionSecurity.startTls,
    _ => null,
  };

  Future<List<TransferResult>> receive(AccountTransfer transfer) async {
    signInNeeded.clear();
    await _saveOwnClients(transfer.ownClients);
    final results = <TransferResult>[];
    for (final account in transfer.accounts) {
      results.add(await _add(account));
    }
    await _joinSync(transfer);
    return results;
  }

  Future<void> _saveOwnClients(Map<String, String> clients) async {
    final own = OwnOAuthClients(_services.secrets);
    for (final MapEntry(:key, :value) in clients.entries) {
      final provider = OAuthProvider.byId(key);
      final registration = OAuthRegistration.fromJson(value);
      if (provider == null ||
          registration == null ||
          registration.problemFor(provider) != null ||
          await own.read(key) != null) {
        continue;
      }
      await own.save(key, registration);
    }
  }

  Future<void> _joinSync(AccountTransfer transfer) async {
    final code = transfer.syncCode;
    final sync = _services.deviceSync;
    if (code == null || await sync.enabled) return;
    final carrier = _services.store.accounts
        .all()
        .where(
          (a) => a.email.toLowerCase() == transfer.syncAccount?.toLowerCase(),
        )
        .firstOrNull;
    if (carrier != null) sync.account = carrier;
    syncTurnedOn = await sync.join(code);
  }

  bool _alreadyHere(TransferredAccount a) => _services.store.accounts.all().any(
    (b) =>
        b.email.toLowerCase() == a.email.toLowerCase() &&
        b.imap.host.toLowerCase() == a.imap.host.toLowerCase(),
  );

  Future<TransferResult> _add(TransferredAccount a) async {
    if (_alreadyHere(a)) {
      return TransferResult(a.email, TransferOutcome.alreadyThere);
    }
    final imapSecurity = _security(a.imap.security);
    final smtpSecurity = _security(a.smtp.security);
    if (imapSecurity == null || smtpSecurity == null) {
      return TransferResult(
        a.email,
        TransferOutcome.failed,
        detail: 'Unknown settings.',
      );
    }
    final DiscoveredSettings settings;
    try {
      settings = DiscoveredSettings(
        email: a.email,
        imap: ServerCandidate(a.imap.host, a.imap.port, imapSecurity),
        smtp: ServerCandidate(a.smtp.host, a.smtp.port, smtpSecurity),
        username: a.username,
        source: DiscoverySource.manual,
      );
    } on ArgumentError {
      return TransferResult(
        a.email,
        TransferOutcome.failed,
        detail: 'Unknown settings.',
      );
    }
    final name = a.displayName;
    try {
      switch (a.signIn) {
        case PasswordSignIn(:final password):
          final result = await _verify(settings, password);
          if (!result.succeeded) {
            return TransferResult(
              a.email,
              TransferOutcome.failed,
              detail: SetupText.problem(result, settings),
            );
          }
          await _services.addAccount(settings, password, displayName: name);
          return TransferResult(a.email, TransferOutcome.added);
        case OAuthSignIn(:final provider, :final tokens, :final client):
          final known = OAuthProvider.byId(provider);
          if (known == null) {
            return TransferResult(
              a.email,
              TransferOutcome.failed,
              detail: 'This copy can\'t sign in with $provider.',
            );
          }
          final stored = OAuthTokens.fromJson(tokens);
          final usable =
              stored != null &&
              stored.refreshToken != null &&
              (stored.registration != null ||
                  (client != null && _clients[provider] == client));
          if (!usable) return _signInHere(known, a);
          var current = stored;
          final issuer = known.forTokens(stored);
          if (stored.needsRefresh()) {
            try {
              current = (await _refresh(
                issuer,
                stored.refreshToken!,
              )).issuedTo(stored.registration);
            } on OAuthException {
              return _signInHere(known, a);
            }
          }
          final result = await _verifyOAuth(settings, current.accessToken);
          if (!result.succeeded) {
            if (result.problem == VerificationProblem.credentials) {
              return _signInHere(known, a);
            }
            return TransferResult(
              a.email,
              TransferOutcome.failed,
              detail: SetupText.problem(result, settings),
            );
          }
          await _services.addOAuthAccount(
            settings,
            known,
            current,
            displayName: name,
          );
          return TransferResult(a.email, TransferOutcome.added);
      }
    } on SecretStoreUnavailableException {
      return TransferResult(
        a.email,
        TransferOutcome.failed,
        detail: 'The keychain on the computer couldn\'t store the sign-in.',
      );
    }
  }

  TransferResult _signInHere(OAuthProvider provider, TransferredAccount a) {
    signInNeeded.add(SignInNeeded(provider, a.email, a.displayName));
    return TransferResult(a.email, TransferOutcome.signInOnComputer);
  }
}
