// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:citusmail/src/mail/privacy_report_model.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/privacy_report_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

/// Mail of the last weeks, as stored after opening it: newsletters with
/// trackers, pictures and tagged links, a boss asking for a read receipt,
/// a scam, and a newsletter not downloaded yet. Relative to [now].
void seedPrivacyMail(TestApp app, DateTime now) {
  final store = app.store;
  final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
  var uid = 400;
  void add(
    int daysAgo,
    String from,
    String name,
    String subject,
    String html, {
    String extraHeaders = '',
    bool download = true,
  }) {
    final at = now.subtract(Duration(days: daysAgo, hours: 1));
    final address = MailAddress(
      displayName: name,
      localPart: from.split('@').first,
      domain: from.split('@').last,
    );
    store.messages.upsertSummaries(inbox.id, [
      MessageSummary(
        uid: ++uid,
        receivedAt: at,
        subject: subject,
        from: address,
        flags: MessageFlags.fromImap([r'\Seen']),
      ),
    ]);
    if (!download) return;
    store.messages.saveBody(
      store.messages.byUid(inbox.id, uid)!.id,
      utf8.encode(
        'From: $name <$from>\r\nTo: alice@citusmail.test\r\n'
        'Subject: $subject\r\n$extraHeaders'
        'Content-Type: text/html; charset=utf-8\r\n\r\n$html\r\n',
      ),
      searchableText: subject,
    );
  }

  const shop =
      '<p><a href="https://shop.example/sale?utm_source=newsletter&amp;utm_campaign=autumn">'
      '<img src="https://cdn.shop.example/banner.jpg" width="600" alt="Autumn sale"></a></p>'
      '<p>Boots are back. <a href="https://shop.example/boots?mc_cid=1&amp;mc_eid=2">Shop now</a></p>'
      '<img src="https://ea.pstmrk.it/open?m=1" alt="">'
      '<img src="https://shop.example/o.gif" width="1" height="1">';
  add(1, 'news@shop.example', 'Shop', 'Autumn sale: 30% off boots', shop);
  add(3, 'news@shop.example', 'Shop', 'New arrivals', shop);
  add(20, 'news@shop.example', 'Shop', 'Summer leftovers', shop);
  add(
    2,
    'deals@market.example',
    'Market',
    'Deals of the day',
    '<p>Today only.</p><img src="https://market.example/pixel/a.gif">'
        '<img src="https://market.example/t.png" width="1">'
        '<img src="https://market.example/o.png" height="0">',
  );
  add(
    5,
    'boss@corp.example',
    'Pat Boss',
    'Plan for Monday',
    '<p>Please read the plan before Monday.</p>',
    extraHeaders: 'Disposition-Notification-To: boss@corp.example\r\n',
  );
  add(
    6,
    'carol@x.example',
    'Carol',
    'Lunch?',
    '<p>Lunch on Friday? <a href="https://maps.example/?q=cafe">This place</a>.</p>',
  );
  // Received, not downloaded: counted as received only.
  add(1, 'news@shop.example', 'Shop', 'Flash sale', shop, download: false);
  app.seedFixture(
    'security/phishing-link-mismatch.eml',
    subject: 'Your account has been limited',
    uid: 399,
    receivedAt: now.subtract(const Duration(days: 4)),
  );
}

void main() {
  final now = DateTime.utc(2026, 11, 4, 12);
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  /// Lets isolates (counting) finish.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  test('counts stored mail per period; nothing is downloaded', () async {
    seedPrivacyMail(app, now);
    final model = PrivacyReportModel(app.services, now: () => now);
    await model.load();

    final week = model.report;
    expect(model.period, PrivacyPeriod.week);
    // Shop twice, Market, the boss, Carol, the scam.
    expect(week.messages, 6);
    expect(model.received, 7, reason: 'with the sale not downloaded');
    expect(week.trackers, 2 + 2 + 3);
    expect(week.remoteImages, 2);
    expect(week.trackingLinks, 4);
    expect(week.readReceipts, 1);
    expect(week.warned, 1);
    expect(week.topTrackers.map((s) => s.address), [
      'deals@market.example',
      'news@shop.example',
    ]);
    expect(model.capped, isFalse);

    model.select(PrivacyPeriod.month);
    final month = model.report;
    // And "Summer leftovers" and the test inbox's "Hello there" (a pixel).
    expect(month.messages, 8);
    expect(month.trackers, 2 + 2 + 2 + 3 + 1);
    expect(month.topTrackers.first.address, 'deals@market.example');
    expect(month.topTrackers[1].emails, 3);
    model.dispose();
  });

  testWidgets('the page: numbers, periods and the senders that track', (
    tester,
  ) async {
    seedPrivacyMail(app, now);
    final shown = <String>[];
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: PrivacyReportPage(
          services: app.services,
          onShowMail: shown.add,
          now: () => now,
        ),
      ),
    );
    await settle(tester);

    expect(
      find.text('Citusmail blocked 7 trackers in the last 7 days'),
      findsOneWidget,
    );
    expect(find.text('In 6 emails on this device.'), findsOneWidget);
    expect(find.text('Trackers blocked'), findsOneWidget);
    expect(
      find.textContaining('Tracking pixels tell a sender when and where'),
      findsOneWidget,
    );
    expect(find.text('Remote images held back'), findsOneWidget);
    expect(find.text('Links with tracking tags'), findsOneWidget);
    expect(find.text('Read receipt not sent'), findsOneWidget);
    expect(find.text('Email warned about'), findsOneWidget);
    expect(find.text('Senders that track you most'), findsOneWidget);
    expect(find.text('3 trackers per email · 3 in 1 email'), findsOneWidget);
    expect(find.text('2 trackers per email · 4 in 2 emails'), findsOneWidget);
    expect(
      find.text(
        'Everything here is counted on this device. Nothing is sent anywhere.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Counted from the 6 of 7 emails received in the '
        'last 7 days whose content is on this device',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Last 30 days'));
    await tester.pumpAndSettle();
    expect(
      find.text('Citusmail blocked 10 trackers in the last 30 days'),
      findsOneWidget,
    );
    expect(find.text('2 trackers per email · 6 in 3 emails'), findsOneWidget);

    await tester.tap(find.text('Shop'));
    await tester.pumpAndSettle();
    expect(shown, ['news@shop.example']);
  });

  testWidgets('nothing on the device yet: says so, no zeros', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: PrivacyReportPage(services: app.services, now: () => now),
      ),
    );
    await settle(tester);
    expect(find.text('Nothing to count yet'), findsOneWidget);
    expect(find.text('Trackers blocked'), findsNothing);
    expect(find.textContaining('Nothing is sent anywhere'), findsOneWidget);
  });
}
