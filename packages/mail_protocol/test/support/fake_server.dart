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

  static Future<FakeServer> start({
    required String greeting,
    required String? Function(String line) onLine,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
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
    });
    return FakeServer._(server, received);
  }

  final ServerSocket _server;

  /// Every line the client sent, in order.
  final List<String> received;

  int get port => _server.port;

  Future<void> close() => _server.close();
}
