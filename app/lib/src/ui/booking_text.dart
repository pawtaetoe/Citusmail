// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_view/mail_view.dart';

import 'app_icons.dart';

/// How bookings and trips read on the Trips pages. Times are the clock
/// times at the place, as the booking gives them.
abstract final class BookingText {
  static const _months = [
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
  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  static IconData icon(ReservationKind kind) => switch (kind) {
    ReservationKind.flight => AppIcons.flight,
    ReservationKind.stay => AppIcons.stay,
    ReservationKind.train => AppIcons.train,
    ReservationKind.bus => AppIcons.bus,
    ReservationKind.car => AppIcons.car,
    ReservationKind.table => AppIcons.table,
    ReservationKind.event => AppIcons.ticket,
  };

  /// "Flight to Tokyo", "Park Hotel Shinjuku", "Table at Burnt Ends".
  static String title(Booking b) {
    final info = b.info;
    final to = b.city ?? info.to?.label;
    return switch (info) {
      FlightReservationInfo() => to == null ? 'Flight' : 'Flight to $to',
      TransitReservationInfo(:final kind) =>
        '${kind == ReservationKind.train ? 'Train' : 'Bus'}'
            '${to == null ? '' : ' to $to'}',
      LodgingReservationInfo(:final hotel) => hotel?.name ?? 'Stay',
      RentalCarReservationInfo(:final provider) =>
        provider == null ? 'Rental car' : 'Car from $provider',
      FoodEstablishmentReservationInfo(:final restaurant) =>
        restaurant?.name == null ? 'Table' : 'Table at ${restaurant!.name}',
      EventReservationInfo(:final eventName) => eventName ?? 'Event',
    };
  }

  /// "Tokyo", "Tokyo and Kyoto", else its first booking's title.
  static String tripTitle(Trip t) => switch (t.destinations) {
    [] => title(t.bookings.first),
    [final one] => one,
    [final a, final b] => '$a and $b',
    [final a, final b, final c] => '$a, $b and $c',
    [final a, final b, ...final rest] => '$a, $b and ${rest.length} more',
  };

  /// "Singapore Changi (SIN)", "SIN", "Burnt Ends".
  static String place(ReservationPlace p) => switch ((p.name, p.code)) {
    (final n?, final c?) when n.toUpperCase() != c => '$n ($c)',
    (final n?, _) => n,
    (_, final c?) => c,
    _ => p.address ?? '',
  };

  /// "Sat 12 Dec", with the year when it is not [now]'s.
  static String day(DateTime d, {DateTime? now}) {
    final year = (now ?? DateTime.now()).year;
    return '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}'
        '${d.year == year ? '' : ' ${d.year}'}';
  }

  /// "12–18 Dec", "30 Dec – 3 Jan", "Sat 12 Dec" for one day.
  static String range(DateTime from, DateTime to, {DateTime? now}) {
    final year = (now ?? DateTime.now()).year;
    final y = to.year == year ? '' : ' ${to.year}';
    String dm(DateTime d) => '${d.day} ${_months[d.month - 1]}';
    if (from.year == to.year && from.month == to.month) {
      return from.day == to.day
          ? day(from, now: now)
          : '${from.day}–${dm(to)}$y';
    }
    final fy = from.year == to.year ? '' : ' ${from.year}';
    return '${dm(from)}$fy – ${dm(to)}$y';
  }

  /// "23:35" or "11:35 PM", as the device shows times; "UTC" added when
  /// the booking gave it in UTC. Empty for a date alone.
  static String time(BuildContext context, PlaceTime t) {
    if (!t.hasTime) return '';
    final text = MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay(hour: t.wall.hour, minute: t.wall.minute),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    return t.utcWritten ? '$text UTC' : text;
  }

  /// "Sat 12 Dec · 23:35".
  static String when(BuildContext context, PlaceTime t) =>
      [day(t.day), if (t.hasTime) time(context, t)].join(' · ');

  /// The line under a booking's title: what, from where to where.
  static String detail(BuildContext context, Booking b) {
    final info = b.info;
    String at(ReservationPlace? p, PlaceTime? t) => [
      ?(p?.code ?? p?.name),
      if (t != null && t.hasTime) time(context, t),
    ].join(' ');
    final arrow = '${at(info.from, info.start)} → ${at(info.to, info.end)}';
    // Arriving the next day: "+1", as timetables write it.
    final days = info.end == null || info.start == null
        ? 0
        : info.end!.day.difference(b.start.day).inDays;
    final nextDay = days > 0 ? ' +$days' : '';
    return switch (info) {
      FlightReservationInfo(:final flightNumber) => [
        ?flightNumber,
        if (info.from != null && info.to != null) '$arrow$nextDay',
      ].join(' · '),
      TransitReservationInfo(:final name, :final number) => [
        if ([?name, ?number].join(' ') case final n when n.isNotEmpty) n,
        if (info.from != null && info.to != null) '$arrow$nextDay',
      ].join(' · '),
      LodgingReservationInfo(:final checkout) => [
        ?b.city,
        if (checkout != null) _nights(b.start.day, checkout.day),
      ].join(' · '),
      RentalCarReservationInfo(:final pickupLocation, :final dropoffTime) => [
        ?pickupLocation?.label,
        if (dropoffTime != null) _days(b.start.day, dropoffTime.day),
      ].join(' · '),
      FoodEstablishmentReservationInfo(:final partySize) => [
        if (partySize != null)
          '$partySize ${partySize == 1 ? 'person' : 'people'}',
        ?b.city,
      ].join(' · '),
      EventReservationInfo(:final venue) => [
        ?venue?.label,
        ?b.city,
      ].join(' · '),
    };
  }

  static String _nights(DateTime from, DateTime to) {
    final n = to.difference(from).inDays;
    return n == 1 ? '1 night' : '$n nights';
  }

  static String _days(DateTime from, DateTime to) {
    final n = to.difference(from).inDays;
    return n <= 1 ? '1 day' : '$n days';
  }
}

/// A booking as a calendar event (an .ics file for the user's own
/// calendar app): its title, times, place and reference.
abstract final class BookingCalendar {
  static const prodId = '-//Citusmail//Trips//EN';

  /// The iCalendar text for [b]. [now] stamps it.
  static String ics(Booking b, {required DateTime now}) {
    final info = b.info;
    final start = b.start;
    final end = b.end;
    final out = ICalWriter()
      ..line('BEGIN:VCALENDAR')
      ..line('PRODID:$prodId')
      ..line('VERSION:2.0')
      ..line('CALSCALE:GREGORIAN')
      ..line('METHOD:PUBLISH')
      ..line('BEGIN:VEVENT')
      ..line('UID:${_uid(b.key)}@trips.citusmail')
      ..line('DTSTAMP:${CalendarTime.formatUtc(now)}');
    if (!start.hasTime) {
      final last = end == null || end.day == start.day
          ? start.day.add(const Duration(days: 1))
          : end.day;
      out
        ..line('DTSTART;VALUE=DATE:${_date(start.day)}')
        ..line('DTEND;VALUE=DATE:${_date(last)}');
    } else {
      out.line('DTSTART:${_time(start)}');
      if (end != null && end.hasTime && end.compareTo(start) > 0) {
        out.line('DTEND:${_time(end)}');
      } else {
        out.line(
          b.kind == ReservationKind.table || b.kind == ReservationKind.event
              ? 'DURATION:PT2H'
              : 'DURATION:PT1H',
        );
      }
    }
    out.line('SUMMARY:${ICalText.escape(_summary(b))}');
    final where = switch (info) {
      LodgingReservationInfo(:final hotel) => [
        ?hotel?.name,
        ?hotel?.address,
      ].join(', '),
      _ => [?info.from?.label, ?info.from?.address].join(', '),
    };
    if (where.isNotEmpty) out.line('LOCATION:${ICalText.escape(where)}');
    final notes = [
      if (b.reference case final r?) 'Booking reference: $r',
      if (b.provider case final p?) 'Booked with: $p',
      if (b.underName case final n?) 'Name: $n',
      if (info.to case final to? when to.label != null)
        'To: ${BookingText.place(to)}',
    ];
    if (notes.isNotEmpty) {
      out.line('DESCRIPTION:${ICalText.escape(notes.join('\n'))}');
    }
    if (b.cancelled) out.line('STATUS:CANCELLED');
    out
      ..line('END:VEVENT')
      ..line('END:VCALENDAR');
    return out.toString();
  }

  /// [b] as an event to hand to the calendar app.
  static CalendarInvite? invite(Booking b, {required DateTime now}) =>
      CalendarInvite.parse(ics(b, now: now));

  static String _summary(Booking b) => switch (b.info) {
    FlightReservationInfo(:final flightNumber) =>
      '${BookingText.title(b)}${flightNumber == null ? '' : ' ($flightNumber)'}',
    _ => BookingText.title(b),
  };

  /// UTC with an offset, else floating (the clock time wherever it is).
  static String _time(PlaceTime t) {
    if (t.offset != null) return CalendarTime.formatUtc(t.instant);
    String two(int n) => n.toString().padLeft(2, '0');
    final w = t.wall;
    return '${_date(w)}T${two(w.hour)}${two(w.minute)}00';
  }

  static String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}'
      '${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

  static String _uid(String key) =>
      key.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '-');
}
