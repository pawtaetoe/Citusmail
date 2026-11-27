// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
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
    messageId: MessageId(++_ids),
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

/// An Avanti West Coast-style confirmation: no markup, the eTickets in a
/// PDF, the journeys in its words.
const _avantiText = '''
Your Booking Confirmation

Hi Alex,

Thanks for booking with Avanti West Coast. Your booking is confirmed and
your eTickets are attached to this email as a PDF. Show them on your
phone or print them, and have them ready for inspection on board.

Booking reference: 21699058

Outward journey
Sunday 28 June 2026
London Euston to Manchester Piccadilly
Depart 08:40   Arrive 10:48
Direct, 2h 8m
Coach C, Seat 42 (window, forward facing)
Ticket: Advance Single, Standard Premium

Return journey
Wednesday 1 July 2026
Manchester Piccadilly to London Euston
Depart 17:35   Arrive 19:47
Direct, 2h 12m
Coach C, Seat 18 (aisle)
Ticket: Advance Single, Standard

Passengers: 1 adult
Total paid: £86.40
Booked on 23 June 2026 at 09:14

Manage your booking at avantiwestcoast.co.uk. Travelling with a Railcard?
Remember to bring it with you.
''';

/// An ÖBB-style ticket email in German: the stations and times on one
/// line, the date written the Austrian way.
const _oebbGerman = '''
Sehr geehrte Frau Tan,

vielen Dank für Ihre Buchung bei den ÖBB. Ihr Ticket finden Sie im
Anhang dieser E-Mail als PDF.

Ticketnummer: 0919 1410 7516 0291
Buchungscode: 8F3KQ2

Hinfahrt
So., 2. August 2026
Wien Hbf ab 08:30 → Salzburg Hbf an 10:52
Railjet Xpress RJX 862, 2. Klasse
Wagen 23, Platz 45, Fenster

Reisende: 1 Erwachsene/r
Preis: € 37,90
Kaufdatum: 26.05.2026, 11:04

Bitte führen Sie Ihr Ticket und einen Lichtbildausweis mit.
Gute Reise wünschen Ihnen Ihre ÖBB.
''';

/// The same ticket in English: the stations as a table's cells, no date
/// but the subject's, and a ticket number only.
const _oebbEnglish = '''
Dear Ms Tan,

Thank you for your booking with ÖBB. Your ticket is attached to this
email as a PDF; please carry it with you together with a photo ID.

Ticket number: 0919 1410 7516 0291

Outward journey
From:
Wien Hbf
To:
Salzburg Hbf
Departure 08:30, arrival 10:52
Railjet Xpress RJX 862, 2nd class
Coach 23, seat 45

Price: EUR 37.90
Date of purchase: 26 May 2026

Have a good journey!
Your ÖBB
''';

/// A Singapore Airlines-style redemption booking: a table, one cell per
/// line once the HTML is text, the airport codes in cells of their own.
const _sqRedemption = '''
Your redemption booking is confirmed

Dear Ms Alice Tan,

Thank you for redeeming your KrisFlyer miles with Singapore Airlines.
Your e-ticket itinerary is attached.

Booking reference
EB3QZK

KrisFlyer miles redeemed
92,000

Flight 1
SQ 322
Sun 12 Jul 2026
Singapore
SIN
22:05
Changi Airport Terminal 3
London
LHR
05:15 (+1)
Heathrow Airport Terminal 2
Business Saver Award

Flight 2
SQ 317
Sun 26 Jul 2026
London
LHR
11:35
Heathrow Airport Terminal 2
Singapore
SIN
07:55 (+1)
Changi Airport Terminal 3
Business Saver Award

Taxes and surcharges paid: SGD 642.30
''';

/// An Osaka hotel's own confirmation, and later its change email under a
/// new reservation number.
const _osakaBooked = '''
Dear Alice Tan,

Thank you for choosing Osaka View Hotel Honmachi. Your reservation has
been booked as follows.

Reservation number: 20261215-4471
Hotel: Osaka View Hotel Honmachi
Address: 2-3-10 Honmachi, Chuo-ku, Osaka 541-0053, Japan

Check-in: Tue, 15 Dec 2026 15:00
Check-out: Mon, 21 Dec 2026 11:00
Nights: 6
Room: Superior Double, non-smoking
Guests: 2 adults

If you need to change or cancel your reservation, please contact us.
Free cancellation until 3 days before arrival.
''';

const _osakaChanged = '''
Dear Alice Tan,

Your reservation at Osaka View Hotel Honmachi has been changed. Please
check the new dates below.

Reservation number: 20261221-4583

Previous dates
Check-in: Tue, 15 Dec 2026
Check-out: Mon, 21 Dec 2026

New dates
Check-in: Mon, 21 Dec 2026 15:00
Check-out: Thu, 24 Dec 2026 11:00
Nights: 3
Room: Superior Double, non-smoking
Guests: 2 adults

Address: 2-3-10 Honmachi, Chuo-ku, Osaka 541-0053, Japan
''';

/// Three more nights at the same hotel, booked separately.
const _osakaMoreNights = '''
Dear Alice Tan,

Thank you for choosing Osaka View Hotel Honmachi again. Your
reservation has been booked as follows.

Reservation number: 20261221-4583
Hotel: Osaka View Hotel Honmachi
Address: 2-3-10 Honmachi, Chuo-ku, Osaka 541-0053, Japan

Check-in: Mon, 21 Dec 2026 15:00
Check-out: Thu, 24 Dec 2026 11:00
Nights: 3
Room: Standard Twin, non-smoking
Guests: 2 adults

If you need to change or cancel your reservation, please contact us.
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

  group('trains and coaches from their words', () {
    test('an Avanti West Coast booking: there and back, one trip', () {
      final found = trips([
        mail(
          'Your Booking Confirmation: 21699058',
          sender: 'avantiwestcoast.co.uk',
          name: 'Avanti West Coast',
          text: _avantiText,
          daysAgo: 134,
        ),
      ]);
      final trip = found.single;
      expect(trip.destinations, ['Manchester']);
      final [out, back] = trip.bookings;
      expect(out.kind, ReservationKind.train);
      final info = out.info as TransitReservationInfo;
      expect(info.reservationNumber, '21699058');
      expect(info.provider, 'Avanti West Coast');
      expect(info.from?.name, 'London Euston');
      expect(info.to?.name, 'Manchester Piccadilly');
      expect(info.start?.wall, DateTime.utc(2026, 6, 28, 8, 40));
      expect(info.end?.wall, DateTime.utc(2026, 6, 28, 10, 48));
      expect(out.city, 'Manchester');
      expect(out.fromCity, 'London');
      expect(back.kind, ReservationKind.train);
      expect(back.start.wall, DateTime.utc(2026, 7, 1, 17, 35));
      expect(back.end?.wall, DateTime.utc(2026, 7, 1, 19, 47));
      expect(back.city, 'London');
      expect(out.cancelled, isFalse);
    });

    test('an ÖBB ticket in German: European dates, times on the line', () {
      final b = bookings([
        mail(
          'Ihr ÖBB Ticket – 0919 1410 7516 0291',
          sender: 'oebb.at',
          name: 'ÖBB',
          text: _oebbGerman,
          daysAgo: 162,
        ),
      ]).single;
      final info = b.info as TransitReservationInfo;
      expect(b.kind, ReservationKind.train);
      expect(info.reservationNumber, '8F3KQ2');
      expect(info.number, 'RJX 862');
      expect(info.from?.name, 'Wien Hbf');
      expect(info.to?.name, 'Salzburg Hbf');
      expect(info.start?.wall, DateTime.utc(2026, 8, 2, 8, 30));
      expect(info.end?.wall, DateTime.utc(2026, 8, 2, 10, 52));
      expect(b.fromCity, 'Vienna');
      expect(b.city, 'Salzburg');
      expect(b.key, 'train:rjx862:2026-08-02');
    });

    test('an ÖBB ticket in English: the date from the subject', () {
      final found = bookings([
        mail(
          'ÖBB ticket – 0919 1410 7516 0291 – Aug 2, 2026',
          sender: 'oebb.at',
          text: _oebbEnglish,
          daysAgo: 162,
        ),
        // The same ticket again, in German: one booking.
        mail(
          'Ihr ÖBB Ticket – 0919 1410 7516 0291',
          sender: 'oebb.at',
          name: 'ÖBB',
          text: _oebbGerman,
          daysAgo: 162,
        ),
      ]);
      final b = found.single;
      expect(b.records, hasLength(2));
      final first = b.infos.first as TransitReservationInfo;
      expect(first.reservationNumber, '0919 1410 7516 0291');
      expect(first.provider, 'ÖBB');
      expect(first.from?.name, 'Wien Hbf');
      expect(first.to?.name, 'Salzburg Hbf');
      expect(first.start?.wall, DateTime.utc(2026, 8, 2, 8, 30));
      expect(first.end?.wall, DateTime.utc(2026, 8, 2, 10, 52));
      expect(b.city, 'Salzburg');
    });

    test('a coach, and a train booked through a travel site', () {
      final coach = bookings([
        mail(
          'Your FlixBus booking confirmation',
          sender: 'flixbus.com',
          name: 'FlixBus',
          text: '''
Hello Alice,

thanks for booking with FlixBus! Show your ticket on your phone when you
board.

Booking number: 3012345678

Outbound trip, Fri 18 Dec 2026
London Victoria Coach Station → Paris Bercy Seine
Departure 07:30, arrival 16:15
1 adult, 1 seat
''',
        ),
      ]).single;
      expect(coach.kind, ReservationKind.bus);
      expect(coach.info.from?.name, 'London Victoria Coach Station');
      expect(coach.start.wall, DateTime.utc(2026, 12, 18, 7, 30));
      expect(coach.city, 'Paris');

      final train = bookings([
        mail(
          'Train ticket booking confirmed',
          sender: 'trip.com',
          name: 'Trip.com',
          text: '''
Your train ticket booking is confirmed.

Booking No.: 1234567890123

Train G102
Shanghai Hongqiao → Beijing South
Sat, 12 Dec 2026
06:37 – 12:15
Coach 05, Seat 12F, 2nd class
''',
        ),
      ]).single;
      expect(train.kind, ReservationKind.train);
      expect(train.start.wall, DateTime.utc(2026, 12, 12, 6, 37));
      expect(train.end?.wall, DateTime.utc(2026, 12, 12, 12, 15));
      expect(train.fromCity, 'Shanghai');
      expect(train.city, 'Beijing');
    });

    test('dates and times written the European way', () {
      final sent = DateTime.utc(2026, 5, 26, 10);
      expect(
        TripText.datesIn('02.08.2026', sent).single.day,
        DateTime(2026, 8, 2),
      );
      expect(
        TripText.datesIn('So., 2. Aug. 2026', sent).single.day,
        DateTime(2026, 8, 2),
      );
      expect(
        TripText.datesIn('Sun 2 August', sent).single.day,
        DateTime(2026, 8, 2),
      );
      expect(
        TripText.datesIn('Mo., 14. Dezember 2026', sent).single.day,
        DateTime(2026, 12, 14),
      );
      expect(
        TripText.datesIn('3. März 2027', sent).single.day,
        DateTime(2027, 3, 3),
      );
      expect(TripText.datesIn('Version 4412.553.901', sent), isEmpty);
      expect(TripText.timesIn('Abfahrt 08:30').single.hour, 8);
    });
  });

  group('flights laid out as tables', () {
    test('a Singapore Airlines redemption booking', () {
      final found = trips([
        mail(
          'Your redemption booking confirmation EB3QZK',
          sender: 'singaporeair.com',
          name: 'Singapore Airlines',
          text: _sqRedemption,
          daysAgo: 237,
        ),
      ]);
      final trip = found.single;
      expect(trip.destinations, ['London']);
      final [out, back] = trip.bookings;
      final info = out.info as FlightReservationInfo;
      expect(info.flightNumber, 'SQ 322');
      expect(info.reservationNumber, 'EB3QZK');
      expect(info.from?.code, 'SIN');
      expect(info.to?.code, 'LHR');
      expect(info.start?.wall, DateTime.utc(2026, 7, 12, 22, 5));
      expect(info.end?.wall, DateTime.utc(2026, 7, 13, 5, 15));
      final home = back.info as FlightReservationInfo;
      expect(home.flightNumber, 'SQ 317');
      expect(home.from?.code, 'LHR');
      expect(home.to?.code, 'SIN');
      expect(home.start?.wall, DateTime.utc(2026, 7, 26, 11, 35));
      expect(home.end?.wall, DateTime.utc(2026, 7, 27, 7, 55));
    });

    test('codes side by side in a row, or one per line', () {
      final row = TripText.flightsIn(
        'Booking reference: EB3QZK\nFlight SQ 322 · Sun 12 Jul 2026\n'
        'Singapore SIN 22:05   London LHR 05:15 (+1)',
        sent: _now,
      ).single;
      expect(row.from?.code, 'SIN');
      expect(row.to?.code, 'LHR');
      expect(row.end?.wall, DateTime.utc(2026, 7, 13, 5, 15));
      final cells = TripText.flightsIn(
        'Flight SQ 322\n12 Jul 2026\nSIN\n22:05\nLHR\n05:15 (+1)',
        sent: _now,
      ).single;
      expect(cells.from?.code, 'SIN');
      expect(cells.to?.code, 'LHR');
    });

    test('words in capitals are not airports', () {
      // THE and AND are not airports; CAN and ADD are, but not here: one
      // follows a word in capitals, and one airport alone is no route.
      expect(
        TripText.flightsIn(
          'Booking reference: EB3QZK\nFlight SQ 322 on 12 Jul 2026, 22:05\n'
          'PLEASE NOTE THE\nAND\nYOU CAN\nADD\nBAGS ONLINE',
          sent: _now,
        ),
        isEmpty,
      );
      // No flight number near: no flight.
      expect(
        TripText.flightsIn(
          'Booking reference: EB3QZK\nSun 12 Jul 2026\nSIN\n22:05\nLHR\n05:15',
          sent: _now,
        ),
        isEmpty,
      );
    });
  });

  group('stays: names and changes', () {
    test('the hotel name, not what the subject says of it', () {
      String? name(String subject, {String? sender}) => TripText.stayIn(
        mail(
          subject,
          sender: 'osakaviewhotel.jp',
          name: sender,
          text:
              'Reservation number: 20261215-4471\n'
              'Check-in: Tue, 15 Dec 2026 15:00\n'
              'Check-out: Mon, 21 Dec 2026 11:00',
        ),
      )?.hotel?.name;
      expect(
        name('Osaka View Hotel Honmachi has been booked'),
        'Osaka View Hotel Honmachi',
      );
      expect(
        name(
          'Reservation confirmation: Osaka View Hotel Honmachi has been booked',
        ),
        'Osaka View Hotel Honmachi',
      );
      expect(
        name('Confirmed: Osaka View Hotel Honmachi has been changed'),
        'Osaka View Hotel Honmachi',
      );
      expect(
        name('Booking confirmed at Osaka View Hotel Honmachi is confirmed'),
        'Osaka View Hotel Honmachi',
      );
      expect(
        name(
          'Your reservation has been confirmed',
          sender: 'Osaka View Hotel Honmachi',
        ),
        'Osaka View Hotel Honmachi',
      );
    });

    test('a stay changed to new dates shows once, with the new dates', () {
      final found = bookings([
        mail(
          'Reservation confirmation: Osaka View Hotel Honmachi has been booked',
          sender: 'osakaviewhotel.jp',
          name: 'Osaka View Hotel Honmachi',
          text: _osakaBooked,
          daysAgo: 40,
        ),
        mail(
          'Reservation change: Osaka View Hotel Honmachi has been changed',
          sender: 'osakaviewhotel.jp',
          name: 'Osaka View Hotel Honmachi',
          text: _osakaChanged,
          daysAgo: 2,
        ),
      ]);
      final stay = found.single;
      final info = stay.info as LodgingReservationInfo;
      expect(info.hotel?.name, 'Osaka View Hotel Honmachi');
      expect(stay.start.wall, DateTime.utc(2026, 12, 21, 15));
      expect(stay.end?.wall, DateTime.utc(2026, 12, 24, 11));
      expect(stay.changed, isTrue);
      expect(stay.previousStart?.day, DateTime(2026, 12, 15));
      expect(stay.records, hasLength(2));
      expect(stay.city, 'Osaka');
    });

    test('two stays back to back, each booked: two stays', () {
      final found = bookings([
        mail(
          'Osaka View Hotel Honmachi has been booked',
          sender: 'osakaviewhotel.jp',
          text: _osakaBooked,
          daysAgo: 40,
        ),
        mail(
          'Osaka View Hotel Honmachi has been booked',
          sender: 'osakaviewhotel.jp',
          text: _osakaMoreNights,
          daysAgo: 2,
        ),
      ]);
      expect(found, hasLength(2));
      expect(found.map((b) => (b.info as LodgingReservationInfo).hotel?.name), [
        'Osaka View Hotel Honmachi',
        'Osaka View Hotel Honmachi',
      ]);
      expect(found.map((b) => b.start.day), [
        DateTime(2026, 12, 15),
        DateTime(2026, 12, 21),
      ]);
      expect(found.every((b) => !b.changed), isTrue);
      expect(
        trips([
          mail(
            'Osaka View Hotel Honmachi has been booked',
            sender: 'osakaviewhotel.jp',
            text: _osakaBooked,
            daysAgo: 40,
          ),
          mail(
            'Osaka View Hotel Honmachi has been booked',
            sender: 'osakaviewhotel.jp',
            text: _osakaMoreNights,
            daysAgo: 2,
          ),
        ]).single.destinations,
        ['Osaka'],
      );
    });

    test('a change elsewhere, or after a gap, is not this stay', () {
      final found = bookings([
        mail(
          'Osaka View Hotel Honmachi has been booked',
          sender: 'osakaviewhotel.jp',
          text: _osakaBooked,
          daysAgo: 40,
        ),
        mail(
          'Reservation change: Osaka View Hotel Honmachi has been changed',
          sender: 'osakaviewhotel.jp',
          text: _osakaChanged
              .replaceAll('21 Dec 2026 15:00', '28 Dec 2026 15:00')
              .replaceAll('24 Dec 2026', '30 Dec 2026'),
          daysAgo: 2,
        ),
      ]);
      expect(found, hasLength(2));
    });
  });

  group('not trips', () {
    test('rail marketing', () {
      const offer = '''
Hi Alex,

Escape to Scotland for less. Save 30% on Advance fares from London
Euston to Glasgow Central when you book by 15 November 2026.

London Euston to Glasgow Central from £29.90
Travel between 1 December 2026 and 28 February 2027.

Booking reference: not needed. Terms and conditions apply.
Unsubscribe
''';
      expect(
        bookings([
          mail(
            'Save 30% on trains to Glasgow',
            sender: 'avantiwestcoast.co.uk',
            name: 'Avanti West Coast',
            text: offer,
          ),
          mail(
            'Save 30% on trains to Glasgow',
            sender: 'avantiwestcoast.co.uk',
            name: 'Avanti West Coast',
            text: offer,
            bulk: true,
          ),
          mail(
            'Your next adventure starts at London Euston',
            sender: 'avantiwestcoast.co.uk',
            name: 'Avanti West Coast',
            text: offer,
          ),
        ]),
        isEmpty,
      );
      expect(
        TripFinder.looksLikeBooking('Save 30% on trains to Glasgow'),
        isFalse,
      );
    });

    test('a UK ETA approval', () {
      const eta = '''
Dear ALICE TAN,

Your application for an electronic travel authorisation (ETA) to travel
to the UK has been approved.

Application reference number: 7543-2190-8812-4410
Passport number ending: 4521
Your ETA is valid for 2 years, until 14 March 2028, or until your
passport expires, if sooner.

You can travel to the UK by plane, train or ferry. You do not need to
print anything: your ETA is linked digitally to your passport.

Date of decision: 14 March 2026
''';
      expect(
        trips([
          mail(
            'ETA application approved',
            sender: 'homeoffice.gov.uk',
            name: 'UK Visas and Immigration',
            text: eta,
          ),
          mail(
            'Your trip to the UK: travel information',
            sender: 'homeoffice.gov.uk',
            name: 'UK Visas and Immigration',
            text: eta,
          ),
        ]),
        isEmpty,
      );
    });

    test('a season ticket renewal: no journey date', () {
      const renewal = '''
Hi Alex,

Thank you for travelling with us.

Ticket: Annual Season, Milton Keynes Central to London Euston
Season ticket number: 7712 3349 0021 5567
Booking reference: 55120391
Your current ticket is valid until 31 December 2026.
Renew by 24 December 2026 to keep travelling without a gap.

Renew online at londonnorthwesternrailway.co.uk, or at any staffed
ticket office.
''';
      expect(
        bookings([
          mail(
            'Your season ticket is due for renewal',
            sender: 'londonnorthwesternrailway.co.uk',
            name: 'London Northwestern Railway',
            text: renewal,
          ),
          // A neutral subject: still no day to travel on.
          mail(
            'A reminder about your ticket',
            sender: 'londonnorthwesternrailway.co.uk',
            name: 'London Northwestern Railway',
            text: renewal,
          ),
        ]),
        isEmpty,
      );
    });

    test('a hotel near a station is a stay, not a train', () {
      final b = bookings([
        mail(
          'Booking confirmation - Hotel Granvia Kyoto',
          sender: 'granviakyoto.com',
          name: 'Hotel Granvia Kyoto',
          text: '''
Confirmation number: GV-88123
Hotel Granvia Kyoto, directly above the JR train platforms.
Access: Kyoto Station to Osaka Station - 15 minutes by train.
Check-in: Tue, 15 Dec 2026 15:00
Check-out: Thu, 17 Dec 2026 12:00
''',
        ),
      ]).single;
      expect(b.kind, ReservationKind.stay);
      expect(b.city, 'Kyoto');
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
