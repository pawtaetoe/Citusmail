// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:mail_oauth/mail_oauth.dart';
import 'package:url_launcher/url_launcher.dart';

/// Runs a provider's sign-in in the user's own browser and brings the
/// answer back: through a one-time loopback listener, or on Android for
/// providers that allow it ([OAuthProvider.appLinkRedirect]: Microsoft)
/// through the app's link (`com.fluminaris.citusmail://oauth`).
final class OAuthBrowser {
  OAuthBrowser(this._tokens);

  final TokenClient _tokens;

  /// How long the user has to finish signing in.
  static const timeout = Duration(minutes: 10);

  /// The redirect address on Android (registered with the provider).
  static final androidRedirect = Uri.parse('com.fluminaris.citusmail://oauth');

  static const _channel = MethodChannel('fmail/oauth');
  static Completer<Uri>? _waiting;

  /// Called once at start-up on Android: answers arrive as app links.
  static void listenForAndroidAnswers() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'redirect' || call.arguments is! String) return;
      final uri = Uri.tryParse(call.arguments as String);
      final waiting = _waiting;
      if (uri != null && waiting != null && !waiting.isCompleted) {
        waiting.complete(uri);
      }
    });
  }

  /// Signs in with [provider] for [email]; returns the tokens. Throws
  /// [OAuthException] (cancelled, refused, network) or [TimeoutException].
  Future<OAuthTokens> signIn(OAuthProvider provider, String email) async {
    final AuthorizationRequest request;
    final Uri answer;
    if (Platform.isAndroid && provider.appLinkRedirect) {
      request = AuthorizationRequest.start(
        provider,
        redirectUri: androidRedirect,
        loginHint: email,
      );
      final waiting = _waiting = Completer<Uri>();
      await _open(request.url);
      answer = await waiting.future.timeout(timeout);
    } else {
      final receiver = await LoopbackReceiver.start(timeout: timeout);
      try {
        request = AuthorizationRequest.start(
          provider,
          redirectUri: receiver.redirectUri,
          loginHint: email,
        );
        final pending = receiver.answer(
          (uri) => uri.queryParameters['state'] == request.state,
        );
        await _open(request.url);
        answer = await pending;
      } finally {
        await receiver.close();
      }
    }
    return _tokens.exchange(request, request.codeFrom(answer));
  }

  static Future<void> _open(Uri url) async {
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      throw const OAuthException(
        OAuthProblem.network,
        'no browser could open the sign-in page',
      );
    }
  }
}
