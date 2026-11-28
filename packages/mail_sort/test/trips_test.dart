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

Booking reference: 40871235

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

Ticketnummer: 1234 5678 9012 3456
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

Ticket number: 1234 5678 9012 3456

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

Thank you for choosing Harbour Lantern Hotel Kitahama. Your reservation has
been booked as follows.

Reservation number: 20261215-4471
Hotel: Harbour Lantern Hotel Kitahama
Address: 1-4-7 Kitahama, Chuo-ku, Osaka 541-0041, Japan

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

Your reservation at Harbour Lantern Hotel Kitahama has been changed. Please
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

Address: 1-4-7 Kitahama, Chuo-ku, Osaka 541-0041, Japan
''';

/// Three more nights at the same hotel, booked separately.
const _osakaMoreNights = '''
Dear Alice Tan,

Thank you for choosing Harbour Lantern Hotel Kitahama again. Your
reservation has been booked as follows.

Reservation number: 20261221-4583
Hotel: Harbour Lantern Hotel Kitahama
Address: 1-4-7 Kitahama, Chuo-ku, Osaka 541-0041, Japan

Check-in: Mon, 21 Dec 2026 15:00
Check-out: Thu, 24 Dec 2026 11:00
Nights: 3
Room: Standard Twin, non-smoking
Guests: 2 adults

If you need to change or cancel your reservation, please contact us.
''';

/// An ÖBB ticket email in English, as its HTML reads as text, every
/// personal detail made up: the booking code on the line after its label,
/// in groups of four digits; the route with a ">" and a city in two
/// languages; the date written "Aug 20 2026"; no times (they are in the
/// PDF); and the booking date above it.
const _oebbReal = '''
logo url
Booking code:
0428 3315 6092 7781
Customer number:
PV318275604
Booking date:
25. May 2026
Transaction number:
531000000774120586
Dear SAM LEE,
please find below the link to your PDF Tickets.
Please remember to print your tickets in A4 format before you start your journey.
Download and print tickets
Please be aware that different cancellation conditions may apply for individual tickets if they have been collected in PDF format. Neither is it possible to convert them into Mobile Tickets or into tickets for pick-up at the station.
Your PDF Tickets
Zürich HB > Bolzano/Bozen
One-way journey for SAM LEE, ALEX LEE
Day of travel: Aug 20 2026 My timetable\u00a0>
My booking >
Updated timetable data
It is always possible that the timetable has changed. Be sure to check out the current timetable shortly before your journey starts. You will find your timetable details under “My timetable” (see above) or in our route planner Scotty.
Any more questions?
Please see our FAQs (currently available in German) for more information. If this did not help in resolving your question, please contact us via oebb.at/kontakt or call us: +43 5 1717.
We wish you a pleasant journey,
Your ÖBB
''';

/// An Avanti West Coast confirmation as its HTML reads as text, every
/// personal detail made up: the route over two lines ("Glasgow
/// Central/Queen St" above "to London Euston / Single"), the times in a
/// table and in brackets, and a "Delay Repay" and "Need a refund?" footer.
const _avantiReal = '''


Your booking is confirmed

Thank you for booking
with Avanti West Coast
Glasgow Central/Queen St
to London Euston / Single
£ 270.00
Outward journey
29 August 2026
£ 270.00
Glasgow Central
08:00
Direct
5h 38min
London Euston
13:38
Advance Single Standard Premium
What can I do with my ticket?
Train operator: \u00a0 Avanti West Coast
Train restrictions: \u00a0 Avanti West Coast Only
Reservations:
Glasgow Central (08:00) to London Euston (13:38)
5h 38min\u00a0\u00a0\u00a0\u00a0Avanti West Coast
Coach:\u00a0J
Seat:\u00a011
Window, Table seat, Near toilet, Power socket, Near luggage rack, Forward facing, Window view, Individual
Coach:\u00a0J
Seat:\u00a08
Window, Table seat, Near toilet, Backward facing, Power socket, Near luggage rack, Window view, Individual
Fare breakdown:
Adult
£135.00
Adult
£135.00
Options & delivery:
2 Adults
Your e-ticket(s) are attached.
Booking reference: \u00a0 30482716
Payment method : Debit or credit card
Credit card used : VISA\u00a0 400000******0000
Payment summary
Train ticket
£270.00
Total
£270.00

Seat Reservations
You can now book or change your seat reservations online via your account.


Change of plans?
If you travel plans change, you can amend your tickets online via your account.


Delay Repay
The easiest way to sign up for Automatic Delay Repay is by opting in via your account. Then, if you're delayed by 15 minutes or more, a claim will automatically be created for you.


Need a refund?
If you need to claim a refund, the quickest way to apply is only via your account.


Frequently Asked Questions
Got a query for us? Here's the best place to start.

First Trenitalia West Coast Rail Limited. (Company number 10349442)
Registered Office: 8th Floor, The Point, 37 North Wharf Road, London, W2 1AF
Contact us | Terms and conditions | Privacy policy
''';

/// A Singapore Airlines redemption confirmation as its HTML reads as text,
/// every personal detail made up: "SQ308" without a space, an "Airbus
/// A380-800" under it, each airport code followed by its time and then a
/// date line without a year ("13 Jul (Mon)"), and the flight again as "SQ
/// 308 SIN - LHR".
const _sqRedemptionReal = '''
This is an automatically generated message. Please do not reply to this address.
Your redemption booking is confirmed
Booking Reference\u00a0KQ7T4P
Singapore Airlines
spacing
Dear\u00a0MR\u00a0Sam Lee,
You're all set for your trip! This email has all the details of your redemption booking on singaporeair.com, and your e-ticket and receipt are attached. Remember to print these, or be sure you have easy access to them when you travel.
spacing
spacing
spacing 20
spacing
Manage booking
spacing 20
Select / Change seats and meals, update passenger details, and more. As 2FA is enabled, a One-Time Password (OTP) will be required for verification when accessing passenger details, change booking, or cancel it.
spacing
spacing 20
spacing
View KrisFlyer account
spacing 20
Find out how many KrisFlyer miles you have and view the details of your account activities.
spacing
Itinerary
Flight
Departs
Arrives
1. Singapore to London - Total travel time:\u00a0 13hrs 45mins
Status: Confirmed
SQ308
Airbus A380-800
Singapore Airlines
SIN 09:00
13 Jul (Mon)
Singapore, Changi , Terminal 3
LHR 15:45
13 Jul (Mon)
London, Heathrow , Terminal 2
Flying time:\u00a013hrs 45mins
Cabin class: Premium Economy (P)
spacing
Passenger
> Visa requirements
Flights
Seats
Baggage
1.
MR SAM LEE
Membership no: 8812345670
SQ 308 SIN - LHR
No seats selected
Free:\u00a035\u00a0kg
spacing
Hertz
Travel advisories
Always check the latest advisories for your destinations before you fly. As entry restrictions and other requirements may change at short notice, you may wish to subscribe to email updates .
plus
spacing
Travel Guard
Added selected coverage for epidemic and pandemic diseases, including Covid-19. Terms and conditions apply.
Checked
spacing
MIX MILES AND CASH
Pss
Enjoy extra legroom with a Extra Legroom Seat.If you're a KrisFlyer member, you can now pay for Extra Legroom Seats with your miles.
Checked
spacing
Baggages
Checking in more bags? You can buy additional baggage allowance, even before arriving at the airport.
Checked
spacing
icon-hotel.com
Choose from over 1.2 million stays worldwide, and earn 3 KrisFlyer miles for every USD 1 spent.
plus
spacing
Rental cars
Off on a road trip? Or just getting from A to B? A wide range of vehicles is available with our partner.
plus
spacing
Hertz
Pre-order exclusive products at duty-free prices on KrisShop Online, and collect them on board when you fly with us.
plus
spacing
KrisFlyer miles redeemed
74,500 miles
Paid with debit/credit card
SGD 65.20
Card details
SAM LEE
Visa Card
XXXX-XXXX-XXXX-0000
Cost breakdown
Miles
Total miles
74,500
SGD
Airport/Government taxes
65.20
Total cost
65.20
To view the full cost breakdown, download your E-ticket (in PDF format, attached to this email).
spacing
spacing
Additional information
Valid travel documents
Each passenger must hold a valid passport (and visa(s), if required) to be allowed entry into each destination on the flight itinerary. Singapore Airlines cannot be held responsible if a passenger is denied entry and/or deported by any local authority.
Privacy Policy
The information you give us is protected by our privacy policy. However, in some circumstances, government regulations may require us to provide information or permit access to our passenger/customer data.
Overbooking of flights for tickets sold in the USA
Airline flights may be overbooked, and there is a slight chance that a seat will not be available on a flight for which a person has a confirmed reservation. If the flight is overbooked, no one will be denied a seat until airline personnel first ask for volunteers willing to give up their reservation in exchange for compensation of the airline's choosing. If there are not enough volunteers, the airline will deny boarding to other persons in accordance with its particular boarding priority. With few exceptions, including failure to comply with the carrier's check-in deadline (which are available upon request from the air carrier), persons denied boarding involuntarily are entitled to compensation. The complete rules for the payment of compensation and each airline's boarding priorities are available at all airport ticket counters and boarding locations. Some airlines do not apply these consumer protections to travel from some foreign countries, although other consumer protections may be available. Check with your airline or your ticket agent.
spacing
Changes to your redemption booking
If you make a change to your redemption booking (such as change of itinerary, travel date, and/or passenger name) through KrisFlyer Membership Services, or a Singapore Airlines reservations or ticket office, the online redemption booking discount will no longer be applicable.
spacing
Ticket collection
You don't need a printed ticket to fly. However, if you are travelling to and from Colombo, Fukuoka, Manila or the USA, you must present a printed copy of this booking confirmation or your e-ticket receipt to the check-in counter staff at the airport.
spacing
Get the SingaporeAir app to check in and receive the latest flight updates


© 2026 Singapore Airlines. All Rights Reserved. Singapore Co. reg. No. 1972000078R | Privacy Policy
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
        // A boarding pass with no booking reference: the same flight.
        mail(
          'Your boarding pass for SQ 638',
          sender: 'singaporeair.com',
          text:
              'Your flight SQ 638 from Singapore (SIN) to Tokyo (NRT) departs '
              'on 12 Dec at 23:35. Add your boarding pass to your wallet.',
        ),
      ]);
      expect(found, hasLength(2));
      expect(found.first.records, hasLength(3));
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

    test('a table at home is not part of a trip; a concert is no trip', () {
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
      // The concert ticket is an event (the Events page's), not a trip.
      expect(found, hasLength(2));
      expect(found[0].destinations, ['Tokyo']);
      expect(found[0].bookings, hasLength(2));
      expect(found[1].bookings.single.kind, ReservationKind.table);
      expect(found[1].destinations, isEmpty);
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
          'Agoda booking confirmation for Hotel Sakura Terrace Shinjuku '
          '(Booking ID 1234567890)',
          sender: 'agoda.com',
          name: 'Agoda',
          text: '''
Booking ID: 1234567890
Hotel Sakura Terrace Shinjuku
Address: 1-19-1 Kabukicho, Shinjuku-ku, Tokyo 160-8466, Japan
Check-in: Sun, 13 Dec 2026 (after 14:00)
Check-out: Fri, 18 Dec 2026 (before 11:00)
''',
        ),
      ]).single;
      final stay = b.info as LodgingReservationInfo;
      expect(stay.hotel?.name, 'Hotel Sakura Terrace Shinjuku');
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

    test('a hotel named for the city, in a town beside it: that city', () {
      // An airport hotel: London in its name, Hounslow as its town.
      final found = trips([
        mail(
          'Your redemption booking confirmation KQ7T4P',
          sender: 'singaporeair.com',
          text: _sqRedemptionReal,
          daysAgo: 238,
        ),
        mail(
          'Confirmation of your reservation: Airport Inn London Heathrow',
          sender: 'airportinn.example',
          daysAgo: 184,
          html: '''
<script type="application/ld+json">
{"@context": "http://schema.org", "@type": "LodgingReservation",
 "reservationNumber": "QWXRTPLM",
 "reservationStatus": "http://schema.org/ReservationConfirmed",
 "reservationFor": {"@type": "LodgingBusiness",
   "name": "Airport Inn London Heathrow",
   "address": {"@type": "PostalAddress", "streetAddress": "1 Bath Road",
     "addressLocality": "HOUNSLOW", "addressCountry": "GB"}},
 "checkinDate": "2026-07-13", "checkoutDate": "2026-07-15"}
</script>''',
        ),
      ]);
      final trip = found.single;
      expect(trip.destinations, ['London']);
      expect(trip.bookings, hasLength(2));
      // A town the app knows comes first; one it does not, as written.
      expect(
        TripFinder.cityOf(
          const ReservationPlace(name: 'Paris Hotel', locality: 'Las Vegas'),
        ),
        'Las Vegas',
      );
      expect(
        TripFinder.cityOf(
          const ReservationPlace(name: 'Hotel Adler', locality: 'Ortisei'),
        ),
        'Ortisei',
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
          'Your Booking Confirmation: 40871235',
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
      expect(info.reservationNumber, '40871235');
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
          'Ihr ÖBB Ticket – 1234 5678 9012 3456',
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
          'ÖBB ticket – 1234 5678 9012 3456 – Aug 2, 2026',
          sender: 'oebb.at',
          text: _oebbEnglish,
          daysAgo: 162,
        ),
        // The same ticket again, in German: one booking.
        mail(
          'Ihr ÖBB Ticket – 1234 5678 9012 3456',
          sender: 'oebb.at',
          name: 'ÖBB',
          text: _oebbGerman,
          daysAgo: 162,
        ),
      ]);
      final b = found.single;
      expect(b.records, hasLength(2));
      final first = b.infos.first as TransitReservationInfo;
      expect(first.reservationNumber, '1234 5678 9012 3456');
      expect(first.provider, 'ÖBB');
      expect(first.from?.name, 'Wien Hbf');
      expect(first.to?.name, 'Salzburg Hbf');
      expect(first.start?.wall, DateTime.utc(2026, 8, 2, 8, 30));
      expect(first.end?.wall, DateTime.utc(2026, 8, 2, 10, 52));
      expect(b.city, 'Salzburg');
    });

    test('an ÖBB ticket as sent: the code on the next line, a ">" route', () {
      final b = bookings([
        mail(
          'ÖBB ticket – 0428 3315 6092 7781 – Aug 20 2026',
          sender: 'oebb.at',
          text: _oebbReal,
          daysAgo: 163,
        ),
      ]).single;
      final info = b.info as TransitReservationInfo;
      expect(b.kind, ReservationKind.train);
      expect(info.reservationNumber, '0428 3315 6092 7781');
      expect(info.provider, 'ÖBB');
      expect(info.from?.name, 'Zürich HB');
      expect(info.to?.name, 'Bolzano');
      expect(b.start.day, DateTime(2026, 8, 20));
      expect(b.start.hasTime, isFalse);
      expect(b.end, isNull);
      expect(b.fromCity, 'Zurich');
      expect(b.city, 'Bolzano');
      expect(b.cancelled, isFalse);
      expect(TripText.referencesIn(_oebbReal), ['0428 3315 6092 7781']);
    });

    test('an ÖBB ticket: the booking date is not the day of travel', () {
      // Without the day of travel, in the text or the subject, there is
      // no journey: not one on the day it was booked.
      final noDay = _oebbReal.replaceFirst(RegExp('Day of travel: .*'), '');
      expect(
        bookings([
          mail(
            'ÖBB ticket – 0428 3315 6092 7781',
            sender: 'oebb.at',
            text: noDay,
            daysAgo: 163,
          ),
        ]),
        isEmpty,
      );
      // Even right above the route.
      final close = _oebbReal.replaceFirst(
        RegExp(r'Transaction number:[\s\S]*Your PDF Tickets\n'),
        '',
      );
      expect(close, contains('25. May 2026\nZürich HB > Bolzano/Bozen'));
      final b = bookings([
        mail(
          'ÖBB ticket – 0428 3315 6092 7781 – Aug 20 2026',
          sender: 'oebb.at',
          text: close,
          daysAgo: 163,
        ),
      ]).single;
      expect(b.start.day, DateTime(2026, 8, 20));
      expect(
        bookings([
          mail(
            'ÖBB ticket – 0428 3315 6092 7781',
            sender: 'oebb.at',
            text: close.replaceFirst(RegExp('Day of travel: .*'), ''),
            daysAgo: 163,
          ),
        ]),
        isEmpty,
      );
    });

    test(
      'an Avanti West Coast booking as sent: one way, times in brackets',
      () {
        final email = mail(
          'Your Booking Confirmation: 30482716',
          sender: 'avantiwestcoast.co.uk',
          name: 'Avanti West Coast',
          text: _avantiReal,
          daysAgo: 134,
        );
        final b = bookings([email]).single;
        final info = b.info as TransitReservationInfo;
        expect(b.kind, ReservationKind.train);
        expect(info.reservationNumber, '30482716');
        expect(info.provider, 'Avanti West Coast');
        expect(info.from?.name, 'Glasgow Central');
        expect(info.to?.name, 'London Euston');
        expect(b.start.wall, DateTime.utc(2026, 8, 29, 8));
        expect(b.end?.wall, DateTime.utc(2026, 8, 29, 13, 38));
        expect(b.fromCity, 'Glasgow');
        expect(b.city, 'London');

        // Each way of writing the route will do alone: over two lines...
        final twoLines = bookings([
          mail(
            'Your Booking Confirmation: 30482716',
            sender: 'avantiwestcoast.co.uk',
            name: 'Avanti West Coast',
            text: _avantiReal.replaceFirst(
              'Glasgow Central (08:00) to London Euston (13:38)\n',
              '',
            ),
            daysAgo: 134,
          ),
        ]).single;
        expect(twoLines.start.wall, DateTime.utc(2026, 8, 29, 8));
        expect(twoLines.end?.wall, DateTime.utc(2026, 8, 29, 13, 38));
        // ...or with the times in brackets.
        final brackets = bookings([
          mail(
            'Your Booking Confirmation: 30482716',
            sender: 'avantiwestcoast.co.uk',
            name: 'Avanti West Coast',
            text: _avantiReal.replaceFirst(
              'Glasgow Central/Queen St\nto London Euston / Single\n',
              '',
            ),
            daysAgo: 134,
          ),
        ]).single;
        expect(brackets.info.from?.name, 'Glasgow Central');
        expect(brackets.start.wall, DateTime.utc(2026, 8, 29, 8));
        expect(brackets.end?.wall, DateTime.utc(2026, 8, 29, 13, 38));
      },
    );

    test('an Avanti footer about Delay Repay and refunds does not veto', () {
      final email = mail(
        'Your Booking Confirmation: 30482716',
        sender: 'avantiwestcoast.co.uk',
        name: 'Avanti West Coast',
        text: _avantiReal,
        daysAgo: 134,
      );
      expect(_avantiReal, contains('Delay Repay'));
      expect(_avantiReal, contains('Need a refund?'));
      final record = TripFinder.read(email);
      expect(record.cancels, isFalse);
      expect(record.reservations, hasLength(1));
      // In the subject, it is a claim, not a journey.
      expect(
        bookings([
          mail(
            'Your Delay Repay claim',
            sender: 'avantiwestcoast.co.uk',
            name: 'Avanti West Coast',
            text: _avantiReal,
            daysAgo: 134,
          ),
        ]),
        isEmpty,
      );
    });

    test('a flight and two trains: London, Bolzano, then London again', () {
      final found = trips([
        mail(
          'Your redemption booking confirmation KQ7T4P',
          sender: 'singaporeair.com',
          text: _sqRedemptionReal,
          daysAgo: 238,
        ),
        mail(
          'ÖBB ticket – 0428 3315 6092 7781 – Aug 20 2026',
          sender: 'oebb.at',
          text: _oebbReal,
          daysAgo: 163,
        ),
        mail(
          'Your Booking Confirmation: 30482716',
          sender: 'avantiwestcoast.co.uk',
          name: 'Avanti West Coast',
          text: _avantiReal,
          daysAgo: 134,
        ),
      ]);
      expect(found.map((t) => t.destinations), [
        ['London'],
        ['Bolzano'],
        ['London'],
      ]);
      expect(found.map((t) => t.start.day), [
        DateTime(2026, 7, 13),
        DateTime(2026, 8, 20),
        DateTime(2026, 8, 29),
      ]);
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
      // Month first, no comma before the year.
      expect(
        TripText.datesIn('Day of travel: Aug 20 2026', sent).single.day,
        DateTime(2026, 8, 20),
      );
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

    test('a Singapore Airlines redemption as sent: "SQ308", times first', () {
      final found = trips([
        mail(
          'Your redemption booking confirmation KQ7T4P',
          sender: 'singaporeair.com',
          text: _sqRedemptionReal,
          daysAgo: 238,
        ),
      ]);
      final trip = found.single;
      expect(trip.destinations, ['London']);
      final b = trip.bookings.single;
      final info = b.info as FlightReservationInfo;
      expect(info.flightNumber, 'SQ 308');
      expect(info.provider, 'Singapore Airlines');
      expect(info.reservationNumber, 'KQ7T4P');
      expect(info.from?.code, 'SIN');
      expect(info.to?.code, 'LHR');
      // No year: the next 13 July after it was sent, in March.
      expect(info.start?.wall, DateTime.utc(2026, 7, 13, 9));
      expect(info.end?.wall, DateTime.utc(2026, 7, 13, 15, 45));
      expect(b.key, 'f:sq308:2026-07-13');
    });

    test('an aircraft is not a flight: "Airbus A380" is not A3 80', () {
      // Aegean Airlines is A3. Without "-800" after it, and with the
      // table's "Flight" heading close above, A380 reads like its flight
      // 80, by the same route and date.
      final a380 = _sqRedemptionReal
          .replaceFirst('A380-800', 'A380')
          .replaceFirst(RegExp(r'1\. Singapore to London.*\nStatus: .*\n'), '');
      expect(a380, contains('Flight\nDeparts\nArrives\nSQ308\nAirbus A380\n'));
      final sent = _now.subtract(const Duration(days: 238));
      final flights = TripText.flightsIn(a380, sent: sent, reference: 'KQ7T4P');
      expect(flights.map((f) => f.flightNumber), ['SQ 308']);
      // Nor without SQ308 above it.
      expect(
        TripText.flightsIn(
          a380.replaceFirst('SQ308\n', ''),
          sent: sent,
          reference: 'KQ7T4P',
        ).map((f) => f.flightNumber),
        isNot(contains('A3 80')),
      );
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
        name('Harbour Lantern Hotel Kitahama has been booked'),
        'Harbour Lantern Hotel Kitahama',
      );
      expect(
        name(
          'Reservation confirmation: Harbour Lantern Hotel Kitahama has been booked',
        ),
        'Harbour Lantern Hotel Kitahama',
      );
      expect(
        name('Confirmed: Harbour Lantern Hotel Kitahama has been changed'),
        'Harbour Lantern Hotel Kitahama',
      );
      expect(
        name(
          'Booking confirmed at Harbour Lantern Hotel Kitahama is confirmed',
        ),
        'Harbour Lantern Hotel Kitahama',
      );
      expect(
        name(
          'Your reservation has been confirmed',
          sender: 'Harbour Lantern Hotel Kitahama',
        ),
        'Harbour Lantern Hotel Kitahama',
      );
    });

    test('a stay changed to new dates shows once, with the new dates', () {
      final found = bookings([
        mail(
          'Reservation confirmation: Harbour Lantern Hotel Kitahama has been booked',
          sender: 'osakaviewhotel.jp',
          name: 'Harbour Lantern Hotel Kitahama',
          text: _osakaBooked,
          daysAgo: 40,
        ),
        mail(
          'Reservation change: Harbour Lantern Hotel Kitahama has been changed',
          sender: 'osakaviewhotel.jp',
          name: 'Harbour Lantern Hotel Kitahama',
          text: _osakaChanged,
          daysAgo: 2,
        ),
      ]);
      final stay = found.single;
      final info = stay.info as LodgingReservationInfo;
      expect(info.hotel?.name, 'Harbour Lantern Hotel Kitahama');
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
          'Harbour Lantern Hotel Kitahama has been booked',
          sender: 'osakaviewhotel.jp',
          text: _osakaBooked,
          daysAgo: 40,
        ),
        mail(
          'Harbour Lantern Hotel Kitahama has been booked',
          sender: 'osakaviewhotel.jp',
          text: _osakaMoreNights,
          daysAgo: 2,
        ),
      ]);
      expect(found, hasLength(2));
      expect(found.map((b) => (b.info as LodgingReservationInfo).hotel?.name), [
        'Harbour Lantern Hotel Kitahama',
        'Harbour Lantern Hotel Kitahama',
      ]);
      expect(found.map((b) => b.start.day), [
        DateTime(2026, 12, 15),
        DateTime(2026, 12, 21),
      ]);
      expect(found.every((b) => !b.changed), isTrue);
      expect(
        trips([
          mail(
            'Harbour Lantern Hotel Kitahama has been booked',
            sender: 'osakaviewhotel.jp',
            text: _osakaBooked,
            daysAgo: 40,
          ),
          mail(
            'Harbour Lantern Hotel Kitahama has been booked',
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
          'Harbour Lantern Hotel Kitahama has been booked',
          sender: 'osakaviewhotel.jp',
          text: _osakaBooked,
          daysAgo: 40,
        ),
        mail(
          'Reservation change: Harbour Lantern Hotel Kitahama has been changed',
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
          'Booking confirmation - Hotel Kamogawa Station Kyoto',
          sender: 'granviakyoto.com',
          name: 'Hotel Kamogawa Station Kyoto',
          text: '''
Confirmation number: GV-88123
Hotel Kamogawa Station Kyoto, directly above the JR train platforms.
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

  group('rental cars from their words', () {
    test('pick-up and drop-off with the desk on the same line', () {
      final found = bookings([
        mail(
          'Reservation Confirmation: ALEX, your Northwind reservation '
          '#40981234XY1 at Geneva Old Town, GO4 is confirmed',
          sender: 'northwindcars.example',
          name: 'Northwind Car Rental',
          daysAgo: 5,
          text: '''
THANK YOU ALEX.
YOUR RESERVATION IS CONFIRMED
YOUR RESERVATION DETAILS
Reservation #40981234XY1
Vehicle
Compact SUV or Similar Kilometers: Unlimited Automatic Transmission
Itinerary
Pick Up Location
Geneva Old Town,GO4 Sat Dec 12, 2026 at 07:30 AM Rue Exemple 1, Geneva, 1200 CH Mon - Fri 8:00 AM - 6:00 PM
Drop Off Location
Geneva Old Town,GO4 Sun Dec 13, 2026 at 11:30 PM Rue Exemple 1, Geneva, 1200 CH Mon - Fri 8:00 AM - 6:00 PM
Estimated Total: \$331.09
*Additional fees may apply if changes are made to your return date, time and/or location.
Flight Arrival Support
Add your flight details so we can hold your car if you are running late.
''',
        ),
      ]);
      final car = found.single.info as RentalCarReservationInfo;
      expect(found.single.kind, ReservationKind.car);
      expect(car.provider, 'Northwind Car Rental');
      expect(car.reservationNumber, '40981234XY1');
      expect(car.pickupLocation?.name, 'Geneva Old Town');
      expect(car.pickupTime?.wall, DateTime.utc(2026, 12, 12, 7, 30));
      expect(car.dropoffTime?.wall, DateTime.utc(2026, 12, 13, 23, 30));
      expect(found.single.city, 'Geneva');
    });

    test('dates under the labels, the desks further down; a change', () {
      String text(String day) =>
          '''
Thank you ALEX, your reservation has been modified.
CONFIRMATION NUMBER
55512345AB2
PICK UP
$day
DROP OFF
Sun Dec 20, 2026 at 08:00 AM
ESTIMATED TOTAL
\$131.20
PICK UP LOCATION
Edinburgh Waverley Station,EW3
1 Example Street,
Edinburgh, EH1 1AA GB
DROP OFF LOCATION
Edinburgh Waverley Station,EW3
1 Example Street,
''';
      final found = bookings([
        mail(
          'Reservation Confirmation: your reservation #55512345AB2 is '
          'confirmed',
          sender: 'europcar.com',
          name: 'Europcar',
          daysAgo: 20,
          text: text('Sat Dec 19, 2026 at 09:00 AM'),
        ),
        mail(
          'Reservation Modify: your reservation #55512345AB2 has been '
          'modified',
          sender: 'europcar.com',
          name: 'Europcar',
          daysAgo: 2,
          text: text('Sat Dec 19, 2026 at 08:00 AM'),
        ),
      ]);
      final b = found.single;
      expect(b.records, hasLength(2));
      expect(b.changed, isTrue);
      final car = b.info as RentalCarReservationInfo;
      expect(car.pickupLocation?.name, 'Edinburgh Waverley Station');
      expect(car.pickupTime?.wall, DateTime.utc(2026, 12, 19, 8));
      expect(b.previousStart?.wall, DateTime.utc(2026, 12, 19, 9));
      expect(b.city, 'Edinburgh');
    });

    test('a pick-up time in mail that is not about a car', () {
      expect(
        bookings([
          mail(
            'Your order is ready - booking reference QX7T2M',
            sender: 'bakery.example',
            name: 'Corner Bakery',
            text:
                'Booking reference: QX7T2M\nPick up: Sat Dec 12, 2026 at '
                '10:00 AM\nReturn: Sun Dec 13, 2026 at 10:00 AM (the cake '
                'stand)\n',
          ),
        ]),
        isEmpty,
      );
    });
  });

  group('flights laid out other ways', () {
    test('each flight\'s times and airports before its number', () {
      // The flight number comes last in each block, under its details.
      final found = bookings([
        mail(
          'China Airlines Reservation Record',
          sender: 'amadeus.com',
          name: 'China Airlines Group',
          daysAgo: 6,
          text: '''
Your booking is confirmed
Reservation number: QX7T2M
Your Flights
Singapore to Taipei - Thursday, December 10 2026
09:05 SIN
nonstop
13:50 TPE
Duration:4h45m Operated By China Airlines Ltd.
Itinerary Details
09:05 Singapore
CHANGI(SIN)
Terminal 3
13:50 Taipei
TAOYUAN INTL(TPE)
CI 701 Operated By China Airlines Ltd.
BOEING 737-800
Taipei to Singapore - Thursday, December 17 2026
15:20 TPE
nonstop
19:55 SIN
Itinerary Details
15:20 Taipei
TAOYUAN INTL(TPE)
19:55 Singapore
CHANGI(SIN)
CI 702 Operated By China Airlines Ltd.
BOEING 737-800
Passengers and contact
Mr Alex Tan
Seats
Singapore to Taipei
22C
Payment Details
Total Price: SGD 640.00
''',
        ),
      ]);
      expect(found, hasLength(2));
      final [out, back] = [
        for (final b in found) b.info as FlightReservationInfo,
      ];
      expect(out.flightNumber, 'CI 701');
      expect((out.from?.code, out.to?.code), ('SIN', 'TPE'));
      expect(out.start?.wall, DateTime.utc(2026, 12, 10, 9, 5));
      expect(out.end?.wall, DateTime.utc(2026, 12, 10, 13, 50));
      expect(back.flightNumber, 'CI 702');
      expect((back.from?.code, back.to?.code), ('TPE', 'SIN'));
      expect(back.start?.wall, DateTime.utc(2026, 12, 17, 15, 20));
      expect(back.reservationNumber, 'QX7T2M');
    });

    test('the number between the departure and the arrival', () {
      final found = bookings([
        mail(
          'ALEX TAN has shared their trip itinerary with you',
          sender: 'travelagency.example',
          name: 'Example Travel',
          daysAgo: 3,
          text: '''
Trip Itinerary
Wed, Dec 9, 2026
Flight
Depart 9:10 am
Bangkok (BKK)
Cathay Pacific Airways CX 616
Airline reference number: QX7T2M
Agency reference number: PLM4KZ
Arrive 1:05 pm
Hong Kong (HKG)
Mon, Dec 14, 2026
Flight
Depart 3:30 pm
Hong Kong (HKG)
Cathay Pacific Airways CX 617
Airline reference number: QX7T2M
Arrive 6:05 pm
Bangkok (BKK)
Questions?
''',
        ),
      ]);
      expect(found, hasLength(2));
      final [out, back] = [
        for (final b in found) b.info as FlightReservationInfo,
      ];
      expect(out.reservationNumber, 'QX7T2M');
      expect((out.from?.code, out.to?.code), ('BKK', 'HKG'));
      expect(out.start?.wall, DateTime.utc(2026, 12, 9, 9, 10));
      expect(out.end?.wall, DateTime.utc(2026, 12, 9, 13, 5));
      expect((back.from?.code, back.to?.code), ('HKG', 'BKK'));
      expect(back.start?.wall, DateTime.utc(2026, 12, 14, 15, 30));
      expect(back.end?.wall, DateTime.utc(2026, 12, 14, 18, 5));
    });

    test('cities instead of airport codes; times before dates', () {
      final found = bookings([
        mail(
          'Itinerary',
          sender: 'trip.com',
          name: 'Trip.com',
          daysAgo: 4,
          text: '''
Booking No. 1234567890123456
Itinerary
Below you will find a summary of your booking details.
Singapore - Tokyo
Peach · MM705（Economy）
Departure：01:40, December 5, 2026, Singapore Changi Airport T2
Arrival：08:50, December 5, 2026, Narita International Airport T1
Tokyo - Singapore
Peach · MM706（Economy）
Departure：17:25, December 12, 2026, Narita International Airport T1
Arrival：00:20, December 13, 2026, Singapore Changi Airport T2
Passenger Name & Ticket No.
''',
        ),
      ]);
      expect(found, hasLength(2));
      final [out, back] = [
        for (final b in found) b.info as FlightReservationInfo,
      ];
      expect(out.flightNumber, 'MM 705');
      expect(found[0].city, 'Tokyo');
      expect(found[0].fromCity, 'Singapore');
      expect(out.start?.wall, DateTime.utc(2026, 12, 5, 1, 40));
      expect(out.end?.wall, DateTime.utc(2026, 12, 5, 8, 50));
      expect(found[1].city, 'Singapore');
      expect(back.start?.wall, DateTime.utc(2026, 12, 12, 17, 25));
      expect(back.end?.wall, DateTime.utc(2026, 12, 13, 0, 20));
      expect(
        trips([...found.expand((b) => b.records.map((r) => r.email))])
            .single
            .destinations,
        ['Tokyo'],
      );
    });

    test('a boarding pass: full-width colons, year-first dates, '
        'landing before it left', () {
      final found = bookings([
        mail(
          'Your booking is confirmed - QX7T2M',
          sender: 'evaair.com',
          name: 'EVA Air',
          daysAgo: 30,
          text: '''
Booking reference: QX7T2M
Flight BR 8 TPE → SFO
Tue, 8 Dec 2026
Depart 23:40   Arrive 19:35
''',
        ),
        mail(
          'BR008 TAIPEI (TAOYUAN) to SAN FRANCISCO Boarding Pass',
          sender: 'evaair.com',
          name: 'EVA Air',
          daysAgo: 0,
          text: '''
Thank you for flying with EVA Air. You have completed the check-in of the following flight.
Check-in Information： Booking Reference：QX7T2M Name：Tan, Alex
Segment
Flight No.
Departure (Local Time)
Arrival (Local Time)
TAIPEI (TAOYUAN) - SAN FRANCISCO
BR008
Boarding time: 22:50
2026/12/08 23:40
2026/12/08 19:35
''',
        ),
      ]);
      // One flight: "BR008" is "BR 8".
      final b = found.single;
      expect(b.records, hasLength(2));
      final f = b.info as FlightReservationInfo;
      expect(f.flightNumber, 'BR 8');
      expect(f.start?.wall, DateTime.utc(2026, 12, 8, 23, 40));
      // Across the date line it lands on the day it left.
      expect(f.end?.wall, DateTime.utc(2026, 12, 8, 19, 35));
      expect(b.city, 'San Francisco');
    });

    // An agency's confirmation: each leg's heading and departure come
    // before its number, its arrival after it. The way out's window runs
    // on into the way back's heading and departure.
    String straddled({required bool codes}) {
      String airport(String code, String name) => codes ? '$code $name' : name;
      return '''
Airline Booking Reference (PNR): QWE7RT
You can use the airline booking reference to check in online.

Departure: Singapore - Taipei | March 3, 2027
* All departure/arrival times are in local time.
07:10
${airport('SIN', 'Singapore Changi Airport T3')}
Scoot TR 868 | Economy | Airbus A320 | No meals
11:55
${airport('TPE', 'Taipei Taoyuan International Airport T1')}

Return: Taipei - Singapore | March 9, 2027
21:30
${airport('TPE', 'Taipei Taoyuan International Airport T1')}
Scoot TR 869 | Economy | Airbus A320 | No meals
Mar 10
02:05
${airport('SIN', 'Singapore Changi Airport T3')}
View policies and request cancellation & change

ROBIN EXAMPLE
Adult ticket | Date of birth: Jan 2, 1990
''';
    }

    for (final codes in [true, false]) {
      test('each leg\'s times from its own block '
          '(${codes ? 'codes' : 'names only'})', () {
        final found = bookings([
          mail(
            'Your flight booking has been confirmed',
            sender: 'agency.example',
            name: 'Example Agency',
            daysAgo: 4,
            text: straddled(codes: codes),
          ),
        ]);
        expect(found.map((b) => b.key), [
          'f:tr868:2027-03-03',
          'f:tr869:2027-03-09',
        ]);
        final [out, back] = [
          for (final b in found) b.info as FlightReservationInfo,
        ];
        expect(out.start?.wall, DateTime.utc(2027, 3, 3, 7, 10));
        expect(out.end?.wall, DateTime.utc(2027, 3, 3, 11, 55));
        expect(back.start?.wall, DateTime.utc(2027, 3, 9, 21, 30));
        // Its own date, by its arrival time.
        expect(back.end?.wall, DateTime.utc(2027, 3, 10, 2, 5));
        expect(found[0].city, 'Taipei');
        expect(found[1].city, 'Singapore');
        if (codes) {
          expect((out.from?.code, out.to?.code), ('SIN', 'TPE'));
          expect(out.from?.name, 'Singapore Changi Airport');
        }
      });
    }

    String peach({required bool back}) =>
        '''
Thank you for your booking. Please confirm your reservation details.
Airport Check-in
QR code
Booking Reference Number
二次元バーコード
QRT5KW
Please scan your QR code or enter your reservation number at a self check-in kiosk to issue your boarding pass.
Flight Information
Booking date 2027/01/10 (Sun) 11:02
Out bound
MM215(A320)
Departure
Arrival
Osaka (Kansai)
2027/02/06 (Sat) 10:05
Terminal 1

Taipei
2027/02/06 (Sat) 12:20
Terminal 1
Fare Type
Standard
${back ? '''
Return
MM216(A320)
Departure
Arrival
Taipei
2027/02/11 (Thu) 13:30
Terminal 1

Osaka (Kansai)
2027/02/11 (Thu) 17:10
Terminal 1
Fare Type
Standard
''' : ''}Passenger
DOE JANE (Adult)
We look forward to seeing you onboard.
''';

    test('an airline\'s own layout: places over their times', () {
      final found = bookings([
        mail(
          '【Peach】 Your Peach Reservation',
          sender: 'flypeach.com',
          name: 'Peach',
          daysAgo: 2,
          text: peach(back: false),
        ),
      ]);
      final f = found.single.info as FlightReservationInfo;
      expect(found.single.key, 'f:mm215:2027-02-06');
      expect(f.reservationNumber, 'QRT5KW');
      expect(f.provider, 'Peach');
      expect(f.start?.wall, DateTime.utc(2027, 2, 6, 10, 5));
      expect(f.end?.wall, DateTime.utc(2027, 2, 6, 12, 20));
      expect(found.single.fromCity, 'Osaka');
      expect(found.single.city, 'Taipei');
    });

    test('that layout out and back: each leg its own places', () {
      final found = bookings([
        mail(
          '【Peach】 Your Peach Reservation',
          sender: 'flypeach.com',
          name: 'Peach',
          daysAgo: 2,
          text: peach(back: true),
        ),
      ]);
      expect(found.map((b) => b.key), [
        'f:mm215:2027-02-06',
        'f:mm216:2027-02-11',
      ]);
      final back = found[1];
      expect(back.fromCity, 'Taipei');
      expect(back.city, 'Osaka');
      expect(back.start.wall, DateTime.utc(2027, 2, 11, 13, 30));
      expect(back.end?.wall, DateTime.utc(2027, 2, 11, 17, 10));
      expect(back.reference, 'QRT5KW');
    });

    TripEmail flight(String day, String departs, String arrives) => mail(
      'Your booking confirmation',
      sender: 'jetstar.com',
      name: 'Jetstar Asia',
      daysAgo: 5,
      text:
          '''
Booking reference: QWE7RT
Flight 3K 521
Singapore (SIN) to Taipei (TPE)
Depart: $day, $departs
Arrive: $arrives
''',
    );

    test('a flight leaving when the same flight lands is a misread', () {
      final found = bookings([
        flight('3 Mar 2027', '07:10', '11:55'),
        // Its arrival read as a departure, and the next leg's time.
        flight('9 Mar 2027', '11:55', '21:30'),
      ]);
      expect(found.map((b) => b.key), ['f:3k521:2027-03-03']);
    });

    test('the same flight on other days at its own times is kept', () {
      final found = bookings([
        flight('3 Mar 2027', '07:10', '11:55'),
        flight('9 Mar 2027', '07:10', '11:55'),
      ]);
      expect(found.map((b) => b.key), [
        'f:3k521:2027-03-03',
        'f:3k521:2027-03-09',
      ]);
    });
  });

  group('events are not trips', () {
    test('a ticket for a tour or a show, with markup', () {
      final found = bookings([
        mail(
          'Your tickets for the Old Town Chocolate Tour',
          sender: 'tickets.example',
          html: '''
<script type="application/ld+json">
{"@type": "EventReservation", "reservationNumber": "QX7T2M",
 "reservationFor": {"@type": "Event", "name": "Old Town Chocolate Tour",
   "startDate": "2026-12-05T10:00:00+01:00",
   "location": {"@type": "Place", "name": "Main Square",
     "address": {"@type": "PostalAddress", "addressLocality": "Brussels"}}}}
</script>''',
          text: 'Booking reference: QX7T2M. See you on 5 Dec 2026 at 10:00.',
        ),
      ]);
      expect(found, isEmpty);
    });
  });
}
