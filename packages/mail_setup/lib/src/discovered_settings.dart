// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';

/// Where discovered settings came from.
enum DiscoverySource {
  /// The provider's settings file over HTTPS (trusted).
  httpsAutoconfig(authenticated: true),

  /// DNS SRV records (RFC 6186). DNS answers are not authenticated.
  dnsSrv(authenticated: false),

  /// The provider's settings file over plain HTTP (could be altered).
  httpAutoconfig(authenticated: false),

  /// Found by trying common host names (each with a valid certificate).
  probed(authenticated: false),

  /// Mozilla's database over HTTPS (trusted, third party).
  mozillaDatabase(authenticated: true),

  /// Built into the app for a well-known provider (no lookup at all).
  builtIn(authenticated: true),

  /// The domain's MX records point to a well-known host (Google
  /// Workspace). DNS is not authenticated, but the servers used are the
  /// host's own, built into the app: a forged answer could only send the
  /// login to Google, never to the forger.
  mailHost(authenticated: true),

  /// Typed by the user.
  manual(authenticated: true);

  const DiscoverySource({required this.authenticated});

  /// True when nobody between the app and the source could have changed the
  /// answer (HTTPS with a valid certificate, or the user).
  final bool authenticated;
}

/// Something the user should look at before the settings are used.
enum SetupWarning {
  /// Found over an unencrypted channel (HTTP or DNS): someone on the
  /// network could have changed it.
  unauthenticatedSource,

  /// A server is outside the email address's domain, so the password would
  /// go to a different organisation's server.
  serverOutsideDomain,
}

/// One server.
final class ServerCandidate {
  const ServerCandidate(this.host, this.port, this.security);

  final String host;
  final int port;
  final ConnectionSecurity security;

  ServerEndpoint get endpoint => ServerEndpoint(host, port, security);

  @override
  bool operator ==(Object other) =>
      other is ServerCandidate &&
      other.host == host &&
      other.port == port &&
      other.security == security;

  @override
  int get hashCode => Object.hash(host, port, security);

  @override
  String toString() => '$host:$port (${security.name})';
}

/// Settings for an account, as found (not yet verified).
final class DiscoveredSettings {
  DiscoveredSettings({
    required this.email,
    required this.imap,
    required this.smtp,
    required this.username,
    required this.source,
  }) : warnings = List.unmodifiable(_warningsFor(email, imap, smtp, source));

  final String email;
  final ServerCandidate imap;
  final ServerCandidate smtp;

  /// Login name (often the email address).
  final String username;
  final DiscoverySource source;
  final List<SetupWarning> warnings;

  /// Whether the user must confirm these settings before the password is
  /// sent anywhere.
  bool get needsConfirmation => warnings.isNotEmpty;

  String get domain =>
      email.substring(email.lastIndexOf('@') + 1).toLowerCase();

  static List<SetupWarning> _warningsFor(
    String email,
    ServerCandidate imap,
    ServerCandidate smtp,
    DiscoverySource source,
  ) {
    final domain = email.substring(email.lastIndexOf('@') + 1).toLowerCase();
    return [
      if (!source.authenticated) SetupWarning.unauthenticatedSource,
      if (source != DiscoverySource.manual &&
          source != DiscoverySource.builtIn &&
          source != DiscoverySource.mailHost &&
          (!isWithinDomain(imap.host, domain) ||
              !isWithinDomain(smtp.host, domain)))
        SetupWarning.serverOutsideDomain,
    ];
  }

  /// [host] is [domain] or one of its subdomains.
  static bool isWithinDomain(String host, String domain) {
    final h = host.toLowerCase(), d = domain.toLowerCase();
    return h == d || h.endsWith('.$d');
  }

  @override
  String toString() =>
      'DiscoveredSettings(${source.name}: IMAP $imap, SMTP $smtp, user $username)';
}
