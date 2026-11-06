// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'reservations.dart';
import 'schema_org.dart';

/// An appointment from schema.org markup: a `ServiceReservation` (a
/// dentist, a salon, a car service), a plain `Reservation` for something
/// that is not travel, a table or a ticket, or an `Event` such as a class.
///
/// Flights, stays, trains, buses, rental cars, tables and event tickets
/// are [ReservationInfo]s (the Trips page), never these.
final class AppointmentInfo {
  const AppointmentInfo({
    this.name,
    this.provider,
    this.start,
    this.end,
    this.place,
    this.online = false,
    this.reservationNumber,
    this.underName,
    this.status,
    this.url,
    this.isEvent = false,
  });

  /// What it is for: the service or class ("Scale and polish").
  final String? name;

  /// Who provides it: the clinic, salon, garage, school.
  final String? provider;
  final PlaceTime? start;
  final PlaceTime? end;

  /// Where it is.
  final ReservationPlace? place;

  /// It happens online (a video call).
  final bool online;

  /// The booking reference.
  final String? reservationNumber;

  /// Who it is for.
  final String? underName;
  final ReservationStatus? status;

  /// The booking's page (manage, reschedule), only when it is `https`.
  final Uri? url;

  /// Read from an `Event` rather than a reservation.
  final bool isEvent;

  /// Event types read as appointments: a plain event, a class, a course
  /// session. Concerts, matches and shows are tickets (Trips) and are left
  /// out.
  static const eventTypes = {'Event', 'EducationEvent', 'CourseInstance'};

  /// [thing] read as an appointment, or null when it isn't one (or has no
  /// start).
  static AppointmentInfo? read(SchemaThing thing) {
    if (thing.isA('ServiceReservation') ||
        (thing.isA('Reservation') && ReservationInfo.read(thing) == null)) {
      return _reservation(thing);
    }
    if (thing.isAny(eventTypes)) return _event(thing);
    return null;
  }

  static AppointmentInfo? _reservation(SchemaThing thing) {
    final f = thing.thing('reservationFor');
    // A reservation for a flight, a hotel, a table... with too little to
    // be read as one is still not an appointment.
    if (f != null && _travelOrTicket(f)) return null;
    final start =
        _time(thing, 'startTime') ??
        _time(thing, 'startDate') ??
        (f == null ? null : _time(f, 'startDate') ?? _time(f, 'startTime'));
    if (start == null) return null;
    final provider =
        thing.thing('provider') ??
        f?.thing('provider') ??
        thing.thing('broker');
    final providerName =
        thing.text('provider') ?? f?.text('provider') ?? thing.text('broker');
    // The place: where it says, else the business itself when it has an
    // address.
    final location =
        thing.values('location').firstOrNull ??
        f?.values('location').firstOrNull ??
        (f != null && f.values('address').isNotEmpty ? f : null) ??
        (provider != null && provider.values('address').isNotEmpty
            ? provider
            : null);
    return AppointmentInfo(
      name: f?.text('name') ?? f?.text('serviceType'),
      provider: providerName,
      start: start,
      end:
          _time(thing, 'endTime') ??
          _time(thing, 'endDate') ??
          (f == null ? null : _time(f, 'endDate') ?? _time(f, 'endTime')),
      place: _online(location) ? null : ReservationPlace.from(location),
      online: _online(location) || (f != null && _onlineMode(f)),
      reservationNumber:
          thing.text('reservationNumber') ??
          thing.text('reservationId') ??
          thing.text('confirmationNumber'),
      underName: thing.text('underName'),
      status: thing
          .texts('reservationStatus')
          .map(ReservationStatus.fromSchema)
          .nonNulls
          .firstOrNull,
      url: thing.httpsUrl('modifyReservationUrl') ?? thing.httpsUrl('url'),
    );
  }

  static AppointmentInfo? _event(SchemaThing thing) {
    final start = _time(thing, 'startDate') ?? _time(thing, 'startTime');
    if (start == null) return null;
    final location = thing.values('location').firstOrNull;
    final cancelled = thing
        .texts('eventStatus')
        .any((s) => s.toLowerCase().endsWith('eventcancelled'));
    return AppointmentInfo(
      name: thing.text('name'),
      provider: thing.text('organizer') ?? thing.text('provider'),
      start: start,
      end: _time(thing, 'endDate') ?? _time(thing, 'endTime'),
      place: _online(location) ? null : ReservationPlace.from(location),
      online: _online(location) || _onlineMode(thing),
      status: cancelled ? ReservationStatus.cancelled : null,
      url: thing.httpsUrl('url'),
      isEvent: true,
    );
  }

  /// Every appointment in [things], nested ones too (in an `@graph`, an
  /// order). What a flight, stay, table or ticket holds is never read: an
  /// event inside an `EventReservation` is a ticket.
  static List<AppointmentInfo> allIn(List<SchemaThing> things) {
    final found = <AppointmentInfo>[];
    final stack = [...things.reversed];
    final seen = <SchemaThing>{};
    while (stack.isNotEmpty && seen.length < 1000) {
      final t = stack.removeLast();
      if (!seen.add(t)) continue;
      if (_travelOrTicket(t) || ReservationInfo.read(t) != null) continue;
      if (read(t) case final a?) {
        found.add(a);
        continue;
      }
      for (final values in t.properties.values.toList().reversed) {
        stack.addAll(values.whereType<SchemaThing>().toList().reversed);
      }
    }
    return found;
  }

  /// Reservations and things the Trips page reads.
  static bool _travelOrTicket(SchemaThing t) =>
      t.isAny(ReservationInfo.types) ||
      t.isAny(const [
        'Flight',
        'TrainTrip',
        'BusTrip',
        'LodgingBusiness',
        'Hotel',
        'FoodEstablishment',
        'Restaurant',
      ]) ||
      // Concerts, matches, shows: tickets.
      (t.types.any((type) => type.endsWith('Event')) && !t.isAny(eventTypes));

  static bool _online(Object? location) =>
      location is SchemaThing && location.isA('VirtualLocation');

  static bool _onlineMode(SchemaThing thing) => thing
      .texts('eventAttendanceMode')
      .any((m) => m.toLowerCase().endsWith('onlineeventattendancemode'));

  static PlaceTime? _time(SchemaThing thing, String name) {
    for (final v in thing.texts(name)) {
      if (PlaceTime.parse(v) case final t?) return t;
    }
    return null;
  }

  @override
  String toString() => 'AppointmentInfo($name, $provider, $start)';
}
