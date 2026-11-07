// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';

import 'discovered_settings.dart';
import 'mini_xml.dart';

/// Microsoft's Autodiscover (Exchange, hosted Exchange, Outlook-style
/// hosting): the domain's own `autodiscover.xml` service, asked with the
/// Outlook request and read for its IMAP and SMTP `<Protocol>` entries.
/// Only the domain's own servers are ever asked; Microsoft's central
/// service, which would need the full address sent to a third party, is
/// not.
final class AutodiscoverParser {
  const AutodiscoverParser();

  static const requestSchema =
      'http://schemas.microsoft.com/exchange/autodiscover/outlook/requestschema/2006';
  static const responseSchema =
      'http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a';

  static final _hostname = RegExp(
    r'^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$',
  );

  /// The request for [email]'s settings.
  static String request(String email) =>
      '<?xml version="1.0" encoding="utf-8"?>\n'
      '<Autodiscover xmlns="$requestSchema">'
      '<Request>'
      '<EMailAddress>${_escape(email)}</EMailAddress>'
      '<AcceptableResponseSchema>$responseSchema</AcceptableResponseSchema>'
      '</Request>'
      '</Autodiscover>';

  /// Settings for [email] from the answer [xml], or null when it has no
  /// usable encrypted IMAP and SMTP servers (an error, a redirect to
  /// another address or service, Exchange-only protocols).
  DiscoveredSettings? parse(String xml, String email) {
    final XmlElement root;
    try {
      root = const MiniXml().parse(xml);
    } on FormatException {
      return null;
    }
    if (root.name != 'Autodiscover') return null;
    final account = root.first('Response')?.first('Account');
    if (account == null) return null;
    if ((account.childText('Action') ?? 'settings') != 'settings') {
      return null; // redirectAddr / redirectUrl: not followed
    }
    ServerCandidate? imap, smtp;
    String? username;
    for (final protocol in account.all('Protocol')) {
      final type = protocol.childText('Type')?.toUpperCase();
      if (type != 'IMAP' && type != 'SMTP') continue;
      final candidate = _server(protocol);
      if (candidate == null) continue;
      if (type == 'IMAP') {
        imap ??= candidate;
        username ??= protocol.childText('LoginName');
      } else {
        smtp ??= candidate;
      }
    }
    if (imap == null || smtp == null) return null;
    final login = username?.trim() ?? '';
    return DiscoveredSettings(
      email: email,
      imap: imap,
      smtp: smtp,
      username: login.isEmpty ? email : login,
      source: DiscoverySource.autodiscover,
    );
  }

  /// One `<Protocol>` as a server, or null when it is not encrypted or
  /// not usable.
  static ServerCandidate? _server(XmlElement protocol) {
    final host = protocol.childText('Server')?.toLowerCase() ?? '';
    final port = int.tryParse(protocol.childText('Port') ?? '');
    if (!_hostname.hasMatch(host) || port == null || port < 1 || port > 65535) {
      return null;
    }
    final ssl = (protocol.childText('SSL') ?? 'on').toLowerCase() == 'on';
    final encryption = (protocol.childText('Encryption') ?? '').toUpperCase();
    final encrypted = ssl || encryption == 'TLS' || encryption == 'SSL';
    if (!encrypted) return null; // plain text: never used
    final implicit = port == 993 || port == 465;
    return ServerCandidate(
      host,
      port,
      implicit ? ConnectionSecurity.implicitTls : ConnectionSecurity.startTls,
    );
  }

  static String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
