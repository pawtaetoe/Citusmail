// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'schema_org.dart';

/// Where a shipped order is, from ordering to the door.
enum DeliveryStatus {
  ordered,
  shipped,

  /// At a pick-up point or locker, waiting to be collected.
  readyForPickup,
  outForDelivery,
  delivered,

  /// A failed delivery attempt, a delay, a customs hold.
  problem,
  returned;

  /// Not delivered yet (a problem or a return is not "on the way" for
  /// good, but it isn't at the door either).
  bool get onTheWay => this != delivered && this != returned;

  /// The status a schema.org value names: an `OrderStatus`
  /// (`http://schema.org/OrderInTransit`) or, for a `DeliveryEvent`, its
  /// name. Null when it says nothing about the delivery.
  static DeliveryStatus? fromSchema(String value) {
    final v = value.trim();
    final local = v.contains('/') ? v.substring(v.lastIndexOf('/') + 1) : v;
    switch (local) {
      case 'OrderProcessing' || 'OrderPaymentDue':
        return ordered;
      case 'OrderInTransit':
        return shipped;
      case 'OrderPickupAvailable':
        return readyForPickup;
      case 'OrderDelivered':
        return delivered;
      case 'OrderProblem':
        return problem;
      case 'OrderReturned':
        return returned;
    }
    final words = v.toLowerCase();
    if (words.contains('out for delivery')) return outForDelivery;
    if (words.contains('return')) return returned;
    if (words.contains('delivered')) return delivered;
    if (words.contains('transit') || words.contains('shipped')) return shipped;
    return null;
  }
}

/// An order, from schema.org `Order` markup.
final class OrderInfo {
  const OrderInfo({
    this.orderNumber,
    this.merchant,
    this.items = const [],
    this.status,
    this.orderDate,
    this.url,
  });

  final String? orderNumber;

  /// The shop: `merchant` or `seller`.
  final String? merchant;

  /// What was ordered, by name.
  final List<String> items;
  final DeliveryStatus? status;
  final DateTime? orderDate;

  /// The order's page, when it is `https`.
  final Uri? url;

  /// [thing] read as an order, or null when it isn't one.
  static OrderInfo? from(SchemaThing thing) {
    if (!thing.isA('Order')) return null;
    return OrderInfo(
      orderNumber:
          thing.text('orderNumber') ?? thing.text('confirmationNumber'),
      merchant: thing.text('merchant') ?? thing.text('seller'),
      items: _itemsOf(thing),
      status: thing
          .texts('orderStatus')
          .map(DeliveryStatus.fromSchema)
          .nonNulls
          .firstOrNull,
      orderDate: thing.date('orderDate'),
      url: thing.httpsUrl('url'),
    );
  }

  /// Every order in [things], nested ones too (a `ParcelDelivery`'s
  /// `partOfOrder`).
  static List<OrderInfo> allIn(List<SchemaThing> things) => [
    for (final t in _all(things)) ?from(t),
  ];

  /// Item names of an order: `orderedItem` (a Product, or an OrderItem
  /// holding one) and `acceptedOffer`'s `itemOffered`.
  static List<String> _itemsOf(SchemaThing order) {
    final names = <String>[];
    for (final v in order.values('orderedItem')) {
      if (v is String) {
        names.add(v);
      } else if (v is SchemaThing) {
        final inner = v.isA('OrderItem') ? v.thing('orderedItem') : v;
        if ((inner ?? v).text('name') case final n?) names.add(n);
      }
    }
    for (final offer in order.things('acceptedOffer')) {
      names.addAll(offer.texts('itemOffered'));
    }
    return _distinct(names);
  }
}

/// A parcel on its way, from schema.org `ParcelDelivery` markup (directly,
/// or as an `Order`'s `orderDelivery`).
final class ParcelDeliveryInfo {
  const ParcelDeliveryInfo({
    this.trackingNumber,
    this.carrier,
    this.trackingUrl,
    this.expectedFrom,
    this.expectedUntil,
    this.status,
    this.items = const [],
    this.order,
  });

  final String? trackingNumber;

  /// The carrier's name: `carrier` or `provider`.
  final String? carrier;

  /// The carrier's tracking page, only when it is `https`.
  final Uri? trackingUrl;
  final DateTime? expectedFrom;
  final DateTime? expectedUntil;
  final DeliveryStatus? status;

  /// What is in the parcel (`itemShipped`), else the order's items.
  final List<String> items;

  /// The order it belongs to (`partOfOrder`, or the order holding it).
  final OrderInfo? order;

  /// [thing] read as a parcel delivery, or null when it isn't one.
  /// [order] is the order it came in, when it was found inside one.
  static ParcelDeliveryInfo? from(SchemaThing thing, {OrderInfo? order}) {
    if (!thing.isA('ParcelDelivery')) return null;
    final partOf = thing.thing('partOfOrder');
    final ofOrder = (partOf == null ? null : OrderInfo.from(partOf)) ?? order;
    final shipped = _distinct([
      for (final v in thing.values('itemShipped'))
        if (v is String) v else ?(v as SchemaThing).text('name'),
    ]);
    final events = [
      ...thing.texts('deliveryStatus'),
      for (final e in thing.things('deliveryStatus')) ...e.texts('eventStatus'),
    ];
    return ParcelDeliveryInfo(
      trackingNumber: thing.text('trackingNumber'),
      carrier: thing.text('carrier') ?? thing.text('provider'),
      trackingUrl: thing.httpsUrl('trackingUrl'),
      expectedFrom: thing.date('expectedArrivalFrom'),
      expectedUntil: thing.date('expectedArrivalUntil'),
      status:
          events.map(DeliveryStatus.fromSchema).nonNulls.firstOrNull ??
          ofOrder?.status,
      items: shipped.isNotEmpty ? shipped : ofOrder?.items ?? const [],
      order: ofOrder,
    );
  }

  /// Every parcel delivery in [things], also those inside an order's
  /// `orderDelivery`.
  static List<ParcelDeliveryInfo> allIn(List<SchemaThing> things) {
    final found = <ParcelDeliveryInfo>[];
    final seen = <SchemaThing>{};
    for (final t in things) {
      if (t.isA('Order')) {
        final order = OrderInfo.from(t);
        for (final d in t.things('orderDelivery')) {
          if (seen.add(d)) {
            if (from(d, order: order) case final p?) found.add(p);
          }
        }
      }
    }
    for (final t in _all(things)) {
      if (seen.add(t)) {
        if (from(t) case final p?) found.add(p);
      }
    }
    return found;
  }
}

/// [things] and every item nested in them, depth first.
Iterable<SchemaThing> _all(List<SchemaThing> things) sync* {
  final stack = [...things.reversed];
  final seen = <SchemaThing>{};
  while (stack.isNotEmpty && seen.length < 1000) {
    final t = stack.removeLast();
    if (!seen.add(t)) continue;
    yield t;
    for (final values in t.properties.values.toList().reversed) {
      stack.addAll(values.whereType<SchemaThing>().toList().reversed);
    }
  }
}

List<String> _distinct(Iterable<String> names) {
  final seen = <String>{};
  return [
    for (final n in names)
      if (n.trim() case final t when t.isNotEmpty && seen.add(t.toLowerCase()))
        t,
  ];
}
