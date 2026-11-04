// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

/// The day [days] from [now], as `2026-12-12`.
String tripDay(DateTime now, int days) {
  final d = DateTime.utc(now.year, now.month, now.day + days);
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// "12 Dec 2026", [days] from [now].
String tripDayText(DateTime now, int days) {
  final d = DateTime.utc(now.year, now.month, now.day + days);
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}

/// Made-up booking mail for the Trips page (tests and screenshots),
/// relative to [now]: a trip to Tokyo (flights and a hotel, with
/// markup), a dinner at home, a concert, a past trip to Bangkok and a
/// cancelled one to Bali (words only), and mail that is not a booking.
void seedTrips(MailStore store, {required DateTime now}) {
  final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
  var uid = 800;
  MessageSummary mail(
    String address,
    String name,
    String subject,
    Duration ago, {
    String? snippet,
    MessageCategory category = MessageCategory.notifications,
    int size = 30000,
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
  String d(int days) => tripDay(now, days);
  String t(int days) => tripDayText(now, days);

  final sq = mail(
    'booking@singaporeair.com',
    'Singapore Airlines',
    'Booking confirmation: Singapore to Tokyo (XKQZPL)',
    day * 20,
    snippet: 'Thank you for booking with Singapore Airlines.',
  );
  final hotel = mail(
    'noreply@booking.com',
    'Booking.com',
    'Your booking is confirmed at Park Hotel Shinjuku',
    day * 19,
    snippet: 'Thanks, Alice! Your booking in Tokyo is confirmed.',
  );
  final dinner = mail(
    'reservations@opentable.com',
    'OpenTable',
    'Your reservation at Burnt Ends is confirmed',
    day * 2,
    snippet: 'Table for 4 at Burnt Ends.',
  );
  final concert = mail(
    'tickets@ticketmaster.sg',
    'Ticketmaster',
    'Your tickets: Coldplay – Music of the Spheres',
    day * 40,
    snippet: 'Your order is confirmed.',
  );
  store.messages.upsertSummaries(inbox.id, [
    sq,
    hotel,
    dinner,
    concert,
    // Words only, not downloaded: the preview says it all.
    mail(
      'itinerary@flyscoot.com',
      'Scoot',
      'Your Scoot booking confirmation - K7XQ2M',
      day * 90,
      snippet:
          'Booking reference: K7XQ2M. Departing flight TR 616 SIN → BKK '
          '${t(-60)} 07:00 – 08:25. Return flight TR 617 BKK → SIN '
          '${t(-56)} 09:20 – 12:45.',
    ),
    mail(
      'noreply@jetstar.com',
      'Jetstar Asia',
      'Jetstar Asia: your itinerary Q2ZP7N',
      day * 9,
      snippet:
          'Your booking reference is Q2ZP7N. Flight 3K 207 Singapore (SIN) '
          'to Bali (DPS) ${t(60)} 08:40 – 11:10. Flight 3K 208 Bali (DPS) '
          'to Singapore (SIN) ${t(64)} 12:05 – 14:40.',
    ),
    mail(
      'noreply@jetstar.com',
      'Jetstar Asia',
      'Your booking has been cancelled',
      day * 3,
      snippet:
          'Your booking Q2ZP7N has been cancelled as requested. Booking '
          'reference: Q2ZP7N. A refund will be made to your card.',
    ),
    // Not on the device yet, says too little in its preview.
    mail(
      'noreply@expedia.com',
      'Expedia',
      'Expedia travel confirmation - Hotel in Hong Kong',
      day * 5,
      snippet: 'Your trip is booked! View your itinerary.',
    ),
    // Not bookings.
    mail(
      'news@singaporeair.com',
      'Singapore Airlines',
      'Fly to Tokyo from S\$398 – this weekend only',
      day,
      snippet:
          'Flights SQ 638 SIN → NRT from S\$398. Booking reference not '
          'needed, book now.',
      category: MessageCategory.newsletters,
    ),
    mail(
      'noreply@booking.com',
      'Booking.com',
      'Alice, rate your stay at Hotel Muse Bangkok',
      day * 50,
      snippet:
          'Confirmation number: 3912345678. Check-in: ${t(-60)}. '
          'Check-out: ${t(-56)}. How was it?',
    ),
  ]);

  void body(MessageSummary m, String html, String text) {
    final stored = store.messages.byUid(inbox.id, m.uid)!;
    final raw =
        '''From: ${m.from!.displayName} <${m.from!.address}>
To: alice@citusmail.test
Subject: ${m.subject}
Content-Type: text/html; charset=utf-8

<html><head><script type="application/ld+json">
$html
</script></head>
<body><p>$text</p></body></html>
''';
    store.messages.saveBody(
      stored.id,
      utf8.encode(raw.replaceAll('\n', '\r\n')),
      searchableText: text,
    );
  }

  String flight(
    String number,
    (String, String) from,
    String departs,
    (String, String) to,
    String arrives, {
    String terminal = '',
  }) =>
      '''
{"@context": "http://schema.org", "@type": "FlightReservation",
 "reservationNumber": "XKQZPL",
 "reservationStatus": "http://schema.org/ReservationConfirmed",
 "underName": {"@type": "Person", "name": "Alice Tan"},
 "modifyReservationUrl": "https://www.singaporeair.com/en_UK/sg/manage-booking/",
 "reservationFor": {"@type": "Flight", "flightNumber": "$number",
   "airline": {"@type": "Airline", "name": "Singapore Airlines", "iataCode": "SQ"},
   "departureAirport": {"@type": "Airport", "name": "${from.$1}", "iataCode": "${from.$2}"},
   "departureTime": "$departs",
   ${terminal.isEmpty ? '' : '"departureTerminal": "$terminal",'}
   "arrivalAirport": {"@type": "Airport", "name": "${to.$1}", "iataCode": "${to.$2}"},
   "arrivalTime": "$arrives"}}''';

  const changi = ('Singapore Changi', 'SIN');
  const narita = ('Tokyo Narita', 'NRT');
  body(
    sq,
    '[${flight('638', changi, '${d(38)}T23:35:00+08:00', narita, '${d(39)}T07:30:00+09:00', terminal: '3')},'
        '${flight('637', narita, '${d(44)}T11:15:00+09:00', changi, '${d(44)}T17:40:00+08:00')}]',
    'Thank you for booking with Singapore Airlines. Booking reference: '
        'XKQZPL.',
  );
  body(
    hotel,
    '''
{"@context": "http://schema.org", "@type": "LodgingReservation",
 "reservationNumber": "4012345678",
 "reservationStatus": "http://schema.org/ReservationConfirmed",
 "underName": {"@type": "Person", "name": "Alice Tan"},
 "broker": {"@type": "Organization", "name": "Booking.com"},
 "reservationFor": {"@type": "LodgingBusiness", "name": "Park Hotel Shinjuku",
   "address": {"@type": "PostalAddress", "streetAddress": "3-4-5 Nishi-Shinjuku",
     "addressLocality": "Tokyo", "postalCode": "160-0023", "addressCountry": "Japan"},
   "telephone": "+81 3 1234 5678"},
 "lodgingUnitDescription": "Superior Double Room",
 "checkinDate": "${d(39)}T15:00:00+09:00",
 "checkoutDate": "${d(44)}T11:00:00+09:00"}''',
    'Thanks, Alice! Your booking in Tokyo is confirmed.',
  );
  body(
    dinner,
    '''
{"@context": "http://schema.org", "@type": "FoodEstablishmentReservation",
 "reservationNumber": "118273",
 "provider": {"@type": "Organization", "name": "OpenTable"},
 "underName": {"@type": "Person", "name": "Alice Tan"},
 "startTime": "${d(10)}T19:30:00+08:00", "partySize": 4,
 "reservationFor": {"@type": "FoodEstablishment", "name": "Burnt Ends",
   "address": {"@type": "PostalAddress", "streetAddress": "7 Dempsey Road",
     "addressLocality": "Singapore", "addressCountry": "SG"}}}''',
    'Table for 4 at Burnt Ends.',
  );
  body(
    concert,
    '''
{"@context": "http://schema.org", "@type": "EventReservation",
 "reservationNumber": "38-12345/SGP",
 "underName": {"@type": "Person", "name": "Alice Tan"},
 "reservedTicket": {"@type": "Ticket", "ticketNumber": "SGP-0042-7781",
   "ticketedSeat": {"@type": "Seat", "seatSection": "PA2", "seatRow": "K", "seatNumber": "21"}},
 "reservationFor": {"@type": "MusicEvent", "name": "Coldplay: Music of the Spheres",
   "startDate": "${d(80)}T19:30:00+08:00",
   "location": {"@type": "Place", "name": "National Stadium",
     "address": {"@type": "PostalAddress", "streetAddress": "1 Stadium Drive",
       "addressLocality": "Singapore", "addressCountry": "SG"}}}}''',
    'Your order is confirmed.',
  );
}
