// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_view/mail_view.dart';

import '../mail/appointments_model.dart' show localTime;
import 'booking_text.dart';

/// How appointments read on the Appointments pages. Times are in the
/// user's own time zone when the email gives an exact moment, else as
/// written (an appointment is where you are).
abstract final class AppointmentWords {
  static IconData icon(AppointmentKind kind) => switch (kind) {
    AppointmentKind.health => Icons.medical_services_outlined,
    AppointmentKind.beauty => Icons.content_cut,
    AppointmentKind.car => Icons.car_repair_outlined,
    AppointmentKind.home => Icons.home_repair_service_outlined,
    AppointmentKind.official => Icons.account_balance_outlined,
    AppointmentKind.interview => Icons.work_outline,
    AppointmentKind.school => Icons.school_outlined,
    AppointmentKind.lesson => Icons.self_improvement_outlined,
    AppointmentKind.delivery => Icons.local_shipping_outlined,
    AppointmentKind.other => Icons.event_outlined,
  };

  /// [t] on this device's clock.
  static DateTime local(PlaceTime t) => localTime(t);

  /// "3:30 PM" or "15:30", as the device shows times. Empty for a date
  /// alone.
  static String time(BuildContext context, PlaceTime t) {
    if (!t.hasTime) return '';
    final l = local(t);
    return MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay(hour: l.hour, minute: l.minute),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
  }

  /// "Tue 12 Nov", with the year when it is not [now]'s.
  static String date(PlaceTime t, {required DateTime now}) {
    final l = local(t);
    return BookingText.day(DateTime(l.year, l.month, l.day), now: now);
  }

  /// "Today", "Tomorrow", else "Tue 12 Nov" (with the year when it is not
  /// this one's).
  static String day(PlaceTime t, {required DateTime now}) {
    final l = local(t);
    final d = DateTime(l.year, l.month, l.day);
    final today = DateTime(now.year, now.month, now.day);
    return switch (DateTime.utc(
      d.year,
      d.month,
      d.day,
    ).difference(DateTime.utc(today.year, today.month, today.day)).inDays) {
      0 => 'Today',
      1 => 'Tomorrow',
      _ => BookingText.day(d, now: now),
    };
  }

  /// "Tue 12 Nov · 3:30 PM", "Tomorrow · 11:00 AM".
  static String when(
    BuildContext context,
    PlaceTime t, {
    required DateTime now,
  }) => [day(t, now: now), if (t.hasTime) time(context, t)].join(' · ');

  /// "3:30 – 4:15 PM" style: start and end times, when the end is known.
  static String hours(BuildContext context, Appointment a) {
    final end = a.end;
    if (!a.start.hasTime) return 'All day';
    if (end == null || !end.hasTime || end.compareTo(a.start) <= 0) {
      return time(context, a.start);
    }
    return '${time(context, a.start)} – ${time(context, end)}';
  }

  /// The line under an appointment's title: what it is for, and where.
  static String detail(Appointment a) =>
      [?a.service, if (a.online) 'Online' else ?_short(a.place)].join(' · ');

  /// The first part of an address ("14 High Street").
  static String? _short(String? place) {
    if (place == null) return null;
    final first = place.split(',').first.trim();
    return first.length < 4 ? place : first;
  }

  /// "Booked with Fresha", for one booked through a booking site.
  static String? bookedWith(Appointment a) {
    final r = a.records.first.email;
    if (!AppointmentFinder.bookingSites.contains(r.sender)) return null;
    return r.senderName ?? r.sender;
  }
}

/// An appointment as a calendar event (an .ics file for the user's own
/// calendar app): its title, time, place and booking reference.
abstract final class AppointmentCalendar {
  static const prodId = '-//Citusmail//Appointments//EN';

  /// The iCalendar text for [a]. [now] stamps it.
  static String ics(Appointment a, {required DateTime now}) {
    final start = a.start;
    final end = a.end;
    final out = ICalWriter()
      ..line('BEGIN:VCALENDAR')
      ..line('PRODID:$prodId')
      ..line('VERSION:2.0')
      ..line('CALSCALE:GREGORIAN')
      ..line('METHOD:PUBLISH')
      ..line('BEGIN:VEVENT')
      ..line('UID:${_uid(a.key)}@appointments.citusmail')
      ..line('DTSTAMP:${CalendarTime.formatUtc(now)}');
    if (!start.hasTime) {
      out
        ..line('DTSTART;VALUE=DATE:${_date(start.day)}')
        ..line(
          'DTEND;VALUE=DATE:${_date(start.day.add(const Duration(days: 1)))}',
        );
    } else {
      out.line('DTSTART:${_time(start)}');
      if (end != null && end.hasTime && end.compareTo(start) > 0) {
        out.line('DTEND:${_time(end)}');
      } else {
        out.line('DURATION:PT1H');
      }
    }
    out.line('SUMMARY:${ICalText.escape(summary(a))}');
    final where = a.online ? 'Online' : a.place;
    if (where != null) out.line('LOCATION:${ICalText.escape(where)}');
    final notes = [
      if (a.reference case final r?) 'Booking reference: $r',
      if (a.service case final s? when a.business != null) s,
    ];
    if (notes.isNotEmpty) {
      out.line('DESCRIPTION:${ICalText.escape(notes.join('\n'))}');
    }
    if (a.cancelled) out.line('STATUS:CANCELLED');
    out
      ..line('END:VEVENT')
      ..line('END:VCALENDAR');
    return out.toString();
  }

  /// "Scale and polish at Bright Smile Dental", else the title.
  static String summary(Appointment a) => switch ((a.service, a.business)) {
    (final s?, final b?) => '$s at $b',
    _ => a.title,
  };

  /// [a] as an event to hand to the calendar app.
  static CalendarInvite? invite(Appointment a, {required DateTime now}) =>
      CalendarInvite.parse(ics(a, now: now));

  /// UTC for an exact moment, else floating (the clock time wherever it
  /// is).
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
