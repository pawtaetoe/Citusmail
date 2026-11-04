// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'schema_org.dart';

/// A date and time as a booking writes it: the clock time at the place
/// (a flight leaving Singapore at 23:35 is 23:35 there, wherever the
/// reader is), and the UTC offset when one is given.
final class PlaceTime implements Comparable<PlaceTime> {
  PlaceTime(
    int year,
    int month,
    int day, {
    int hour = 0,
    int minute = 0,
    this.hasTime = true,
    this.offset,
    this.utcWritten = false,
  }) : wall = DateTime.utc(year, month, day, hour, minute);

  /// The clock time at the place, as written. Its fields are what to
  /// show; it is a UTC [DateTime] only so nothing converts it.
  final DateTime wall;

  /// False for a date alone ("2026-12-12").
  final bool hasTime;

  /// The UTC offset written with it (`+08:00`), if any.
  final Duration? offset;

  /// Written as UTC (`Z`): the time is not the place's own.
  final bool utcWritten;

  /// The moment it stands for: exact with an offset, else read as this
  /// device's local time (close enough to sort and group).
  DateTime get instant => switch (offset) {
    final o? => wall.subtract(o),
    null => DateTime(wall.year, wall.month, wall.day, wall.hour, wall.minute),
  };

  /// The day at the place.
  DateTime get day => DateTime(wall.year, wall.month, wall.day);

  static final _iso = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})'
    r'(?:[T ](\d{2}):(\d{2})(?::\d{2}(?:\.\d+)?)?\s*(Z|[+-]\d{2}:?\d{2})?)?$',
    caseSensitive: false,
  );

  /// An ISO 8601 date or date and time (`2026-12-12T23:35:00+08:00`),
  /// or null.
  static PlaceTime? parse(String value) {
    final m = _iso.firstMatch(value.trim());
    if (m == null) return null;
    final y = int.parse(m[1]!);
    final mo = int.parse(m[2]!);
    final d = int.parse(m[3]!);
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    if (m[4] == null) return PlaceTime(y, mo, d, hasTime: false);
    final h = int.parse(m[4]!);
    final mi = int.parse(m[5]!);
    if (h > 24 || mi > 59) return null;
    final zone = m[6];
    Duration? offset;
    if (zone != null && zone.toUpperCase() != 'Z') {
      final digits = zone.replaceAll(':', '');
      final sign = digits.startsWith('-') ? -1 : 1;
      offset = Duration(
        hours: sign * int.parse(digits.substring(1, 3)),
        minutes: sign * int.parse(digits.substring(3, 5)),
      );
    }
    return PlaceTime(
      y,
      mo,
      d,
      hour: h,
      minute: mi,
      offset: zone == null ? null : offset ?? Duration.zero,
      utcWritten: zone?.toUpperCase() == 'Z',
    );
  }

  @override
  int compareTo(PlaceTime other) => instant.compareTo(other.instant);

  @override
  bool operator ==(Object other) =>
      other is PlaceTime &&
      other.wall == wall &&
      other.hasTime == hasTime &&
      other.offset == offset;

  @override
  int get hashCode => Object.hash(wall, hasTime, offset);

  @override
  String toString() =>
      '${wall.toIso8601String().substring(0, hasTime ? 16 : 10)}'
      '${offset == null ? '' : ' $offset'}';
}

/// What kind of booking a reservation is.
enum ReservationKind { flight, stay, train, bus, car, table, event }

/// Where a reservation stands, from schema.org `reservationStatus`.
enum ReservationStatus {
  confirmed,
  pending,
  cancelled;

  static ReservationStatus? fromSchema(String value) {
    final v = value.trim();
    final local = v.contains('/') ? v.substring(v.lastIndexOf('/') + 1) : v;
    return switch (local.toLowerCase()) {
      'reservationconfirmed' || 'confirmed' => confirmed,
      'reservationpending' || 'reservationhold' || 'pending' => pending,
      'reservationcancelled' || 'cancelled' || 'canceled' => cancelled,
      _ => null,
    };
  }
}

/// An airport, station, hotel, restaurant or venue.
final class ReservationPlace {
  const ReservationPlace({this.name, this.code, this.address, this.locality});

  final String? name;

  /// An airport's IATA code (`SIN`).
  final String? code;

  /// The postal address as one line.
  final String? address;

  /// Its town or city (`addressLocality`).
  final String? locality;

  /// What to call it: its name, else its code.
  String? get label => name ?? code;

  bool get isEmpty =>
      name == null && code == null && address == null && locality == null;

  /// [thing] (a `Place`, `Airport`, `LodgingBusiness`...) read as a place;
  /// a plain text value is its name.
  static ReservationPlace? from(Object? value) {
    if (value is String) {
      final t = value.trim();
      return t.isEmpty ? null : ReservationPlace(name: t);
    }
    if (value is! SchemaThing) return null;
    final address = value.values('address').firstOrNull;
    final place = ReservationPlace(
      name: value.text('name'),
      code: value.text('iataCode')?.toUpperCase(),
      address: _address(address),
      locality: address is SchemaThing ? address.text('addressLocality') : null,
    );
    return place.isEmpty ? null : place;
  }

  static String? _address(Object? address) {
    if (address is String) return address.trim().isEmpty ? null : address;
    if (address is! SchemaThing) return null;
    final parts = [
      for (final name in const [
        'streetAddress',
        'addressLocality',
        'addressRegion',
        'postalCode',
        'addressCountry',
      ])
        ?address.text(name),
    ];
    return parts.isEmpty ? address.text('name') : parts.join(', ');
  }

  @override
  String toString() => label ?? address ?? '';
}

/// A booking from schema.org reservation markup: a flight, a hotel stay,
/// a train or bus trip, a rental car, a restaurant table or an event
/// ticket. The fields every kind has are here; each kind adds its own.
sealed class ReservationInfo {
  const ReservationInfo({
    this.reservationNumber,
    this.underName,
    this.status,
    this.provider,
    this.url,
  });

  ReservationKind get kind;

  /// The booking reference (PNR, confirmation number).
  final String? reservationNumber;

  /// Who it is for (passenger, guest).
  final String? underName;
  final ReservationStatus? status;

  /// Who provides it: the airline, rail or bus company, rental company,
  /// or the site it was booked on.
  final String? provider;

  /// The booking's page (manage, check in), only when it is `https`.
  final Uri? url;

  /// When it starts: departure, check-in, pick-up, the table, the event.
  PlaceTime? get start;

  /// When it ends: arrival, check-out, drop-off, if known.
  PlaceTime? get end;

  /// Where it starts (departure airport or station, pick-up), or the
  /// place itself for a stay, a table or an event.
  ReservationPlace? get from;

  /// Where it ends (arrival airport or station, drop-off); null for one
  /// place.
  ReservationPlace? get to;

  /// The schema.org types read, by their own name.
  static const types = {
    'FlightReservation',
    'LodgingReservation',
    'TrainReservation',
    'BusReservation',
    'RentalCarReservation',
    'FoodEstablishmentReservation',
    'EventReservation',
  };

  /// [thing] read as a reservation, or null when it isn't one (or says
  /// too little to be shown).
  static ReservationInfo? read(SchemaThing thing) {
    final kind = _kindOf(thing);
    if (kind == null) return null;
    final f = thing.thing('reservationFor');
    final common = (
      number:
          thing.text('reservationNumber') ??
          thing.text('reservationId') ??
          thing.text('confirmationNumber'),
      under: thing.text('underName'),
      status: thing
          .texts('reservationStatus')
          .map(ReservationStatus.fromSchema)
          .nonNulls
          .firstOrNull,
      url:
          thing.httpsUrl('modifyReservationUrl') ??
          thing.httpsUrl('url') ??
          thing.httpsUrl('checkinUrl'),
    );
    String? broker() => thing.text('broker') ?? thing.text('provider');
    switch (kind) {
      case ReservationKind.flight:
        if (f == null) return null;
        final airline = f.thing('airline');
        final code = airline?.text('iataCode')?.toUpperCase();
        final number = f.text('flightNumber')?.replaceAll(' ', '');
        return FlightReservationInfo(
          reservationNumber: common.number,
          underName: common.under,
          status: common.status,
          url: common.url,
          provider: airline?.text('name') ?? f.text('airline') ?? broker(),
          flightNumber: switch (number) {
            null => null,
            // "638" with airline SQ is SQ 638.
            final n when code != null && RegExp(r'^\d+$').hasMatch(n) =>
              '$code $n',
            final n => FlightReservationInfo.spaced(n),
          },
          airlineCode: code,
          departureAirport: ReservationPlace.from(
            f.values('departureAirport').firstOrNull,
          ),
          arrivalAirport: ReservationPlace.from(
            f.values('arrivalAirport').firstOrNull,
          ),
          departureTime: _time(f, 'departureTime'),
          arrivalTime: _time(f, 'arrivalTime'),
          departureTerminal: f.text('departureTerminal'),
          departureGate: f.text('departureGate'),
          arrivalTerminal: f.text('arrivalTerminal'),
          seat: thing.text('airplaneSeat') ?? _seat(thing),
          ticketNumber: _ticketNumber(thing),
        );
      case ReservationKind.stay:
        if (f == null) return null;
        return LodgingReservationInfo(
          reservationNumber: common.number,
          underName: common.under,
          status: common.status,
          url: common.url,
          provider: broker(),
          hotel: ReservationPlace.from(f),
          checkin: _time(thing, 'checkinTime') ?? _time(thing, 'checkinDate'),
          checkout:
              _time(thing, 'checkoutTime') ?? _time(thing, 'checkoutDate'),
          room: thing.text('lodgingUnitDescription'),
          telephone: f.text('telephone'),
        );
      case ReservationKind.train || ReservationKind.bus:
        if (f == null) return null;
        final train = kind == ReservationKind.train;
        String? text(String trainName, String busName) =>
            f.text(train ? trainName : busName);
        Object? place(List<String> names) =>
            names.map((n) => f.values(n).firstOrNull).nonNulls.firstOrNull;
        return TransitReservationInfo(
          kind: kind,
          reservationNumber: common.number,
          underName: common.under,
          status: common.status,
          url: common.url,
          provider:
              f.text('provider') ??
              text('trainCompany', 'busCompany') ??
              broker(),
          number: text('trainNumber', 'busNumber'),
          name: text('trainName', 'busName'),
          departureStation: ReservationPlace.from(
            place(
              train
                  ? const ['departureStation']
                  : const ['departureBusStop', 'departureStation'],
            ),
          ),
          arrivalStation: ReservationPlace.from(
            place(
              train
                  ? const ['arrivalStation']
                  : const ['arrivalBusStop', 'arrivalStation'],
            ),
          ),
          departureTime: _time(f, 'departureTime'),
          arrivalTime: _time(f, 'arrivalTime'),
          platform: f.text('departurePlatform'),
          seat: _seat(thing),
          ticketNumber: _ticketNumber(thing),
        );
      case ReservationKind.car:
        final car = f;
        return RentalCarReservationInfo(
          reservationNumber: common.number,
          underName: common.under,
          status: common.status,
          url: common.url,
          provider:
              thing.text('provider') ??
              car?.text('rentalCompany') ??
              car?.thing('brand')?.text('name') ??
              thing.text('broker'),
          car: car?.text('name') ?? car?.text('model'),
          pickupLocation: ReservationPlace.from(
            thing.values('pickupLocation').firstOrNull,
          ),
          pickupTime: _time(thing, 'pickupTime'),
          dropoffLocation: ReservationPlace.from(
            thing.values('dropoffLocation').firstOrNull,
          ),
          dropoffTime: _time(thing, 'dropoffTime'),
        );
      case ReservationKind.table:
        if (f == null) return null;
        return FoodEstablishmentReservationInfo(
          reservationNumber: common.number,
          underName: common.under,
          status: common.status,
          url: common.url,
          provider: broker(),
          restaurant: ReservationPlace.from(f),
          startTime: _time(thing, 'startTime') ?? _time(thing, 'startDate'),
          endTime: _time(thing, 'endTime'),
          partySize: int.tryParse(
            (thing.text('partySize') ?? '').replaceAll(RegExp(r'\.0+$'), ''),
          ),
        );
      case ReservationKind.event:
        if (f == null) return null;
        final location = f.values('location').firstOrNull;
        return EventReservationInfo(
          reservationNumber: common.number,
          underName: common.under,
          status: common.status,
          url: common.url,
          provider: broker(),
          eventName: f.text('name'),
          startDate: _time(f, 'startDate') ?? _time(thing, 'startTime'),
          endDate: _time(f, 'endDate'),
          venue: ReservationPlace.from(location),
          ticketNumber: _ticketNumber(thing),
          seat: _seat(thing),
        );
    }
  }

  /// Every reservation in [things], nested ones too (several flights in a
  /// `subReservation`, an `@graph`).
  static List<ReservationInfo> allIn(List<SchemaThing> things) {
    final found = <ReservationInfo>[];
    final stack = [...things.reversed];
    final seen = <SchemaThing>{};
    while (stack.isNotEmpty && seen.length < 1000) {
      final t = stack.removeLast();
      if (!seen.add(t)) continue;
      if (read(t) case final r?) found.add(r);
      for (final values in t.properties.values.toList().reversed) {
        stack.addAll(values.whereType<SchemaThing>().toList().reversed);
      }
    }
    return found;
  }

  static ReservationKind? _kindOf(SchemaThing thing) {
    if (thing.isA('FlightReservation')) return ReservationKind.flight;
    if (thing.isA('LodgingReservation')) return ReservationKind.stay;
    if (thing.isA('TrainReservation')) return ReservationKind.train;
    if (thing.isA('BusReservation')) return ReservationKind.bus;
    if (thing.isA('RentalCarReservation')) return ReservationKind.car;
    if (thing.isA('FoodEstablishmentReservation')) return ReservationKind.table;
    if (thing.isA('EventReservation')) return ReservationKind.event;
    // A plain Reservation, by what it is for.
    if (!thing.isA('Reservation')) return null;
    final f = thing.thing('reservationFor');
    if (f == null) return null;
    if (f.isA('Flight')) return ReservationKind.flight;
    if (f.isAny(const ['LodgingBusiness', 'Hotel', 'Motel', 'Hostel'])) {
      return ReservationKind.stay;
    }
    if (f.isA('TrainTrip')) return ReservationKind.train;
    if (f.isA('BusTrip')) return ReservationKind.bus;
    if (f.isAny(const ['FoodEstablishment', 'Restaurant'])) {
      return ReservationKind.table;
    }
    if (f.types.any((t) => t.endsWith('Event'))) return ReservationKind.event;
    return null;
  }

  static PlaceTime? _time(SchemaThing thing, String name) {
    for (final v in thing.texts(name)) {
      if (PlaceTime.parse(v) case final t?) return t;
    }
    return null;
  }

  /// `reservedTicket.ticketNumber`, or the reservation's own.
  static String? _ticketNumber(SchemaThing thing) =>
      thing.thing('reservedTicket')?.text('ticketNumber') ??
      thing.text('ticketNumber');

  /// `reservedTicket.ticketedSeat`: "Coach 7, seat 12A" style.
  static String? _seat(SchemaThing thing) {
    final ticket = thing.thing('reservedTicket');
    final seat = ticket?.thing('ticketedSeat');
    if (seat == null) return ticket?.text('ticketedSeat');
    final parts = [
      if (seat.text('seatSection') case final s?) 'Section $s',
      if (seat.text('seatRow') case final r?) 'Row $r',
      if (seat.text('seatNumber') case final n?) 'Seat $n',
    ];
    return parts.isEmpty ? null : parts.join(', ');
  }
}

/// A flight segment. A return trip is two of these with one reference.
final class FlightReservationInfo extends ReservationInfo {
  const FlightReservationInfo({
    super.reservationNumber,
    super.underName,
    super.status,
    super.provider,
    super.url,
    this.flightNumber,
    this.airlineCode,
    this.departureAirport,
    this.arrivalAirport,
    this.departureTime,
    this.arrivalTime,
    this.departureTerminal,
    this.departureGate,
    this.arrivalTerminal,
    this.seat,
    this.ticketNumber,
  });

  @override
  ReservationKind get kind => ReservationKind.flight;

  /// "SQ 638".
  final String? flightNumber;

  /// The airline's IATA code (`SQ`); its name is [provider].
  final String? airlineCode;
  final ReservationPlace? departureAirport;
  final ReservationPlace? arrivalAirport;
  final PlaceTime? departureTime;
  final PlaceTime? arrivalTime;
  final String? departureTerminal;
  final String? departureGate;
  final String? arrivalTerminal;
  final String? seat;
  final String? ticketNumber;

  @override
  PlaceTime? get start => departureTime;
  @override
  PlaceTime? get end => arrivalTime;
  @override
  ReservationPlace? get from => departureAirport;
  @override
  ReservationPlace? get to => arrivalAirport;

  /// "SQ638" -> "SQ 638"; anything else as it is.
  static String spaced(String number) {
    final m = RegExp(r'^([A-Z]{2}|[A-Z]\d|\d[A-Z])\s*(\d{1,4}[A-Z]?)$')
        .firstMatch(number.toUpperCase().trim());
    return m == null ? number.trim() : '${m[1]} ${m[2]}';
  }
}

/// A hotel (or other lodging) stay.
final class LodgingReservationInfo extends ReservationInfo {
  const LodgingReservationInfo({
    super.reservationNumber,
    super.underName,
    super.status,
    super.provider,
    super.url,
    this.hotel,
    this.checkin,
    this.checkout,
    this.room,
    this.telephone,
  });

  @override
  ReservationKind get kind => ReservationKind.stay;

  /// Its name and address.
  final ReservationPlace? hotel;
  final PlaceTime? checkin;
  final PlaceTime? checkout;

  /// The room booked ("Superior Double Room").
  final String? room;
  final String? telephone;

  @override
  PlaceTime? get start => checkin;
  @override
  PlaceTime? get end => checkout;
  @override
  ReservationPlace? get from => hotel;
  @override
  ReservationPlace? get to => null;
}

/// A train or bus trip ([kind] says which).
final class TransitReservationInfo extends ReservationInfo {
  const TransitReservationInfo({
    required this.kind,
    super.reservationNumber,
    super.underName,
    super.status,
    super.provider,
    super.url,
    this.number,
    this.name,
    this.departureStation,
    this.arrivalStation,
    this.departureTime,
    this.arrivalTime,
    this.platform,
    this.seat,
    this.ticketNumber,
  });

  @override
  final ReservationKind kind;

  /// The train or bus number ("ICE 1003").
  final String? number;

  /// Its name ("Nozomi").
  final String? name;
  final ReservationPlace? departureStation;
  final ReservationPlace? arrivalStation;
  final PlaceTime? departureTime;
  final PlaceTime? arrivalTime;
  final String? platform;
  final String? seat;
  final String? ticketNumber;

  @override
  PlaceTime? get start => departureTime;
  @override
  PlaceTime? get end => arrivalTime;
  @override
  ReservationPlace? get from => departureStation;
  @override
  ReservationPlace? get to => arrivalStation;
}

/// A rental car, from pick-up to drop-off.
final class RentalCarReservationInfo extends ReservationInfo {
  const RentalCarReservationInfo({
    super.reservationNumber,
    super.underName,
    super.status,
    super.provider,
    super.url,
    this.car,
    this.pickupLocation,
    this.pickupTime,
    this.dropoffLocation,
    this.dropoffTime,
  });

  @override
  ReservationKind get kind => ReservationKind.car;

  /// The car ("Toyota Corolla or similar").
  final String? car;
  final ReservationPlace? pickupLocation;
  final PlaceTime? pickupTime;
  final ReservationPlace? dropoffLocation;
  final PlaceTime? dropoffTime;

  @override
  PlaceTime? get start => pickupTime;
  @override
  PlaceTime? get end => dropoffTime;
  @override
  ReservationPlace? get from => pickupLocation;
  @override
  ReservationPlace? get to => dropoffLocation;
}

/// A table at a restaurant.
final class FoodEstablishmentReservationInfo extends ReservationInfo {
  const FoodEstablishmentReservationInfo({
    super.reservationNumber,
    super.underName,
    super.status,
    super.provider,
    super.url,
    this.restaurant,
    this.startTime,
    this.endTime,
    this.partySize,
  });

  @override
  ReservationKind get kind => ReservationKind.table;

  final ReservationPlace? restaurant;
  final PlaceTime? startTime;
  final PlaceTime? endTime;

  /// How many people.
  final int? partySize;

  @override
  PlaceTime? get start => startTime;
  @override
  PlaceTime? get end => endTime;
  @override
  ReservationPlace? get from => restaurant;
  @override
  ReservationPlace? get to => null;
}

/// A ticket for a concert, match, show or other event.
final class EventReservationInfo extends ReservationInfo {
  const EventReservationInfo({
    super.reservationNumber,
    super.underName,
    super.status,
    super.provider,
    super.url,
    this.eventName,
    this.startDate,
    this.endDate,
    this.venue,
    this.ticketNumber,
    this.seat,
  });

  @override
  ReservationKind get kind => ReservationKind.event;

  final String? eventName;
  final PlaceTime? startDate;
  final PlaceTime? endDate;
  final ReservationPlace? venue;
  final String? ticketNumber;
  final String? seat;

  @override
  PlaceTime? get start => startDate;
  @override
  PlaceTime? get end => endDate;
  @override
  ReservationPlace? get from => venue;
  @override
  ReservationPlace? get to => null;
}
