// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_view/mail_view.dart';

import '../../../core/theme/app_icons.dart';
import 'appointment_text.dart';

/// How events read on the Events pages and the calendar. Times are in the
/// user's own time zone when the email gives an exact moment, else as
/// written (a ticket's time is the venue's), as for appointments.
abstract final class EventWords {
  static IconData icon(EventKind kind) => switch (kind) {
    EventKind.tour => AppIcons.tour,
    EventKind.concert => AppIcons.concert,
    EventKind.show => AppIcons.show,
    EventKind.movie => AppIcons.movie,
    EventKind.sport => AppIcons.sport,
    EventKind.festival => AppIcons.festival,
    EventKind.exhibition => AppIcons.exhibition,
    EventKind.workshop => AppIcons.workshop,
    EventKind.meeting => AppIcons.meeting,
    EventKind.interview => AppIcons.interview,
    EventKind.other => AppIcons.ticket,
  };

  /// "Tue 12 Nov · 3:30 PM", "Tomorrow · 7:30 PM".
  static String when(
    BuildContext context,
    PlaceTime t, {
    required DateTime now,
  }) => AppointmentWords.when(context, t, now: now);

  /// "7:30 – 10:00 PM": start and end times, when the end is known.
  static String hours(BuildContext context, Event e) {
    final end = e.end;
    if (!e.start.hasTime) return 'All day';
    final start = AppointmentWords.time(context, e.start);
    if (end == null || !end.hasTime || end.compareTo(e.start) <= 0) {
      return start;
    }
    return '$start – ${AppointmentWords.time(context, end)}';
  }

  /// The line under an event's title: what kind, and where (or online).
  static String detail(Event e) => [
    EventFinder.word(e.kind),
    if (e.online) 'Online' else ?_short(e.venue),
  ].join(' · ');

  /// The first part of an address ("Riverside Arena").
  static String? _short(String? place) {
    if (place == null) return null;
    final first = place.split(',').first.trim();
    return first.length < 4 ? place : first;
  }
}

/// An event as a calendar event (an .ics file for the user's own
/// calendar app): its title, time, venue or link, and reference.
abstract final class EventCalendar {
  static const prodId = '-//Citusmail//Events//EN';

  /// The iCalendar text for [e]. [now] stamps it.
  static String ics(Event e, {required DateTime now}) {
    final start = e.start;
    final end = e.end;
    final out = ICalWriter()
      ..line('BEGIN:VCALENDAR')
      ..line('PRODID:$prodId')
      ..line('VERSION:2.0')
      ..line('CALSCALE:GREGORIAN')
      ..line('METHOD:PUBLISH')
      ..line('BEGIN:VEVENT')
      ..line('UID:${_uid(e.key)}@events.citusmail')
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
        final meeting =
            e.kind == EventKind.meeting || e.kind == EventKind.interview;
        out.line(meeting ? 'DURATION:PT1H' : 'DURATION:PT2H');
      }
    }
    out.line('SUMMARY:${ICalText.escape(e.title)}');
    final where = e.venue ?? e.link?.toString();
    if (where != null) out.line('LOCATION:${ICalText.escape(where)}');
    if (e.link case final l?) out.line('URL:${ICalText.escape(l.toString())}');
    final notes = [
      if (e.reference case final r?) 'Booking reference: $r',
      if (e.link case final l?) 'Join: $l',
    ];
    if (notes.isNotEmpty) {
      out.line('DESCRIPTION:${ICalText.escape(notes.join('\n'))}');
    }
    if (e.cancelled) out.line('STATUS:CANCELLED');
    out
      ..line('END:VEVENT')
      ..line('END:VCALENDAR');
    return out.toString();
  }

  /// [e] as an event to hand to the calendar app.
  static CalendarInvite? invite(Event e, {required DateTime now}) =>
      CalendarInvite.parse(ics(e, now: now));

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
