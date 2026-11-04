// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

/// Made-up shop and carrier mail for the Deliveries page (tests and
/// screenshots), relative to [now].
void seedDeliveries(MailStore store, {required DateTime now}) {
  final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
  var uid = 600;
  MessageSummary mail(
    String address,
    String name,
    String subject,
    Duration ago, {
    String? snippet,
    MessageCategory category = MessageCategory.notifications,
    int size = 20000,
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
      size: size,
      category: category,
      flags: MessageFlags.fromImap([r'\Seen']),
    );
  }

  const day = Duration(days: 1);
  final expected = now.add(const Duration(days: 2)).toIso8601String();
  final amazon = mail(
    'shipment-tracking@amazon.sg',
    'Amazon.sg',
    'Your Amazon.sg order of "Kindle Paperwhite..." has shipped',
    const Duration(hours: 5),
    snippet: 'Your package is on its way.',
  );
  store.messages.upsertSummaries(inbox.id, [
    amazon,
    mail(
      'info@mail.shopee.sg',
      'Shopee',
      'Your order 241101ABCDEF12 is out for delivery',
      const Duration(hours: 2),
      snippet:
          'Order 241101ABCDEF12 is out for delivery with Shopee Express. '
          'Tracking number: SPXSG041234567890',
    ),
    mail(
      'info@mail.shopee.sg',
      'Shopee',
      'Your order 241101ABCDEF12 has been shipped',
      day * 2,
      snippet: 'Order 241101ABCDEF12 has been shipped by the seller.',
    ),
    mail(
      'mcinfo@ups.com',
      'UPS',
      'UPS Update: Package Scheduled for Delivery',
      day,
      snippet:
          'Your package from Gadget Hub is on the way. Tracking Number: '
          '1Z999AA10123456784. Scheduled Delivery: ${_weekday(now.add(day * 4))}',
    ),
    mail(
      'noreply@singpost.com',
      'SingPost',
      'Your item RR123456789SG has been delivered',
      day * 3,
      snippet: 'Your item RR123456789SG has been delivered to your mailbox.',
    ),
    mail(
      'orders@bookdepot.example',
      'Book Depot',
      'Your order BD-88231 has been dispatched',
      day * 45,
      snippet: 'Order BD-88231 has been dispatched with Ninja Van.',
    ),
    mail(
      'noreply@lazada.sg',
      'Lazada',
      'Your package has been delivered',
      day * 60,
      snippet: 'Order #352117908866123 was delivered. Rate your purchase!',
    ),
    // Not deliveries.
    mail(
      'news@fashion.example',
      'Fashion Co',
      'Free delivery on all orders this weekend!',
      day,
      snippet: 'Your favourite items, delivered to your door.',
      category: MessageCategory.newsletters,
    ),
    mail(
      'billing@fedex.com',
      'FedEx Billing',
      'Your FedEx invoice is ready',
      day * 2,
      snippet: 'Invoice number 123456789012. Amount due S\$45.00.',
    ),
  ]);

  // The Amazon email is on the device, with its markup.
  final stored = store.messages.byUid(inbox.id, amazon.uid)!;
  final raw =
      '''From: Amazon.sg <shipment-tracking@amazon.sg>
To: alice@citusmail.test
Subject: Your Amazon.sg order has shipped
Content-Type: text/html; charset=utf-8

<html><head><script type="application/ld+json">
{"@context": "http://schema.org", "@type": "ParcelDelivery",
 "carrier": {"@type": "Organization", "name": "Ninja Van"},
 "trackingNumber": "NVSGAMZ0012345678",
 "expectedArrivalUntil": "$expected",
 "itemShipped": [{"@type": "Product", "name": "Kindle Paperwhite (16 GB)"},
                 {"@type": "Product", "name": "USB-C charging cable"}],
 "partOfOrder": {"@type": "Order", "orderNumber": "171-5551234-7654321",
   "merchant": {"@type": "Organization", "name": "Amazon.sg"},
   "orderStatus": "http://schema.org/OrderInTransit"}}
</script></head>
<body><p>Your package is on its way. Track your package with Ninja Van.</p></body></html>
''';
  store.messages.saveBody(
    stored.id,
    utf8.encode(raw.replaceAll('\n', '\r\n')),
    searchableText: 'Your package is on its way.',
  );
}

String _weekday(DateTime d) => const [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
][d.toLocal().weekday - 1];
