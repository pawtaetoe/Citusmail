// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A request the fake server received.
final class Received {
  Received(this.method, this.uri, this.headers, this.body);

  final String method;
  final Uri uri;
  final HttpHeaders headers;
  final String body;

  Map<String, Object?> get json => jsonDecode(body) as Map<String, Object?>;
}

/// What the fake server answers.
final class Reply {
  const Reply(
    this.status, {
    this.body = '',
    this.chunks,
    this.headers = const {},
    this.delay = Duration.zero,
  });

  /// A JSON answer.
  Reply.json(Object? value, {int status = 200, Map<String, String>? headers})
    : this(
        status,
        body: jsonEncode(value),
        headers: {'content-type': 'application/json', ...?headers},
      );

  /// Server-sent events, one write per event.
  Reply.events(List<String> events, {Duration delay = Duration.zero})
    : this(
        200,
        chunks: [for (final e in events) '$e\n\n'],
        headers: {'content-type': 'text/event-stream'},
        delay: delay,
      );

  final int status;
  final String body;
  final List<String>? chunks;
  final Map<String, String> headers;

  /// Between chunks.
  final Duration delay;
}

/// An HTTP server on 127.0.0.1 that answers from a handler and records
/// requests: stands in for a provider, so no test reaches a real API.
final class FakeServer {
  FakeServer._(this._server, this.handler);

  static Future<FakeServer> start(
    FutureOr<Reply> Function(Received request) handler,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return FakeServer._(server, handler).._listen();
  }

  final HttpServer _server;
  FutureOr<Reply> Function(Received request) handler;
  final requests = <Received>[];

  /// Connections open now.
  int get openConnections => _server.connectionsInfo().total;

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}');

  void _listen() => _server.listen((request) async {
    final body = await utf8.decoder.bind(request).join();
    final received = Received(
      request.method,
      request.uri,
      request.headers,
      body,
    );
    requests.add(received);
    final reply = await handler(received);
    final response = request.response..statusCode = reply.status;
    reply.headers.forEach(response.headers.set);
    try {
      if (reply.chunks case final chunks?) {
        response.bufferOutput = false;
        for (final chunk in chunks) {
          response.write(chunk);
          await response.flush();
          if (reply.delay > Duration.zero) {
            await Future<void>.delayed(reply.delay);
          }
        }
      } else {
        response.write(reply.body);
      }
      await response.close();
    } on Object {
      // The client went away.
    }
  });

  Future<void> close() => _server.close(force: true);
}

/// An SSE event line pair.
String sse(Object? data, {String? event}) =>
    '${event == null ? '' : 'event: $event\n'}data: ${data is String ? data : jsonEncode(data)}';
