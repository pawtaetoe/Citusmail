// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';

import 'discovered_settings.dart';
import 'mini_xml.dart';

/// Why a settings file could not be used.
enum AutoconfigProblem {
  /// Not a valid settings file.
  invalid,

  /// No encrypted IMAP or SMTP server listed (plain-text ones are ignored).
  noSecureServers,

  /// The provider only allows OAuth2 login (not supported yet).
  oauthOnly,
}

/// Reads Thunderbird-style autoconfig files (config-v1.1.xml), as served by
/// providers, cPanel and Mozilla's database.
final class AutoconfigParser {
  const AutoconfigParser();

  static final _hostname = RegExp(
    r'^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$',
  );

  /// Settings for [email] from [xml], or the reason there are none.
  (DiscoveredSettings?, AutoconfigProblem?) parse(
    String xml,
    String email,
    DiscoverySource source,
  ) {
    final XmlElement root;
    try {
      root = const MiniXml().parse(xml);
    } on FormatException {
      return (null, AutoconfigProblem.invalid);
    }
    final provider = root.name == 'clientConfig'
        ? root.first('emailProvider')
        : null;
    if (provider == null) return (null, AutoconfigProblem.invalid);

    final imaps = [
      for (final s in provider.all('incomingServer'))
        if (s.attributes['type'] == 'imap') s,
    ];
    final smtps = [
      for (final s in provider.all('outgoingServer'))
        if (s.attributes['type'] == 'smtp') s,
    ];
    final imap = _best(imaps, email);
    final smtp = _best(smtps, email);
    if (imap == null || smtp == null) {
      final anyServer = [...imaps, ...smtps];
      final oauthOnly =
          anyServer.isNotEmpty &&
          anyServer.every((s) => _auth(s).every((a) => a == 'OAuth2'));
      return (
        null,
        oauthOnly
            ? AutoconfigProblem.oauthOnly
            : AutoconfigProblem.noSecureServers,
      );
    }
    final username = _substitute(imap.$2, email);
    return (
      DiscoveredSettings(
        email: email,
        imap: imap.$1,
        smtp: smtp.$1,
        username: username,
        source: source,
      ),
      null,
    );
  }

  /// The best usable server: implicit TLS before STARTTLS; password login.
  (ServerCandidate, String)? _best(List<XmlElement> servers, String email) {
    final usable = <(ServerCandidate, String)>[];
    for (final s in servers) {
      final security = switch (s.childText('socketType')?.toUpperCase()) {
        'SSL' || 'TLS' => ConnectionSecurity.implicitTls,
        'STARTTLS' => ConnectionSecurity.startTls,
        _ => null, // "plain": never used
      };
      final host = _substitute(
        s.childText('hostname') ?? '',
        email,
      ).toLowerCase();
      final port = int.tryParse(s.childText('port') ?? '');
      final auth = _auth(s);
      final passwordLogin =
          auth.isEmpty ||
          auth.any((a) => a.startsWith('password-') || a == 'plain');
      if (security == null ||
          port == null ||
          port < 1 ||
          port > 65535 ||
          !_hostname.hasMatch(host) ||
          !passwordLogin) {
        continue;
      }
      usable.add((
        ServerCandidate(host, port, security),
        s.childText('username') ?? '%EMAILADDRESS%',
      ));
    }
    usable.sort(
      (a, b) => a.$1.security.index.compareTo(b.$1.security.index),
    ); // implicitTls first
    return usable.firstOrNull;
  }

  static List<String> _auth(XmlElement server) => [
    for (final a in server.all('authentication')) a.text,
  ];

  static String _substitute(String value, String email) {
    final at = email.lastIndexOf('@');
    return value
        .replaceAll('%EMAILADDRESS%', email)
        .replaceAll('%EMAILLOCALPART%', email.substring(0, at))
        .replaceAll('%EMAILDOMAIN%', email.substring(at + 1));
  }
}
