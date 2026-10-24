// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A scripted plain-text server on 127.0.0.1 for testing how clients
/// handle hostile or broken servers. [onLine] gets each line the client
/// sends and returns the raw reply (may contain several lines at once).
final class FakeServer {
  FakeServer._(this._server, this.received);

  /// With [tls], the server speaks TLS from the start (implicit TLS).
  static Future<FakeServer> start({
    required String greeting,
    required String? Function(String line) onLine,
    SecurityContext? tls,
  }) async {
    final Stream<Socket> server = tls == null
        ? await ServerSocket.bind(InternetAddress.loopbackIPv4, 0)
        : await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, tls);
    final received = <String>[];
    server.listen((socket) {
      socket.add(utf8.encode(greeting));
      var buffer = '';
      socket.listen(
        (data) {
          buffer += latin1.decode(data);
          while (buffer.contains('\n')) {
            final index = buffer.indexOf('\n');
            final line = buffer.substring(0, index).replaceAll('\r', '');
            buffer = buffer.substring(index + 1);
            received.add(line);
            final reply = onLine(line);
            if (reply != null) socket.add(latin1.encode(reply)); // one write
          }
        },
        onError: (_) {},
        onDone: () => socket.destroy(),
      );
    }, onError: (Object _) {}); // refused TLS handshakes
    return FakeServer._(server, received);
  }

  final Stream<Socket> _server;

  /// Every line the client sent, in order.
  final List<String> received;

  int get port => switch (_server) {
    final ServerSocket s => s.port,
    final SecureServerSocket s => s.port,
    _ => throw StateError('unknown server'),
  };

  Future<void> close() => switch (_server) {
    final ServerSocket s => s.close(),
    final SecureServerSocket s => s.close(),
    _ => Future.value(),
  };
}
