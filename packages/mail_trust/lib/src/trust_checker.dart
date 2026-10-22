// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_view/mail_view.dart';

import 'attachments.dart';
import 'authentication_results.dart';
import 'brands.dart';
import 'domains.dart';
import 'links.dart';
import 'trust_report.dart';

/// What the checker knows besides the message itself.
final class TrustContext {
  const TrustContext({this.trustedAuthServId, this.ownDomains = const {}});

  /// The user's own server's name in `Authentication-Results` (see
  /// [AuthServIds.learn]); null until it is known, and then sender
  /// verification is skipped.
  final String? trustedAuthServId;

  /// Registrable domains of the user's own addresses, to spot lookalikes
  /// such as `tommykunq.cc` for `tommykung.cc`.
  final Set<String> ownDomains;
}

/// Checks a message for the signs of phishing, on the device. Never
/// touches the network and never moves mail: it only reports.
final class TrustChecker {
  const TrustChecker();

  TrustReport check(
    MessageView view, [
    TrustContext context = const TrustContext(),
  ]) {
    final check = _Check(view, context)
      ..sender()
      ..displayName()
      ..links()
      ..attachments();
    return check.report();
  }
}

/// One run of the checks over one message.
final class _Check {
  _Check(this.view, this.context)
    : from = view.message.from.firstOrNull,
      fromDomain = _domainOf(view.message.from.firstOrNull),
      fromRegistrable = view.message.from.firstOrNull == null
          ? null
          : Domains.registrable(view.message.from.first.domain);

  final MessageView view;
  final TrustContext context;
  final MailAddress? from;
  final String? fromDomain;
  final String? fromRegistrable;

  final _findings = <TrustFinding>[];
  final _links = <String, LinkVerdict>{};
  final _attachments = <String, AttachmentVerdict>{};
  var _verified = false;

  /// Brands already reported as imitated, so one trick gives one finding.
  final _imitated = <Brand>{};

  static String? _domainOf(MailAddress? address) =>
      address == null ? null : Domains.normalize(address.domain);

  void _add(FindingKind kind, TrustLevel level, String message) =>
      _findings.add(TrustFinding(kind, level, message));

  // ------------------------------------------------------------- sender

  /// Verification by the user's server, and the look of the domain.
  void sender() {
    _verification();
    final domain = fromDomain;
    final registrable = fromRegistrable;
    if (domain == null || registrable == null) return;

    final deceptive = domain.split('.').where(Lookalikes.isDeceptive);
    final brand = Brands.imitatedBy(registrable);
    if (brand != null) _imitated.add(brand);
    if (deceptive.isNotEmpty) {
      _add(
        FindingKind.mixedScripts,
        TrustLevel.danger,
        'The sender\'s address uses letters from another alphabet to look like '
        '"${Lookalikes.skeleton(registrable)}"'
        '${brand == null ? '' : ' (${brand.name})'}.',
      );
    } else if (brand != null) {
      _add(
        FindingKind.lookalikeDomain,
        TrustLevel.danger,
        'The sender\'s address ($registrable) imitates ${brand.name}.',
      );
    }

    for (final own in context.ownDomains) {
      if (own != registrable &&
          Lookalikes.skeleton(own, digits: true) ==
              Lookalikes.skeleton(registrable, digits: true)) {
        _add(
          FindingKind.lookalikeDomain,
          TrustLevel.danger,
          'The sender\'s address ($registrable) looks like your own domain, $own.',
        );
      }
    }
  }

  void _verification() {
    final values = view.message.headers
        .all('authentication-results')
        .map((f) => f.value);
    final results = AuthServIds.trusted(values, context.trustedAuthServId);
    if (results.isEmpty) return;

    final registrable = fromRegistrable;
    AuthResult? dmarc, spf;
    for (final r in results) {
      dmarc ??= r.dmarc;
      spf ??= r.spf;
      for (final dkim in r.dkim) {
        final d = dkim.domain;
        if (dkim.passed &&
            registrable != null &&
            d != null &&
            Domains.registrable(d) == registrable) {
          _verified = true;
        }
      }
    }
    if (dmarc?.passed ?? false) _verified = true;

    final shown = fromDomain ?? 'the address it shows';
    if (dmarc != null && dmarc.failed) {
      // Mailing lists that keep the author's address break DMARC honestly;
      // still worth a warning, but not an alarm.
      final list = view.message.headers.contains('list-id');
      _add(
        FindingKind.failedVerification,
        list ? TrustLevel.caution : TrustLevel.danger,
        'Your mail server couldn\'t confirm this came from $shown. '
        '${list ? 'Mailing lists sometimes cause this.' : 'The sender may be forged.'}',
      );
    } else if (dmarc == null &&
        !_verified &&
        spf != null &&
        spf.failed &&
        registrable != null &&
        spf.domain != null &&
        Domains.registrable(spf.domain!) == registrable) {
      _add(
        FindingKind.failedVerification,
        TrustLevel.caution,
        'Your mail server couldn\'t confirm this came from $shown.',
      );
    }
  }

  // -------------------------------------------------------- display name

  void displayName() {
    final address = from;
    final registrable = fromRegistrable;
    if (address == null || registrable == null) return;
    final name = address.displayName;

    final claimed = Brands.claimedBy(name);
    if (claimed != null && !claimed.owns(registrable)) {
      if (_imitated.add(claimed)) {
        _add(
          FindingKind.impersonatedBrand,
          claimed.distinctive ? TrustLevel.danger : TrustLevel.caution,
          'The sender calls itself ${claimed.name}, but writes from '
          '$registrable, which ${claimed.name} doesn\'t use.',
        );
      }
    }

    // "service@paypal.com" <someone@elsewhere.example>
    final shown = _emailInName.firstMatch(name ?? '');
    if (shown != null) {
      final shownRegistrable = Domains.registrable(shown.group(1)!);
      if (shownRegistrable != null && shownRegistrable != registrable) {
        final owner = Brands.owner(shownRegistrable);
        _add(
          FindingKind.addressInName,
          owner != null ? TrustLevel.danger : TrustLevel.caution,
          'The name shows the address ${shown.group(0)}, but the mail came '
          'from ${address.address}.',
        );
      }
    }
  }

  static final _emailInName = RegExp(
    '[^\\s<>"@()]+@([a-zA-Z0-9\\u00a1-\\uffff-]+(?:\\.[a-zA-Z0-9\\u00a1-\\uffff-]+)+)',
  );

  // --------------------------------------------------------------- links

  void links() {
    for (final shown in DocumentLinks.collect(view.body)) {
      final verdict = _checkLink(shown);
      if (verdict == null) continue;
      final key = shown.link.toString();
      final previous = _links[key];
      _links[key] = previous == null
          ? verdict
          : LinkVerdict(
              shown.link,
              previous.level.max(verdict.level),
              {...previous.reasons, ...verdict.reasons}.toList(),
            );
    }
    final dangerous = _links.values.where((v) => v.level == TrustLevel.danger);
    if (dangerous.isNotEmpty) {
      _add(
        FindingKind.deceptiveLink,
        TrustLevel.danger,
        dangerous.first.reasons.first,
      );
    }
  }

  LinkVerdict? _checkLink(ShownLink shown) {
    final link = shown.link;
    if (link.scheme != 'http' && link.scheme != 'https') return null;
    final host = _decoded(link.host);
    if (host.isEmpty) return null;

    var level = TrustLevel.ok;
    final reasons = <String>[];
    void flag(TrustLevel l, String reason) {
      level = level.max(l);
      reasons.add(reason);
    }

    if (link.userInfo.isNotEmpty) {
      flag(
        TrustLevel.danger,
        'The link hides where it goes: it opens $host, not '
        '${_decoded(link.userInfo)}.',
      );
    }
    if (Domains.isIpAddress(host)) {
      flag(
        TrustLevel.caution,
        'The link goes to a numeric internet address, not a named site.',
      );
    }

    final normalized = Domains.normalize(host);
    final registrable = Domains.registrable(host);
    final imitated = registrable == null
        ? null
        : Brands.imitatedBy(registrable);
    if (normalized != null &&
        normalized.split('.').any(Lookalikes.isDeceptive)) {
      flag(
        TrustLevel.danger,
        'The link\'s address uses letters from another alphabet to look like '
        '"${Lookalikes.skeleton(normalized)}".',
      );
    } else if (imitated != null) {
      flag(
        TrustLevel.danger,
        'The link goes to $registrable, which imitates ${imitated.name}.',
      );
    }

    final text = DocumentLinks.shownHost(shown.text);
    final textRegistrable = text == null ? null : Domains.registrable(text);
    if (textRegistrable != null && textRegistrable != registrable) {
      final brand = Brands.owner(textRegistrable);
      final sameOwner =
          brand != null && registrable != null && brand.owns(registrable);
      if (!sameOwner) {
        flag(
          brand != null ? TrustLevel.danger : TrustLevel.caution,
          'The link shows $text but goes to ${registrable ?? host}.',
        );
      }
    }
    return reasons.isEmpty ? null : LinkVerdict(link, level, reasons);
  }

  /// Percent-decoded (Dart's Uri encodes non-ASCII hosts); as written if
  /// the encoding is broken.
  static String _decoded(String s) {
    try {
      return Uri.decodeComponent(s);
    } on ArgumentError {
      return s;
    } on FormatException {
      return s; // percent-encoded bytes that are not UTF-8
    }
  }

  // --------------------------------------------------------- attachments

  void attachments() {
    for (final attachment in view.attachments) {
      final verdict = RiskyFiles.check(attachment.fileName);
      if (verdict != null) _attachments[attachment.fileName] = verdict;
    }
    if (_attachments.isEmpty) return;
    final worst = _attachments.values.reduce(
      (a, b) => b.level.index > a.level.index ? b : a,
    );
    _add(
      FindingKind.riskyAttachment,
      worst.level,
      _attachments.length == 1
          ? '${worst.fileName}: ${worst.reason}'
          : '${_attachments.length} attachments could harm your device, '
                'including ${worst.fileName}.',
    );
  }

  TrustReport report() {
    // Most serious first; ties keep the order found.
    final ordered = [
      for (final level in TrustLevel.values.reversed)
        ..._findings.where((f) => f.level == level),
    ];
    return TrustReport(
      findings: ordered,
      links: _links,
      attachments: _attachments,
      verified: _verified,
    );
  }
}
