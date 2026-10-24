// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Catches the browser's answer to a sign-in on desktops (RFC 8252
/// loopback redirect): a one-time listener on 127.0.0.1, at a random port,
/// that takes exactly one answer and closes.
///
/// Other programs on the device could connect too, but an answer is only
/// accepted with the right `state`, and its code is useless without the
/// app's PKCE verifier.
final class LoopbackReceiver {
  LoopbackReceiver._(this._server, this.timeout);

  /// Listens on a free port.
  static Future<LoopbackReceiver> start({
    Duration timeout = const Duration(minutes: 10),
  }) async => LoopbackReceiver._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    timeout,
  );

  final HttpServer _server;
  final Duration timeout;

  /// Where the provider sends the browser: `http://127.0.0.1:<port>/`.
  Uri get redirectUri => Uri.parse('http://127.0.0.1:${_server.port}/');

  /// The answer's full address, once it arrives. [accept] decides whether
  /// a request is the answer (it must carry the right `state`); others get
  /// a 404 and waiting goes on. Throws [TimeoutException] if none comes.
  Future<Uri> answer(bool Function(Uri uri) accept) async {
    final completer = Completer<Uri>();
    final subscription = _server.listen((request) async {
      final uri = redirectUri.resolve(request.uri.toString());
      final response = request.response
        ..headers.contentType = ContentType.html
        ..headers.set('Cache-Control', 'no-store')
        ..headers.set('Referrer-Policy', 'no-referrer');
      if (request.method != 'GET' || completer.isCompleted || !accept(uri)) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final failed = uri.queryParameters.containsKey('error');
      response.write(_page(failed));
      await response.close();
      completer.complete(uri);
    });
    try {
      return await completer.future.timeout(timeout);
    } finally {
      await subscription.cancel();
      await close();
    }
  }

  Future<void> close() => _server.close(force: true);

  static String _page(bool failed) {
    final text = failed
        ? 'Sign-in didn\'t complete. You can close this tab and try again in the app.'
        : 'You\'re signed in. You can close this tab and return to the app.';
    return '<!doctype html><meta charset="utf-8">'
        '<title>Sign-in</title>'
        '<p style="font:16px sans-serif;margin:3em">${const HtmlEscape().convert(text)}</p>';
  }
}
