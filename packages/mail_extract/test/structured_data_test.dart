// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_extract/mail_extract.dart';
import 'package:test/test.dart';

/// A shipping email in the shape big shops send: JSON-LD in the head,
/// the visible part as ordinary HTML.
const _amazonStyle = '''
<html><head>
<meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
<script type="application/ld+json">
{
  "@context": "http://schema.org",
  "@type": "ParcelDelivery",
  "deliveryAddress": {
    "@type": "PostalAddress",
    "streetAddress": "12 Example Road",
    "addressLocality": "Singapore",
    "postalCode": "123456",
    "addressCountry": "SG"
  },
  "expectedArrivalFrom": "2026-11-06T09:00:00+08:00",
  "expectedArrivalUntil": "2026-11-07T21:00:00+08:00",
  "carrier": {"@type": "Organization", "name": "UPS"},
  "itemShipped": [
    {"@type": "Product", "name": "Kindle Paperwhite (16 GB)"},
    {"@type": "Product", "name": "USB-C charging cable"}
  ],
  "trackingNumber": "1Z999AA10123456784",
  "trackingUrl": "https://www.ups.com/track?tracknum=1Z999AA10123456784",
  "deliveryStatus": {"@type": "DeliveryEvent", "eventStatus": "http://schema.org/OrderInTransit"},
  "partOfOrder": {
    "@type": "Order",
    "orderNumber": "171-5551234-7654321",
    "merchant": {"@type": "Organization", "name": "Amazon.sg"},
    "orderStatus": "http://schema.org/OrderInTransit"
  }
}
</script>
</head><body><p>Your package is on its way!</p></body></html>
''';

void main() {
  group('JSON-LD', () {
    test('an Amazon-style ParcelDelivery', () {
      final things = StructuredData.extract(_amazonStyle);
      expect(things, hasLength(1));
      final p = ParcelDeliveryInfo.allIn(things).single;
      expect(p.trackingNumber, '1Z999AA10123456784');
      expect(p.carrier, 'UPS');
      expect(
        p.trackingUrl,
        Uri.parse('https://www.ups.com/track?tracknum=1Z999AA10123456784'),
      );
      expect(p.expectedUntil, DateTime.utc(2026, 11, 7, 13));
      expect(p.expectedFrom, DateTime.utc(2026, 11, 6, 1));
      expect(p.status, DeliveryStatus.shipped);
      expect(p.items, ['Kindle Paperwhite (16 GB)', 'USB-C charging cable']);
      expect(p.order?.orderNumber, '171-5551234-7654321');
      expect(p.order?.merchant, 'Amazon.sg');
    });

    test('an Order with several items, and its delivery inside it', () {
      const source = '''
<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@type": "Order",
  "merchant": {"@type": "Organization", "name": "Book Depot"},
  "orderNumber": "BD-88231",
  "orderStatus": "https://schema.org/OrderProcessing",
  "orderDate": "2026-11-01",
  "url": "https://bookdepot.example/orders/BD-88231",
  "acceptedOffer": [
    {"@type": "Offer", "itemOffered": {"@type": "Product", "name": "The Remains of the Day"}, "price": "14.90", "priceCurrency": "SGD"},
    {"@type": "Offer", "itemOffered": {"@type": "Book", "name": "Klara and the Sun"}, "price": 18.5}
  ],
  "orderedItem": [
    {"@type": "OrderItem", "orderQuantity": 1, "orderedItem": {"@type": "Product", "name": "Bookmark set"}}
  ],
  "orderDelivery": {
    "@type": "ParcelDelivery",
    "provider": {"@type": "Organization", "name": "Ninja Van"},
    "trackingNumber": "NVSGBKDP000123456"
  }
}
</script>''';
      final things = StructuredData.extract(source);
      final order = OrderInfo.allIn(things).single;
      expect(order.orderNumber, 'BD-88231');
      expect(order.merchant, 'Book Depot');
      expect(order.status, DeliveryStatus.ordered);
      expect(order.orderDate, DateTime(2026, 11, 1));
      expect(order.url?.host, 'bookdepot.example');
      expect(order.items, [
        'Bookmark set',
        'The Remains of the Day',
        'Klara and the Sun',
      ]);
      final p = ParcelDeliveryInfo.allIn(things).single;
      expect(p.carrier, 'Ninja Van');
      expect(p.trackingNumber, 'NVSGBKDP000123456');
      expect(p.order?.orderNumber, 'BD-88231');
      expect(p.items, hasLength(3), reason: "the order's items");
      expect(p.status, DeliveryStatus.ordered);
    });

    test('an @graph document with references by @id', () {
      const source = '''
<script type='application/ld+json'>
{
  "@context": "http://schema.org",
  "@graph": [
    {"@id": "#shop", "@type": "Organization", "name": "Gadget Hub"},
    {"@id": "#order", "@type": "Order", "orderNumber": "GH-1009",
     "seller": {"@id": "#shop"},
     "orderedItem": "Wireless earbuds"},
    {"@type": "ParcelDelivery", "partOfOrder": {"@id": "#order"},
     "carrier": "DHL Express", "trackingNumber": "1234567890",
     "deliveryStatus": "http://schema.org/OrderDelivered"}
  ]
}
</script>''';
      final things = StructuredData.extract(source);
      expect(things.map((t) => t.types.single), [
        'Organization',
        'Order',
        'ParcelDelivery',
      ]);
      final p = ParcelDeliveryInfo.allIn(things).single;
      expect(p.carrier, 'DHL Express');
      expect(p.status, DeliveryStatus.delivered);
      expect(p.order?.merchant, 'Gadget Hub');
      expect(p.items, ['Wireless earbuds']);
    });

    test('an array of items, and a trailing comma', () {
      const source = '''
<script type="application/ld+json">[
  {"@type": "ParcelDelivery", "trackingNumber": "RR123456789SG", "carrier": "SingPost",},
  {"@type": "ParcelDelivery", "trackingNumber": "RR987654321SG", "carrier": "SingPost"}
]</script>''';
      final parcels = ParcelDeliveryInfo.allIn(StructuredData.extract(source));
      expect(parcels.map((p) => p.trackingNumber), [
        'RR123456789SG',
        'RR987654321SG',
      ]);
    });

    test('malformed JSON is skipped, the next script still read', () {
      const source = '''
<script type="application/ld+json">{"@type": "ParcelDelivery", "trackingNumber": </script>
<script type="application/ld+json"><!--
{"@type": "Order", "orderNumber": "A-1"}
--></script>''';
      final things = StructuredData.extract(source);
      expect(things, hasLength(1));
      expect(OrderInfo.allIn(things).single.orderNumber, 'A-1');
    });

    test('only https tracking pages', () {
      const source = '''
<script type="application/ld+json">
{"@type": "ParcelDelivery", "trackingNumber": "X1",
 "trackingUrl": "javascript:alert(1)"}</script>
<script type="application/ld+json">
{"@type": "ParcelDelivery", "trackingNumber": "X2",
 "trackingUrl": "http://carrier.example/t/X2"}</script>''';
      final parcels = ParcelDeliveryInfo.allIn(StructuredData.extract(source));
      expect(parcels.map((p) => p.trackingUrl), [null, null]);
    });

    test('huge or deeply nested documents stay within limits', () {
      final deep = '${'{"@type":"Thing","x":' * 200}"end"${'}' * 200}';
      final nestedLists = '${'[' * 5000}${']' * 5000}';
      final many = [
        for (var i = 0; i < 1000; i++)
          '{"@type":"ParcelDelivery","trackingNumber":"T$i"}',
      ].join(',');
      final source =
          '<script type="application/ld+json">$deep</script>'
          '<script type="application/ld+json">$nestedLists</script>'
          '<script type="application/ld+json">[$many]</script>';
      final things = StructuredData.extract(source);
      expect(ParcelDeliveryInfo.allIn(things).length, lessThanOrEqualTo(200));
      // A script beyond the size limit is skipped.
      final big =
          '<script type="application/ld+json">{"@type":"Order","orderNumber":"'
          '${'9' * 600000}"}</script>';
      expect(StructuredData.extract(big), isEmpty);
    });

    test('ordinary scripts and plain HTML give nothing', () {
      expect(
        StructuredData.extract(
          '<script>var order = {"@type": "Order"};</script><p>Hi</p>',
        ),
        isEmpty,
      );
      expect(StructuredData.extract(''), isEmpty);
    });
  });

  group('microdata', () {
    test('a ParcelDelivery with nested items', () {
      const source = '''
<div itemscope itemtype="http://schema.org/ParcelDelivery">
  <div itemprop="carrier" itemscope itemtype="http://schema.org/Organization">
    <meta itemprop="name" content="FedEx"/>
  </div>
  <p>Tracking number: <span itemprop="trackingNumber">612999995555</span></p>
  <link itemprop="trackingUrl" href="https://www.fedex.com/fedextrack/?trknbr=612999995555"/>
  <time itemprop="expectedArrivalUntil" datetime="2026-11-09">Monday</time>
  <div itemprop="itemShipped" itemscope itemtype="http://schema.org/Product">
    <span itemprop="name">Espresso
      machine</span>
  </div>
  <div itemprop="partOfOrder" itemscope itemtype="http://schema.org/Order">
    <span itemprop="orderNumber">KC-4471</span>
    <div itemprop="merchant" itemscope itemtype="http://schema.org/Organization">
      <span itemprop="name">Kitchen Corner</span>
    </div>
    <link itemprop="orderStatus" href="http://schema.org/OrderInTransit"/>
  </div>
</div>''';
      final things = StructuredData.extract(source);
      expect(things, hasLength(1));
      final p = ParcelDeliveryInfo.allIn(things).single;
      expect(p.carrier, 'FedEx');
      expect(p.trackingNumber, '612999995555');
      expect(p.trackingUrl?.host, 'www.fedex.com');
      expect(p.expectedUntil, DateTime(2026, 11, 9));
      expect(p.items, ['Espresso machine']);
      expect(p.order?.orderNumber, 'KC-4471');
      expect(p.order?.merchant, 'Kitchen Corner');
      expect(p.status, DeliveryStatus.shipped);
    });

    test('scripts in the HTML are never run, only read', () {
      const source = '''
<div itemscope itemtype="https://schema.org/Order">
  <script>document.write('<span itemprop="orderNumber">EVIL</span>')</script>
  <span itemprop="orderNumber">REAL-1</span>
</div>''';
      final order = OrderInfo.allIn(StructuredData.extract(source)).single;
      expect(order.orderNumber, 'REAL-1');
    });
  });

  group('status names', () {
    test('schema.org order statuses and event names', () {
      expect(
        DeliveryStatus.fromSchema('http://schema.org/OrderReturned'),
        DeliveryStatus.returned,
      );
      expect(
        DeliveryStatus.fromSchema('OrderPickupAvailable'),
        DeliveryStatus.readyForPickup,
      );
      expect(
        DeliveryStatus.fromSchema('Out for delivery'),
        DeliveryStatus.outForDelivery,
      );
      expect(DeliveryStatus.fromSchema('Payment received'), isNull);
    });
  });

  test('reservations read as generic items too', () {
    const source = '''
<script type="application/ld+json">
{"@type": "FlightReservation", "reservationNumber": "RXJ34P",
 "reservationFor": {"@type": "Flight", "flightNumber": "110",
   "airline": {"@type": "Airline", "name": "Example Air", "iataCode": "EA"},
   "departureTime": "2027-03-04T20:15:00-08:00"}}
</script>''';
    final t = StructuredData.extract(source).single;
    expect(t.isA('FlightReservation'), isTrue);
    expect(t.text('reservationNumber'), 'RXJ34P');
    final flight = t.thing('reservationFor')!;
    expect(flight.text('airline'), 'Example Air');
    expect(flight.date('departureTime'), DateTime.utc(2027, 3, 5, 4, 15));
  });
}
