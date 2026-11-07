// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_trust/mail_trust.dart';

import 'autoconfig_parser.dart';
import 'discovered_settings.dart';
import 'dns_srv.dart';
import 'known_providers.dart';
import 'settings_fetcher.dart';
import 'verification.dart';

/// A discovery step, for showing progress.
enum DiscoveryStep {
  /// The domain's own settings file over HTTPS.
  providerFileSecure,

  /// Mozilla's database (only with consent).
  mozillaDatabase,

  /// The domain's MX records.
  dnsRecords,

  /// The settings file and Mozilla's entry of the mail host the MX
  /// records point to.
  mailHostProviderFile,

  /// The domain's own settings file over plain HTTP.
  providerFileUnencrypted,

  /// SRV records naming the servers.
  dnsService,

  /// Common server names.
  probing,
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
/// Otherwise it tries sources in this order and stops at the first that
/// works:
///
/// 1. the domain's own settings file over HTTPS
///    (`autoconfig.<domain>`, then `<domain>/.well-known`);
/// 2. Mozilla's database, only if [askMozillaConsent] allows it (asked
///    once per discovery);
/// 3. DNS MX records: Google Workspace or Microsoft 365 are recognised;
///    any other mail host's base domain gets steps 1 and 2 again, which
///    is what finds the settings of a custom domain hosted with a
///    provider;
/// 4. the domain's own settings file over plain HTTP (cPanel often
///    serves only this), used only when it names servers of the domain
///    or of its mail host, each with a valid certificate;
/// 5. DNS SRV records (RFC 6186 / 8314);
/// 6. common host names, each required to have a valid certificate.
///
/// Privacy: the email address itself goes only to the domain's own
/// servers and to those of its mail host (its provider), in the HTTPS
/// request for the settings file (some providers need it). Everything
/// else (Mozilla, DNS, the plain-HTTP request, probing) sees the domain
/// only. Results from unauthenticated
/// sources (3 to 6) are only used if their servers answer with a valid
/// certificate, and are flagged for the user to confirm
/// ([DiscoveredSettings.warnings]).
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

    DiscoveredSettings? fromFile(
      String? xml,
      DiscoverySource source, {
      String? mailHostDomain,
    }) {
      if (xml == null) return null;
      final (settings, problem) = _parser.parse(
        xml,
        address,
        source,
        mailHostDomain: mailHostDomain,
      );
      if (problem == AutoconfigProblem.oauthOnly) oauthOnly = true;
      return settings;
    }

    // The provider's own file over HTTPS, with the address (some
    // providers answer per mailbox), then the well-known place.
    Future<DiscoveredSettings?> providerFiles(
      String forDomain, {
      String? mailHostDomain,
    }) async {
      for (final uri in [
        Uri.https('autoconfig.$forDomain', '/mail/config-v1.1.xml', {
          'emailaddress': address,
        }),
        Uri.https(forDomain, '/.well-known/autoconfig/mail/config-v1.1.xml'),
      ]) {
        final found = fromFile(
          await _fetcher.fetch(uri),
          DiscoverySource.httpsAutoconfig,
          mailHostDomain: mailHostDomain,
        );
        if (found != null) return found;
      }
      return null;
    }

    // Mozilla's database: an outside service, so only with consent, asked
    // once. Only the domain is sent.
    bool? mozillaAllowed;
    Future<DiscoveredSettings?> mozilla(
      String forDomain, {
      String? mailHostDomain,
    }) async {
      if (askMozillaConsent == null) return null;
      mozillaAllowed ??= await askMozillaConsent(domain);
      if (!mozillaAllowed!) return null;
      onStep?.call(DiscoveryStep.mozillaDatabase);
      return fromFile(
        await _fetcher.fetch(Uri.parse('$mozillaBase$forDomain')),
        DiscoverySource.mozillaDatabase,
        mailHostDomain: mailHostDomain,
      );
    }

    // 1 and 2: the domain itself.
    onStep?.call(DiscoveryStep.providerFileSecure);
    final own = await providerFiles(domain);
    if (own != null) return DiscoveryResult(own);
    final fromMozilla = await mozilla(domain);
    if (fromMozilla != null) return DiscoveryResult(fromMozilla);

    // 3: where the domain's mail really goes.
    onStep?.call(DiscoveryStep.dnsRecords);
    final mx = await _mx.lookupMx(domain);
    switch (MailHost.fromMx(mx)) {
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
    final hostDomain = mailHostDomain(domain, mx);
    if (hostDomain != null) {
      onStep?.call(DiscoveryStep.mailHostProviderFile);
      final hosted =
          await providerFiles(hostDomain, mailHostDomain: hostDomain) ??
          await mozilla(hostDomain, mailHostDomain: hostDomain);
      if (hosted != null) return DiscoveryResult(hosted);
    }

    // 4: unencrypted, so anyone on the network could have written it. It
    // may only name servers of the domain itself or of its mail host
    // (each then checked with a real TLS connection); a file that names
    // anything else is thrown away as if it had not been served. The
    // address is never sent in the clear.
    onStep?.call(DiscoveryStep.providerFileUnencrypted);
    final fromHttp = fromFile(
      await _fetcher.fetch(
        Uri.parse('http://autoconfig.$domain/mail/config-v1.1.xml'),
      ),
      DiscoverySource.httpAutoconfig,
      mailHostDomain: hostDomain,
    );
    if (fromHttp != null &&
        servesDomain(fromHttp, domain, mx) &&
        await _reachable(fromHttp)) {
      return DiscoveryResult(fromHttp);
    }

    // 5 and 6: DNS SRV, then guessing.
    onStep?.call(DiscoveryStep.dnsService);
    final fromDns = await _fromSrv(address, domain);
    if (fromDns != null) return DiscoveryResult(fromDns);

    onStep?.call(DiscoveryStep.probing);
    final probed = await _probe(address, domain);
    if (probed != null) return DiscoveryResult(probed);

    return DiscoveryResult(null, oauthOnly: oauthOnly);
  }

  /// The base (registrable) domain of the most preferred MX record, when
  /// it is another domain than [domain]'s own: `privateemail.com` for an
  /// MX of `mx1.privateemail.com`. Null when the mail is handled within
  /// the domain itself, or there are no records.
  static String? mailHostDomain(String domain, List<MxRecord> mx) {
    final own = Domains.registrable(domain);
    for (final record in mx) {
      final base = Domains.registrable(_exchange(record));
      if (base == null) continue;
      return base == own ? null : base;
    }
    return null;
  }

  static String _exchange(MxRecord record) =>
      record.exchange.replaceAll(RegExp(r'\.$'), '').toLowerCase();

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

  /// Whether every server in [settings] belongs to [domain] or to the
  /// mail host its [mx] records name: the same registrable domain (by the
  /// public suffix list, so `mail.example.co.uk` belongs to
  /// `example.co.uk`, and `imap.hoster.example` to an MX of
  /// `mx1.hoster.example`). Settings from a source that could have been
  /// tampered with are used only when this holds.
  static bool servesDomain(
    DiscoveredSettings settings,
    String domain,
    List<MxRecord> mx,
  ) {
    final allowed = <String>{
      ?Domains.registrable(domain),
      for (final record in mx) ?Domains.registrable(_exchange(record)),
    };
    if (allowed.isEmpty) return false;
    for (final host in [settings.imap.host, settings.smtp.host]) {
      final registrable = Domains.registrable(host);
      if (registrable == null || !allowed.contains(registrable)) return false;
    }
    return true;
  }
}
