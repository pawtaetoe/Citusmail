// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_web/mail_web.dart';

/// Stands in for the web servers named in test mail: plain TCP on
/// 127.0.0.1, answering by request line ("GET /banner.jpg"), and
/// recording every request. [client] sends every host here.
final class FakeWeb {
  FakeWeb._(this._socket);

  static Future<FakeWeb> start() async =>
      FakeWeb._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0))
        .._listen();

  final ServerSocket _socket;

  /// Request line -> raw answer.
  final routes = <String, List<int>>{};

  /// Answer for anything not in [routes].
  List<int> fallback = latin1.encode(
    'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n',
  );

  /// "Host request-line" of each request, in order.
  final requests = <String>[];

  /// Answers [line] with a 200 and [body].
  void serve(String line, Uint8List body) => routes[line] = [
    ...latin1.encode(
      'HTTP/1.1 200 OK\r\nContent-Length: ${body.length}\r\n\r\n',
    ),
    ...body,
  ];

  void _listen() => _socket.listen((client) {
    final got = BytesBuilder();
    client.listen((data) {
      got.add(data);
      final text = latin1.decode(got.toBytes());
      final end = text.indexOf('\r\n\r\n');
      if (end < 0) return;
      final length = int.parse(
        RegExp(r'Content-Length: (\d+)').firstMatch(text)?.group(1) ?? '0',
      );
      if (text.length < end + 4 + length) return;
      final line = text.split(' HTTP/1.1').first;
      final host = RegExp(r'Host: (\S+)').firstMatch(text)?.group(1);
      requests.add('$host $line');
      client
        ..add(routes[line] ?? fallback)
        ..close();
    }, onError: (_) {});
  });

  /// Every name looks public; connections come here, unencrypted.
  WebClient get client => WebClient(
    resolver: (_) async => [InternetAddress('93.184.216.34')],
    connector: (host, address, port, timeout) => MailSocket.connect(
      ServerEndpoint(
        host,
        _socket.port,
        ConnectionSecurity.startTls,
        connectAddress: '127.0.0.1',
      ),
    ),
  );

  Future<void> close() => _socket.close();
}
