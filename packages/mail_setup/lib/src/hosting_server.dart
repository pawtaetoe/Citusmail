// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';

import 'discovered_settings.dart';
import 'dns_srv.dart';
import 'verification.dart';

/// Finds the name a shared hosting server goes by, when a domain's own
/// mail name points at it.
///
/// On cPanel hosting (Namecheap, HostGator, Bluehost, A2 and others),
/// `mail.example.com` points at a shared server such as
/// `business905-5.web-hosting.com`, whose certificate is for that name or
/// for `*.web-hosting.com`, never for the customer's domain. Signing in
/// to `mail.example.com` therefore fails with a host name mismatch,
/// rightly. The server's own name is usually what its address points
/// back to (its PTR record).
///
/// A name is suggested only when the certificate the server presented
/// covers it, and a fresh connection to that name passes the full
/// certificate check (nothing is logged in to; no password is sent).
/// DNS answers are not authenticated, but since the connection is checked
/// against the name actually connected to, a forged PTR record gains
/// nothing beyond what typing that name would. The user still decides:
/// the name is only offered.
final class HostingServerFinder {
  HostingServerFinder({HostNameResolver? resolver, ServerAvailability? prober})
    : _resolver = resolver ?? HostNameResolver.system(),
      _prober = prober ?? const ServerProber();

  final HostNameResolver _resolver;
  final ServerAvailability _prober;

  /// At most this many addresses and names are looked at.
  static const _limit = 4;

  static final _hostName = RegExp(
    r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$',
  );

  /// The hosting server's own name for the server that [failure] is
  /// about, or null when there is no such name, it isn't covered by the
  /// certificate, or it doesn't pass the certificate check itself.
  Future<String?> find(
    DiscoveredSettings settings,
    VerificationResult failure,
  ) async {
    final certificate = failure.certificate;
    final role = failure.role;
    if (failure.tlsFailure != TlsFailure.hostnameMismatch ||
        certificate == null ||
        role == null) {
      return null;
    }
    final server = role == ServerRole.imap ? settings.imap : settings.smtp;
    final other = role == ServerRole.imap ? settings.smtp : settings.imap;
    final host = _clean(server.host);

    final names = <String>{};
    final addresses = await _resolver.lookupAddresses(host);
    for (final address in addresses.take(_limit)) {
      for (final ptr in await _resolver.lookupPtr(address)) {
        final name = _clean(ptr);
        if (name != host &&
            _hostName.hasMatch(name) &&
            certificate.covers(name)) {
          names.add(name);
        }
      }
    }

    for (final name in names.take(_limit)) {
      if (!await _available(role, server, name)) continue;
      // The other server moves too when it has the same name, so it must
      // pass as well.
      if (_clean(other.host) == host &&
          !await _available(
            role == ServerRole.imap ? ServerRole.smtp : ServerRole.imap,
            other,
            name,
          )) {
        continue;
      }
      return name;
    }
    return null;
  }

  Future<bool> _available(
    ServerRole role,
    ServerCandidate server,
    String name,
  ) async {
    final candidate = ServerCandidate(name, server.port, server.security);
    try {
      return role == ServerRole.imap
          ? await _prober.imapAvailable(candidate)
          : await _prober.smtpAvailable(candidate);
    } on Object {
      return false;
    }
  }

  static String _clean(String name) =>
      name.trim().toLowerCase().replaceFirst(RegExp(r'\.$'), '');
}
