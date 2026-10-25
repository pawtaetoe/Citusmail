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
    this.clientSecret = '',
    this.smtpPort = 587,
    this.extraParameters = const {},
    this.appLinkRedirect = false,
  });

  /// `microsoft` or `google`.
  final String id;
  final String name;
  final String authorizationUrl;
  final String tokenUrl;
  final List<String> scopes;

  /// The app's registration with the provider (public, not a secret);
  /// empty when this build has none, and the provider can't be used.
  final String clientId;

  /// Google's desktop registrations come with a "client secret" that every
  /// copy of the app carries, so it protects nothing (Google says as much
  /// for installed apps); the token endpoint still asks for it. Empty when
  /// the provider doesn't use one (Microsoft).
  final String clientSecret;
  final String imapHost;
  final String smtpHost;

  /// SMTP submission with STARTTLS.
  final int smtpPort;

  /// Added to the sign-in address (`prompt=select_account`...).
  final Map<String, String> extraParameters;

  /// Whether the answer can come back on Android through the app's own
  /// link (registered with the provider). Otherwise Android also uses the
  /// one-time 127.0.0.1 receiver, as desktops do.
  final bool appLinkRedirect;

  bool get configured => clientId.isNotEmpty;

  /// The same provider with another registration (developer tools that
  /// take the client id at run time instead of from the build).
  OAuthProvider withClientId(String clientId, {String? clientSecret}) =>
      OAuthProvider(
        id: id,
        name: name,
        authorizationUrl: authorizationUrl,
        tokenUrl: tokenUrl,
        scopes: scopes,
        clientId: clientId,
        clientSecret: clientSecret ?? this.clientSecret,
        imapHost: imapHost,
        smtpHost: smtpHost,
        smtpPort: smtpPort,
        extraParameters: extraParameters,
        appLinkRedirect: appLinkRedirect,
      );

  /// The same provider with the user's own registration.
  OAuthProvider withRegistration(OAuthRegistration registration) =>
      withClientId(
        registration.clientId,
        clientSecret: registration.clientSecret,
      );

  /// The user's own registration this provider carries, or null when it
  /// has the build's (or none).
  OAuthRegistration? get ownRegistration {
    final builtIn = byId(id);
    return (builtIn != null && builtIn.clientId == clientId) || !configured
        ? null
        : OAuthRegistration(clientId, clientSecret);
  }

  /// The provider to renew [tokens] with: the one that issued them.
  OAuthProvider forTokens(OAuthTokens tokens) => switch (tokens.registration) {
    final own? => withRegistration(own),
    null => this,
  };

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
    appLinkRedirect: true,
  );

  /// Gmail and Google Workspace mail. The registration comes from the
  /// build (`--dart-define=CITUSMAIL_GOOGLE_CLIENT_ID=...` and
  /// `CITUSMAIL_GOOGLE_CLIENT_SECRET`), or from the user ("bring your
  /// own", see [OAuthRegistration]) until Google has verified the app.
  /// Full mail access (`https://mail.google.com/`) is the only scope that
  /// allows IMAP and SMTP.
  static const google = OAuthProvider(
    id: 'google',
    name: 'Google',
    authorizationUrl: 'https://accounts.google.com/o/oauth2/v2/auth',
    tokenUrl: 'https://oauth2.googleapis.com/token',
    scopes: ['https://mail.google.com/'],
    clientId: String.fromEnvironment('CITUSMAIL_GOOGLE_CLIENT_ID'),
    clientSecret: String.fromEnvironment('CITUSMAIL_GOOGLE_CLIENT_SECRET'),
    imapHost: 'imap.gmail.com',
    smtpHost: 'smtp.gmail.com',
    // A refresh token is only given with offline access; consent is asked
    // each time so a new sign-in always gets one.
    extraParameters: {
      'access_type': 'offline',
      'prompt': 'consent select_account',
    },
  );

  static const all = [microsoft, google];

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

  static const _googleDomains = {'gmail.com', 'googlemail.com'};

  /// The provider an email domain must sign in with, or null if it doesn't
  /// need OAuth (as far as the app knows from the domain alone).
  static OAuthProvider? forDomain(String domain) =>
      _microsoftDomains.contains(domain.toLowerCase()) ? microsoft : null;

  /// A provider an email domain may sign in with instead of a password
  /// (Gmail: Google sign-in or an app password), or null.
  static OAuthProvider? optionalForDomain(String domain) =>
      _googleDomains.contains(domain.toLowerCase()) ? google : null;
}

/// The user's own registration with a provider ("bring your own"): for
/// early testers, before the app's own registration is approved. Kept in
/// the keychain like the tokens it is used with.
final class OAuthRegistration {
  OAuthRegistration(String clientId, [String clientSecret = ''])
    : clientId = clientId.trim(),
      clientSecret = clientSecret.trim();

  final String clientId;
  final String clientSecret;

  /// What a registration for [provider] looks like: Google client ids end
  /// in `.apps.googleusercontent.com` and come with a secret.
  String? problemFor(OAuthProvider provider) {
    final plain = RegExp(r'^[A-Za-z0-9._-]{8,200}$');
    if (provider.id == 'google') {
      if (!RegExp(r'^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$')
          .hasMatch(clientId)) {
        return 'A Google client ID ends in .apps.googleusercontent.com';
      }
      if (!plain.hasMatch(clientSecret)) {
        return 'Enter the client secret shown with the client ID';
      }
      return null;
    }
    if (provider.id == 'microsoft') {
      final guid = RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
      );
      return guid.hasMatch(clientId)
          ? null
          : 'A Microsoft client ID looks like 00000000-0000-0000-0000-000000000000';
    }
    if (!plain.hasMatch(clientId)) return 'That is not a client ID';
    if (clientSecret.isNotEmpty && !plain.hasMatch(clientSecret)) {
      return 'That is not a client secret';
    }
    return null;
  }

  String toJson() => jsonEncode({
    'client': clientId,
    if (clientSecret.isNotEmpty) 'secret': clientSecret,
  });

  static OAuthRegistration? fromJson(String? text) {
    if (text == null) return null;
    try {
      final json = jsonDecode(text);
      if (json is! Map ||
          json['client'] is! String ||
          (json['secret'] != null && json['secret'] is! String)) {
        return null;
      }
      return OAuthRegistration(
        json['client'] as String,
        (json['secret'] as String?) ?? '',
      );
    } on FormatException {
      return null;
    }
  }
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
    this.registration,
  });

  final String accessToken;
  final DateTime expiresAt;
  final String? refreshToken;

  /// The user's own registration that issued these tokens; null for the
  /// app's built-in one. A refresh token works only with the client that
  /// got it, so renewals must use the same one.
  final OAuthRegistration? registration;

  /// The same tokens, recorded as issued to [registration].
  OAuthTokens issuedTo(OAuthRegistration? registration) => OAuthTokens(
    accessToken: accessToken,
    expiresAt: expiresAt,
    refreshToken: refreshToken,
    registration: registration,
  );

  /// Whether the access token should be renewed before use.
  bool needsRefresh({
    DateTime? now,
    Duration margin = const Duration(minutes: 5),
  }) => !(now ?? DateTime.now()).toUtc().add(margin).isBefore(expiresAt);

  String toJson() => jsonEncode({
    'access': accessToken,
    'expires': expiresAt.toUtc().millisecondsSinceEpoch,
    if (refreshToken != null) 'refresh': refreshToken,
    if (registration case final r?) ...{
      'client': r.clientId,
      if (r.clientSecret.isNotEmpty) 'secret': r.clientSecret,
    },
  });

  static OAuthTokens? fromJson(String? text) {
    if (text == null) return null;
    try {
      final json = jsonDecode(text);
      if (json is! Map ||
          json['access'] is! String ||
          json['expires'] is! int ||
          (json['refresh'] != null && json['refresh'] is! String) ||
          (json['client'] != null && json['client'] is! String) ||
          (json['secret'] != null && json['secret'] is! String)) {
        return null;
      }
      final client = json['client'] as String?;
      return OAuthTokens(
        accessToken: json['access'] as String,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          json['expires'] as int,
          isUtc: true,
        ),
        refreshToken: json['refresh'] as String?,
        registration: client == null
            ? null
            : OAuthRegistration(client, (json['secret'] as String?) ?? ''),
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
        if (request.provider.clientSecret.isNotEmpty)
          'client_secret': request.provider.clientSecret,
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
      if (provider.clientSecret.isNotEmpty)
        'client_secret': provider.clientSecret,
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
