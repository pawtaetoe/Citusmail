// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:test/test.dart';

/// Wednesday, 4 November 2026.
final _now = DateTime.utc(2026, 11, 4, 10);
var _ids = 0;

DeliveryEmail mail(
  String subject, {
  required String shop,
  String? name,
  String text = '',
  int daysAgo = 0,
  String? html,
  bool bulk = false,
}) {
  final things = html == null
      ? const <SchemaThing>[]
      : StructuredData.extract(html);
  return DeliveryEmail(
    messageId: ++_ids,
    shop: shop,
    senderName: name,
    subject: subject,
    text: text,
    at: _now.subtract(Duration(days: daysAgo)),
    parcels: ParcelDeliveryInfo.allIn(things),
    orders: OrderInfo.allIn(things),
    bulk: bulk,
  );
}

/// Windows as the app finds them: deliveries first, from the same mail.
List<ReturnWindow> find(List<DeliveryEmail> emails) => ReturnWindows.find(
  emails,
  deliveries: DeliveryFinder.find(emails, now: _now),
);

DateTime day(int y, int m, int d) => DateTime.utc(y, m, d);

ReturnPolicy? policy(String text) => ReturnWindows.policyIn(text, sent: _now);

void main() {
  group('policies in words', () {
    test('a number of days, and what they count from', () {
      expect(policy('Return within 30 days for a full refund.')?.days, 30);
      expect(policy('Return within 30 days.')!.fromDelivery, isFalse);
      final p = policy(
        'You can return most items within 30 days of delivery for a full '
        'refund.',
      )!;
      expect((p.days, p.fromDelivery), (30, true));
      expect(policy('30-day returns on all orders.')?.days, 30);
      expect(policy('15 Days Free Returns')?.days, 15);
      expect(policy('Enjoy our 30 day money-back guarantee.')?.days, 30);
      expect(policy('You have fourteen days to return your items.')?.days, 14);
      expect(
        policy('Return period: 14 days from the date of purchase.'),
        isA<ReturnPolicy>().having((p) => p.fromDelivery, 'from', false),
      );
      expect(
        policy('Change of mind returns within 15 days upon receipt.'),
        isA<ReturnPolicy>()
            .having((p) => p.days, 'days', 15)
            .having((p) => p.fromDelivery, 'from', true),
      );
      expect(
        policy(
          'Within 30 days of receiving your order, you can send it back for '
          'free.',
        )?.fromDelivery,
        isTrue,
      );
    });

    test('a stated last day', () {
      expect(
        policy('Free returns until 15 Dec 2026.')?.until,
        day(2026, 12, 15),
      );
      expect(policy('Return by 15/12/2026')?.until, day(2026, 12, 15));
      expect(
        policy('This item is eligible for return until December 4, 2026.')
            ?.until,
        day(2026, 12, 4),
      );
      expect(
        policy('Your refund window closes on Fri, 4 Dec.')?.until,
        day(2026, 12, 4),
      );
      expect(
        policy('Return or replace items: Eligible through December 4, 2026')
            ?.until,
        day(2026, 12, 4),
      );
      // A date wins over a number of days.
      expect(
        policy(
          '30-day returns. Holiday purchases can be returned until 31 Jan '
          '2027.',
        )?.until,
        day(2027, 1, 31),
      );
    });

    test('not a window', () {
      // Processing times.
      expect(policy('Returns are processed within 5 business days.'), isNull);
      expect(
        policy(
          'Once we receive your return, your refund will be issued within '
          '10 days.',
        ),
        isNull,
      );
      expect(policy('Refunds take 7-10 days to appear.'), isNull);
      // Delivery dates and warranties.
      expect(policy('Arriving by Fri, 4 Dec. Delivered by 6 Dec.'), isNull);
      expect(policy('Covered by a 1-year limited warranty.'), isNull);
      expect(policy('Order placed on 2 Nov 2026. Total S\$45.90'), isNull);
      // What can't be returned.
      expect(policy('This item is not eligible for return.'), isNull);
    });

    test('final sale', () {
      expect(ReturnWindows.isFinalSale('FINAL SALE - no returns'), isTrue);
      expect(ReturnWindows.isFinalSale('This item is non-returnable.'), isTrue);
      expect(ReturnWindows.isFinalSale('All sales are final.'), isTrue);
      // About some products, not this order.
      expect(
        ReturnWindows.isFinalSale(
          'Items marked final sale cannot be returned.',
        ),
        isFalse,
      );
      expect(
        ReturnWindows.isFinalSale('Gift cards are non-refundable.'),
        isFalse,
      );
      expect(
        ReturnWindows.isFinalSale('No return label needed: just drop it off.'),
        isFalse,
      );
    });

    test('returned or refunded', () {
      expect(
        ReturnWindows.saysReturned('Your refund has been processed', ''),
        isTrue,
      );
      expect(ReturnWindows.saysReturned('Return received', ''), isTrue);
      expect(
        ReturnWindows.saysReturned(
          'Update on order 241101ABCDEF12',
          'We have received your return and your refund has been '
              'processed.',
        ),
        isTrue,
      );
      // A policy is not a refund.
      expect(
        ReturnWindows.saysReturned(
          'Your order has shipped',
          'To get your refund, return it within 30 days.',
        ),
        isFalse,
      );
      expect(ReturnWindows.saysReturned('Re: your return', 'Thanks!'), isFalse);
    });
  });

  test('receipts worth reading', () {
    expect(ReturnWindows.looksLikeReceipt('Your UNIQLO e-receipt'), isTrue);
    expect(ReturnWindows.looksLikeReceipt('Your receipt from Apple'), isTrue);
    expect(
      ReturnWindows.looksLikeReceipt('Order Confirmed: 241020XYZ7788'),
      isTrue,
    );
    expect(
      ReturnWindows.looksLikeReceipt('Thank you for shopping with us'),
      isTrue,
    );
    expect(
      ReturnWindows.looksLikeReceipt('Your FedEx invoice is ready'),
      isFalse,
    );
    expect(ReturnWindows.looksLikeReceipt('Re: your receipt'), isFalse);
  });

  group('shops', () {
    test('Amazon: "eligible through" a date, on the delivery', () {
      final w = find([
        mail(
          'Your Amazon.sg order of "Kindle Paperwhite..."',
          shop: 'amazon.sg',
          name: 'Amazon.sg',
          daysAgo: 6,
          text:
              'Hello Sam,\nThank you for your order. We\'ll send a '
              'confirmation when your item ships.\n\nOrder # '
              '171-5551234-7654321\nKindle Paperwhite (16 GB)\nS\$239.00\n\n'
              'Return or replace items: Eligible through December 4, 2026\n',
        ),
        mail(
          'Your Amazon.sg order of "Kindle Paperwhite..." has shipped',
          shop: 'amazon.sg',
          name: 'Amazon.sg',
          daysAgo: 4,
          text:
              'Your package is on its way. Order # 171-5551234-7654321. '
              'Delivery with Ninja Van, tracking ID NVSGAMZ0012345678.',
        ),
        mail(
          'Delivered: Your Amazon.sg package',
          shop: 'amazon.sg',
          name: 'Amazon.sg',
          daysAgo: 2,
          text: 'Your package was delivered. Order # 171-5551234-7654321.',
        ),
      ]).single;
      expect(w.deadline, day(2026, 12, 4));
      expect(w.basis, ReturnBasis.stated);
      expect(w.daysLeft(_now), 30);
      expect(w.shopName, 'Amazon.sg');
      expect(w.orderNumber, '171-5551234-7654321');
      expect(w.deliveryKey, w.key);
      expect(w.key, 't:NVSGAMZ0012345678');
      expect(w.quote, contains('Eligible through December 4, 2026'));
    });

    test('Lazada: 15 days from receipt, counted from the delivery', () {
      final w = find([
        mail(
          'Thank you for your order #3301234567890',
          shop: 'lazada.sg',
          name: 'Lazada',
          daysAgo: 9,
          text:
              'Hi Sam, your order #3301234567890 has been placed.\n'
              'Xiaomi Smart Band 9\n\n'
              'Lazada Guarantee: Change of mind returns within 15 days upon '
              'receipt.',
        ),
        mail(
          'Your package has been delivered',
          shop: 'lazada.sg',
          name: 'Lazada',
          daysAgo: 3,
          text:
              'Your package for order #3301234567890 has been delivered by '
              'Lazada Express. Happy shopping!',
        ),
      ]).single;
      expect(w.basis, ReturnBasis.delivery);
      expect(w.countedFrom, day(2026, 11, 1));
      expect(w.deadline, day(2026, 11, 16));
      expect(w.days, 15);
      expect(w.fromDeliveryUnknown, isFalse);
    });

    test('from delivery, while it is still on the way: the order date', () {
      final w = find([
        mail(
          'Your order 241101ABCDEF12 has been shipped',
          shop: 'shopee.sg',
          name: 'Shopee',
          daysAgo: 2,
          text:
              'Order 241101ABCDEF12 has been shipped by the seller with '
              'Shopee Express. You may request a return or refund within 15 '
              'days of receiving your order.',
        ),
      ]).single;
      expect(w.basis, ReturnBasis.order);
      expect(w.fromDeliveryUnknown, isTrue);
      expect(w.countedFrom, day(2026, 11, 2));
      expect(w.deadline, day(2026, 11, 17));
    });

    test('Shopee: "15 Days Free Returns" from the order', () {
      final w = find([
        mail(
          'Order Confirmed: 241020XYZ7788',
          shop: 'shopee.sg',
          name: 'Shopee',
          daysAgo: 10,
          text:
              'Your order 241020XYZ7788 is confirmed.\nAnker 20W Charger x1\n'
              'Shopee Mall: 15 Days Free Returns',
        ),
      ]).single;
      expect(w.basis, ReturnBasis.order);
      expect(w.fromDeliveryUnknown, isFalse);
      expect(w.deadline, day(2026, 11, 9));
      expect(w.key, 'o:shopee.sg:241020XYZ7788');
    });

    test('Uniqlo: "return by" a date in an e-receipt', () {
      final w = find([
        mail(
          'Your UNIQLO e-receipt',
          shop: 'uniqlo.com',
          name: 'UNIQLO',
          daysAgo: 1,
          text:
              'Thank you for shopping at UNIQLO ION Orchard.\n'
              'Receipt No. 0123-4567-890\nAIRism Cotton T-Shirt S\$19.90\n'
              'Return by 15/12/2026 with this receipt and the tags attached.',
        ),
      ]).single;
      expect(w.deadline, day(2026, 12, 15));
      expect(w.basis, ReturnBasis.stated);
      expect(w.shopName, 'UNIQLO');
    });

    test('Apple: 14 calendar days of receipt, no delivery known', () {
      final w = find([
        mail(
          'We\'re processing your order W1234567890',
          shop: 'apple.com',
          name: 'Apple Store',
          daysAgo: 3,
          text:
              'Thank you for your order. Order Number: W1234567890.\n'
              'AirPods Pro 2\n\n'
              'Apple Store Online purchases can be returned within 14 '
              'calendar days of receipt. Some exceptions apply.',
        ),
      ]).single;
      expect(w.days, 14);
      expect(w.basis, ReturnBasis.order);
      expect(w.fromDeliveryUnknown, isTrue);
      expect(w.deadline, day(2026, 11, 15));
      expect(w.orderNumber, 'W1234567890');
    });

    test('schema.org order: merchant, items and order date', () {
      const html = '''
<script type="application/ld+json">
{"@context":"http://schema.org","@type":"Order","merchant":{"@type":"Organization","name":"Gadget Hub"},
"orderNumber":"GH-55012","orderDate":"2026-10-20T08:00:00+08:00",
"acceptedOffer":{"@type":"Offer","itemOffered":{"@type":"Product","name":"Mechanical keyboard"}}}
</script>''';
      final w = find([
        mail(
          'Your Gadget Hub order is confirmed',
          shop: 'gadgethub.example',
          daysAgo: 1,
          html: html,
          text: 'Thanks for shopping with us. 30-day returns, no questions.',
        ),
      ]).single;
      expect(w.shopName, 'Gadget Hub');
      expect(w.items, ['Mechanical keyboard']);
      expect(w.countedFrom, day(2026, 10, 20));
      expect(w.deadline, day(2026, 11, 19));
    });
  });

  group('left out', () {
    test('no policy stated: nothing invented', () {
      expect(
        find([
          mail(
            'Thank you for your order #3309988776655',
            shop: 'lazada.sg',
            name: 'Lazada',
            daysAgo: 2,
            text: 'Your order #3309988776655 has been placed. Total S\$12.90.',
          ),
        ]),
        isEmpty,
      );
    });

    test('final sale', () {
      expect(
        find([
          mail(
            'Order confirmation #A10023',
            shop: 'fashionco.example',
            name: 'Fashion Co',
            daysAgo: 2,
            text:
                'Order #A10023\nSilk scarf (FINAL SALE)\n\nFinal sale: this '
                'item cannot be returned or exchanged.\n\nFree 30-day '
                'returns on full-price items.',
          ),
        ]),
        isEmpty,
      );
      // A note about other products keeps the window.
      expect(
        find([
          mail(
            'Order confirmation #A10024',
            shop: 'fashionco.example',
            name: 'Fashion Co',
            daysAgo: 2,
            text:
                'Order #A10024\nLinen shirt\n\nItems marked final sale are '
                'non-returnable; everything else can be returned within 30 '
                'days.',
          ),
        ]).single.deadline,
        day(2026, 12, 2),
      );
    });

    test('refunded, by order number', () {
      expect(
        find([
          mail(
            'Order Confirmed: 241020XYZ7788',
            shop: 'shopee.sg',
            name: 'Shopee',
            daysAgo: 10,
            text: 'Order 241020XYZ7788 confirmed. 15 Days Free Returns.',
          ),
          mail(
            'Refund processed for order 241020XYZ7788',
            shop: 'shopee.sg',
            name: 'Shopee',
            daysAgo: 1,
            text: 'S\$18.90 has been refunded to your ShopeePay wallet.',
          ),
        ]),
        isEmpty,
      );
    });

    test('returned, by the item named', () {
      expect(
        find([
          mail(
            'Your UNIQLO e-receipt',
            shop: 'uniqlo.com',
            name: 'UNIQLO',
            daysAgo: 8,
            html: '''
<script type="application/ld+json">
{"@context":"http://schema.org","@type":"Order","merchant":"UNIQLO","orderedItem":{"@type":"Product","name":"Ultra Light Down Jacket"}}
</script>''',
            text: 'Return by 15/12/2026 with this receipt.',
          ),
          mail(
            'We\'ve received your return',
            shop: 'uniqlo.com',
            name: 'UNIQLO',
            daysAgo: 1,
            text: 'Ultra Light Down Jacket: refund of S\$79.90 on its way.',
          ),
        ]),
        isEmpty,
      );
    });

    test('returned to the sender', () {
      expect(
        find([
          mail(
            'Order confirmation 88123456',
            shop: 'bookdepot.example',
            name: 'Book Depot',
            daysAgo: 20,
            text: 'Order 88123456. Return within 30 days of delivery.',
          ),
          mail(
            'Your parcel is being returned to sender',
            shop: 'bookdepot.example',
            name: 'Book Depot',
            daysAgo: 3,
            text: 'Order 88123456: tracking number RR987654321SG.',
          ),
        ]),
        isEmpty,
      );
    });

    test('a newsletter about free returns', () {
      expect(
        find([
          mail(
            'New arrivals: free 30-day returns on everything',
            shop: 'fashionco.example',
            name: 'Fashion Co',
            bulk: true,
            text: 'Shop the new season. Free returns within 30 days.',
          ),
          mail(
            'Weekend sale',
            shop: 'fashionco.example',
            name: 'Fashion Co',
            text: 'Up to 50% off. 30-day returns.',
          ),
        ]),
        isEmpty,
      );
    });

    test('replies and forwards', () {
      expect(
        find([
          mail(
            'Fwd: Your UNIQLO e-receipt',
            shop: 'gmail.com',
            name: 'Sam',
            text: 'Return by 15/12/2026.',
          ),
        ]),
        isEmpty,
      );
    });
  });

  test('soonest deadline first; closed ones too', () {
    final list = find([
      mail(
        'Your UNIQLO e-receipt',
        shop: 'uniqlo.com',
        name: 'UNIQLO',
        daysAgo: 1,
        text: 'Return by 15/12/2026.',
      ),
      mail(
        'Order Confirmed: 241020XYZ7788',
        shop: 'shopee.sg',
        name: 'Shopee',
        daysAgo: 30,
        text: 'Order 241020XYZ7788. 15 Days Free Returns.',
      ),
      mail(
        'We\'re processing your order W1234567890',
        shop: 'apple.com',
        name: 'Apple Store',
        daysAgo: 3,
        text: 'Order Number: W1234567890. Returnable within 14 days.',
      ),
    ]);
    expect(
      [for (final w in list) w.shopName],
      ['Shopee', 'Apple Store', 'UNIQLO'],
    );
    expect(list.first.daysLeft(_now), lessThan(0));
  });
}
