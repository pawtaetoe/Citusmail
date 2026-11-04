// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

/// Made-up purchase mail with return policies, relative to [now]: an
/// Amazon order delivered two days ago ("within 30 days of delivery"), a
/// UNIQLO e-receipt to return within two days, an Apple order ("14
/// calendar days of receipt", not delivered yet), and two that must not
/// be listed: a final-sale order and a refunded one.
void seedReturns(MailStore store, {required DateTime now}) {
  final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
  var uid = 700;
  MessageSummary mail(
    String address,
    String name,
    String subject,
    Duration ago, {
    String? snippet,
  }) {
    final at = address.indexOf('@');
    return MessageSummary(
      uid: uid++,
      receivedAt: now.subtract(ago),
      subject: subject,
      from: MailAddress(
        localPart: address.substring(0, at),
        domain: address.substring(at + 1),
        displayName: name,
      ),
      snippet: snippet,
      size: 30000,
      category: MessageCategory.notifications,
      flags: MessageFlags.fromImap([r'\Seen']),
    );
  }

  const day = Duration(days: 1);
  final local = now.toLocal().add(day * 2);
  String two(int n) => n.toString().padLeft(2, '0');
  final returnBy = '${two(local.day)}/${two(local.month)}/${local.year}';

  final uniqlo = mail(
    'noreply@ml.uniqlo.com',
    'UNIQLO',
    'Your UNIQLO e-receipt',
    day * 28,
  );
  final apple = mail(
    'order_acknowledgment@orders.apple.com',
    'Apple Store',
    'We\'re processing your order W1234567890',
    day * 3,
  );
  store.messages.upsertSummaries(inbox.id, [
    mail(
      'auto-confirm@amazon.sg',
      'Amazon.sg',
      'Your Amazon.sg order #171-1112223-3334445',
      day * 6,
      snippet:
          'Thank you for your order. Order # 171-1112223-3334445. Bose '
          'QuietComfort Earbuds. You can return items within 30 days of '
          'delivery.',
    ),
    mail(
      'shipment-tracking@amazon.sg',
      'Amazon.sg',
      'Your Amazon.sg order has shipped',
      day * 4,
      snippet:
          'Order # 171-1112223-3334445 is on its way with Ninja Van, '
          'tracking ID NVSGAMZ0099887766.',
    ),
    mail(
      'shipment-tracking@amazon.sg',
      'Amazon.sg',
      'Delivered: your Amazon.sg package',
      day * 2,
      snippet:
          'Your package was delivered. Order # 171-1112223-3334445. Tracking '
          'ID NVSGAMZ0099887766.',
    ),
    uniqlo,
    apple,
    // Final sale: not returnable.
    mail(
      'orders@fashionco.example',
      'Fashion Co',
      'Order confirmation #A10023',
      day * 2,
      snippet:
          'Order #A10023. Silk scarf (final sale). Final sale: this item '
          'cannot be returned or exchanged.',
    ),
    // Refunded already.
    mail(
      'info@mail.shopee.sg',
      'Shopee',
      'Order Confirmed: 241020XYZ7788',
      day * 10,
      snippet: 'Your order 241020XYZ7788 is confirmed. 15 Days Free Returns.',
    ),
    mail(
      'info@mail.shopee.sg',
      'Shopee',
      'Refund processed for order 241020XYZ7788',
      day,
      snippet: 'S\$18.90 has been refunded to your ShopeePay wallet.',
    ),
  ]);

  void body(MessageSummary m, String from, String json, String text) {
    final stored = store.messages.byUid(inbox.id, m.uid)!;
    final raw =
        '''From: $from
To: alice@citusmail.test
Subject: ${m.subject}
Content-Type: text/html; charset=utf-8

<html><head><script type="application/ld+json">$json</script></head>
<body>$text</body></html>
''';
    store.messages.saveBody(
      stored.id,
      utf8.encode(raw.replaceAll('\n', '\r\n')),
      searchableText: text,
    );
  }

  body(
    uniqlo,
    'UNIQLO <noreply@ml.uniqlo.com>',
    '{"@context": "http://schema.org", "@type": "Order", '
        '"merchant": {"@type": "Organization", "name": "UNIQLO"}, '
        '"orderNumber": "SG-ONL-5520193", '
        '"orderedItem": [{"@type": "Product", "name": "Ultra Light Down Jacket"}, '
        '{"@type": "Product", "name": "AIRism Cotton T-Shirt"}]}',
    '<p>Thank you for shopping at UNIQLO.</p>'
        '<p>Order SG-ONL-5520193: Ultra Light Down Jacket S\$79.90, AIRism '
        'Cotton T-Shirt S\$19.90.</p>'
        '<p>Return by $returnBy with this receipt and the tags attached.</p>',
  );
  body(
    apple,
    'Apple Store <order_acknowledgment@orders.apple.com>',
    '{"@context": "http://schema.org", "@type": "Order", '
        '"merchant": {"@type": "Organization", "name": "Apple Store"}, '
        '"orderNumber": "W1234567890", '
        '"orderedItem": {"@type": "Product", "name": "AirPods Pro 2"}}',
    '<p>Thank you for your order. Order Number: W1234567890.</p>'
        '<p>AirPods Pro 2</p>'
        '<p>Apple Store Online purchases can be returned within 14 calendar '
        'days of receipt. Some exceptions apply.</p>',
  );
}
