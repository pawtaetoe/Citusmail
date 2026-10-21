// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

/// How a connection is secured.
enum ConnectionSecurity {
  /// TLS from the first byte (IMAP 993, SMTP 465). Preferred.
  implicitTls,

  /// Plain connection upgraded with STARTTLS before login (IMAP 143,
  /// SMTP 587). STARTTLS is required: if the server does not offer it, the
  /// connection is refused rather than continued unencrypted.
  startTls,
}

/// A mail server address.
final class ServerEndpoint {
  const ServerEndpoint(
    this.host,
    this.port,
    this.security, {
    this.connectAddress,
  });

  /// The server's name. The TLS certificate must be valid for this name.
  final String host;

  /// Where to open the connection, when different from [host] (for example
  /// a pinned IP address, or 127.0.0.1 in tests). The certificate is still
  /// checked against [host], so this never weakens TLS.
  final String? connectAddress;
  final int port;
  final ConnectionSecurity security;

  @override
  String toString() => '$host:$port (${security.name})';
}

/// Which certificates to trust.
///
/// The default trusts the operating system's certificate authorities, as
/// a browser does. Certificate checks can never be turned off; tests use
/// [trustOnly] with the local test CA instead.
final class TlsSettings {
  const TlsSettings() : _trustedPem = null;

  /// Trusts only the given PEM certificate(s), not the system store.
  const TlsSettings.trustOnly(List<int> pem) : _trustedPem = pem;

  final List<int>? _trustedPem;

  /// A context requiring TLS 1.2 or newer.
  SecurityContext createContext() {
    final pem = _trustedPem;
    final context = SecurityContext(withTrustedRoots: pem == null)
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2;
    if (pem != null) context.setTrustedCertificatesBytes(pem);
    return context;
  }
}
