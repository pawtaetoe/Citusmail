// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mail_protocol/mail_protocol.dart';

import 'address_policy.dart';

/// Why a request did not complete.
enum WebProblem {
  /// The address is not one this client will use (not https, a port
  /// other than 443, a user name in it, an IP address, too long...).
  unsafeUrl,

  /// The name points into a private network.
  privateAddress,

  /// The name doesn't exist.
  notFound,

  /// The server could not be reached.
  unreachable,

  /// The TLS connection failed (certificate not valid for the name...).
  insecure,

  /// The server took too long.
  timeout,

  /// The server's answer was not valid HTTP.
  badResponse,
}

final class WebException implements Exception {
  const WebException(this.problem, this.message);

  final WebProblem problem;
  final String message;

  @override
  String toString() => 'WebException(${problem.name}): $message';
}

/// The status and headers of an answer. The body is not read.
final class WebResponse {
  const WebResponse(this.statusCode, this.headers);

  final int statusCode;

  /// Lower-case name -> values.
  final Map<String, List<String>> headers;

  bool get ok => statusCode >= 200 && statusCode < 300;
}

/// Limits for one request.
final class WebLimits {
  const WebLimits({
    this.timeout = const Duration(seconds: 20),
    this.maxUrlLength = 4096,
    this.maxHeaderLine = 8 * 1024,
    this.maxHeaders = 100,
  });

  /// For the whole request: lookup, connection, sending and the answer.
  final Duration timeout;
  final int maxUrlLength;
  final int maxHeaderLine;
  final int maxHeaders;
}

/// Looks up a host name's addresses.
typedef HostResolver = Future<List<InternetAddress>> Function(String host);

/// Opens a TLS connection to [address], checking the certificate for
/// [host].
typedef WebConnector = Future<MailSocket> Function(
  String host,
  InternetAddress address,
  int port,
  Duration timeout,
);

/// A deliberately small HTTPS client for addresses found in mail.
///
/// What it sends is fixed: the method, the path, `Host`, a generic
/// `User-Agent`, and the body. Never cookies, `Referer`, language or
/// encoding preferences, or anything else that could identify the user
/// beyond what the address itself contains. Redirects are not followed;
/// the caller sees the 3xx status. Only port 443 on public addresses.
final class WebClient {
  WebClient({
    HostResolver? resolver,
    WebConnector? connector,
    this.policy = const PublicAddressPolicy(),
    this.limits = const WebLimits(),
  }) : _resolve = resolver ?? _systemLookup,
       _connect = connector ?? _tlsConnect;

  /// The same for every user and request, so it identifies no one.
  static const userAgent = 'Mozilla/5.0';

  final AddressPolicy policy;
  final WebLimits limits;
  final HostResolver _resolve;
  final WebConnector _connect;

  /// POSTs [body] to [url] and returns the answer's status and headers.
  /// Throws [WebException].
  Future<WebResponse> post(
    Uri url, {
    required List<int> body,
    required String contentType,
  }) => _request('POST', url, body: body, contentType: contentType);

  Future<WebResponse> _request(
    String method,
    Uri url, {
    List<int> body = const [],
    String? contentType,
  }) async {
    final target = _check(url);
    try {
      return await _exchange(
        method,
        target,
        body,
        contentType,
      ).timeout(limits.timeout);
    } on TimeoutException {
      throw WebException(WebProblem.timeout, '${target.host} took too long');
    } on MailTlsException catch (e) {
      throw WebException(WebProblem.insecure, e.message);
    } on MailTimeoutException catch (e) {
      throw WebException(WebProblem.timeout, e.message);
    } on MailProtocolException catch (e) {
      throw WebException(WebProblem.badResponse, e.message);
    } on MailException catch (e) {
      throw WebException(WebProblem.unreachable, e.message);
    }
  }

  Future<WebResponse> _exchange(
    String method,
    Uri target,
    List<int> body,
    String? contentType,
  ) async {
    final List<InternetAddress> addresses;
    try {
      addresses = await _resolve(target.host);
    } on SocketException {
      throw WebException(WebProblem.notFound, '${target.host} not found');
    }
    if (addresses.isEmpty) {
      throw WebException(WebProblem.notFound, '${target.host} not found');
    }
    // Every address must be public: a name that also points into the
    // local network is refused rather than raced.
    if (!addresses.every(policy.allows)) {
      throw WebException(
        WebProblem.privateAddress,
        '${target.host} points into a private network',
      );
    }
    final socket = await _connect(
      target.host,
      addresses.first,
      443,
      limits.timeout,
    );
    try {
      await socket.write(_requestBytes(method, target, body, contentType));
      return await _readResponse(socket);
    } finally {
      await socket.close();
    }
  }

  List<int> _requestBytes(
    String method,
    Uri target,
    List<int> body,
    String? contentType,
  ) {
    final path = target.path.isEmpty ? '/' : target.path;
    final requestTarget = target.hasQuery ? '$path?${target.query}' : path;
    final head = StringBuffer()
      ..write('$method $requestTarget HTTP/1.1\r\n')
      ..write('Host: ${target.host}\r\n')
      ..write('User-Agent: $userAgent\r\n')
      ..write('Accept: */*\r\n');
    if (contentType != null) head.write('Content-Type: $contentType\r\n');
    if (method == 'POST' || body.isNotEmpty) {
      head.write('Content-Length: ${body.length}\r\n');
    }
    head.write('Connection: close\r\n\r\n');
    return [...ascii.encode(head.toString()), ...body];
  }

  Future<WebResponse> _readResponse(MailSocket socket) async {
    final status = latin1.decode(
      await socket.readLine(timeout: limits.timeout),
    );
    final match = RegExp(r'^HTTP/1\.[01] (\d{3})(?: .*)?$').firstMatch(status);
    if (match == null) {
      throw const WebException(WebProblem.badResponse, 'not an HTTP answer');
    }
    final headers = <String, List<String>>{};
    for (var count = 0; ; count++) {
      if (count > limits.maxHeaders) {
        throw const WebException(WebProblem.badResponse, 'too many headers');
      }
      final line = latin1.decode(
        await socket.readLine(timeout: limits.timeout),
      );
      if (line.isEmpty) break;
      final colon = line.indexOf(':');
      if (colon <= 0) {
        throw const WebException(WebProblem.badResponse, 'malformed header');
      }
      headers
          .putIfAbsent(line.substring(0, colon).trim().toLowerCase(), () => [])
          .add(line.substring(colon + 1).trim());
    }
    return WebResponse(int.parse(match.group(1)!), headers);
  }

  /// [url] if this client will request it; throws [WebException] otherwise.
  Uri _check(Uri url) {
    String? reason;
    final text = url.toString();
    if (text.length > limits.maxUrlLength) {
      reason = 'the address is too long';
    } else if (url.scheme != 'https') {
      reason = 'only https addresses are used';
    } else if (url.userInfo.isNotEmpty) {
      reason = 'the address contains a user name';
    } else if (url.hasPort && url.port != 443) {
      reason = 'only the standard https port is used';
    } else if (!RegExp(
      r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$',
    ).hasMatch(url.host)) {
      // Also refuses IP addresses (no letters in the last label) and
      // non-ASCII names, which Uri keeps percent-encoded.
      reason = 'not a usable host name';
    } else if (!RegExp(r'[a-z]').hasMatch(url.host.split('.').last)) {
      reason = 'IP addresses are not used';
    } else if (!RegExp(r'^[\x21-\x7E]*$').hasMatch('${url.path}${url.query}')) {
      reason = 'the address contains invalid characters';
    }
    if (reason != null) throw WebException(WebProblem.unsafeUrl, reason);
    return url;
  }

  static Future<List<InternetAddress>> _systemLookup(String host) =>
      InternetAddress.lookup(host);

  static Future<MailSocket> _tlsConnect(
    String host,
    InternetAddress address,
    int port,
    Duration timeout,
  ) => MailSocket.connect(
    // Connects to the checked address; the certificate is checked for
    // the name, so a DNS answer can't redirect the connection unnoticed.
    ServerEndpoint(
      host,
      port,
      ConnectionSecurity.implicitTls,
      connectAddress: address.address,
    ),
    timeout: timeout,
    limits: const MailSocketLimits(
      maxLineLength: 8 * 1024,
      maxBufferedBytes: 256 * 1024,
    ),
  );
}
