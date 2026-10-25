// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';

import 'discovered_settings.dart';
import 'dns_srv.dart';

/// A big mail service a domain's mail is hosted with, as its MX records
/// show (a company's own domain at Google Workspace or Microsoft 365).
enum MailHost {
  /// Google Workspace: Gmail's servers, with an app password.
  google(['google.com', 'googlemail.com']),

  /// Microsoft 365 (Exchange Online): Outlook's servers; mail apps must
  /// sign in on Microsoft's page, passwords are refused.
  microsoft365(['mail.protection.outlook.com', 'mx.microsoft']);

  const MailHost(this._suffixes);

  final List<String> _suffixes;

  bool _hosts(String exchange) {
    final host = exchange.toLowerCase().replaceAll(RegExp(r'\.$'), '');
    return _suffixes.any((s) => host == s || host.endsWith('.$s'));
  }

  /// The service every most-preferred MX record points to, or null (no
  /// records, another host, or a mix). Backup MX records don't count.
  static MailHost? fromMx(List<MxRecord> records) {
    if (records.isEmpty) return null;
    final best = records
        .map((r) => r.preference)
        .reduce((a, b) => a < b ? a : b);
    final primary = records.where((r) => r.preference == best);
    for (final host in values) {
      if (primary.every((r) => host._hosts(r.exchange))) return host;
    }
    return null;
  }
}

/// A mail service whose settings are built into the app, so its addresses
/// need no lookup at all (nothing is asked of DNS, the provider or
/// Mozilla), and whose quirks setup can explain.
final class KnownProvider {
  const KnownProvider({
    required this.id,
    required this.name,
    required this.domains,
    required this.imap,
    required this.smtp,
    this.appPasswordUrl,
  });

  /// `gmail`.
  final String id;
  final String name;

  /// Email domains served by this provider.
  final Set<String> domains;
  final ServerCandidate imap;
  final ServerCandidate smtp;

  /// Where the user creates an app password, for providers that refuse the
  /// account's own password from mail apps; null when the account password
  /// works.
  final String? appPasswordUrl;

  bool get needsAppPassword => appPasswordUrl != null;

  /// Gmail, with an app password (Google account with 2-Step Verification).
  static const gmail = KnownProvider(
    id: 'gmail',
    name: 'Gmail',
    domains: {'gmail.com', 'googlemail.com'},
    imap: ServerCandidate(
      'imap.gmail.com',
      993,
      ConnectionSecurity.implicitTls,
    ),
    smtp: ServerCandidate(
      'smtp.gmail.com',
      465,
      ConnectionSecurity.implicitTls,
    ),
    appPasswordUrl: 'https://myaccount.google.com/apppasswords',
  );

  static const all = [gmail];

  /// The provider of [email]'s domain, or null.
  static KnownProvider? forEmail(String email) {
    final at = email.trim().lastIndexOf('@');
    if (at < 0) return null;
    final domain = email.trim().substring(at + 1).toLowerCase();
    return all.where((p) => p.domains.contains(domain)).firstOrNull;
  }

  /// The provider whose IMAP server is [host] (for saved accounts, and
  /// for work addresses hosted by the provider), or null.
  static KnownProvider? forImapHost(String host) =>
      all.where((p) => p.imap.host == host.toLowerCase()).firstOrNull;

  /// The settings for [email] on this provider.
  DiscoveredSettings settingsFor(
    String email, {
    DiscoverySource source = DiscoverySource.builtIn,
  }) => DiscoveredSettings(
    email: email.trim(),
    imap: imap,
    smtp: smtp,
    username: email.trim(),
    source: source,
  );

  /// App passwords are shown in groups (`abcd efgh ijkl mnop`); the
  /// spaces are not part of the password. Anything else is kept as typed.
  String normalizePassword(String password) {
    if (!needsAppPassword) return password;
    final grouped = RegExp(r'^\s*[a-zA-Z]{4}( [a-zA-Z]{4}){3}\s*$');
    return grouped.hasMatch(password)
        ? password.replaceAll(RegExp(r'\s'), '')
        : password;
  }
}
