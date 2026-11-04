// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// An evaluation of [MailTypeClassifier] with the finders, over a made-up
/// but realistic labelled sample of mail: the rules alone, the rules with
/// the classifier before any correction, and after a few corrections.
/// Precision and recall are printed (run with `--reporter expanded`).
library;

import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:test/test.dart';

final _now = DateTime.utc(2026, 11, 4);

DateTime _day(int month, int day, [int year = 2026]) =>
    DateTime.utc(year, month, day, 9);

/// One labelled email: what it truly is ([kind]; null: none of them).
final class _Mail {
  _Mail(
    this.kind,
    this.from,
    this.name,
    this.subject,
    this.text,
    this.at, {
    String? company,
    this.bulk = false,
    this.html,
  }) : company = company ?? _registrable(from);

  final MailKind? kind;
  final String from;
  final String name;
  final String subject;
  final String text;
  final DateTime at;
  final String company;
  final bool bulk;

  /// The schema.org markup in its HTML, if any.
  final String? html;
  late final int id;

  List<ReservationInfo> get reservations => html == null
      ? const []
      : ReservationInfo.allIn(StructuredData.extract(html!));

  MailSample get sample => MailSample(
    address: from,
    domain: company,
    senderName: name,
    subject: subject,
    text: text,
    bulk: bulk,
  );

  static String _registrable(String address) {
    final parts = address.substring(address.indexOf('@') + 1).split('.');
    return parts.sublist(parts.length - 2).join('.');
  }
}

const _s = MailKind.subscription;
const _d = MailKind.delivery;
const _b = MailKind.booking;

final List<_Mail> _sample = [
  // ---------------------------------------------------- subscriptions
  for (final (i, month) in [9, 10, 11].indexed)
    _Mail(
      _s,
      'invoice+statements@mail.anthropic.com',
      'Anthropic, PBC',
      'Your receipt from Anthropic, PBC #2841-33${17 + i}',
      'Receipt from Anthropic, PBC. Amount paid \$20.00. Date paid '
          '${['Sep', 'Oct', 'Nov'][i]} 1, 2026. Payment method Visa - 4242. '
          'Claude Pro, ${['Sep', 'Oct', 'Nov'][i]} 1 – '
          '${['Oct', 'Nov', 'Dec'][i]} 1, 2026. Subscription renews monthly. '
          'If you have any questions, contact us at support.',
      _day(month, 1),
    ),
  for (final (i, month) in [8, 9, 10].indexed)
    _Mail(
      _s,
      'invoice+statements@stripe.com',
      'Kitepad',
      'Your Kitepad receipt [#1190-77${40 + i}]',
      'Receipt from Kitepad Inc. Amount paid US\$8.00. Kitepad Plus '
          '(monthly). Next billing date is the 14th. Manage your plan in '
          'settings. Powered by Stripe.',
      _day(month, 14),
    ),
  _Mail(
    _s,
    'hello@kitepad.io',
    'Kitepad',
    'Your free trial of Kitepad Plus has started',
    'Welcome to Kitepad Plus! Your 14-day free trial ends on Aug 14. '
        'After that it is \$8 per month. Cancel any time.',
    _day(7, 31),
  ),
  for (final (i, month) in [8, 9, 10].indexed)
    _Mail(
      _s,
      'billing@myrepublic.com.sg',
      'MyRepublic',
      'Your MyRepublic e-bill for ${['August', 'September', 'October'][i]} 2026',
      'Dear customer, your e-bill is ready. Account no 3301-8812. Amount '
          'due S\$49.95 by 21 ${['Aug', 'Sep', 'Oct'][i]} 2026. Fibre broadband '
          '1Gbps monthly plan. Pay via GIRO, PayNow or card.',
      _day(month, 3),
      company: 'myrepublic.com.sg',
    ),
  for (final (i, month) in [8, 9, 10].indexed)
    _Mail(
      _s,
      'ebill@spdigital.sg',
      'SP Group',
      'Your SP Group utilities bill is ready',
      'Your utilities bill for ${['Jul', 'Aug', 'Sep'][i]} 2026 is ready. '
          'Electricity 312 kWh, water 9.2 Cu M. Total amount payable '
          'S\$${[118.30, 124.75, 109.40][i]}. Payment due date '
          '${['Aug', 'Sep', 'Oct'][i]} 25, 2026. GIRO deduction applies.',
      _day(month, 10),
      company: 'spdigital.sg',
    ),
  _Mail(
    _s,
    'support@porkbun.com',
    'porkbun.com',
    'porkbun.com | Order Confirmation',
    'Thank you for your order! Domain renewal: example-family.net, 1 year, '
        '\$11.06. Auto-renew is ON. Your domain now expires on 2027-09-02.',
    _day(9, 2),
  ),
  _Mail(
    _s,
    'support@porkbun.com',
    'porkbun.com',
    'porkbun.com | Order Confirmation',
    'Thank you for your order! Domain renewal: alexlim.dev, 1 year, '
        '\$12.98. Auto-renew is ON. Your domain now expires on 2027-10-19.',
    _day(10, 19),
  ),
  for (final (i, month) in [9, 10].indexed)
    _Mail(
      _s,
      'info@account.streamflix.com',
      'StreamFlix',
      'Your StreamFlix membership payment',
      'Thanks for your payment of S\$17.98 for your Standard plan. Your '
          'membership renews on ${['Oct', 'Nov'][i]} 22. View billing details.',
      _day(month, 22),
    ),
  // ---------------------------------- not subscriptions (look-alikes)
  for (final (i, (month, day, total)) in [
    (8, 3, '12.40'),
    (8, 21, '9.80'),
    (9, 6, '23.15'),
    (10, 2, '15.60'),
  ].indexed)
    _Mail(
      null,
      'no-reply@grab.com',
      'Grab',
      'Your Grab E-Receipt',
      'Hope you enjoyed your ride! GrabCar Premium. Booking ID '
          'A-6RTX${i}9QJ. Pick-up 8:12 PM Orchard Road, drop-off 8:41 PM '
          'Tiong Bahru. Total S\$$total. Paid by Mastercard. Ride more, save '
          'more with a GrabUnlimited membership.',
      _day(month, day),
    ),
  for (final (i, (month, day, total)) in [
    (9, 12, '14.20'),
    (10, 9, '18.90'),
  ].indexed)
    _Mail(
      null,
      'no-reply@gojek.com',
      'Gojek',
      'Your Gojek E-Receipt',
      'Thanks for riding with Gojek! GoCar. Booking ID GJ-55${i}1. Pick-up '
          '7:02 PM Raffles Place, drop-off 7:25 PM Holland Village. Total '
          'S\$$total. Paid by Visa. Ride more and save with a GoClub membership.',
      _day(month, day),
    ),
  for (final (i, (subject, text)) in [
    (
      '[acme/payments] Invoice PDF is missing the tax line (#311)',
      'The invoice PDF generated for annual subscriptions drops the GST '
          'line. @alexlim can you take a look?',
    ),
    (
      '[acme/payments] Receipt emails sent twice after renewal (#318)',
      'After a subscription renewal the receipt job runs twice and '
          'customers get two receipts.',
    ),
    (
      '[acme/web] Billing page shows the wrong plan (#902)',
      'On the billing page the plan name is cached. Steps to reproduce: '
          'renew the subscription, reload.',
    ),
  ].indexed)
    _Mail(
      null,
      'notifications@github.com',
      ['Mei Chen', 'Rahul K', 'Dana Ortiz'][i],
      subject,
      '$text\n\n—\nReply to this email directly, view it on GitHub, or '
          'unsubscribe. You are receiving this because you were mentioned.',
      _day(9 + i, 5 + i),
      bulk: true,
    ),
  for (final (i, (subject, text)) in [
    (
      '[acme/infra] Invoice export job times out (#57)',
      'The nightly invoice export for subscriptions times out after 30 '
          'minutes. @alexlim assigned.',
    ),
    (
      '[acme/infra] Payment webhook retries flood the queue (#61)',
      'Payment webhooks for renewals retry without backoff. Proposed fix '
          'in the linked merge request.',
    ),
  ].indexed)
    _Mail(
      null,
      'notifications@codeberg.org',
      ['Jonas W', 'Ana P'][i],
      subject,
      '$text\n\n—\nReply to this email directly or view it on Codeberg. '
          'You are receiving this because you were mentioned.',
      _day(10, 12 + i),
      bulk: true,
    ),
  _Mail(
    null,
    'notifications@github.com',
    'Mei Chen',
    'Re: [acme/payments] Invoice PDF is missing the tax line (#311)',
    'Fixed in #314, the receipt and invoice now show GST. Thanks!\n\nReply '
        'to this email directly, view it on GitHub.',
    _day(9, 8),
    bulk: true,
  ),
  _Mail(
    null,
    'cdp-estatement@sgx.com',
    'CDP',
    'Your CDP Monthly Statement for September 2026',
    'Your CDP monthly statement is ready. Log in to CDP Internet to view '
        'your holdings and transactions. This is a computer-generated email.',
    _day(10, 6),
  ),
  _Mail(
    null,
    'cdp-estatement@sgx.com',
    'CDP',
    'CDP: Payment received for your SRS subscription to SGS bonds',
    'We have received your payment of S\$1,000.00 for your application '
        'for Singapore Government Securities. Allotment results will be sent '
        'by email.',
    _day(9, 20),
  ),
  _Mail(
    null,
    'jamie.tan@gmail.com',
    'Jamie Tan',
    'Re: splitting the Netflix bill',
    'Sure, I\'ll transfer you S\$8.99 for my share of the subscription this '
        'month. Dinner on me next time!',
    _day(10, 23),
    company: 'gmail.com',
  ),
  // ------------------------------------------------------- deliveries
  for (final (i, (subject, text, month, day)) in [
    (
      'Your Shopee order 2610ABCD has been shipped',
      'Your parcel is on the way. Tracking number SPXSG04412893311. '
          'Estimated delivery 24 Oct - 27 Oct.',
      10,
      22,
    ),
    (
      'Your parcel is out for delivery',
      'Order 2610ABCD: your parcel SPXSG04412893311 is out for delivery '
          'today.',
      10,
      25,
    ),
  ].indexed)
    _Mail(
      _d,
      'info@mail.shopee.sg',
      'Shopee',
      subject,
      text,
      _day(month, day, 2026).add(Duration(hours: i)),
      company: 'shopee.sg',
    ),
  _Mail(
    _d,
    'shipment-tracking@amazon.sg',
    'Amazon.sg',
    'Your Amazon.sg order of "USB-C Hub" has shipped',
    'Your package is on the way. Arriving Thursday 29 October. Order '
        '#503-7781234-5512007. Carrier: Ninja Van, tracking number '
        'NVSGAMZ0012345678. Track package.',
    _day(10, 26),
    company: 'amazon.sg',
  ),
  _Mail(
    _d,
    'shipment-tracking@amazon.sg',
    'Amazon.sg',
    'Delivered: your Amazon.sg package',
    'Your package was delivered. Order #503-7781234-5512007. It was '
        'handed directly to a resident.',
    _day(10, 29),
    company: 'amazon.sg',
  ),
  _Mail(
    _d,
    'noreply@lazada.sg',
    'Lazada',
    'Your package is in transit',
    'Order 4419028831 is in transit with J&T Express. Tracking number '
        '880012334561. Expected delivery 6 Nov.',
    _day(11, 2),
    company: 'lazada.sg',
  ),
  _Mail(
    _d,
    'notification@singpost.com',
    'SingPost',
    'Your item is ready for collection',
    'Item RR123456785SG is ready for collection at Tanjong Pagar Post '
        'Office. Please collect by 10 Nov with your ID.',
    _day(11, 3),
  ),
  // -------------------------------- not deliveries (food orders etc.)
  for (final (i, (restaurant, month, day)) in [
    ('Nasi Lemak Corner', 9, 18),
    ('Pho Saigon', 10, 7),
    ('Burger Lab', 10, 28),
  ].indexed)
    _Mail(
      null,
      'no-reply@grab.com',
      'GrabFood',
      'Your GrabFood order from $restaurant is on its way',
      'Your driver has picked up your order 1-B7Q${i}X and is on the way. '
          'Estimated arrival 7:45 PM. Total S\$24.80 paid by Visa.',
      _day(month, day),
    ),
  for (final (i, (restaurant, month, day)) in [
    ('Thai Express', 10, 15),
    ('Sushi Go', 11, 1),
  ].indexed)
    _Mail(
      null,
      'noreply@foodpanda.sg',
      'foodpanda',
      'Your order from $restaurant is on the way',
      'Your rider has picked up order sg-8xq$i and is on the way. '
          'Estimated delivery 8:05 PM. Total S\$31.20 paid by card.',
      _day(month, day),
      company: 'foodpanda.sg',
    ),
  // --------------------------------------------------------- bookings
  _Mail(
    _b,
    'booking@singaporeair.com',
    'Singapore Airlines',
    'Booking confirmation - Singapore to Tokyo (Haneda)',
    'Thank you for booking with us. Your booking is confirmed.\n\n'
        'Booking reference: ZK8P4Q\n\n'
        'Departing flight\n'
        'SQ 636   SIN → HND\n'
        'Sat, 12 Dec 2026\n'
        'Depart 22:55   Arrive 06:55 (+1)\n\n'
        'Economy, 1 adult.',
    _day(10, 20),
  ),
  _Mail(
    _b,
    'noreply@booking.com',
    'Booking.com',
    'Your booking is confirmed at Hotel Gracery Shinjuku',
    'Check-in Sun 13 Dec 2026 from 14:00, check-out Thu 17 Dec 2026 '
        'until 11:00. Confirmation number 4412.553.901. 1 room, 2 adults.',
    _day(10, 21),
    html: _ld(
      '{"@type": "LodgingReservation", "reservationNumber": "4412553901", '
      '"checkinTime": "2026-12-13T14:00:00+09:00", '
      '"checkoutTime": "2026-12-17T11:00:00+09:00", '
      '"reservationFor": {"@type": "LodgingBusiness", '
      '"name": "Hotel Gracery Shinjuku", "address": {"@type": '
      '"PostalAddress", "addressLocality": "Tokyo"}}}',
    ),
  ),
  _Mail(
    _b,
    'noreply@chope.co',
    'Chope',
    'Your table reservation at Burnt Ends is confirmed',
    'Table for 2 on Sat 14 Nov 2026 at 7:30 PM. Reservation ID CH-77120. '
        'Please arrive on time.',
    _day(11, 1),
    company: 'chope.co',
    html: _ld(
      '{"@type": "FoodEstablishmentReservation", "reservationNumber": '
      '"CH-77120", "startTime": "2026-11-14T19:30:00+08:00", '
      '"partySize": "2", "reservationFor": {"@type": "FoodEstablishment", '
      '"name": "Burnt Ends", "address": {"@type": "PostalAddress", '
      '"addressLocality": "Singapore"}}}',
    ),
  ),
  // ----------------------- not bookings (appointments, not travel)
  for (final (i, (from, name, what, month, day)) in [
    ('hello@snipstudio.com', 'Snip Studio', 'Haircut with Mel', 11, 12),
    ('hello@snipstudio.com', 'Snip Studio', 'Colour and cut', 10, 9),
    ('appointments@movewell.com', 'MoveWell Physio', 'Physio session', 11, 18),
  ].indexed)
    _Mail(
      null,
      from,
      name,
      'Booking confirmed: $what on $day ${month == 10 ? 'Oct' : 'Nov'}',
      'Your booking is confirmed. $what on $day '
          '${month == 10 ? 'Oct' : 'Nov'} 2026 at 3:30 PM. Booking reference '
          'BK-${4410 + i}. Need to reschedule? Reply or call us.',
      _day(month, day - 7),
      // Booking sites mark appointments up as events.
      html: _ld(
        '{"@type": "EventReservation", "reservationNumber": "BK-${4410 + i}", '
        '"reservationFor": {"@type": "Event", "name": "$what", '
        '"startDate": "2026-$month-${day}T15:30:00+08:00", '
        '"location": {"@type": "Place", "name": "$name", "address": '
        '{"@type": "PostalAddress", "addressLocality": "Singapore"}}}}',
      ),
    ),
  // ------------------------------------- everyday mail (none of them)
  _Mail(
    null,
    'news@uniqlo.com',
    'UNIQLO',
    'Free delivery this weekend on orders over \$60',
    'Shop the new HEATTECH range. Free delivery and returns. Unsubscribe.',
    _day(10, 30),
    bulk: true,
  ),
  _Mail(
    null,
    'alerts@dbs.com',
    'DBS',
    'Your credit card e-Statement is ready',
    'Your DBS credit card e-Statement for October is now available in '
        'digibank. Minimum payment due 25 Nov.',
    _day(11, 2),
  ),
  _Mail(
    null,
    'priya.r@company.com',
    'Priya R',
    'Trip report: Tokyo offsite booking',
    'Hi all, here are my notes from the offsite. Next year we should book '
        'the hotel earlier. Slides attached.',
    _day(10, 30),
  ),
];

/// What one pipeline picked up, per kind: the ids of the emails of the
/// items it lists.
String _ld(String json) => '<script type="application/ld+json">$json</script>';

typedef _Picked = Map<MailKind, Set<int>>;

final _byId = {for (final m in _sample) m.id: m};

/// The finders over [_sample], minus what the user hid, minus (with
/// [classifier]) items most of whose emails the classifier rejects.
_Picked _run({
  MailTypeClassifier? classifier,
  Set<String> hiddenSubscriptions = const {},
  Set<String> hiddenDeliveries = const {},
  Set<String> hiddenBookings = const {},
}) {
  bool vetoed(MailKind kind, Iterable<int> ids) =>
      classifier != null &&
      classifier.rejectsItem(kind, [for (final id in ids) _byId[id]!.sample]);
  final subscriptions = SubscriptionFinder.find([
    for (final m in _sample)
      SubscriptionEmail(
        messageId: m.id,
        company: m.company,
        senderName: m.name,
        subject: m.subject,
        text: m.text,
        at: m.at,
      ),
  ], now: _now);
  final deliveries = DeliveryFinder.find([
    for (final m in _sample)
      if (DeliveryFinder.subjectWords.any(m.subject.toLowerCase().contains))
        DeliveryEmail(
          messageId: m.id,
          shop: m.company,
          senderName: m.name,
          subject: m.subject,
          text: m.text,
          at: m.at,
          bulk: m.bulk,
        ),
  ], now: _now);
  final bookings = TripFinder.bookings([
    for (final m in _sample)
      TripEmail(
        messageId: m.id,
        sender: m.company,
        senderName: m.name,
        subject: m.subject,
        text: m.text,
        at: m.at,
        reservations: m.reservations,
        bulk: m.bulk,
      ),
  ]);
  return {
    _s: {
      for (final s in subscriptions)
        if (!hiddenSubscriptions.contains(s.company))
          if ([for (final r in s.records) r.email.messageId] case final ids
              when !vetoed(_s, ids))
            ...ids,
    },
    _d: {
      for (final d in deliveries)
        if (!hiddenDeliveries.contains(d.key))
          if ([for (final r in d.records) r.email.messageId] case final ids
              when !vetoed(_d, ids))
            ...ids,
    },
    _b: {
      for (final b in bookings)
        if (!hiddenBookings.contains(b.key))
          if ([for (final r in b.records) r.email.messageId] case final ids
              when !vetoed(_b, ids))
            ...ids,
    },
  };
}

typedef _Score = ({int tp, int fp, int fn, double precision, double recall});

_Score _score(Set<int> picked, MailKind kind) {
  final truth = {
    for (final m in _sample)
      if (m.kind == kind) m.id,
  };
  final tp = picked.intersection(truth).length;
  final fp = picked.difference(truth).length;
  final fn = truth.difference(picked).length;
  return (
    tp: tp,
    fp: fp,
    fn: fn,
    precision: tp + fp == 0 ? 1 : tp / (tp + fp),
    recall: tp + fn == 0 ? 1 : tp / (tp + fn),
  );
}

String _row(String label, _Picked picked) {
  String cell(MailKind k) {
    final s = _score(picked[k]!, k);
    return '${k.name.padRight(12)} P ${s.precision.toStringAsFixed(2)} '
        'R ${s.recall.toStringAsFixed(2)} (${s.tp} right, ${s.fp} wrong, '
        '${s.fn} missed)';
  }

  return [
    label,
    for (final k in [_s, _d, _b]) '  ${cell(k)}',
  ].join('\n');
}

void main() {
  for (final (i, m) in _sample.indexed) {
    m.id = i + 1;
  }

  test('the sample is 40 to 80 emails', () {
    expect(_sample.length, inInclusiveRange(40, 80));
  });

  test('evaluation: rules, rules with the classifier, after corrections', () {
    final rules = _run();
    final untaught = _run(classifier: MailTypeClassifier());
    // Nothing learned: exactly what the rules pick up.
    expect(untaught, rules);

    // The rules' mistakes the user corrects, one item each: Grab rides
    // ("Not a subscription"), a GitHub notification ("Not a
    // subscription"), one GrabFood order ("Not a delivery") and a
    // haircut ("Not a booking").
    final classifier = MailTypeClassifier();
    final subscriptions = SubscriptionFinder.find([
      for (final m in _sample)
        SubscriptionEmail(
          messageId: m.id,
          company: m.company,
          senderName: m.name,
          subject: m.subject,
          text: m.text,
          at: m.at,
        ),
    ], now: _now);
    final hiddenSubscriptions = {'grab.com', 'github.com'};
    for (final s in subscriptions) {
      if (!hiddenSubscriptions.contains(s.company)) continue;
      for (final r in s.records) {
        classifier.reject(_s, _byId[r.email.messageId]!.sample);
      }
    }
    final firstFood = _sample.firstWhere((m) => m.name == 'GrabFood');
    final deliveries = DeliveryFinder.find([
      for (final m in _sample)
        if (DeliveryFinder.subjectWords.any(m.subject.toLowerCase().contains))
          DeliveryEmail(
            messageId: m.id,
            shop: m.company,
            senderName: m.name,
            subject: m.subject,
            text: m.text,
            at: m.at,
          ),
    ], now: _now);
    final food = deliveries.where(
      (d) => d.records.any((r) => r.email.messageId == firstFood.id),
    );
    for (final d in food) {
      for (final r in d.records) {
        classifier.reject(_d, _byId[r.email.messageId]!.sample);
      }
    }
    final firstHaircut = _sample.firstWhere((m) => m.name == 'Snip Studio');
    final bookings = TripFinder.bookings([
      for (final m in _sample)
        TripEmail(
          messageId: m.id,
          sender: m.company,
          senderName: m.name,
          subject: m.subject,
          text: m.text,
          at: m.at,
          reservations: m.reservations,
        ),
    ]);
    final haircut = bookings.where(
      (b) => b.records.any((r) => r.email.messageId == firstHaircut.id),
    );
    for (final b in haircut) {
      for (final r in b.records) {
        classifier.reject(_b, _byId[r.email.messageId]!.sample);
      }
    }
    final hidden = (
      subscriptions: hiddenSubscriptions,
      deliveries: {for (final d in food) d.key},
      bookings: {for (final b in haircut) b.key},
    );
    final hiddenOnly = _run(
      hiddenSubscriptions: hidden.subscriptions,
      hiddenDeliveries: hidden.deliveries,
      hiddenBookings: hidden.bookings,
    );
    // Stored and read back, as the app does.
    final learned = MailTypeClassifier.fromText(classifier.toText());
    final taught = _run(
      classifier: learned,
      hiddenSubscriptions: hidden.subscriptions,
      hiddenDeliveries: hidden.deliveries,
      hiddenBookings: hidden.bookings,
    );

    // The evaluation's report.
    // ignore: avoid_print
    print(
      [
        _row('Rules alone', rules),
        _row('Rules + classifier, no corrections', untaught),
        _row('After the corrections, hiding only', hiddenOnly),
        _row('After the corrections, with the classifier', taught),
        'Learned state: ${classifier.toText().length} characters',
      ].join('\n'),
    );

    for (final kind in [_s, _d, _b]) {
      final before = _score(hiddenOnly[kind]!, kind);
      final after = _score(taught[kind]!, kind);
      // Never anything new picked up, never a true one lost.
      expect(taught[kind]!.difference(hiddenOnly[kind]!), isEmpty);
      expect(after.tp, before.tp, reason: '${kind.name}: none lost');
      expect(after.precision, greaterThanOrEqualTo(before.precision));
    }
    // The look-alikes of what was corrected are gone: Gojek rides, the
    // Codeberg notification, the other food orders and the physio
    // session. What nobody corrected stays (the CDP bond payment).
    expect(
      [
        for (final id in taught[_s]!)
          if (_byId[id]!.kind != _s) _byId[id]!.subject,
      ],
      ['CDP: Payment received for your SRS subscription to SGS bonds'],
    );
    expect(_score(taught[_d]!, _d).fp, 0);
    expect(_score(taught[_b]!, _b).fp, 0);
  });
}
