// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Booking layouts and wordings found missing or misread in real mail,
// each as an invented fixture of the same shape.

import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

var _ids = 0;

TripEmail mail(
  String subject, {
  required String sender,
  String? name,
  String text = '',
  DateTime? at,
  String? html,
}) => TripEmail(
  messageId: MessageId(++_ids),
  sender: sender,
  senderName: name,
  subject: subject,
  text: text,
  at: at ?? DateTime.utc(2026, 8, 3, 9),
  reservations: html == null
      ? const []
      : ReservationInfo.allIn(StructuredData.extract(html)),
);

FlightReservationInfo flight(Booking b) => b.info as FlightReservationInfo;

void main() {
  group('a stay', () {
    test(
      'a refund policy\'s "if the booking is cancelled" is no cancellation',
      () {
        const policy =
            'Cancel booking\nCancellation Policy\nThe amount due is not '
            'refundable even if the booking is cancelled or modified.';
        expect(TripText.saysCancelled('Your stay', policy), isFalse);
        expect(
          TripText.saysCancelled(
            'Your stay',
            'Your booking has been cancelled.',
          ),
          isTrue,
        );
        final b = TripFinder.bookings([
          mail(
            'Your reservation is confirmed: Fernwood Airport Inn, ref QZPL4471',
            sender: 'fernwood-inns.example',
            name: 'Fernwood Inns',
            text: 'Your reservation is confirmed\n$policy',
            html: '''
<script type="application/ld+json">
{"@type": "LodgingReservation", "reservationNumber": "QZPL4471",
 "reservationStatus": "http://schema.org/ReservationConfirmed",
 "reservationFor": {"@type": "LodgingBusiness", "name": "Fernwood Airport Inn"},
 "checkinDate": "2026-09-12", "checkoutDate": "2026-09-13"}
</script>''',
          ),
        ]).single;
        expect(b.cancelled, isFalse);
      },
    );

    test('dates as a range after "Dates", times by "Check in"', () {
      final b = TripFinder.bookings([
        mail(
          'Your reservation at Larkspur Lodge Quayside is confirmed. #40718293',
          sender: 'larkspur-lodge.example',
          name: 'Larkspur Lodge',
          text:
              'Confirmation #40718293\nLarkspur Lodge Quayside\n'
              'Dates 12 Sep 2026 - 15 Sep 2026 Check in 3:00 pm / Check out '
              '12:00 pm',
        ),
        mail(
          'Booking confirmed: Pebble Cove Hostel',
          sender: 'pebble-cove.example',
          text:
              'Booking reference: PCH88214\nDate of stay: From 3 Oct 2026 to 4 '
              'Oct 2026',
        ),
      ]);
      final quay = b.first.info as LodgingReservationInfo;
      expect(quay.checkin?.wall, DateTime.utc(2026, 9, 12, 15));
      expect(quay.checkout?.wall, DateTime.utc(2026, 9, 15, 12));
      final cove = b.last.info as LodgingReservationInfo;
      expect(cove.checkin?.day, DateTime(2026, 10, 3));
      expect(cove.checkout?.day, DateTime(2026, 10, 4));
    });
  });

  group('flights', () {
    test('"City CODE City CODE time time", the number further down', () {
      final b = TripFinder.bookings([
        mail(
          'Fjordair - 03 Feb 2027: Lisbon - Oslo (Booking reference: QW3E4R)',
          sender: 'fjordair.example',
          name: 'Fjordair',
          text: '''
Booking Confirmation QW3E4R Issued 2 Nov, 2026
Flights
Departure • Wed 03 Feb, 2027 Economy Classic
Lisbon LIS Helsinki HEL 09:10 15:05 Humberto Delgado Airport Terminal 1 Helsinki Vantaa
Flight AY 1742
Connection • Wed 03 Feb, 2027 Economy Classic
Helsinki HEL Oslo OSL 16:20 17:00 Helsinki Vantaa Oslo Gardermoen
Flight AY 913
''',
          at: DateTime.utc(2026, 10, 13, 9),
        ),
      ]);
      expect(b, hasLength(2));
      expect(flight(b.first).departureAirport?.code, 'LIS');
      expect(flight(b.first).arrivalAirport?.code, 'HEL');
      expect(flight(b.first).start?.wall, DateTime.utc(2027, 2, 3, 9, 10));
      expect(flight(b.first).end?.wall, DateTime.utc(2027, 2, 3, 15, 5));
      expect(flight(b.last).flightNumber, 'AY 913');
      expect(flight(b.last).departureAirport?.code, 'HEL');
    });

    test('an agency\'s "From: CODE … time / To: CODE … time" itinerary', () {
      final b = TripFinder.bookings([
        mail(
          'Confirmed: your trip to Madrid',
          sender: 'cardtravel.example',
          name: 'Card Travel',
          text: '''
| Your trip #5521-0098 is confirmed |
| Saturday, September 26, 2026 Iberia - Dublin - Madrid |
| From: DUB Dublin Airport. Dublin, IE 05:04 pm |
| To: MAD Madrid Barajas. Madrid, ES 08:35 pm |
| Flight Number: | IB 3721 Operated by Iberia |
| Airline Confirmation: | QK7DNP |
''',
          at: DateTime.utc(2026, 8, 1, 9),
        ),
      ]);
      final f = flight(b.single);
      expect(f.reservationNumber, 'QK7DNP');
      expect(f.flightNumber, 'IB 3721');
      expect(f.departureAirport?.code, 'DUB');
      expect(f.arrivalAirport?.code, 'MAD');
      expect(f.start?.wall, DateTime.utc(2026, 9, 26, 17, 4));
      expect(f.end?.wall, DateTime.utc(2026, 9, 26, 20, 35));
    });

    test('an e-ticket receipt, one cell per line, "20Apr" and "EI0123"', () {
      final b = TripFinder.bookings([
        mail(
          'Your e-ticket receipt, booking ref QX7ABC, for your flight '
          '(DUB to HEL)',
          sender: 'exampleair.example',
          name: 'Example Air',
          text: '''
Booking Reference: QX7ABC
From
To
Flight
Class
Date
Departure
Arrival
DUBLIN
HELSINKI VANTAA
EI0123
V
20Apr
06:45
11:50
Ok
HELSINKI VANTAA
DUBLIN
EI0124
V
24Apr
13:10
14:30
Ok
''',
          at: DateTime.utc(2027, 4, 5, 9),
        ),
      ]);
      expect(b, hasLength(2));
      expect(flight(b.first).flightNumber, 'EI 123');
      expect(flight(b.first).start?.wall, DateTime.utc(2027, 4, 20, 6, 45));
      expect(flight(b.first).end?.wall, DateTime.utc(2027, 4, 20, 11, 50));
      expect(TripFinder.cityOf(flight(b.last).departureAirport), 'Helsinki');
      expect(TripFinder.cityOf(flight(b.last).arrivalAirport), 'Dublin');
      expect(flight(b.last).start?.wall, DateTime.utc(2027, 4, 24, 13, 10));
    });

    test('a boarding pass with no booking reference, "28Jul27"', () {
      final b = TripFinder.bookings([
        mail(
          'EI123/28Jul27/014C/ROE',
          sender: 'exampleair.example',
          name: 'Example Air',
          text: '''
Names on this boarding pass must match the passport.
FLIGHT
SEAT
EI123
28A
DUB
HEL
DEPARTURE
BOARDING TIME
28Jul27 07:45
07:05
''',
          at: DateTime.utc(2027, 7, 27, 9),
        ),
      ]);
      final f = flight(b.single);
      expect(f.flightNumber, 'EI 123');
      expect(f.departureAirport?.code, 'DUB');
      expect(f.start?.wall, DateTime.utc(2027, 7, 28, 7, 45));
      // The other time is boarding's, not the landing.
      expect(f.end, isNull);
    });

    test('a rescheduled flight: the revised times, by their labels', () {
      final b = TripFinder.bookings([
        mail(
          'Important: a change to your flight EI 412',
          sender: 'exampleair.example',
          name: 'Example Air',
          text: '''
Booking reference: QB4N7T
Flight EI 412 Dublin (DUB) to Helsinki (HEL)
Scheduled departure
11:25
Sat, 3 Oct 2026
Scheduled arrival
13:00
Revised departure
12:30
Revised arrival
13:57
''',
          at: DateTime.utc(2026, 9, 20, 9),
        ),
      ]);
      final f = flight(b.single);
      expect(f.start?.wall, DateTime.utc(2026, 10, 3, 12, 30));
      expect(f.end?.wall, DateTime.utc(2026, 10, 3, 13, 57));
      expect(b.single.changed, isTrue);
    });

    test('"Booking locator：", and a reminder citing it joins the booking', () {
      final first = mail(
        'Your booking QL7M2X',
        sender: 'exampleair.example',
        name: 'Example Air',
        text: '''
Booking locator ： QL7M2X
Flight EI 362 Dublin (DUB) to Helsinki (HEL)
Sat, 3 Oct 2026 09:05 - 13:20
''',
        at: DateTime.utc(2026, 9, 1, 9),
      );
      final reminder = mail(
        'Travel reminder',
        sender: 'exampleair.example',
        name: 'Example Air',
        text:
            'Booking locator ： QL7M2X - Departure：2026/10/03 Dublin EI0362 '
            'Helsinki DUBHEL 09:053hr 15mins13:20',
        at: DateTime.utc(2026, 10, 1, 9),
      );
      final b = TripFinder.bookings([first, reminder]).single;
      expect(flight(b).reservationNumber, 'QL7M2X');
      expect(b.records, hasLength(2));
    });

    test('an image\'s words between the label and the reference', () {
      expect(
        TripText.referencesIn(
          'Booking Reference Number [QR code image] QZ8K2P\n'
          '2026/11/19 (Thu) 18:40',
        ),
        ['QZ8K2P'],
      );
    });

    test('another booking of the same flight, same times, is no change', () {
      String ld(String ref) =>
          '''
<script type="application/ld+json">
{"@type": "FlightReservation", "reservationNumber": "$ref",
 "reservationFor": {"@type": "Flight", "flightNumber": "412",
   "airline": {"@type": "Airline", "iataCode": "EI"},
   "departureAirport": {"@type": "Airport", "iataCode": "DUB"},
   "departureTime": "2026-10-03T11:25:00+01:00",
   "arrivalAirport": {"@type": "Airport", "iataCode": "HEL"},
   "arrivalTime": "2026-10-03T16:00:00+03:00"}}
</script>''';
      final b = TripFinder.bookings([
        mail(
          'Booking confirmation QA1AAA',
          sender: 'exampleair.example',
          html: ld('QA1AAA'),
          at: DateTime.utc(2026, 8, 1),
        ),
        mail(
          'Reservation update for booking reference QB2BBB',
          sender: 'exampleair.example',
          html: ld('QB2BBB'),
          at: DateTime.utc(2026, 8, 2),
        ),
      ]).single;
      expect(b.records, hasLength(2));
      expect(b.changed, isFalse);
    });
  });

  group('trains', () {
    test('the operator\'s name is not part of the first station', () {
      final b = TripFinder.bookings([
        mail(
          'Your Booking Confirmation: 70412236',
          sender: 'westvale-rail.example',
          name: 'Westvale North Rail',
          text:
              'Your ticket is confirmed. Your booking is confirmed Thank you '
              'for booking with Westvale North Rail Alder Central/Low Level to '
              'Birchmoor Central Outward Saturday 26 September 2026 Depart '
              '08:00 Arrive 13:38',
        ),
      ]);
      final t = b.single.info as TransitReservationInfo;
      expect(t.departureStation?.name, 'Alder Central');
      expect(t.arrivalStation?.name, 'Birchmoor Central');
    });
  });
}
