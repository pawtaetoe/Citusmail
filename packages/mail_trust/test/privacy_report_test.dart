// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mail_trust/mail_trust.dart';
import 'package:mail_view/mail_view.dart';
import 'package:test/test.dart';

MessageView mail(String headers, String html) => MessageView.parse(
  Uint8List.fromList(
    utf8.encode(
      '${headers.trim()}\r\n'
      'Content-Type: text/html; charset=utf-8\r\n\r\n$html\r\n',
    ),
  ),
);

MessageView fixture(String path) =>
    MessageView.parse(File('../../test-data/mail/$path').readAsBytesSync());

const trusted = TrustContext(trustedAuthServId: 'mail.citusmail.test');

/// A shop's newsletter: an open pixel from a tracking host, a tiny pixel,
/// a banner and a product photo from the internet, links with campaign
/// tags (one of them twice), and plain links.
const newsletter = '''
<table><tr><td>
  <a href="https://shop.example/autumn?utm_source=newsletter&amp;utm_medium=email&amp;utm_campaign=autumn">
    <img src="https://cdn.shop.example/banner.jpg" alt="Autumn sale" width="600" height="200">
  </a>
  <h1>Autumn sale: 30% off boots</h1>
  <p>Our warmest boots are back. <a href="https://shop.example/boots?id=42&amp;mc_cid=abc123&amp;mc_eid=def456">Shop boots</a></p>
  <p><img src="https://cdn.shop.example/boots.jpg" alt="Boots" width="300"></p>
  <p><a href="https://shop.example/boots?id=42&amp;mc_cid=abc123&amp;mc_eid=def456">See all boots</a></p>
  <p><a href="https://shop.example/help">Help centre</a> · <a href="https://shop.example/stores?city=Oslo">Find a store</a></p>
</td></tr></table>
<img src="https://ea.pstmrk.it/open?m=v3_1.abc" alt="">
<img src="https://shop.example/o.gif?u=9" width="1" height="1">
''';

void main() {
  group('one message', () {
    test('trackers, held-back images and tagged links are counted', () {
      final p = MessagePrivacy.of(
        mail(
          'From: Shop <news@shop.example>\r\nSubject: Autumn sale',
          newsletter,
        ),
      );
      expect(p.trackers, 2);
      expect(p.remoteImages, 2);
      expect(p.trackingLinks, 2, reason: 'the same link twice counts once');
      expect(p.readReceipt, isFalse);
      expect(p.warned, isFalse);
    });

    test('a personal note has nothing to count', () {
      final p = MessagePrivacy.of(
        mail(
          'From: Carol <carol@x.example>\r\nSubject: Lunch?',
          '<p>Lunch on Friday? The place on '
              '<a href="https://maps.example/place?q=cafe&amp;zoom=15">Main St</a> '
              'looks good.</p>',
        ),
        trust: TrustReport.empty,
      );
      expect(p.trackers, 0);
      expect(p.remoteImages, 0);
      expect(p.trackingLinks, 0, reason: 'ordinary parameters stay');
      expect(p.readReceipt, isFalse);
      expect(p.warned, isFalse);
    });

    test('a read receipt request is noticed', () {
      final p = MessagePrivacy.of(
        mail(
          'From: Boss <boss@corp.example>\r\n'
              'Disposition-Notification-To: boss@corp.example\r\n'
              'Subject: Read this today',
          '<p>Please read the attached plan.</p>',
        ),
      );
      expect(p.readReceipt, isTrue);
    });

    test('mail the phishing checks warn about', () {
      final view = fixture('security/phishing-link-mismatch.eml');
      final p = MessagePrivacy.of(
        view,
        trust: const TrustChecker().check(view, trusted),
      );
      expect(p.warned, isTrue);
      // Unchecked mail (the user's own) is never "warned".
      expect(MessagePrivacy.of(view).warned, isFalse);
    });

    test('images from a sender whose images are always loaded', () {
      final verified = const TrustChecker().check(
        fixture('newsletters/one-click-unsubscribe.eml'),
        trusted,
      );
      expect(verified.verified, isTrue);
      final html = mail(
        'From: Shop <news@shop.example>',
        '<p><img src="https://cdn.shop.example/a.jpg" width="300"></p>',
      );
      expect(MessagePrivacy.of(html).remoteImages, 1);
      expect(
        MessagePrivacy.of(
          html,
          trust: verified,
          imagesAllowed: true,
        ).remoteImages,
        0,
      );
      // Not verified: the reader holds them back anyway.
      expect(
        MessagePrivacy.of(
          html,
          trust: TrustReport.empty,
          imagesAllowed: true,
        ).remoteImages,
        1,
      );
    });

    test('links in lists, quotes and image links are found', () {
      final p = MessagePrivacy.of(
        mail(
          'From: a@b.example',
          '<ul><li><a href="https://a.example/?fbclid=1">one</a></li></ul>'
              '<blockquote><a href="https://b.example/?gclid=2">two</a></blockquote>'
              '<a href="https://c.example/x?utm_source=x">'
              '<img src="https://c.example/logo.png" alt="Logo" width="100"></a>'
              '<a href="mailto:me@a.example?subject=utm_source">mail</a>',
        ),
      );
      expect(p.trackingLinks, 3);
    });
  });

  group('the report', () {
    final now = DateTime.utc(2026, 11, 4, 12);
    PrivacyEmail email(
      String address,
      int daysAgo, {
      String? name,
      int trackers = 0,
      int images = 0,
      int links = 0,
      bool receipt = false,
      bool warned = false,
    }) => PrivacyEmail(
      address: address,
      name: name,
      receivedAt: now.subtract(Duration(days: daysAgo)),
      privacy: MessagePrivacy(
        trackers: trackers,
        remoteImages: images,
        trackingLinks: links,
        readReceipt: receipt,
        warned: warned,
      ),
    );

    final emails = [
      email(
        'news@shop.example',
        1,
        name: 'Shop',
        trackers: 2,
        images: 3,
        links: 4,
      ),
      email('news@shop.example', 3, name: 'Shop News', trackers: 2, images: 1),
      email('NEWS@shop.example', 20, name: 'Shop', trackers: 2, links: 2),
      email('deals@market.example', 2, name: 'Market', trackers: 3, images: 5),
      email('boss@corp.example', 5, receipt: true),
      email('carol@x.example', 6, name: 'Carol'),
      email('security@paypa1.example', 25, warned: true, trackers: 1),
      email('old@shop.example', 31, trackers: 9),
      email('', 1, trackers: 1),
    ];

    test('sums the last 7 days', () {
      final r = PrivacyReport.of(
        emails,
        since: now.subtract(const Duration(days: 7)),
      );
      expect(r.messages, 6);
      expect(r.trackers, 2 + 2 + 3 + 1);
      expect(r.remoteImages, 9);
      expect(r.trackingLinks, 4);
      expect(r.readReceipts, 1);
      expect(r.warned, 0);
    });

    test('sums the last 30 days, not older', () {
      final r = PrivacyReport.of(
        emails,
        since: now.subtract(const Duration(days: 30)),
      );
      expect(r.messages, 8);
      expect(r.trackers, 2 + 2 + 2 + 3 + 1 + 1);
      expect(r.trackingLinks, 6);
      expect(r.warned, 1);
    });

    test('ranks senders by trackers per email', () {
      final r = PrivacyReport.of(
        emails,
        since: now.subtract(const Duration(days: 30)),
      );
      expect(r.topTrackers.map((s) => s.address), [
        'deals@market.example',
        'news@shop.example',
        'security@paypa1.example',
      ]);
      final shop = r.topTrackers[1];
      expect(shop.emails, 3, reason: 'the address in any case');
      expect(shop.trackers, 6);
      expect(shop.perEmail, 2);
      expect(shop.name, 'Shop', reason: 'the newest name');
      // Senders that never tracked, and mail without a sender, are left out.
      expect(
        r.topTrackers.map((s) => s.address),
        isNot(contains('carol@x.example')),
      );
    });

    test('ties: more trackers in all first; at most [top]', () {
      final r = PrivacyReport.of(
        [
          email('a@one.example', 1, trackers: 1),
          email('b@two.example', 1, trackers: 1),
          email('b@two.example', 2, trackers: 1),
          email('c@three.example', 1, trackers: 1),
        ],
        since: now.subtract(const Duration(days: 7)),
        top: 2,
      );
      expect(r.topTrackers.map((s) => s.address), [
        'b@two.example',
        'a@one.example',
      ]);
    });

    test('nothing received: an empty report', () {
      final r = PrivacyReport.of(const [], since: now);
      expect(r.messages, 0);
      expect(r.topTrackers, isEmpty);
    });
  });
}
