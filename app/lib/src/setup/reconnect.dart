// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:mail_oauth/mail_oauth.dart';
import 'package:mail_setup/mail_setup.dart';
import 'package:mail_store/mail_store.dart';

import '../app.dart' show appName;
import 'setup_controller.dart';

/// Gives a saved account a new password, or a new OAuth sign-in, without
/// removing it: the new secret is checked with a real login first, and
/// only then replaces the old one in the keychain. Mail, folders and
/// settings stay as they are.
final class Reconnector {
  Reconnector({
    required this._verify,
    required this._verifyOAuth,
    required this._oauthSignIn,
    required this._readSecret,
    required this._save,
    this._ownClient,
  });

  final VerifyFn _verify;
  final VerifyOAuthFn _verifyOAuth;
  final OAuthSignInFn _oauthSignIn;
  final Future<String?> Function(String key) _readSecret;
  final Future<void> Function(Account account, String secret) _save;
  final OwnClientFn? _ownClient;

  /// The account's saved settings, for checking a login.
  static DiscoveredSettings settingsOf(Account a) => DiscoveredSettings(
    email: a.email,
    imap: ServerCandidate(a.imap.host, a.imap.port, a.imap.security),
    smtp: ServerCandidate(a.smtp.host, a.smtp.port, a.smtp.security),
    username: a.username,
    source: DiscoverySource.manual,
  );

  /// Checks [password] and saves it. Returns what went wrong, or null.
  Future<String?> usePassword(Account account, String password) async {
    final settings = settingsOf(account);
    final secret =
        KnownProvider.forImapHost(account.imap.host)
            ?.normalizePassword(password) ??
        password;
    if (secret.isEmpty) return 'Enter the password.';
    final result = await _verify(settings, secret);
    if (!result.succeeded) return SetupText.problem(result, settings);
    await _save(account, secret);
    return null;
  }

  /// The provider an OAuth account signs in with again: the client that
  /// signed it in before (its refresh token belongs to it), else this
  /// build's, else the user's own. Null when there is none.
  Future<OAuthProvider?> providerFor(Account account) async {
    final provider = switch (account.oauthProvider) {
      final id? => OAuthProvider.byId(id),
      null => null,
    };
    if (provider == null) return null;
    final previous = OAuthTokens.fromJson(
      await _readSecret(account.keychainKey),
    );
    if (previous?.registration case final own?) {
      return provider.withRegistration(own);
    }
    if (provider.configured) return provider;
    final own = await _ownClient?.call(provider.id);
    return own == null ? null : provider.withRegistration(own);
  }

  /// Runs the browser sign-in for [account] again, checks the mail
  /// servers with it, and saves the new tokens. Returns what went wrong,
  /// or null.
  Future<String?> signInAgain(Account account) async {
    final provider = await providerFor(account);
    if (provider == null) {
      return 'This copy of $appName can\'t sign in to '
          '${account.oauthProvider ?? 'this provider'} accounts.';
    }
    final OAuthTokens tokens;
    try {
      tokens = (await _oauthSignIn(
        provider,
        account.email,
      )).issuedTo(provider.ownRegistration);
    } on OAuthException catch (e) {
      return switch (e.problem) {
        OAuthProblem.cancelled => 'Sign-in was cancelled.',
        OAuthProblem.network =>
          'Couldn\'t reach ${provider.name}. Check your connection.',
        _ => '${provider.name} didn\'t complete the sign-in: ${e.message}',
      };
    } on TimeoutException {
      return 'Sign-in took too long. Try again.';
    }
    final settings = settingsOf(account);
    final result = await _verifyOAuth(settings, tokens.accessToken);
    if (!result.succeeded) {
      // Most often: signed in as someone else in the browser.
      return '${SetupText.problem(result, settings)} Make sure you signed in as '
          '${account.email}.';
    }
    await _save(account, tokens.toJson());
    return null;
  }
}
