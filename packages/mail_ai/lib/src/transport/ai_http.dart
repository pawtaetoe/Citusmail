// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:mail_web/mail_web.dart';

import '../ai_errors.dart';
import '../ai_types.dart';

/// One HTTP request to an AI provider.
final class AiHttpRequest {
  const AiHttpRequest(
    this.method,
    this.url, {
    this.headers = const {},
    this.body,
  });

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final List<int>? body;
}

/// The answer's status and headers; [body] streams as it arrives.
final class AiHttpResponse {
  const AiHttpResponse(this.statusCode, this.headers, this.body);

  final int statusCode;

  /// Lower-case names.
  final Map<String, String> headers;

  /// Cancelling the subscription closes the connection.
  final Stream<List<int>> body;
}

/// How provider adapters reach the network: [IoAiHttp] in the app, a
/// fake or a local test server in tests.
abstract interface class AiHttp {
  /// Throws [AiException] ([AiProblem.network] or
  /// [AiProblem.cancelled]); any HTTP status is returned, not thrown.
  Future<AiHttpResponse> send(AiHttpRequest request, {AiCancel? cancel});
}

/// The only HTTP client the assistant uses, and the only place in the
/// app outside account setup that makes HTTP requests (the import check
/// in tool/ allows `HttpClient` here and nowhere else in mail_ai).
///
/// - **https**, TLS 1.2 or newer, certificates always checked.
/// - **Plain http only into the user's own network**: to a name whose
///   every address is loopback, private or link-local (a model on this
///   computer or the local network, such as Ollama or LM Studio). Keys
///   and mail never cross the internet unencrypted.
/// - No user names in addresses, no redirects followed, no cookies, a
///   generic user agent, only the headers the adapter sets.
/// - Time limits: [connectTimeout] to connect, [idleTimeout] between
///   pieces of the answer (models can take a while to start).
final class IoAiHttp implements AiHttp {
  IoAiHttp({
    this.connectTimeout = const Duration(seconds: 20),
    this.idleTimeout = const Duration(seconds: 120),
    Future<List<InternetAddress>> Function(String host)? lookup,
    this.context,
  }) : _lookup = lookup ?? InternetAddress.lookup;

  final Duration connectTimeout;
  final Duration idleTimeout;
  final Future<List<InternetAddress>> Function(String host) _lookup;

  /// Trusted certificates (tests); the system's by default.
  final SecurityContext? context;

  static const _policy = PublicAddressPolicy();

  /// Whether plain http may go to [url]: only when every address of its
  /// host is inside the user's own network.
  Future<bool> _local(Uri url) async {
    final literal = InternetAddress.tryParse(url.host);
    final List<InternetAddress> addresses;
    try {
      addresses = literal != null ? [literal] : await _lookup(url.host);
    } on SocketException {
      throw AiException(AiProblem.network, '${url.host} not found');
    }
    return addresses.isNotEmpty && !addresses.any(_policy.allows);
  }

  @override
  Future<AiHttpResponse> send(AiHttpRequest request, {AiCancel? cancel}) async {
    final url = request.url;
    if (url.userInfo.isNotEmpty) {
      throw const AiException(
        AiProblem.badRequest,
        'the address must not contain a user name',
      );
    }
    if (url.scheme == 'http') {
      if (!await _local(url)) {
        throw AiException(
          AiProblem.badRequest,
          'plain http is only used on your own network; use https for '
          '${url.host}',
        );
      }
    } else if (url.scheme != 'https') {
      throw const AiException(AiProblem.badRequest, 'not an https address');
    }
    if (cancel?.isCancelled ?? false) throw aiCancelled;

    final client =
        HttpClient(
            context:
                context ??
                (SecurityContext(withTrustedRoots: true)
                  ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2),
          )
          ..userAgent = 'Mozilla/5.0'
          ..connectionTimeout = connectTimeout
          ..idleTimeout = const Duration(seconds: 5)
          ..autoUncompress = true
          ..badCertificateCallback = ((_, _, _) => false);
    var closed = false;
    void close() {
      if (closed) return;
      closed = true;
      client.close(force: true);
    }

    unawaited(cancel?.whenCancelled.then((_) => close()));
    try {
      final req = await client.openUrl(request.method, url);
      req
        ..followRedirects = false
        ..persistentConnection = false;
      request.headers.forEach(req.headers.set);
      if (request.body case final body?) {
        req.contentLength = body.length;
        req.add(body);
      }
      final response = await req.close().timeout(idleTimeout);
      final headers = <String, String>{};
      response.headers.forEach(
        (name, values) => headers[name.toLowerCase()] = values.join(', '),
      );
      final body = _body(response, close, cancel);
      return AiHttpResponse(response.statusCode, headers, body);
    } on AiException {
      close();
      rethrow;
    } on Object catch (e) {
      close();
      if (cancel?.isCancelled ?? false) throw aiCancelled;
      throw AiException(AiProblem.network, _describe(e, url));
    }
  }

  /// The answer's body: pieces as they come, at most [idleTimeout] apart;
  /// the connection closes when it ends or is cancelled.
  Stream<List<int>> _body(
    HttpClientResponse response,
    void Function() close,
    AiCancel? cancel,
  ) async* {
    try {
      await for (final chunk in response.timeout(idleTimeout)) {
        if (cancel?.isCancelled ?? false) throw aiCancelled;
        yield chunk;
      }
    } on TimeoutException {
      throw const AiException(AiProblem.network, 'the answer stopped coming');
    } on HttpException catch (e) {
      if (cancel?.isCancelled ?? false) throw aiCancelled;
      throw AiException(AiProblem.network, e.message);
    } on SocketException catch (e) {
      if (cancel?.isCancelled ?? false) throw aiCancelled;
      throw AiException(AiProblem.network, e.message);
    } finally {
      close();
    }
  }

  static String _describe(Object e, Uri url) => switch (e) {
    TimeoutException() => '${url.host} took too long',
    HandshakeException() => 'the secure connection to ${url.host} failed',
    SocketException(:final message) =>
      message.isEmpty ? '${url.host} unreachable' : message,
    HttpException(:final message) => message,
    _ => '${url.host} unreachable',
  };
}
