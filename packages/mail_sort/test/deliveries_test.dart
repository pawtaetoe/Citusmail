// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

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
    messageId: MessageId(++_ids),
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

List<Delivery> find(List<DeliveryEmail> emails, {Set<String>? marked}) =>
    DeliveryFinder.find(emails, now: _now, markedDelivered: marked ?? const {});

void main() {
  group('text only', () {
    test('SingPost: out for delivery, with its tracking page', () {
      final d = find([
        mail(
          'Your item RR123456789SG is out for delivery',
          shop: 'singpost.com',
          name: 'SingPost',
          text:
              'Dear Customer,\n\nYour item with tracking number RR123456789SG '
              'is out for delivery today. Please ensure someone is available '
              'to receive it.\n\nSingapore Post Limited',
        ),
      ]).single;
      expect(d.status, DeliveryStatus.outForDelivery);
      expect(d.trackingNumber, 'RR123456789SG');
      expect(d.carrier, Carrier.singPost);
      expect(d.trackingUrl.toString(), contains('RR123456789SG'));
      expect(d.trackingUrl!.scheme, 'https');
      expect(d.key, 't:RR123456789SG');
    });

    test('Ninja Van: on the way, with the expected date', () {
      final d = find([
        mail(
          'Your parcel from Lazada is on the way!',
          shop: 'ninjavan.co',
          name: 'Ninja Van',
          text:
              'Hi Alice, your parcel NVSGLZD0001234567 from Lazada is on its '
              'way. Estimated delivery: Sat, 7 Nov 2026. Track your parcel '
              'with Ninja Van.',
        ),
      ]).single;
      expect(d.status, DeliveryStatus.shipped);
      expect(d.carrier, Carrier.ninjaVan);
      expect(d.trackingNumber, 'NVSGLZD0001234567');
      expect(d.expected, DateTime(2026, 11, 7));
      expect(d.trackingUrl?.host, 'www.ninjavan.co');
    });

    test('Shopee: ordered, shipped and delivered are one delivery', () {
      const order = '241101ABCDEF12';
      final list = find([
        mail(
          'Thank you for your order',
          shop: 'shopee.sg',
          name: 'Shopee',
          text: 'Order ID: $order\nWireless mouse x1\nTotal: \$15.90',
          daysAgo: 4,
        ),
        mail(
          'Your order $order has been shipped',
          shop: 'shopee.sg',
          name: 'Shopee',
          text:
              'Your order $order has been shipped out by the seller via '
              'Shopee Express. It should arrive within 3 days.',
          daysAgo: 3,
        ),
        mail(
          'Your order $order has been delivered',
          shop: 'shopee.sg',
          name: 'Shopee',
          text: 'Order $order was delivered. Please confirm receipt.',
          daysAgo: 1,
        ),
      ]);
      final d = list.single;
      expect(d.records, hasLength(3));
      expect(d.status, DeliveryStatus.delivered);
      expect(d.orderNumber, order);
      expect(d.shopName, 'Shopee');
      expect(d.key, 'o:shopee.sg:$order');
      expect(d.deliveredAt, _now.subtract(const Duration(days: 1)));
      expect(d.records.first.status, DeliveryStatus.ordered);
    });

    test('shipping mail sorted as a newsletter still counts with a number', () {
      final d = find([
        mail(
          'Your Lazada order has been shipped',
          shop: 'lazada.sg',
          name: 'Lazada',
          text: 'Order #352117908866123 is on its way to you.',
          bulk: true,
        ),
      ]).single;
      expect(d.orderNumber, '352117908866123');
      expect(d.status, DeliveryStatus.shipped);
    });

    test('UPS 1Z number, scheduled day', () {
      final d = find([
        mail(
          'UPS Update: Package Scheduled for Delivery Tuesday',
          shop: 'ups.com',
          name: 'UPS',
          text:
              'Hello, your package is on the way.\n'
              'Tracking Number: 1Z999AA10123456784\n'
              'Scheduled Delivery: Tuesday\n'
              'Shipped From: Gadget Hub',
        ),
      ]).single;
      expect(d.carrier, Carrier.ups);
      expect(d.trackingNumber, '1Z999AA10123456784');
      expect(d.status, DeliveryStatus.shipped);
      expect(d.expected, DateTime(2026, 11, 10)); // next Tuesday
      expect(
        d.trackingUrl.toString(),
        'https://www.ups.com/track?tracknum=1Z999AA10123456784',
      );
    });

    test('FedEx, DHL and USPS numbers need the carrier nearby', () {
      final fedex = DeliveryFinder.trackingNumbersIn(
        'Your FedEx tracking number is 612999995555.',
      ).single;
      expect(fedex.carrier, Carrier.fedex);
      final dhl = DeliveryFinder.trackingNumbersIn(
        'DHL Express waybill 1234567890 is on its way',
      ).single;
      expect(dhl.carrier, Carrier.dhl);
      final usps = DeliveryFinder.trackingNumbersIn(
        'USPS: 9400111899223197428490 in transit',
      ).single;
      expect(usps.carrier, Carrier.usps);
      // The same digits with nobody named: not a tracking number.
      expect(
        DeliveryFinder.trackingNumbersIn('Reference 612999995555'),
        isEmpty,
      );
      // A 10-digit number near FedEx (wrong length) isn't one either.
      expect(
        DeliveryFinder.trackingNumbersIn('FedEx: 1234567890 is our number'),
        isEmpty,
      );
    });

    test('a carrier email joins the shop\'s order by tracking number', () {
      final list = find([
        mail(
          'Your Kitchen Corner order KC-4471 has shipped',
          shop: 'kitchencorner.example',
          name: 'Kitchen Corner',
          text:
              'Order KC-4471 is on its way with J&T Express. Tracking number: '
              'JTE800123456789',
          daysAgo: 2,
        ),
        mail(
          'Your parcel JTE800123456789 is out for delivery',
          shop: 'jtexpress.sg',
          name: 'J&T Express',
          text: 'Your parcel JTE800123456789 is out for delivery today.',
        ),
      ]);
      final d = list.single;
      expect(d.records, hasLength(2));
      expect(d.shopName, 'Kitchen Corner', reason: 'not the carrier');
      expect(d.carrierName, 'J&T Express');
      expect(d.status, DeliveryStatus.outForDelivery);
      expect(d.trackingUrl, isNull, reason: 'no known page');
    });

    test('status words', () {
      DeliveryStatus? s(String subject, [String text = '']) =>
          DeliveryFinder.statusOf(subject, text);
      expect(s('Delivered: Your Amazon.sg package'), DeliveryStatus.delivered);
      expect(
        s('Your package will be delivered today'),
        DeliveryStatus.outForDelivery,
      );
      expect(
        s('Your package will be delivered tomorrow'),
        DeliveryStatus.shipped,
      );
      expect(s('Delivery attempt failed'), DeliveryStatus.problem);
      expect(
        s('We missed you: we tried to deliver your parcel'),
        DeliveryStatus.problem,
      );
      expect(
        s('Your parcel is being returned to sender'),
        DeliveryStatus.returned,
      );
      expect(
        s('Your parcel is ready for collection'),
        DeliveryStatus.readyForPickup,
      );
      expect(s('Order confirmed'), DeliveryStatus.ordered);
      expect(
        s('Order #1234 update', 'Good news! Your order has been shipped.'),
        DeliveryStatus.shipped,
      );
      // Bodies tell what will happen: not a statement.
      expect(
        s(
          'Thanks for shopping',
          "We'll email you when your order has shipped.",
        ),
        isNull,
      );
    });

    test('expected dates', () {
      final sent = DateTime(2026, 11, 4, 9);
      DateTime? e(String text) => DeliveryFinder.expectedIn(text, sent);
      expect(e('Arriving Thursday, November 7'), DateTime(2026, 11, 7));
      expect(e('Estimated delivery: 7th Nov'), DateTime(2026, 11, 7));
      expect(e('Arriving tomorrow'), DateTime(2026, 11, 5));
      expect(e('Expected delivery date: 2026-11-09'), DateTime(2026, 11, 9));
      expect(
        e('Estimated delivery between 6 Nov and 8 Nov'),
        DateTime(2026, 11, 8),
      );
      expect(e('Arrives Jan 3'), DateTime(2027, 1, 3), reason: 'next year');
      expect(e('Ships from Singapore'), isNull);
    });
  });

  group('markup', () {
    test('an Amazon-style ParcelDelivery', () {
      final d = find([
        mail(
          'Your Amazon.sg order has shipped',
          shop: 'amazon.sg',
          name: 'Amazon.sg',
          html: '''
<script type="application/ld+json">
{"@context": "http://schema.org", "@type": "ParcelDelivery",
 "carrier": {"@type": "Organization", "name": "Ninja Van"},
 "trackingNumber": "NVSGAMZ0012345678",
 "expectedArrivalUntil": "2026-11-07T21:00:00+08:00",
 "itemShipped": [{"@type": "Product", "name": "Kindle Paperwhite"}],
 "partOfOrder": {"@type": "Order", "orderNumber": "171-5551234-7654321",
   "merchant": {"@type": "Organization", "name": "Amazon.sg"},
   "orderStatus": "http://schema.org/OrderInTransit"}}
</script>''',
        ),
      ]).single;
      expect(d.status, DeliveryStatus.shipped);
      expect(d.items, ['Kindle Paperwhite']);
      expect(d.carrier, Carrier.ninjaVan);
      expect(d.orderNumber, '171-5551234-7654321');
      expect(d.expected, DateTime.utc(2026, 11, 7, 13));
    });

    test('an unknown carrier keeps the markup\'s https page', () {
      final d = find([
        mail(
          'Shipping confirmation',
          shop: 'bookdepot.example',
          html: '''
<div itemscope itemtype="http://schema.org/ParcelDelivery">
  <meta itemprop="trackingNumber" content="QX12345678SG01"/>
  <div itemprop="carrier" itemscope itemtype="http://schema.org/Organization">
    <meta itemprop="name" content="Speedy Couriers"/></div>
  <link itemprop="trackingUrl" href="https://speedy.example/t/QX12345678SG01"/>
</div>''',
        ),
      ]).single;
      expect(d.carrier, isNull);
      expect(d.carrierName, 'Speedy Couriers');
      expect(d.trackingUrl?.host, 'speedy.example');
    });
  });

  group('over time', () {
    test('no news for a month: probably delivered', () {
      final d = find([
        mail(
          'Your order has been dispatched',
          shop: 'shop.example',
          text: 'Your order #55123 has been dispatched with DHL.',
          daysAgo: 40,
        ),
      ]).single;
      expect(d.status, DeliveryStatus.delivered);
      expect(d.probablyDelivered, isTrue);
      expect(d.carrier, Carrier.dhl, reason: 'named in the text');
    });

    test('marked delivered by the user', () {
      final emails = [
        mail(
          'Your order has been dispatched',
          shop: 'shop.example',
          text: 'Your order #55124 has been dispatched.',
          daysAgo: 5,
        ),
      ];
      final key = find(emails).single.key;
      final d = find(emails, marked: {key}).single;
      expect(d.status, DeliveryStatus.delivered);
      expect(d.markedDelivered, isTrue);
      expect(d.probablyDelivered, isFalse);
    });
  });

  group('not deliveries', () {
    test('an invoice number near a carrier', () {
      expect(
        find([
          mail(
            'Your FedEx invoice is ready',
            shop: 'fedex.com',
            name: 'FedEx Billing',
            text: 'Invoice number 123456789012. Amount due S\$45.00.',
          ),
        ]),
        isEmpty,
      );
    });

    test('a phone number near a carrier', () {
      expect(
        DeliveryFinder.trackingNumbersIn(
          'Questions about your parcel? Call DHL at 6567891234.',
        ),
        isEmpty,
      );
      expect(
        find([
          mail(
            'How did we do? Tell DHL about your experience',
            shop: 'dhl.com',
            text: 'Questions about your parcel? Call DHL at 6567891234.',
          ),
        ]),
        isEmpty,
      );
    });

    test('a verification code', () {
      expect(
        find([
          mail(
            'Your Lazada verification code',
            shop: 'lazada.sg',
            text: 'Your code is 482913. Do not share it with anyone.',
          ),
        ]),
        isEmpty,
      );
    });

    test('a newsletter mentioning delivery', () {
      for (final bulk in [true, false]) {
        expect(
          find([
            mail(
              'Free delivery on all orders this weekend!',
              shop: 'fashion.example',
              text:
                  'Shop now and enjoy free delivery. Your favourite items, '
                  'delivered to your door.',
              bulk: bulk,
            ),
            mail(
              'Arriving soon: our winter collection',
              shop: 'fashion.example',
              text: 'New items are on their way to our stores.',
              bulk: bulk,
            ),
          ]),
          isEmpty,
        );
      }
    });

    test('an order confirmation alone is not shipped yet', () {
      expect(
        find([
          mail(
            'Order #123456789012 confirmed',
            shop: 'shop.example',
            text: 'Thank you for your order. FedEx shipping selected.',
          ),
        ]),
        isEmpty,
      );
    });

    test('replies and forwards', () {
      expect(
        find([
          mail(
            'Fwd: Your parcel is out for delivery',
            shop: 'gmail.com',
            text: 'Your parcel RR123456789SG is out for delivery today.',
          ),
        ]),
        isEmpty,
      );
    });
  });

  group('carriers and shops', () {
    test('a courier that picked up the parcel, then delivers it today', () {
      expect(
        DeliveryFinder.statusOf(
          'Swift Van has picked up your parcel SWX123456789',
          '',
        ),
        DeliveryStatus.shipped,
      );
      expect(
        DeliveryFinder.statusOf(
          'Your parcel from Acme Sports is being delivered to you today!',
          '',
        ),
        DeliveryStatus.outForDelivery,
      );
      expect(
        DeliveryFinder.statusOf(
          'Parcel update',
          'Your parcel from Acme Sports has been picked up by Swift Van!',
        ),
        DeliveryStatus.shipped,
      );
    });

    test('the courier\'s updates join the shop\'s order', () {
      final d = find([
        mail(
          'Your order AB12CD34EF is shipped!',
          shop: 'acmesports.example',
          name: 'Acme Sports',
          text: 'Order no. AB12CD34EF. Our carrier has taken over.',
          daysAgo: 3,
        ),
        mail(
          'Ninja Van has picked up your parcel NVSGACM00000123456',
          shop: 'ninjavan.co',
          name: 'Ninja Van',
          text:
              'Your parcel from Acme Sports Sg has been picked up by Ninja '
              'Van! Order tracking ID NVSGACM00000123456',
          daysAgo: 2,
        ),
        mail(
          'Your parcel from Acme Sports Sg is being delivered to you today!',
          shop: 'ninjavan.co',
          name: 'Ninja Van',
          text: 'Order tracking ID NVSGACM00000123456',
        ),
      ]).single;
      expect(d.status, DeliveryStatus.outForDelivery);
      expect(d.shop, 'acmesports.example');
      expect(d.shopName, 'Acme Sports');
      expect(d.orderNumber, 'AB12CD34EF');
      expect(d.trackingNumber, 'NVSGACM00000123456');
      expect(d.carrier, Carrier.ninjaVan);
      expect(d.records, hasLength(3));
    });

    test('a carrier email names the shop by its sender name', () {
      final d = find([
        mail(
          'Your order 0a1b2c3d4e5f is ready to be shipped',
          shop: 'shipmentsplatform.example',
          name: 'Example Toys B.V.',
          text: 'Track your shipment',
          daysAgo: 4,
        ),
        mail(
          'DHL On Demand Delivery',
          shop: 'dhl.com',
          name: 'DHL Express',
          text:
              'Your DHL Express shipment with waybill number 1234567890 from '
              'EXAMPLE TOYS BV has been delivered on Fri 28 Nov at 12:07.',
        ),
      ]).single;
      expect(d.status, DeliveryStatus.delivered);
      expect(d.shopName, 'Example Toys B.V.');
      expect(d.trackingNumber, '1234567890');
    });

    test('two orders from the shop: the courier is not guessed', () {
      final found = find([
        mail(
          'Your order AA11BB22CC is shipped!',
          shop: 'acmesports.example',
          name: 'Acme Sports',
          daysAgo: 3,
        ),
        mail(
          'Your order DD33EE44FF is shipped!',
          shop: 'acmesports.example',
          name: 'Acme Sports',
          daysAgo: 3,
        ),
        mail(
          'Your parcel from Acme Sports is on its way',
          shop: 'ninjavan.co',
          name: 'Ninja Van',
          text: 'Tracking ID NVSGACM00000999999',
        ),
      ]);
      expect(found, hasLength(3));
    });

    test('a courier alone: the shop it names', () {
      final d = find([
        mail(
          'Swift has delivered your parcel',
          shop: 'ninjavan.co',
          name: 'Ninja Van SG',
          text:
              'Your parcel from Example Mart has been delivered! '
              'Tracking ID NVSGEXM00000111111',
        ),
      ]).single;
      expect(d.shopName, 'Example Mart');
    });

    test('a shipment number is a tracking number', () {
      final r = DeliveryFinder.read(
        mail(
          'Courier: Shipment is on its way',
          shop: 'courier.example',
          text:
              'Dear Customer, Your shipment number: 200700000001 is on its '
              'way to you.',
        ),
      );
      expect(r.trackingNumbers, ['200700000001']);
      expect(r.status, DeliveryStatus.shipped);
    });
  });

  group('not parcels', () {
    test('a refund on its way is money, not a delivery', () {
      expect(
        find([
          mail(
            'Your refund is on its way',
            shop: 'food.example',
            text:
                'Sorry that your order ab12-3456-cdef from Example Burger '
                "didn't turn out the way it should've.",
          ),
          mail(
            'Your cashback has been sent',
            shop: 'cashback.example',
            text: 'Your order 99887766 earned cashback.',
          ),
        ]),
        isEmpty,
      );
    });
  });
}
