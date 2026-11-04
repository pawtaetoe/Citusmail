// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_extract/mail_extract.dart';
import 'package:test/test.dart';

/// A return flight in the shape big airlines send: one JSON-LD array, a
/// FlightReservation per segment, the same booking reference.
const _singaporeAirlinesStyle = '''
<html><head>
<script type="application/ld+json">
[
  {
    "@context": "http://schema.org",
    "@type": "FlightReservation",
    "reservationNumber": "XKQZPL",
    "reservationStatus": "http://schema.org/ReservationConfirmed",
    "underName": {"@type": "Person", "name": "Alice Tan"},
    "airplaneSeat": "42A",
    "reservedTicket": {"@type": "Ticket", "ticketNumber": "6182345678901"},
    "modifyReservationUrl": "https://www.singaporeair.com/manage-booking?pnr=XKQZPL",
    "reservationFor": {
      "@type": "Flight",
      "flightNumber": "638",
      "airline": {"@type": "Airline", "name": "Singapore Airlines", "iataCode": "SQ"},
      "departureAirport": {"@type": "Airport", "name": "Singapore Changi", "iataCode": "SIN"},
      "departureTime": "2026-12-12T23:35:00+08:00",
      "departureTerminal": "3",
      "departureGate": "B5",
      "arrivalAirport": {"@type": "Airport", "name": "Tokyo Narita", "iataCode": "NRT"},
      "arrivalTime": "2026-12-13T07:30:00+09:00",
      "arrivalTerminal": "1"
    }
  },
  {
    "@context": "http://schema.org",
    "@type": "FlightReservation",
    "reservationNumber": "XKQZPL",
    "reservationStatus": "http://schema.org/ReservationConfirmed",
    "underName": {"@type": "Person", "name": "Alice Tan"},
    "reservationFor": {
      "@type": "Flight",
      "flightNumber": "SQ637",
      "airline": {"@type": "Airline", "name": "Singapore Airlines", "iataCode": "SQ"},
      "departureAirport": {"@type": "Airport", "name": "Tokyo Narita", "iataCode": "NRT"},
      "departureTime": "2026-12-18T11:15:00+09:00",
      "arrivalAirport": {"@type": "Airport", "name": "Singapore Changi", "iataCode": "SIN"},
      "arrivalTime": "2026-12-18T17:40:00+08:00"
    }
  }
]
</script>
</head><body><p>Your booking is confirmed.</p></body></html>
''';

/// A hotel confirmation with microdata, as some booking sites still send.
const _bookingComStyle = '''
<html><body>
<div itemscope itemtype="http://schema.org/LodgingReservation">
  <meta itemprop="reservationNumber" content="4012345678">
  <link itemprop="reservationStatus" href="http://schema.org/ReservationConfirmed">
  <div itemprop="underName" itemscope itemtype="http://schema.org/Person">
    <meta itemprop="name" content="Alice Tan">
  </div>
  <div itemprop="reservationFor" itemscope itemtype="http://schema.org/LodgingBusiness">
    <h2 itemprop="name">Park Hotel Shinjuku</h2>
    <div itemprop="address" itemscope itemtype="http://schema.org/PostalAddress">
      <span itemprop="streetAddress">3-4-5 Nishi-Shinjuku</span>,
      <span itemprop="addressLocality">Tokyo</span>
      <span itemprop="postalCode">160-0023</span>
      <span itemprop="addressCountry">Japan</span>
    </div>
    <meta itemprop="telephone" content="+81 3 1234 5678">
  </div>
  <p>Check-in: <time itemprop="checkinDate" datetime="2026-12-13T15:00:00+09:00">Sun 13 Dec from 15:00</time></p>
  <p>Check-out: <time itemprop="checkoutDate" datetime="2026-12-18T11:00:00+09:00">Fri 18 Dec until 11:00</time></p>
  <meta itemprop="lodgingUnitDescription" content="Superior Double Room">
  <div itemprop="broker" itemscope itemtype="http://schema.org/Organization">
    <meta itemprop="name" content="Booking.com">
  </div>
  <link itemprop="modifyReservationUrl" href="https://secure.booking.com/myreservations.html">
</div>
<p>Thanks, Alice! Your booking in Tokyo is confirmed.</p>
</body></html>
''';

const _openTableStyle = '''
<script type="application/ld+json">
{
  "@context": "http://schema.org",
  "@type": "FoodEstablishmentReservation",
  "reservationNumber": "OT-118273",
  "reservationStatus": "http://schema.org/Confirmed",
  "underName": {"@type": "Person", "name": "Alice Tan"},
  "provider": {"@type": "Organization", "name": "OpenTable"},
  "startTime": "2026-11-20T19:30:00+08:00",
  "partySize": 4,
  "reservationFor": {
    "@type": "FoodEstablishment",
    "name": "Burnt Ends",
    "address": {
      "@type": "PostalAddress",
      "streetAddress": "7 Dempsey Road, #01-02",
      "addressLocality": "Singapore",
      "postalCode": "249671",
      "addressCountry": "SG"
    },
    "telephone": "+65 6224 3933"
  }
}
</script>
''';

const _eventTicket = '''
<script type="application/ld+json">
{
  "@context": "http://schema.org",
  "@type": "EventReservation",
  "reservationNumber": "38-12345/SGP",
  "reservationStatus": "http://schema.org/ReservationConfirmed",
  "underName": {"@type": "Person", "name": "Alice Tan"},
  "reservedTicket": {
    "@type": "Ticket",
    "ticketNumber": "SGP-0042-7781",
    "ticketedSeat": {"@type": "Seat", "seatSection": "PA2", "seatRow": "K", "seatNumber": "21"}
  },
  "reservationFor": {
    "@type": "MusicEvent",
    "name": "Coldplay: Music of the Spheres World Tour",
    "startDate": "2027-01-23T19:30:00+08:00",
    "location": {
      "@type": "Place",
      "name": "National Stadium",
      "address": {"@type": "PostalAddress", "streetAddress": "1 Stadium Drive", "addressLocality": "Singapore", "addressCountry": "SG"}
    }
  }
}
</script>
''';

const _trainBusCar = '''
<script type="application/ld+json">
{"@context": "http://schema.org", "@graph": [
  {
    "@type": "TrainReservation",
    "reservationNumber": "JR7781",
    "reservedTicket": {"@type": "Ticket", "ticketedSeat": {"@type": "Seat", "seatSection": "7", "seatNumber": "12A"}},
    "reservationFor": {
      "@type": "TrainTrip",
      "trainNumber": "225",
      "trainName": "Nozomi",
      "provider": {"@type": "Organization", "name": "JR Central"},
      "departureStation": {"@type": "TrainStation", "name": "Tokyo"},
      "departureTime": "2026-12-15T09:00:00+09:00",
      "departurePlatform": "18",
      "arrivalStation": {"@type": "TrainStation", "name": "Kyoto"},
      "arrivalTime": "2026-12-15T11:15:00+09:00"
    }
  },
  {
    "@type": "BusReservation",
    "reservationNumber": "FLX 2381 7764",
    "reservationFor": {
      "@type": "BusTrip",
      "busNumber": "N 112",
      "provider": "FlixBus",
      "departureBusStop": {"@type": "BusStop", "name": "Berlin ZOB"},
      "departureTime": "2027-03-02T08:15:00+01:00",
      "arrivalBusStop": {"@type": "BusStop", "name": "Hamburg ZOB"},
      "arrivalTime": "2027-03-02T11:30:00+01:00"
    }
  },
  {
    "@type": "RentalCarReservation",
    "reservationNumber": "H8271635",
    "provider": {"@type": "Organization", "name": "Hertz"},
    "reservationFor": {"@type": "Car", "name": "Toyota Corolla or similar", "brand": {"@type": "Brand", "name": "Toyota"}},
    "pickupLocation": {"@type": "Place", "name": "Hertz Kahului Airport", "address": {"@type": "PostalAddress", "addressLocality": "Kahului", "addressRegion": "HI"}},
    "pickupTime": "2027-02-10T10:00:00-10:00",
    "dropoffLocation": {"@type": "Place", "name": "Hertz Kahului Airport"},
    "dropoffTime": "2027-02-14T10:00:00-10:00"
  }
]}
</script>
''';

void main() {
  group('PlaceTime', () {
    test('keeps the clock time at the place and its offset', () {
      final t = PlaceTime.parse('2026-12-12T23:35:00+08:00')!;
      expect(t.wall.hour, 23);
      expect(t.wall.minute, 35);
      expect(t.offset, const Duration(hours: 8));
      expect(t.instant, DateTime.utc(2026, 12, 12, 15, 35));
      expect(t.day, DateTime(2026, 12, 12));
    });

    test('negative offsets, UTC and dates alone', () {
      expect(
        PlaceTime.parse('2027-02-10T10:00-10:00')!.instant,
        DateTime.utc(2027, 2, 10, 20),
      );
      final z = PlaceTime.parse('2026-12-12T15:35:00Z')!;
      expect(z.utcWritten, isTrue);
      expect(z.offset, Duration.zero);
      final d = PlaceTime.parse('2026-12-13')!;
      expect(d.hasTime, isFalse);
      expect(d.offset, isNull);
      expect(PlaceTime.parse('13 Dec 2026'), isNull);
      expect(PlaceTime.parse('2026-13-01'), isNull);
    });

    test('without an offset, the moment is read as local time', () {
      final t = PlaceTime.parse('2026-12-12T23:35')!;
      expect(t.offset, isNull);
      expect(t.instant, DateTime(2026, 12, 12, 23, 35));
    });
  });

  group('flights', () {
    test('a Singapore Airlines-style return flight: two segments', () {
      final things = StructuredData.extract(_singaporeAirlinesStyle);
      final r = ReservationInfo.allIn(things);
      expect(r, hasLength(2));
      final out = r[0] as FlightReservationInfo;
      expect(out.kind, ReservationKind.flight);
      expect(out.reservationNumber, 'XKQZPL');
      expect(out.status, ReservationStatus.confirmed);
      expect(out.underName, 'Alice Tan');
      expect(out.flightNumber, 'SQ 638');
      expect(out.provider, 'Singapore Airlines');
      expect(out.airlineCode, 'SQ');
      expect(out.departureAirport?.code, 'SIN');
      expect(out.departureAirport?.name, 'Singapore Changi');
      expect(out.arrivalAirport?.code, 'NRT');
      expect(out.departureTime?.wall.hour, 23);
      expect(out.arrivalTime?.offset, const Duration(hours: 9));
      expect(out.departureTerminal, '3');
      expect(out.departureGate, 'B5');
      expect(out.arrivalTerminal, '1');
      expect(out.seat, '42A');
      expect(out.ticketNumber, '6182345678901');
      expect(out.url?.host, 'www.singaporeair.com');
      final back = r[1] as FlightReservationInfo;
      expect(back.flightNumber, 'SQ 637', reason: '"SQ637" spaced');
      expect(back.from?.code, 'NRT');
      expect(back.to?.code, 'SIN');
      expect(back.start!.compareTo(out.start!), greaterThan(0));
    });

    test('a plain Reservation for a Flight, and other links', () {
      final r = ReservationInfo.allIn(
        StructuredData.extract('''
<script type="application/ld+json">
{"@type": "Reservation", "reservationId": "ABC123",
 "url": "javascript:alert(1)",
 "reservationFor": {"@type": "Flight", "flightNumber": "TR 2",
   "departureAirport": "SIN", "arrivalAirport": "TPE",
   "departureTime": "2026-12-01T06:00:00+08:00"}}
</script>'''),
      ).single;
      expect(r, isA<FlightReservationInfo>());
      expect((r as FlightReservationInfo).flightNumber, 'TR 2');
      expect(r.reservationNumber, 'ABC123');
      expect(r.from?.name, 'SIN');
      expect(r.url, isNull, reason: 'only https');
    });

    test('a cancelled segment', () {
      final r = ReservationInfo.allIn(
        StructuredData.extract('''
<script type="application/ld+json">
{"@type": "FlightReservation", "reservationNumber": "XKQZPL",
 "reservationStatus": "http://schema.org/ReservationCancelled",
 "reservationFor": {"@type": "Flight", "flightNumber": "638",
   "airline": {"@type": "Airline", "iataCode": "SQ"},
   "departureTime": "2026-12-12T23:35:00+08:00"}}
</script>'''),
      ).single;
      expect(r.status, ReservationStatus.cancelled);
    });
  });

  test('a Booking.com-style hotel in microdata', () {
    final r = ReservationInfo.allIn(StructuredData.extract(_bookingComStyle));
    final stay = r.single as LodgingReservationInfo;
    expect(stay.kind, ReservationKind.stay);
    expect(stay.reservationNumber, '4012345678');
    expect(stay.hotel?.name, 'Park Hotel Shinjuku');
    expect(stay.hotel?.locality, 'Tokyo');
    expect(stay.hotel?.address, '3-4-5 Nishi-Shinjuku, Tokyo, 160-0023, Japan');
    expect(stay.checkin?.wall, DateTime.utc(2026, 12, 13, 15));
    expect(stay.checkout?.wall, DateTime.utc(2026, 12, 18, 11));
    expect(stay.room, 'Superior Double Room');
    expect(stay.provider, 'Booking.com');
    expect(stay.telephone, '+81 3 1234 5678');
    expect(stay.underName, 'Alice Tan');
    expect(stay.url?.host, 'secure.booking.com');
  });

  test('an OpenTable-style table', () {
    final r = ReservationInfo.allIn(StructuredData.extract(_openTableStyle));
    final table = r.single as FoodEstablishmentReservationInfo;
    expect(table.kind, ReservationKind.table);
    expect(table.restaurant?.name, 'Burnt Ends');
    expect(table.restaurant?.locality, 'Singapore');
    expect(table.partySize, 4);
    expect(table.startTime?.wall.hour, 19);
    expect(table.provider, 'OpenTable');
    expect(table.status, ReservationStatus.confirmed);
  });

  test('an event ticket with its seat', () {
    final r = ReservationInfo.allIn(StructuredData.extract(_eventTicket));
    final e = r.single as EventReservationInfo;
    expect(e.kind, ReservationKind.event);
    expect(e.eventName, 'Coldplay: Music of the Spheres World Tour');
    expect(e.venue?.name, 'National Stadium');
    expect(e.venue?.locality, 'Singapore');
    expect(e.ticketNumber, 'SGP-0042-7781');
    expect(e.seat, 'Section PA2, Row K, Seat 21');
    expect(e.startDate?.instant, DateTime.utc(2027, 1, 23, 11, 30));
  });

  test('a train, a bus and a rental car in one @graph', () {
    final r = ReservationInfo.allIn(StructuredData.extract(_trainBusCar));
    expect(r.map((x) => x.kind), [
      ReservationKind.train,
      ReservationKind.bus,
      ReservationKind.car,
    ]);
    final train = r[0] as TransitReservationInfo;
    expect(train.number, '225');
    expect(train.name, 'Nozomi');
    expect(train.provider, 'JR Central');
    expect(train.from?.name, 'Tokyo');
    expect(train.to?.name, 'Kyoto');
    expect(train.platform, '18');
    expect(train.seat, 'Section 7, Seat 12A');
    final bus = r[1] as TransitReservationInfo;
    expect(bus.number, 'N 112');
    expect(bus.provider, 'FlixBus');
    expect(bus.from?.name, 'Berlin ZOB');
    expect(bus.end?.wall.hour, 11);
    final car = r[2] as RentalCarReservationInfo;
    expect(car.provider, 'Hertz');
    expect(car.car, 'Toyota Corolla or similar');
    expect(car.pickupLocation?.locality, 'Kahului');
    expect(car.pickupTime?.offset, const Duration(hours: -10));
    expect(car.dropoffTime?.wall.day, 14);
  });

  test('not reservations: orders, parcels, a bare Flight', () {
    expect(
      ReservationInfo.allIn(
        StructuredData.extract('''
<script type="application/ld+json">
[{"@type": "Order", "orderNumber": "1"},
 {"@type": "Flight", "flightNumber": "SQ 638"},
 {"@type": "FlightReservation", "reservationNumber": "NOFLIGHT"}]
</script>'''),
      ),
      isEmpty,
    );
  });
}
