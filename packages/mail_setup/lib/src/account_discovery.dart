// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';

import 'autoconfig_parser.dart';
import 'discovered_settings.dart';
import 'dns_srv.dart';
import 'known_providers.dart';
import 'settings_fetcher.dart';
import 'verification.dart';

/// A discovery step, for showing progress.
enum DiscoveryStep {
  providerFileSecure,
  dnsRecords,
  providerFileUnencrypted,
  probing,
  mozillaDatabase,
}

/// The outcome of discovery.
final class DiscoveryResult {
  const DiscoveryResult(this.settings, {this.oauthOnly = false, this.host});

  /// Null when nothing usable was found (use the manual form).
  final DiscoveredSettings? settings;

  /// The provider requires OAuth2 login, which is not supported yet.
  final bool oauthOnly;

  /// The big mail service the domain is hosted with, when its MX records
  /// show one. For [MailHost.microsoft365] there are no settings: the
  /// account signs in on Microsoft's page.
  final MailHost? host;
}

/// Finds server settings for an email address. Well-known providers
/// ([KnownProvider]) are answered from the app itself, with no lookup.
/// Otherwise it tries sources from most to least trustworthy and stops at
/// the first that works:
///
/// 1. the provider's settings file over HTTPS;
/// 2. DNS: MX records pointing to Google Workspace or Microsoft 365, then
///    SRV records (RFC 6186 / 8314);
/// 3. the provider's settings file over HTTP (cPanel often serves only this);
/// 4. common host names, each required to have a valid certificate;
/// 5. Mozilla's database, only if [askMozillaConsent] allows it.
///
/// Only the domain is ever looked up; the full address is never sent.
/// Results from unauthenticated sources (2-4) are only used if their
/// servers answer with a valid certificate, and are flagged for the user
/// to confirm ([DiscoveredSettings.warnings]).
final class AccountDiscovery {
  AccountDiscovery({
    SettingsFetcher? fetcher,
    SrvResolver? srv,
    MxResolver? mx,
    ServerAvailability? prober,
    this.mozillaBase = 'https://autoconfig.thunderbird.net/v1.1/',
  }) : _fetcher = fetcher ?? HttpSettingsFetcher(),
       _srv = srv ?? UdpSrvResolver.system(),
       _mx = mx ?? _mxOf(srv ?? UdpSrvResolver.system()),
       _prober = prober ?? const ServerProber();

  final SettingsFetcher _fetcher;
  final SrvResolver _srv;
  final MxResolver _mx;

  /// The SRV resolver also answers MX queries (the system's, or none).
  static MxResolver _mxOf(SrvResolver srv) =>
      srv is MxResolver ? srv as MxResolver : const NoSrvResolver();
  final ServerAvailability _prober;
  final String mozillaBase;

  static const _parser = AutoconfigParser();
  static final _email = RegExp(
    r'^[^@\s]+@([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+)$',
  );

  Future<DiscoveryResult> discover(
    String email, {
    Future<bool> Function(String domain)? askMozillaConsent,
    void Function(DiscoveryStep step)? onStep,
  }) async {
    final match = _email.firstMatch(email.trim());
    if (match == null) {
      throw ArgumentError.value(
        email,
        'email',
        'not a supported email address',
      );
    }
    final address = email.trim();
    final domain = match.group(1)!.toLowerCase();
    if (KnownProvider.forEmail(address) case final known?) {
      return DiscoveryResult(known.settingsFor(address));
    }
    var oauthOnly = false;

    DiscoveredSettings? fromFile(String? xml, DiscoverySource source) {
      if (xml == null) return null;
      final (settings, problem) = _parser.parse(xml, address, source);
      if (problem == AutoconfigProblem.oauthOnly) oauthOnly = true;
      return settings;
    }

    onStep?.call(DiscoveryStep.providerFileSecure);
    for (final uri in [
      Uri.parse('https://autoconfig.$domain/mail/config-v1.1.xml'),
      Uri.parse('https://$domain/.well-known/autoconfig/mail/config-v1.1.xml'),
    ]) {
      final found = fromFile(
        await _fetcher.fetch(uri),
        DiscoverySource.httpsAutoconfig,
      );
      if (found != null) return DiscoveryResult(found);
    }

    onStep?.call(DiscoveryStep.dnsRecords);
    switch (MailHost.fromMx(await _mx.lookupMx(domain))) {
      case MailHost.google:
        return DiscoveryResult(
          KnownProvider.gmail.settingsFor(
            address,
            source: DiscoverySource.mailHost,
          ),
          host: MailHost.google,
        );
      case MailHost.microsoft365:
        return const DiscoveryResult(null, host: MailHost.microsoft365);
      case null:
        break;
    }
    final fromDns = await _fromSrv(address, domain);
    if (fromDns != null) return DiscoveryResult(fromDns);

    onStep?.call(DiscoveryStep.providerFileUnencrypted);
    final fromHttp = fromFile(
      await _fetcher.fetch(
        Uri.parse('http://autoconfig.$domain/mail/config-v1.1.xml'),
      ),
      DiscoverySource.httpAutoconfig,
    );
    if (fromHttp != null && await _reachable(fromHttp)) {
      return DiscoveryResult(fromHttp);
    }

    onStep?.call(DiscoveryStep.probing);
    final probed = await _probe(address, domain);
    if (probed != null) return DiscoveryResult(probed);

    if (askMozillaConsent != null && await askMozillaConsent(domain)) {
      onStep?.call(DiscoveryStep.mozillaDatabase);
      final found = fromFile(
        await _fetcher.fetch(Uri.parse('$mozillaBase$domain')),
        DiscoverySource.mozillaDatabase,
      );
      if (found != null) return DiscoveryResult(found);
    }
    return DiscoveryResult(null, oauthOnly: oauthOnly);
  }

  Future<DiscoveredSettings?> _fromSrv(String email, String domain) async {
    Future<ServerCandidate?> first(
      String service,
      ConnectionSecurity security,
    ) async {
      final records = await _srv.lookup('$service._tcp.$domain');
      final record = records.firstOrNull;
      return record == null
          ? null
          : ServerCandidate(record.target, record.port, security);
    }

    final imap =
        await first('_imaps', ConnectionSecurity.implicitTls) ??
        await first('_imap', ConnectionSecurity.startTls);
    final smtp =
        await first('_submissions', ConnectionSecurity.implicitTls) ??
        await first('_submission', ConnectionSecurity.startTls);
    if (imap == null || smtp == null) return null;
    final settings = DiscoveredSettings(
      email: email,
      imap: imap,
      smtp: smtp,
      username: email,
      source: DiscoverySource.dnsSrv,
    );
    return await _reachable(settings) ? settings : null;
  }

  /// Common host names, implicit TLS first. Probes run in parallel.
  Future<DiscoveredSettings?> _probe(String email, String domain) async {
    final imapCandidates = [
      for (final host in [domain, 'imap.$domain', 'mail.$domain']) ...[
        ServerCandidate(host, 993, ConnectionSecurity.implicitTls),
        ServerCandidate(host, 143, ConnectionSecurity.startTls),
      ],
    ];
    final smtpCandidates = [
      for (final host in [domain, 'smtp.$domain', 'mail.$domain']) ...[
        ServerCandidate(host, 465, ConnectionSecurity.implicitTls),
        ServerCandidate(host, 587, ConnectionSecurity.startTls),
      ],
    ];
    final imapOk = await Future.wait(imapCandidates.map(_prober.imapAvailable));
    final smtpOk = await Future.wait(smtpCandidates.map(_prober.smtpAvailable));
    final imap = [
      for (var i = 0; i < imapOk.length; i++)
        if (imapOk[i]) imapCandidates[i],
    ].firstOrNull;
    final smtp = [
      for (var i = 0; i < smtpOk.length; i++)
        if (smtpOk[i]) smtpCandidates[i],
    ].firstOrNull;
    if (imap == null || smtp == null) return null;
    return DiscoveredSettings(
      email: email,
      imap: imap,
      smtp: smtp,
      username: email,
      source: DiscoverySource.probed,
    );
  }

  Future<bool> _reachable(DiscoveredSettings s) async =>
      await _prober.imapAvailable(s.imap) &&
      await _prober.smtpAvailable(s.smtp);
}
