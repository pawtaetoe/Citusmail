// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'test_app.dart';

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
