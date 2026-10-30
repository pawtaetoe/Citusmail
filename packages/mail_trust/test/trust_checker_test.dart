// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mail_trust/mail_trust.dart';
import 'package:mail_view/mail_view.dart';
import 'package:test/test.dart';

final fixtureDir = Directory('../../test-data/mail');

MessageView fixture(String path) =>
    MessageView.parse(File('${fixtureDir.path}/$path').readAsBytesSync());

MessageView mail(String headers, {String html = '<p>Hello</p>'}) =>
    MessageView.parse(
      Uint8List.fromList(
        utf8.encode(
          '${headers.trim()}\n'
          'Content-Type: text/html; charset=utf-8\n\n$html\n',
        ),
      ),
    );

const trusted = TrustContext(trustedAuthServId: 'mail.citusmail.test');
const checker = TrustChecker();

Set<FindingKind> kinds(TrustReport r) => {for (final f in r.findings) f.kind};

void main() {
  group('Authentication-Results', () {
    test('parses results, properties and comments', () {
      final r = AuthenticationResults.parse(
        'Mail.Citusmail.Test 1; (checked (twice)) spf=fail smtp.mailfrom=x@mailbox.example; '
        'dkim=pass (2048-bit) header.d=shop.example header.s="mail"; '
        'dmarc=fail (p=REJECT) header.from=mailbox.example',
      )!;
      expect(r.authServId, 'mail.citusmail.test');
      expect(r.spf!.failed, isTrue);
      expect(r.spf!.domain, 'mailbox.example');
      expect(r.dkim.single.passed, isTrue);
      expect(r.dkim.single.domain, 'shop.example');
      expect(r.dkim.single.properties['header.s'], 'mail');
      expect(r.dmarc!.failed, isTrue);
      expect(r.dmarc!.domain, 'mailbox.example');
    });

    test('"none" and junk are harmless', () {
      expect(AuthenticationResults.parse('mx.example; none')!.results, isEmpty);
      expect(AuthenticationResults.parse(''), isNull);
      expect(AuthenticationResults.parse(';;;'), isNull);
      expect(AuthenticationResults.parse('x; =; dkim=; spf'), isNotNull);
      expect(AuthenticationResults.parse('(' * 10000), isNull);
    });

    test('the server id is learned from most recent mail', () {
      String ar(String id) => '$id; spf=pass smtp.mailfrom=a.example';
      expect(
        AuthServIds.learn([for (var i = 0; i < 4; i++) ar('mx.me')]),
        isNull,
      );
      expect(
        AuthServIds.learn([for (var i = 0; i < 5; i++) ar('mx.me')]),
        'mx.me',
      );
      expect(
        AuthServIds.learn([
          for (var i = 0; i < 6; i++) ar('mx.me'),
          for (var i = 0; i < 5; i++) null,
        ]),
        isNull,
        reason: 'only 55% carry it',
      );
      expect(
        AuthServIds.learn([
          for (var i = 0; i < 8; i++) ar('MX.me'),
          ar('evil.example'),
          null,
        ]),
        'mx.me',
      );
    });

    test('results below a different id are not trusted', () {
      final values = [
        'mx.me; spf=pass smtp.mailfrom=a.example',
        'forged.example; dmarc=pass header.from=paypal.com',
        'mx.me; dmarc=pass header.from=paypal.com',
      ];
      final trustedResults = AuthServIds.trusted(values, 'mx.me');
      expect(trustedResults, hasLength(1));
      expect(AuthServIds.trusted(values, null), isEmpty);
      expect(AuthServIds.trusted(values.reversed, 'mx.me'), hasLength(1));
    });
  });

  group('fixtures', () {
    test('phishing with a mismatched link is dangerous', () {
      final report = checker.check(
        fixture('security/phishing-link-mismatch.eml'),
        trusted,
      );
      expect(report.level, TrustLevel.danger);
      expect(
        kinds(report),
        containsAll([
          FindingKind.failedVerification,
          FindingKind.impersonatedBrand,
          FindingKind.deceptiveLink,
        ]),
      );
      final link = report.link(
        Uri.parse('https://paypa1-login.example/verify?id=1'),
      )!;
      expect(link.level, TrustLevel.danger);
      expect(link.reasons, contains(contains('imitates PayPal')));
      expect(link.reasons, contains(contains('shows www.paypal.com')));
      expect(report.verified, isFalse);
    });

    test('without a learned server id, verification is skipped', () {
      final report = checker.check(
        fixture('security/phishing-link-mismatch.eml'),
      );
      expect(kinds(report), isNot(contains(FindingKind.failedVerification)));
      expect(
        report.level,
        TrustLevel.danger,
        reason: 'the brand claim remains',
      );
    });

    test('a punycode lookalike sender is dangerous', () {
      final report = checker.check(fixture('security/punycode-lookalike.eml'));
      expect(report.level, TrustLevel.danger);
      expect(kinds(report), contains(FindingKind.mixedScripts));
      expect(report.findings.first.message, contains('"apple.example"'));
      expect(
        report.findings.where((f) => f.kind == FindingKind.impersonatedBrand),
        isEmpty,
        reason: 'one trick, one finding',
      );
      final link = report.link(
        Uri.parse('https://xn--pple-43d.example/account'),
      );
      expect(link?.level, TrustLevel.danger);
    });

    test('risky attachments are each flagged', () {
      final report = checker.check(fixture('security/risky-attachments.eml'));
      expect(report.attachment('invoice.pdf.exe')?.level, TrustLevel.danger);
      expect(report.attachment('terms.docm')?.level, TrustLevel.caution);
      expect(report.attachment('invoice.html')?.level, TrustLevel.caution);
      expect(report.level, TrustLevel.danger);
      expect(report.findings.single.message, contains('3 attachments'));
    });

    test('a verified newsletter is fine, its failing copy is not', () {
      final good = checker.check(
        fixture('newsletters/one-click-unsubscribe.eml'),
        trusted,
      );
      expect(good.level, TrustLevel.ok);
      expect(good.verified, isTrue);
      expect(good.dkimPasses.single.domain, 'shop.example');
      expect(good.dkimPasses.single.properties['header.s'], 'mail');
      expect(good.findings, isEmpty);

      final bad = checker.check(
        fixture('newsletters/one-click-dkim-fail.eml'),
        trusted,
      );
      expect(bad.verified, isFalse);
      expect(bad.findings.single.kind, FindingKind.failedVerification);
      expect(
        bad.level,
        TrustLevel.caution,
        reason: 'has List-Id: lists can break DMARC',
      );
    });

    test('ordinary fixtures raise nothing', () {
      for (final path in [
        'people/plain-text.eml',
        'people/html-alternative.eml',
        'people/attachment-inline-image.eml',
        'notifications/github.eml',
        'notifications/bank-alert.eml',
      ]) {
        expect(checker.check(fixture(path)).findings, isEmpty, reason: path);
      }
    });
  });

  group('sender', () {
    test('a brand name from a free mail address', () {
      final r = checker.check(
        mail('From: PayPal Service <paypal.help@gmail.example>'),
      );
      expect(r.findings.single.kind, FindingKind.impersonatedBrand);
      expect(r.level, TrustLevel.danger);
    });

    test('the brand writing from its own domain is fine', () {
      for (final from in [
        'PayPal <service@paypal.com>',
        'PayPal <service@mail.paypal.de>',
        'Amazon.co.uk <ship@amazon.co.uk>',
        'Microsoft account team <x@accountprotection.microsoft.com>',
        'Instagram <security@mail.instagram.com>',
      ]) {
        expect(
          checker.check(mail('From: $from')).findings,
          isEmpty,
          reason: from,
        );
      }
    });

    test('an ordinary word as a brand only gets a caution', () {
      final r = checker.check(mail('From: Chase <chase@friends.example>'));
      expect(r.level, TrustLevel.caution);
    });

    test('an address in the display name that is not the sender', () {
      final r = checker.check(
        mail('From: "service@paypal.com" <x@mailbox.example>'),
      );
      expect(kinds(r), contains(FindingKind.addressInName));
      expect(r.level, TrustLevel.danger);
      final plain = checker.check(
        mail('From: "bob@work.example" <bob@home.example>'),
      );
      expect(plain.level, TrustLevel.caution);
      final same = checker.check(
        mail('From: "bob@example.com" <bob@mail.example.com>'),
      );
      expect(same.findings, isEmpty);
    });

    test('a lookalike of the user\'s own domain', () {
      final r = checker.check(
        mail('From: Tommy <me@tommykunq.cc>\n'),
        const TrustContext(ownDomains: {'tommykung.cc'}),
      );
      expect(r.findings, isEmpty, reason: 'q is not a lookalike of g');
      final r2 = checker.check(
        mail('From: Tommy <me@t0mmykung.cc>'),
        const TrustContext(ownDomains: {'tommykung.cc'}),
      );
      expect(r2.findings.single.kind, FindingKind.lookalikeDomain);
      final own = checker.check(
        mail('From: Tommy <me@tommykung.cc>'),
        const TrustContext(ownDomains: {'tommykung.cc'}),
      );
      expect(own.findings, isEmpty);
    });

    test('SPF failure without DMARC is a caution', () {
      final r = checker.check(
        mail(
          'Authentication-Results: mail.citusmail.test; spf=fail smtp.mailfrom=bob@shop.example\n'
          'From: Bob <bob@shop.example>',
        ),
        trusted,
      );
      expect(r.findings.single.kind, FindingKind.failedVerification);
      expect(r.level, TrustLevel.caution);
    });

    test('forwarded mail whose ARC chain checked out: caution only', () {
      final r = checker.check(
        mail(
          'Authentication-Results: mail.citusmail.test; arc=pass; '
          'dmarc=fail header.from=openrouter.ai\n'
          'From: OpenRouter Team <welcome@openrouter.ai>',
        ),
        trusted,
      );
      expect(r.level, TrustLevel.caution);
      expect(r.findings.single.message, contains('forwarded'));
    });

    test('ARC counts only from the user\'s own server', () {
      final r = checker.check(
        mail(
          'Authentication-Results: mail.citusmail.test; dmarc=fail header.from=openrouter.ai\n'
          'Authentication-Results: mx.attacker.example; arc=pass\n'
          'From: OpenRouter Team <welcome@openrouter.ai>',
        ),
        trusted,
      );
      expect(r.level, TrustLevel.danger);
      final failed = checker.check(
        mail(
          'Authentication-Results: mail.citusmail.test; arc=fail; '
          'dmarc=fail header.from=openrouter.ai\n'
          'From: OpenRouter Team <welcome@openrouter.ai>',
        ),
        trusted,
      );
      expect(failed.level, TrustLevel.danger);
    });

    test('a forged pass below the real result changes nothing', () {
      final r = checker.check(
        mail(
          'Authentication-Results: mail.citusmail.test; dmarc=fail header.from=paypal.com\n'
          'Authentication-Results: mail.citusmail.test.evil.example; dmarc=pass header.from=paypal.com\n'
          'From: PayPal <service@paypal.com>',
        ),
        trusted,
      );
      expect(r.level, TrustLevel.danger);
      expect(r.verified, isFalse);
    });

    test('a forged result on top is ignored entirely', () {
      final r = checker.check(
        mail(
          'Authentication-Results: mx.attacker.example; dmarc=pass header.from=paypal.com\n'
          'Authentication-Results: mail.citusmail.test; dmarc=fail header.from=paypal.com\n'
          'From: PayPal <service@paypal.com>',
        ),
        trusted,
      );
      expect(r.verified, isFalse);
      expect(r.findings, isEmpty, reason: 'the trusted result is not on top');
    });
  });

  group('a link on its own', () {
    test('the message link checks, without shown text', () {
      expect(
        TrustChecker.checkLink(Uri.parse('https://openrouter.ai/unsub?x=1')),
        isNull,
      );
      expect(
        TrustChecker.checkLink(Uri.parse('https://paypa1.com/u'))!.level,
        TrustLevel.danger,
      );
      expect(
        TrustChecker.checkLink(Uri.parse('https://user@evil.example/u'))!.level,
        TrustLevel.danger,
      );
      expect(
        TrustChecker.checkLink(Uri.parse('http://203.0.113.9/u'))!.level,
        TrustLevel.caution,
      );
      expect(TrustChecker.checkLink(Uri.parse('mailto:u@x.example')), isNull);
    });
  });

  group('what the message says and whom it was sent to', () {
    const context = TrustContext(trustedAuthServId: 'mail.citusmail.test');

    test('an outsider naming your institution, with a form: red', () {
      final r = checker.check(
        fixture('security/org-impersonation-form.eml'),
        context,
      );
      expect(r.level, TrustLevel.danger);
      expect(kinds(r), {
        FindingKind.namesOwnOrganisation,
        FindingKind.speaksForBrand,
        FindingKind.hiddenRecipients,
        FindingKind.formLink,
      });
      final org = r.findings.firstWhere(
        (f) => f.kind == FindingKind.namesOwnOrganisation,
      );
      expect(org.message, contains('East Institute of Technology'));
      expect(org.message, contains('eit.easttech.edu.sg'));
      expect(
        r.findings
            .firstWhere((f) => f.kind == FindingKind.speaksForBrand)
            .message,
        allOf(contains('Microsoft'), contains('IBM')),
      );
      // The form link warns when tapped too.
      expect(
        r.link(Uri.parse('https://forms.gle/AbCdEfGh123'))!.level,
        TrustLevel.caution,
      );
    });

    test('your institution writing to you is not flagged', () {
      final r = checker.check(
        mail(
          'From: Registry <registry@easttech.edu.sg>\n'
          'To: <2500123@eit.easttech.edu.sg>\n'
          'Subject: East Institute of Technology: exam timetable',
        ),
        context,
      );
      expect(r.findings, isEmpty);
    });

    test('a claim alone, addressed to you: only worth a look', () {
      final r = checker.check(
        mail(
          'From: Events <events@partner.example>\n'
          'To: <2500123@eit.easttech.edu.sg>\n'
          'Subject: Workshop for East Institute of Technology students',
        ),
        context,
      );
      expect(kinds(r), {FindingKind.namesOwnOrganisation});
      expect(r.level, TrustLevel.caution);
    });

    test('a form link alone: amber, not red', () {
      final r = checker.check(
        mail(
          'From: Ana <ana@club.example>\nTo: <bob@club.example>',
          html: '<a href="https://docs.google.com/forms/d/x/viewform">Sign up</a>',
        ),
        context,
      );
      expect(kinds(r), {FindingKind.formLink});
      expect(r.level, TrustLevel.caution);
    });

    test('app store badges in a footer do not speak for Google', () {
      final r = checker.check(
        mail(
          'From: Shop <news@shop.example>\nTo: <bob@club.example>',
          html:
              '<p>Our news</p><p>Get it on Google Play</p>'
              '<p>Download on the App Store</p>',
        ),
        context,
      );
      expect(r.findings, isEmpty);
    });

    test('initials need three letters; free mail names no institution', () {
      expect(
        ContentSignals.namedOrganisation('Hello Bob Smith', [
          'bs.example.org',
          'gmail.com',
        ]),
        isNull,
      );
      expect(
        ContentSignals.namedOrganisation('Notice from NUS', ['u.nus.edu']),
        (name: 'NUS', host: 'u.nus.edu'),
      );
    });

    test('your own mail to a Bcc list is not "hidden recipients"', () {
      final r = checker.check(
        mail(
          'From: Bob <bob@club.example>\nTo: undisclosed-recipients:;\n'
          'Subject: Meeting',
        ),
        const TrustContext(ownDomains: {'club.example'}),
      );
      expect(r.findings, isEmpty);
    });
  });

  group('links', () {
    TrustReport links(String html) =>
        checker.check(mail('From: Shop <news@shop.example>', html: html));

    test('a tracking redirect is only flagged when tapped', () {
      final r = links(
        '<a href="https://click.mailer.example/abc">www.example.com</a>',
      );
      expect(r.level, TrustLevel.ok);
      final link = r.link(Uri.parse('https://click.mailer.example/abc'))!;
      expect(link.level, TrustLevel.caution);
      expect(link.reasons.single, contains('shows www.example.com'));
    });

    test('a link showing a brand domain going elsewhere is dangerous', () {
      final r = links('<a href="https://evil.example/">https://paypal.com</a>');
      expect(r.level, TrustLevel.danger);
      expect(r.findings.single.kind, FindingKind.deceptiveLink);
    });

    test('text split by styling is read as one', () {
      final r = links('<a href="https://evil.example/"><b>paypal</b>.com</a>');
      expect(r.level, TrustLevel.danger);
    });

    test('the same brand under another of its domains is fine', () {
      final r = links('<a href="https://www.paypal.me/x">paypal.com</a>');
      expect(r.links, isEmpty);
    });

    test('user-info tricks and numeric addresses', () {
      final r = links(
        '<a href="https://paypal.com@evil.example/">Sign in</a> '
        '<a href="http://192.168.0.1/login">Router</a>',
      );
      expect(r.level, TrustLevel.danger);
      expect(
        r.link(Uri.parse('https://paypal.com@evil.example/'))!.reasons.single,
        contains('opens evil.example'),
      );
      expect(
        r.link(Uri.parse('http://192.168.0.1/login'))!.level,
        TrustLevel.caution,
      );
    });

    test('broken percent-encoding in a link does not break the check', () {
      final r = links('<a href="https://ex%C3%28.example/">example.com</a>');
      expect(r.findings, isEmpty);
    });

    test('honest links raise nothing', () {
      final r = links(
        '<a href="https://shop.example/deals">Deals</a> '
        '<a href="https://www.example.com/">example.com</a> '
        '<a href="mailto:help@shop.example">help@other.example</a>',
      );
      expect(r.links, isEmpty);
      expect(r.findings, isEmpty);
    });
  });
}
