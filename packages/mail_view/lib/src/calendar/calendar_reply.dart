// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'calendar_invite.dart';
import 'calendar_time.dart';
import 'ical.dart';

/// Builds the iTIP REPLY (RFC 5546 3.2.3) an attendee sends the organizer
/// to accept, decline or tentatively accept an invitation: the event's
/// UID, SEQUENCE, ORGANIZER and times, and only the replying attendee,
/// with their answer.
abstract final class CalendarReply {
  static const prodId = '-//Citusmail//Calendar reply//EN';

  /// The iCalendar text. [attendee] is the user's own ATTENDEE from
  /// [invite]. [comment] is an optional note to the organizer.
  static String build(
    CalendarInvite invite, {
    required CalendarPerson attendee,
    required CalendarAnswer answer,
    required DateTime now,
    String? comment,
  }) {
    final event = invite.event;
    final out = ICalWriter()
      ..line('BEGIN:VCALENDAR')
      ..line('PRODID:$prodId')
      ..line('VERSION:2.0')
      ..line('CALSCALE:GREGORIAN')
      ..line('METHOD:REPLY');
    // The time zones the copied times refer to.
    final zones = {
      for (final name in const ['DTSTART', 'DTEND', 'RECURRENCE-ID'])
        ?event.property(name)?.parameter('TZID'),
    };
    for (final zone in invite.calendar.components('VTIMEZONE')) {
      if (zones.contains(zone.property('TZID')?.value.trim())) zone.write(out);
    }
    out
      ..line('BEGIN:VEVENT')
      ..line('UID:${_single(invite.uid)}')
      ..line('SEQUENCE:${invite.sequence}')
      ..line('DTSTAMP:${CalendarTime.formatUtc(now)}');
    for (final name in const [
      'RECURRENCE-ID',
      'DTSTART',
      'DTEND',
      'DURATION',
      'SUMMARY',
      'LOCATION',
      'ORGANIZER',
    ]) {
      if (event.property(name) case final p?) out.line(p.line);
    }
    final parameters = <String, String>{
      for (final MapEntry(:key, :value) in attendee.property.parameters.entries)
        if (key != 'PARTSTAT' && key != 'RSVP' && key != 'X-NUM-GUESTS')
          key: value,
      'PARTSTAT': answer.token,
    };
    out.line(attendee.property.withParameters(parameters).line);
    final note = comment?.trim();
    if (note != null && note.isNotEmpty) {
      out.line('COMMENT:${ICalText.escape(note)}');
    }
    out
      ..line('END:VEVENT')
      ..line('END:VCALENDAR');
    return out.toString();
  }

  static String _single(String value) =>
      value.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '');
}
