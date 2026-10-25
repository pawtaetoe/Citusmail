// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:mail_oauth/mail_oauth.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

/// Where the live check keeps its OAuth tokens between runs.
abstract interface class TokenVault {
  Future<String?> read();
  Future<void> write(String value);
}

/// The live test account's OAuth tokens, kept current the way the app's
/// keychain credentials keep them: renewed with the refresh token shortly
/// before the access token expires, and saved back after each renewal.
final class LiveTokens implements CredentialProvider {
  LiveTokens(this._vault, this._renew);

  final TokenVault _vault;
  final Future<OAuthTokens> Function(String refreshToken) _renew;
  OAuthTokens? _current;

  /// How many times the tokens were renewed in this run.
  int renewals = 0;

  /// The stored tokens, or null if this account has not signed in yet.
  Future<OAuthTokens?> stored() async =>
      _current ??= OAuthTokens.fromJson(await _vault.read());

  /// Starts from tokens from a fresh sign-in, and saves them.
  Future<void> signedIn(OAuthTokens tokens) async {
    await _vault.write(tokens.toJson());
    _current = tokens;
  }

  /// A usable access token, renewed first if it is about to expire.
  Future<OAuthTokens> current() async {
    final tokens = await stored();
    if (tokens == null) {
      throw StateError('not signed in yet');
    }
    return tokens.needsRefresh() ? renew() : tokens;
  }

  /// Renews now, whether or not the access token is still good.
  Future<OAuthTokens> renew() async {
    final tokens = await stored();
    final refresh = tokens?.refreshToken;
    if (refresh == null) {
      throw StateError('no refresh token: sign in again');
    }
    final renewed = await _renew(refresh);
    await _vault.write(renewed.toJson());
    renewals++;
    return _current = renewed;
  }

  /// Treats the access token as expired, so the next use must renew it
  /// (checks that a session renews tokens by itself).
  void expireNow() {
    final tokens = _current;
    if (tokens == null) return;
    _current = OAuthTokens(
      accessToken: tokens.accessToken,
      expiresAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
      refreshToken: tokens.refreshToken,
    );
  }

  @override
  Future<String> passwordFor(Account account) async =>
      (await current()).accessToken;
}

/// Signs in on the provider's page in the system browser, with the
/// answer caught on 127.0.0.1 (as the desktop app does).
Future<OAuthTokens> browserSignIn(
  OAuthProvider provider,
  String email,
  TokenClient tokens, {
  void Function(String line)? say,
  Duration timeout = const Duration(minutes: 10),
}) async {
  final receiver = await LoopbackReceiver.start(timeout: timeout);
  try {
    final request = AuthorizationRequest.start(
      provider,
      redirectUri: receiver.redirectUri,
      loginHint: email,
    );
    final pending = receiver.answer(
      (uri) => uri.queryParameters['state'] == request.state,
    );
    say?.call(
      'Sign in to $email in your browser. If it does not open, visit:\n'
      '  ${request.url}',
    );
    await _openBrowser(request.url);
    final answer = await pending;
    return await tokens.exchange(request, request.codeFrom(answer));
  } finally {
    await receiver.close();
  }
}

/// Best effort: the address is also printed for opening by hand.
Future<void> _openBrowser(Uri url) async {
  final (command, arguments) = switch (Platform.operatingSystem) {
    'macos' => ('open', [url.toString()]),
    'windows' => ('rundll32', ['url.dll,FileProtocolHandler', url.toString()]),
    _ => ('xdg-open', [url.toString()]),
  };
  try {
    await Process.start(command, arguments, mode: ProcessStartMode.detached);
  } on ProcessException {
    // No browser launcher: the printed address still works.
  }
}
