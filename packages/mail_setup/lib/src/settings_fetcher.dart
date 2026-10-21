// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Downloads small settings files. Returns null on any failure (not found,
/// TLS error, timeout, too large): discovery simply moves on.
abstract interface class SettingsFetcher {
  Future<String?> fetch(Uri uri);
}

/// Fetches over HTTP(S) privately and strictly:
/// - certificates are always checked (TLS 1.2+); there is no override;
/// - no User-Agent, no cookies, and never the email address in the URL;
/// - HTTPS may redirect only to HTTPS (at most 3 times), HTTP never
///   redirects;
/// - at most [maxBytes] and [timeout] per request.
final class HttpSettingsFetcher implements SettingsFetcher {
  HttpSettingsFetcher({
    this._context,
    this.timeout = const Duration(seconds: 15),
    this.maxBytes = 100 * 1024,
  });

  final SecurityContext? _context;
  final Duration timeout;
  final int maxBytes;

  @override
  Future<String?> fetch(Uri uri) async {
    if (uri.scheme != 'https' && uri.scheme != 'http') return null;
    final client =
        HttpClient(
            context:
                _context ??
                (SecurityContext(withTrustedRoots: true)
                  ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2),
          )
          ..userAgent = null
          ..connectionTimeout = timeout
          ..badCertificateCallback = ((_, _, _) => false);
    try {
      return await _get(
        client,
        uri,
        redirectsLeft: uri.scheme == 'https' ? 3 : 0,
      ).timeout(timeout);
    } on Object {
      return null; // offline, TLS failure, timeout...: try the next source
    } finally {
      client.close(force: true);
    }
  }

  Future<String?> _get(
    HttpClient client,
    Uri uri, {
    required int redirectsLeft,
  }) async {
    final request = await client.getUrl(uri);
    request
      ..followRedirects = false
      ..headers.set(HttpHeaders.acceptHeader, 'application/xml, text/xml');
    final response = await request.close();
    if (response.isRedirect) {
      await response.drain<void>();
      final location = response.headers.value(HttpHeaders.locationHeader);
      final next = location == null ? null : uri.resolve(location);
      if (redirectsLeft <= 0 || next == null || next.scheme != 'https') {
        return null;
      }
      return _get(client, next, redirectsLeft: redirectsLeft - 1);
    }
    if (response.statusCode != 200) {
      await response.drain<void>();
      return null;
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > maxBytes) return null;
    }
    return utf8.decode(bytes, allowMalformed: true);
  }
}
