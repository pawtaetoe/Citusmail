// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:mail_web/mail_web.dart';

/// A mail provider that signs in with OAuth 2.0.
final class OAuthProvider {
  const OAuthProvider({
    required this.id,
    required this.name,
    required this.authorizationUrl,
    required this.tokenUrl,
    required this.scopes,
    required this.clientId,
    required this.imapHost,
    required this.smtpHost,
    this.smtpPort = 587,
    this.extraParameters = const {},
  });

  /// `microsoft`, later `google`.
  final String id;
  final String name;
  final String authorizationUrl;
  final String tokenUrl;
  final List<String> scopes;

  /// The app's registration with the provider (public, not a secret);
  /// empty when this build has none, and the provider can't be used.
  final String clientId;
  final String imapHost;
  final String smtpHost;

  /// SMTP submission with STARTTLS.
  final int smtpPort;

  /// Added to the sign-in address (`prompt=select_account`...).
  final Map<String, String> extraParameters;

  bool get configured => clientId.isNotEmpty;

  /// The same provider with another registration (developer tools that
  /// take the client id at run time instead of from the build).
  OAuthProvider withClientId(String clientId) => OAuthProvider(
    id: id,
    name: name,
    authorizationUrl: authorizationUrl,
    tokenUrl: tokenUrl,
    scopes: scopes,
    clientId: clientId,
    imapHost: imapHost,
    smtpHost: smtpHost,
    smtpPort: smtpPort,
    extraParameters: extraParameters,
  );

  /// The provider with [id] (`microsoft`), or null.
  static OAuthProvider? byId(String id) =>
      all.where((p) => p.id == id).firstOrNull;

  /// Outlook.com, Hotmail and Microsoft 365. The client id comes from the
  /// build: `--dart-define=CITUSMAIL_MS_CLIENT_ID=...`.
  static const microsoft = OAuthProvider(
    id: 'microsoft',
    name: 'Microsoft',
    authorizationUrl:
        'https://login.microsoftonline.com/common/oauth2/v2.0/authorize',
    tokenUrl: 'https://login.microsoftonline.com/common/oauth2/v2.0/token',
    scopes: [
      'https://outlook.office.com/IMAP.AccessAsUser.All',
      'https://outlook.office.com/SMTP.Send',
      'offline_access',
    ],
    clientId: String.fromEnvironment('CITUSMAIL_MS_CLIENT_ID'),
    imapHost: 'outlook.office365.com',
    smtpHost: 'smtp-mail.outlook.com',
    extraParameters: {'prompt': 'select_account'},
  );

  static const all = [microsoft];

  /// Domains whose mail is Microsoft's consumer service.
  static const _microsoftDomains = {
    'outlook.com',
    'hotmail.com',
    'live.com',
    'msn.com',
    'passport.com',
    'outlook.de',
    'outlook.fr',
    'outlook.es',
    'outlook.it',
    'outlook.jp',
    'hotmail.co.uk',
    'hotmail.de',
    'hotmail.fr',
    'hotmail.it',
    'hotmail.es',
    'live.de',
    'live.co.uk',
    'live.fr',
    'live.nl',
    'live.it',
  };

  /// The provider for an email domain, or null if it doesn't need OAuth
  /// (as far as the app knows from the domain alone).
  static OAuthProvider? forDomain(String domain) =>
      _microsoftDomains.contains(domain.toLowerCase()) ? microsoft : null;
}

/// RFC 7636 proof key: the app keeps [verifier] and sends only
/// [challenge], so a stolen authorization code is useless to anyone else.
final class Pkce {
  Pkce._(this.verifier) : challenge = challengeFor(verifier);

  factory Pkce.generate([Random? random]) {
    final r = random ?? Random.secure();
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    return Pkce._(
      String.fromCharCodes([
        for (var i = 0; i < 64; i++) chars.codeUnitAt(r.nextInt(chars.length)),
      ]),
    );
  }

  final String verifier;
  final String challenge;

  /// S256: base64url(SHA-256(verifier)) without padding.
  static String challengeFor(String verifier) => base64Url
      .encode(sha256.convert(ascii.encode(verifier)).bytes)
      .replaceAll('=', '');
}

/// One sign-in attempt: the address to open in the browser, and what is
/// needed to check and use the answer.
final class AuthorizationRequest {
  AuthorizationRequest._(
    this.provider,
    this.redirectUri,
    this.pkce,
    this.state,
    this.loginHint,
  );

  factory AuthorizationRequest.start(
    OAuthProvider provider, {
    required Uri redirectUri,
    String? loginHint,
    Random? random,
  }) {
    if (!provider.configured) {
      throw StateError('${provider.name} sign-in is not set up in this build');
    }
    final r = random ?? Random.secure();
    final state = base64Url
        .encode([for (var i = 0; i < 24; i++) r.nextInt(256)])
        .replaceAll('=', '');
    return AuthorizationRequest._(
      provider,
      redirectUri,
      Pkce.generate(r),
      state,
      loginHint,
    );
  }

  final OAuthProvider provider;
  final Uri redirectUri;
  final Pkce pkce;

  /// Random; the answer must carry it back (against forged answers).
  final String state;

  /// The address the user typed, so the provider can skip asking.
  final String? loginHint;

  /// Where the browser goes.
  Uri get url => Uri.parse(provider.authorizationUrl).replace(
    queryParameters: {
      'client_id': provider.clientId,
      'response_type': 'code',
      'redirect_uri': redirectUri.toString(),
      'response_mode': 'query',
      'scope': provider.scopes.join(' '),
      'state': state,
      'code_challenge': pkce.challenge,
      'code_challenge_method': 'S256',
      'login_hint': ?loginHint,
      ...provider.extraParameters,
    },
  );

  /// The authorization code in the browser's answer [redirect]. Throws
  /// [OAuthException] for a refusal, a forged answer (wrong state) or an
  /// answer meant for another address.
  String codeFrom(Uri redirect) {
    if (redirect.scheme != redirectUri.scheme ||
        redirect.host != redirectUri.host ||
        redirect.port != redirectUri.port ||
        _path(redirect) != _path(redirectUri)) {
      throw const OAuthException(
        OAuthProblem.invalidAnswer,
        'the answer came to the wrong address',
      );
    }
    final q = redirect.queryParameters;
    if (q['state'] != state) {
      throw const OAuthException(
        OAuthProblem.invalidAnswer,
        'the answer does not belong to this sign-in',
      );
    }
    if (q['error'] case final error?) {
      throw OAuthException(
        error == 'access_denied'
            ? OAuthProblem.cancelled
            : OAuthProblem.refused,
        q['error_description'] ?? error,
      );
    }
    final code = q['code'];
    if (code == null || code.isEmpty || code.length > 4096) {
      throw const OAuthException(OAuthProblem.invalidAnswer, 'no code');
    }
    return code;
  }

  static String _path(Uri u) => u.path.isEmpty ? '/' : u.path;
}

enum OAuthProblem {
  /// The user cancelled or declined.
  cancelled,

  /// The provider refused (account not allowed, app not approved...).
  refused,

  /// The sign-in has expired or was revoked: sign in again.
  signInAgain,

  /// The answer was malformed, forged or for another sign-in.
  invalidAnswer,

  /// The provider couldn't be reached.
  network,
}

final class OAuthException implements Exception {
  const OAuthException(this.problem, this.message);

  final OAuthProblem problem;

  /// From the provider or this app; never contains tokens.
  final String message;

  @override
  String toString() => 'OAuthException(${problem.name}): $message';
}

/// What a sign-in gives: a short-lived access token for IMAP and SMTP,
/// and a refresh token to get new ones. Both are secrets for the system
/// keychain only.
final class OAuthTokens {
  const OAuthTokens({
    required this.accessToken,
    required this.expiresAt,
    this.refreshToken,
  });

  final String accessToken;
  final DateTime expiresAt;
  final String? refreshToken;

  /// Whether the access token should be renewed before use.
  bool needsRefresh({
    DateTime? now,
    Duration margin = const Duration(minutes: 5),
  }) => !(now ?? DateTime.now()).toUtc().add(margin).isBefore(expiresAt);

  String toJson() => jsonEncode({
    'access': accessToken,
    'expires': expiresAt.toUtc().millisecondsSinceEpoch,
    if (refreshToken != null) 'refresh': refreshToken,
  });

  static OAuthTokens? fromJson(String? text) {
    if (text == null) return null;
    try {
      final json = jsonDecode(text);
      if (json is! Map ||
          json['access'] is! String ||
          json['expires'] is! int ||
          (json['refresh'] != null && json['refresh'] is! String)) {
        return null;
      }
      return OAuthTokens(
        accessToken: json['access'] as String,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          json['expires'] as int,
          isUtc: true,
        ),
        refreshToken: json['refresh'] as String?,
      );
    } on FormatException {
      return null;
    }
  }
}

/// Talks to a provider's token endpoint, through the hardened [WebClient].
final class TokenClient {
  TokenClient(this._web, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final WebClient _web;
  final DateTime Function() _now;

  static const _maxAnswer = 64 * 1024;

  /// Exchanges the code from a sign-in for tokens.
  Future<OAuthTokens> exchange(AuthorizationRequest request, String code) =>
      _post(request.provider, {
        'grant_type': 'authorization_code',
        'client_id': request.provider.clientId,
        'code': code,
        'redirect_uri': request.redirectUri.toString(),
        'code_verifier': request.pkce.verifier,
        'scope': request.provider.scopes.join(' '),
      });

  /// New tokens from a refresh token. A provider may send a new refresh
  /// token; if not, the old one stays.
  Future<OAuthTokens> refresh(
    OAuthProvider provider,
    String refreshToken,
  ) async {
    final tokens = await _post(provider, {
      'grant_type': 'refresh_token',
      'client_id': provider.clientId,
      'refresh_token': refreshToken,
      'scope': provider.scopes.join(' '),
    });
    return tokens.refreshToken != null
        ? tokens
        : OAuthTokens(
            accessToken: tokens.accessToken,
            expiresAt: tokens.expiresAt,
            refreshToken: refreshToken,
          );
  }

  Future<OAuthTokens> _post(
    OAuthProvider provider,
    Map<String, String> form,
  ) async {
    final WebResponse response;
    try {
      response = await _web.post(
        Uri.parse(provider.tokenUrl),
        body: utf8.encode(Uri(queryParameters: form).query),
        contentType: 'application/x-www-form-urlencoded',
        maxAnswer: _maxAnswer,
      );
    } on WebException catch (e) {
      throw OAuthException(OAuthProblem.network, e.message);
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(response.body ?? const []));
    } on FormatException {
      throw const OAuthException(
        OAuthProblem.invalidAnswer,
        'the token answer is not JSON',
      );
    }
    if (json is! Map) {
      throw const OAuthException(OAuthProblem.invalidAnswer, 'not an object');
    }
    if (!response.ok || json['error'] != null) {
      final error = json['error'];
      throw OAuthException(
        error == 'invalid_grant'
            ? OAuthProblem.signInAgain
            : OAuthProblem.refused,
        (json['error_description'] ?? error ?? 'error ${response.statusCode}')
            .toString()
            .split('\n')
            .first,
      );
    }
    final access = json['access_token'];
    final type = json['token_type'];
    final expiresIn = json['expires_in'];
    final refresh = json['refresh_token'];
    if (access is! String ||
        access.isEmpty ||
        (type is String && type.toLowerCase() != 'bearer') ||
        (refresh != null && refresh is! String)) {
      throw const OAuthException(
        OAuthProblem.invalidAnswer,
        'the token answer is incomplete',
      );
    }
    final seconds = switch (expiresIn) {
      final int s => s,
      final String s => int.tryParse(s) ?? 3600,
      _ => 3600,
    };
    return OAuthTokens(
      accessToken: access,
      expiresAt: _now().toUtc().add(
        Duration(seconds: seconds.clamp(60, 86400)),
      ),
      refreshToken: refresh as String?,
    );
  }
}
