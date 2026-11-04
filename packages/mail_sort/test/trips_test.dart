// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:test/test.dart';

final _now = DateTime.utc(2026, 11, 4, 10);
var _ids = 0;

TripEmail mail(
  String subject, {
  required String sender,
  String? name,
  String text = '',
  int daysAgo = 0,
  String? html,
  bool bulk = false,
}) {
  final things = html == null
      ? const <SchemaThing>[]
      : StructuredData.extract(html);
  return TripEmail(
    messageId: ++_ids,
    sender: sender,
    senderName: name,
    subject: subject,
    text: text,
    at: _now.subtract(Duration(days: daysAgo)),
    reservations: ReservationInfo.allIn(things),
    bulk: bulk,
  );
}

List<Booking> bookings(List<TripEmail> emails) => TripFinder.bookings(emails);
List<Trip> trips(List<TripEmail> emails) =>
    TripFinder.trips(TripFinder.bookings(emails));

String _flightLd(
  String number,
  String from,
  String to,
  String departs,
  String arrives, {
  String reference = 'XKQZPL',
  String status = 'ReservationConfirmed',
}) =>
    '''
{"@context": "http://schema.org", "@type": "FlightReservation",
 "reservationNumber": "$reference",
 "reservationStatus": "http://schema.org/$status",
 "underName": {"@type": "Person", "name": "Alice Tan"},
 "reservationFor": {"@type": "Flight", "flightNumber": "$number",
   "airline": {"@type": "Airline", "name": "Singapore Airlines", "iataCode": "SQ"},
   "departureAirport": {"@type": "Airport", "iataCode": "$from"},
   "departureTime": "$departs",
   "arrivalAirport": {"@type": "Airport", "iataCode": "$to"},
   "arrivalTime": "$arrives"}}''';

String _script(List<String> items) =>
    '<script type="application/ld+json">[${items.join(',')}]</script>';

final _sqReturn = _script([
  _flightLd(
    '638',
    'SIN',
    'NRT',
    '2026-12-12T23:35:00+08:00',
    '2026-12-13T07:30:00+09:00',
  ),
  _flightLd(
    '637',
    'NRT',
    'SIN',
    '2026-12-18T11:15:00+09:00',
    '2026-12-18T17:40:00+08:00',
  ),
]);

const _parkHotel = '''
<script type="application/ld+json">
{"@context": "http://schema.org", "@type": "LodgingReservation",
 "reservationNumber": "4012345678",
 "reservationStatus": "http://schema.org/ReservationConfirmed",
 "broker": {"@type": "Organization", "name": "Booking.com"},
 "reservationFor": {"@type": "LodgingBusiness", "name": "Park Hotel Shinjuku",
   "address": {"@type": "PostalAddress", "streetAddress": "3-4-5 Nishi-Shinjuku",
     "addressLocality": "Tokyo", "addressCountry": "JP"}},
 "checkinDate": "2026-12-13T15:00:00+09:00",
 "checkoutDate": "2026-12-18T11:00:00+09:00"}
</script>''';

/// A Scoot-style confirmation: no markup, one line per flight.
const _scootText = '''
Hi ALICE TAN,

Thanks for flying with Scoot! Your booking is confirmed.

Booking reference: K7XQ2M

Departing flight
TR 808   SIN → NRT
Sat, 12 Dec 2026
Depart 01:30   Arrive 09:05

Return flight
TR 809   NRT → SIN
Fri, 18 Dec 2026
Depart 10:40   Arrive 16:55

Baggage: 20kg checked baggage. Manage your booking at scoot.com.
''';

void main() {
  group('from markup', () {
    test('a Singapore Airlines-style return flight and a hotel: one trip', () {
      final found = trips([
        mail(
          'Booking confirmation: Singapore to Tokyo',
          sender: 'singaporeair.com',
          name: 'Singapore Airlines',
          html: _sqReturn,
          daysAgo: 20,
        ),
        mail(
          'Your booking is confirmed at Park Hotel Shinjuku',
          sender: 'booking.com',
          name: 'Booking.com',
          html: _parkHotel,
          daysAgo: 19,
        ),
      ]);
      final trip = found.single;
      expect(trip.destinations, ['Tokyo']);
      expect(trip.bookings.map((b) => b.kind), [
        ReservationKind.flight,
        ReservationKind.stay,
        ReservationKind.flight,
      ]);
      expect(trip.start.day, DateTime(2026, 12, 12));
      expect(trip.lastDay, DateTime(2026, 12, 18));
      final out = trip.bookings.first;
      expect(out.reference, 'XKQZPL');
      expect(out.key, 'f:sq638:2026-12-12');
      expect(out.city, 'Tokyo');
      expect(out.fromCity, 'Singapore');
      expect(out.underName, 'Alice Tan');
      expect(out.cancelled, isFalse);
      expect(out.changed, isFalse);
      expect(trip.bookings[1].provider, 'Booking.com');
    });

    test('a reminder repeating the booking is not a second one', () {
      final found = bookings([
        mail(
          'Booking confirmation',
          sender: 'singaporeair.com',
          html: _sqReturn,
          daysAgo: 30,
        ),
        mail(
          'Online check-in is now open for your flight to Tokyo',
          sender: 'singaporeair.com',
          html: _script([
            _flightLd(
              '638',
              'SIN',
              'NRT',
              '2026-12-12T23:35:00+08:00',
              '2026-12-13T07:30:00+09:00',
            ),
          ]),
        ),
        // A boarding-pass reminder with no booking details at all.
        mail(
          'Your boarding pass for SQ 638',
          sender: 'singaporeair.com',
          text:
              'Your flight SQ 638 from Singapore (SIN) to Tokyo (NRT) departs '
              'on 12 Dec at 23:35. Add your boarding pass to your wallet.',
        ),
      ]);
      expect(found, hasLength(2));
      expect(found.first.records, hasLength(2));
    });

    test('a cancelled segment, and a schedule change in markup', () {
      final found = bookings([
        mail(
          'Booking confirmation',
          sender: 'singaporeair.com',
          html: _sqReturn,
          daysAgo: 30,
        ),
        mail(
          'Schedule change to your booking XKQZPL',
          sender: 'singaporeair.com',
          html: _script([
            _flightLd(
              '638',
              'SIN',
              'NRT',
              '2026-12-12T23:55:00+08:00',
              '2026-12-13T07:50:00+09:00',
            ),
          ]),
          daysAgo: 5,
        ),
        mail(
          'Your flight has been cancelled',
          sender: 'singaporeair.com',
          html: _script([
            _flightLd(
              '637',
              'NRT',
              'SIN',
              '2026-12-18T11:15:00+09:00',
              '2026-12-18T17:40:00+08:00',
              status: 'ReservationCancelled',
            ),
          ]),
          daysAgo: 1,
        ),
      ]);
      final [out, back] = found;
      expect(out.changed, isTrue);
      expect(out.start.wall.minute, 55);
      expect(out.previousStart?.wall.minute, 35);
      expect(out.cancelled, isFalse);
      expect(back.cancelled, isTrue);
      expect(back.changed, isFalse);
    });

    test('a table and a ticket at home are not part of a trip', () {
      final found = trips([
        mail(
          'Booking confirmation',
          sender: 'singaporeair.com',
          html: _sqReturn,
          daysAgo: 30,
        ),
        mail(
          'Your reservation at Burnt Ends is confirmed',
          sender: 'opentable.com',
          name: 'OpenTable',
          html: '''
<script type="application/ld+json">
{"@type": "FoodEstablishmentReservation", "reservationNumber": "118273",
 "startTime": "2026-12-19T19:30:00+08:00", "partySize": "4",
 "reservationFor": {"@type": "FoodEstablishment", "name": "Burnt Ends",
   "address": {"@type": "PostalAddress", "addressLocality": "Singapore"}}}
</script>''',
        ),
        mail(
          'Your tickets for Coldplay',
          sender: 'ticketmaster.sg',
          html: '''
<script type="application/ld+json">
{"@type": "EventReservation", "reservationNumber": "38-12345",
 "reservationFor": {"@type": "MusicEvent", "name": "Coldplay",
   "startDate": "2027-01-23T19:30:00+08:00",
   "location": {"@type": "Place", "name": "National Stadium",
     "address": {"@type": "PostalAddress", "addressLocality": "Singapore"}}}}
</script>''',
        ),
      ]);
      expect(found, hasLength(3));
      expect(found[0].destinations, ['Tokyo']);
      expect(found[0].bookings, hasLength(2));
      expect(found[1].bookings.single.kind, ReservationKind.table);
      expect(found[1].destinations, isEmpty);
      expect(found[2].bookings.single.kind, ReservationKind.event);
    });
  });

  group('text only', () {
    test('a Scoot-style return flight', () {
      final found = bookings([
        mail(
          'Your Scoot booking confirmation - K7XQ2M',
          sender: 'flyscoot.com',
          name: 'Scoot',
          text: _scootText,
          daysAgo: 10,
        ),
      ]);
      expect(found, hasLength(2));
      final out = found[0].info as FlightReservationInfo;
      expect(out.flightNumber, 'TR 808');
      expect(out.provider, 'Scoot');
      expect(out.reservationNumber, 'K7XQ2M');
      expect(out.from?.code, 'SIN');
      expect(out.to?.code, 'NRT');
      expect(out.start?.wall, DateTime.utc(2026, 12, 12, 1, 30));
      expect(out.start?.offset, isNull);
      expect(out.end?.wall, DateTime.utc(2026, 12, 12, 9, 5));
      final back = found[1].info as FlightReservationInfo;
      expect(back.flightNumber, 'TR 809');
      expect(back.start?.wall, DateTime.utc(2026, 12, 18, 10, 40));
      expect(found[0].city, 'Tokyo');
    });

    test('names and codes in brackets, overnight arrival, no year', () {
      final found = bookings([
        mail(
          'Your e-ticket itinerary',
          sender: 'singaporeair.com',
          name: 'Singapore Airlines',
          text: '''
Dear Ms Alice Tan,

Thank you for choosing Singapore Airlines.
Booking reference (PNR): XKQZPL

Flight 1: SQ 638
Singapore (SIN) to Tokyo Narita (NRT)
Depart: Sat 12 Dec, 23:35
Arrive: 07:30 (+1)
Terminal 3

Flight 2: SQ 637 operated by Singapore Airlines
Tokyo Narita (NRT) to Singapore (SIN)
Depart: Fri 18 Dec, 11:15 AM
Arrive: 5:40 PM
''',
        ),
      ]);
      expect(found, hasLength(2));
      final out = found[0].info as FlightReservationInfo;
      expect(out.reservationNumber, 'XKQZPL');
      expect(out.from?.name, 'Singapore');
      expect(out.to?.name, 'Tokyo Narita');
      expect(out.start?.wall, DateTime.utc(2026, 12, 12, 23, 35));
      expect(out.end?.wall, DateTime.utc(2026, 12, 13, 7, 30));
      final back = found[1].info as FlightReservationInfo;
      expect(back.start?.wall, DateTime.utc(2026, 12, 18, 11, 15));
      expect(back.end?.wall, DateTime.utc(2026, 12, 18, 17, 40));
    });

    test('Jetstar Asia: a digit and a letter, the route before it', () {
      final f = bookings([
        mail(
          'Jetstar Asia: your itinerary',
          sender: 'jetstar.com',
          text:
              'Your booking reference is Q2ZP7N.\n\nSingapore (SIN) - Bangkok '
              '(BKK)\nFlight 3K 685 · Mon 25 Jan 2027 · 08:10 - 09:35',
        ),
      ]).single;
      final info = f.info as FlightReservationInfo;
      expect(info.flightNumber, '3K 685');
      expect(info.from?.code, 'SIN');
      expect(info.to?.code, 'BKK');
      expect(info.start?.wall, DateTime.utc(2027, 1, 25, 8, 10));
      expect(f.city, 'Bangkok');
    });

    test('a Booking.com-style hotel', () {
      final b = bookings([
        mail(
          'Your booking is confirmed at Park Hotel Tokyo',
          sender: 'booking.com',
          name: 'Booking.com',
          text: '''
Thanks, Alice! Your booking in Tokyo is confirmed.

Park Hotel Tokyo
Confirmation number: 4012345678
PIN code: 1234

Check-in   Sunday, December 13, 2026 (from 3:00 PM)
Check-out  Friday, December 18, 2026 (until 11:00 AM)

Free cancellation until 11 December 2026.
''',
        ),
      ]).single;
      final stay = b.info as LodgingReservationInfo;
      expect(stay.hotel?.name, 'Park Hotel Tokyo');
      expect(stay.reservationNumber, '4012345678');
      expect(stay.checkin?.wall, DateTime.utc(2026, 12, 13, 15));
      expect(stay.checkout?.wall, DateTime.utc(2026, 12, 18, 11));
      expect(stay.provider, 'Booking.com');
      expect(b.city, 'Tokyo');
      expect(b.cancelled, isFalse, reason: '"free cancellation" is a term');
    });

    test('Agoda: the name from the subject, the city from the address', () {
      final b = bookings([
        mail(
          'Agoda booking confirmation for Hotel Gracery Shinjuku '
          '(Booking ID 1234567890)',
          sender: 'agoda.com',
          name: 'Agoda',
          text: '''
Booking ID: 1234567890
Hotel Gracery Shinjuku
Address: 1-19-1 Kabukicho, Shinjuku-ku, Tokyo 160-8466, Japan
Check-in: Sun, 13 Dec 2026 (after 14:00)
Check-out: Fri, 18 Dec 2026 (before 11:00)
''',
        ),
      ]).single;
      final stay = b.info as LodgingReservationInfo;
      expect(stay.hotel?.name, 'Hotel Gracery Shinjuku');
      expect(stay.checkin?.wall.hour, 14);
      expect(b.city, 'Tokyo');
    });

    test('Airbnb: no hotel name, the city it goes to', () {
      final b = bookings([
        mail(
          "Reservation confirmed - You're going to Kyoto!",
          sender: 'airbnb.com',
          name: 'Airbnb',
          text: '''
Cozy machiya near Gion
Entire home hosted by Kenji

Check-in
Tue, Dec 15
3:00 PM

Checkout
Thu, Dec 17
11:00 AM

Confirmation code
HMXK3Q9ZTA
''',
        ),
      ]).single;
      final stay = b.info as LodgingReservationInfo;
      expect(stay.hotel?.name, 'Stay in Kyoto');
      expect(stay.checkin?.wall, DateTime.utc(2026, 12, 15, 15));
      expect(stay.checkout?.wall, DateTime.utc(2026, 12, 17, 11));
      expect(b.reference, 'HMXK3Q9ZTA');
    });

    test('a cancellation marks every flight of the booking', () {
      final found = trips([
        mail(
          'Your Scoot booking confirmation - K7XQ2M',
          sender: 'flyscoot.com',
          text: _scootText,
          daysAgo: 10,
        ),
        mail(
          'Your booking has been cancelled',
          sender: 'flyscoot.com',
          text:
              'Hi Alice, your booking K7XQ2M has been cancelled as requested. '
              'Booking reference: K7XQ2M. A refund will be made to your card.',
        ),
      ]);
      final trip = found.single;
      expect(trip.cancelled, isTrue);
      expect(trip.bookings.every((b) => b.records.length == 2), isTrue);
    });

    test('a schedule change: the new times count', () {
      final found = bookings([
        mail(
          'Your Scoot booking confirmation - K7XQ2M',
          sender: 'flyscoot.com',
          text: _scootText,
          daysAgo: 10,
        ),
        mail(
          'Important: schedule change to your flight TR 808',
          sender: 'flyscoot.com',
          text: '''
Booking reference: K7XQ2M
We're sorry, the time of your flight has changed.

TR 808   SIN → NRT   Sat, 12 Dec 2026
Previous: Depart 01:30   Arrive 09:05
New: Depart 02:15   Arrive 09:50
''',
        ),
      ]);
      expect(found, hasLength(2));
      final out = found.first;
      expect(out.changed, isTrue);
      expect(out.start.wall, DateTime.utc(2026, 12, 12, 2, 15));
      expect(out.end?.wall, DateTime.utc(2026, 12, 12, 9, 50));
      expect(out.previousStart?.wall, DateTime.utc(2026, 12, 12, 1, 30));
      expect(found[1].changed, isFalse);
    });
  });

  group('not bookings', () {
    test('airline newsletters with flight deals', () {
      expect(
        bookings([
          mail(
            'Fly to Tokyo from S\$398 – this weekend only',
            sender: 'singaporeair.com',
            text:
                'Book by 8 Nov. Flights SQ 638 SIN → NRT on 12 Dec 2026, '
                '23:35. Booking reference: not needed, just book!',
            bulk: true,
          ),
          mail(
            'Great deals to Bangkok',
            sender: 'flyscoot.com',
            text:
                'Booking reference: K7XQ2M is not required. Flight TR 616 '
                'SIN → BKK, 25 Jan 2027, 07:00.',
          ),
        ]),
        isEmpty,
      );
    });

    test('"rate your stay" and loyalty statements', () {
      expect(
        bookings([
          mail(
            'Alice, rate your stay at Park Hotel Tokyo',
            sender: 'booking.com',
            text:
                'Confirmation number: 4012345678. Check-in: 13 Dec 2026. '
                'Check-out: 18 Dec 2026. How was it?',
          ),
          mail(
            'Your KrisFlyer statement for November',
            sender: 'singaporeair.com',
            text:
                'Membership number 8812345678. Flight SQ 321 SIN → LHR '
                '12 Oct 2026: 5,000 miles. Flight SQ 322 LHR → SIN 20 Oct '
                '2026: 5,000 miles.',
          ),
          mail(
            'Check-in is now open for your flight to Tokyo',
            sender: 'singaporeair.com',
            text:
                'Your flight SQ 638 from Singapore (SIN) to Tokyo (NRT) '
                'departs at 23:35 on 12 Dec 2026. Check in now.',
          ),
        ]),
        isEmpty,
      );
    });

    test('replies, and mail without a reference or a route', () {
      expect(
        bookings([
          mail(
            'Re: Your Scoot booking confirmation - K7XQ2M',
            sender: 'gmail.com',
            text: _scootText,
          ),
          mail(
            'Meeting about the Tokyo trip',
            sender: 'company.example',
            text:
                'Booking reference: ABC123. Let us meet at 10:30 AM 12 Dec '
                '2026 in room TR 4.',
          ),
          mail(
            'Your order confirmation',
            sender: 'shop.example',
            text:
                'Order number: 1234567. Delivery 12 Dec 2026. Thanks for '
                'shopping. Reference: AB 1234',
          ),
        ]),
        isEmpty,
      );
    });
  });

  group('references', () {
    test('only next to booking words, and only of the right shape', () {
      expect(TripText.referencesIn('Booking reference: XKQZPL'), ['XKQZPL']);
      expect(TripText.referencesIn('PNR XKQZPL'), ['XKQZPL']);
      expect(TripText.referencesIn('Confirmation code\nHMXK3Q9ZTA'), [
        'HMXK3Q9ZTA',
      ]);
      expect(TripText.referencesIn('Itinerary # 72012345678901'), [
        '72012345678901',
      ]);
      expect(TripText.referencesIn('Booking reference: below'), isEmpty);
      expect(TripText.referencesIn('Booking reference: PLEASE'), isEmpty);
      expect(TripText.referencesIn('booking reference ABCDEFGH'), isEmpty);
      expect(TripText.referencesIn('Your code is XKQZPL'), isEmpty);
    });

    test('cancelled, but not "free cancellation"', () {
      expect(
        TripText.saysCancelled('Your booking has been cancelled', ''),
        isTrue,
      );
      expect(TripText.saysCancelled('Cancellation confirmed', ''), isTrue);
      expect(
        TripText.saysCancelled(
          'Booking confirmed',
          'Free cancellation until 11 Dec. See the cancellation policy.',
        ),
        isFalse,
      );
      expect(
        TripText.saysCancelled(
          'Update',
          'We are sorry: your flight TR 808 has been cancelled.',
        ),
        isTrue,
      );
    });
  });

  group('trips', () {
    test('separate trips: Tokyo, then Bangkok, then Kuala Lumpur', () {
      final found = trips([
        mail(
          'Booking confirmation',
          sender: 'singaporeair.com',
          html: _sqReturn,
          daysAgo: 30,
        ),
        mail(
          'Itinerary',
          sender: 'flyscoot.com',
          html: _script([
            _flightLd(
              'TR 616',
              'SIN',
              'BKK',
              '2027-01-25T07:00:00+08:00',
              '2027-01-25T08:25:00+07:00',
              reference: 'BKK111',
            ),
            _flightLd(
              'TR 617',
              'BKK',
              'SIN',
              '2027-01-28T09:20:00+07:00',
              '2027-01-28T12:45:00+08:00',
              reference: 'BKK111',
            ),
          ]),
        ),
        mail(
          'Itinerary',
          sender: 'airasia.com',
          html: _script([
            _flightLd(
              'AK 702',
              'SIN',
              'KUL',
              '2027-01-30T10:00:00+08:00',
              '2027-01-30T11:05:00+08:00',
              reference: 'KUL222',
            ),
          ]),
        ),
      ]);
      expect(found.map((t) => t.destinations), [
        ['Tokyo'],
        ['Bangkok'],
        ['Kuala Lumpur'],
      ]);
      expect(
        TripFinder.homeOf(found.expand((t) => t.bookings).toList()),
        'Singapore',
      );
    });

    test('a trip through two cities: by train from Tokyo to Kyoto', () {
      final found = trips([
        mail(
          'Booking confirmation',
          sender: 'singaporeair.com',
          html: _script([
            _flightLd(
              '638',
              'SIN',
              'NRT',
              '2026-12-12T23:35:00+08:00',
              '2026-12-13T07:30:00+09:00',
            ),
            _flightLd(
              '619',
              'KIX',
              'SIN',
              '2026-12-18T11:00:00+09:00',
              '2026-12-18T16:50:00+08:00',
            ),
          ]),
        ),
        mail(
          'Your Shinkansen ticket',
          sender: 'smart-ex.jp',
          html: '''
<script type="application/ld+json">
{"@type": "TrainReservation", "reservationNumber": "JR7781",
 "reservationFor": {"@type": "TrainTrip", "trainNumber": "225", "trainName": "Nozomi",
   "departureStation": {"@type": "TrainStation", "name": "Tokyo"},
   "departureTime": "2026-12-15T09:00:00+09:00",
   "arrivalStation": {"@type": "TrainStation", "name": "Kyoto"},
   "arrivalTime": "2026-12-15T11:15:00+09:00"}}
</script>''',
        ),
      ]);
      final trip = found.single;
      expect(trip.destinations, ['Tokyo', 'Kyoto']);
      expect(trip.bookings.map((b) => b.kind), [
        ReservationKind.flight,
        ReservationKind.train,
        ReservationKind.flight,
      ]);
    });
  });

  test('looks like a booking (to download)', () {
    expect(TripFinder.looksLikeBooking('Your flight to Tokyo'), isTrue);
    expect(TripFinder.looksLikeBooking('Booking confirmation'), isTrue);
    expect(
      TripFinder.looksLikeBooking('Fly to Tokyo: deals from S\$398'),
      isFalse,
    );
    expect(TripFinder.looksLikeBooking('Re: our trip'), isFalse);
    expect(TripFinder.looksLikeBooking('Lunch on Friday?'), isFalse);
  });
}
