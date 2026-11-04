// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'calendar_time.dart';
import 'ical.dart';
import 'time_zones.dart';

/// What a calendar message is for (iTIP, RFC 5546).
enum CalendarMethod {
  /// An invitation, or an update to one.
  request,

  /// The organizer cancelled the event.
  cancel,

  /// An attendee's answer to the user's invitation.
  reply,

  /// An event to add, with nothing to answer.
  publish,

  /// Anything else (COUNTER, REFRESH, ADD...).
  other;

  static CalendarMethod parse(String? value) =>
      switch (value?.trim().toUpperCase()) {
        'REQUEST' => request,
        'CANCEL' => cancel,
        'REPLY' => reply,
        'PUBLISH' || null || '' => publish,
        _ => other,
      };
}

/// How someone answered (PARTSTAT).
enum CalendarAnswer {
  accepted('ACCEPTED'),
  tentative('TENTATIVE'),
  declined('DECLINED'),
  needsAction('NEEDS-ACTION'),
  delegated('DELEGATED');

  const CalendarAnswer(this.token);

  /// As written in iCalendar.
  final String token;

  static CalendarAnswer? parse(String? value) {
    final upper = value?.trim().toUpperCase();
    for (final answer in values) {
      if (answer.token == upper) return answer;
    }
    return null;
  }
}

/// An ORGANIZER or ATTENDEE.
final class CalendarPerson {
  CalendarPerson._(this.property, this.email, this.name);

  /// Null unless the value is a `mailto:` address.
  static CalendarPerson? read(ICalProperty property) {
    final value = property.value.trim();
    final m = RegExp(r'^mailto:(.+)$', caseSensitive: false).firstMatch(value);
    String? email;
    if (m != null) {
      email = Uri.decodeComponent(m.group(1)!.trim())
          .replaceAll(RegExp(r'[\s<>"]'), '');
      if (!RegExp(r'^[^@]+@[^@]+$').hasMatch(email)) email = null;
    }
    final name = property.parameter('CN')?.trim();
    if (email == null && (name == null || name.isEmpty)) return null;
    return CalendarPerson._(
      property,
      email,
      name == null || name.isEmpty || name == email ? null : name,
    );
  }

  /// As written in the file (to answer with).
  final ICalProperty property;

  /// The address, or null if the file gave none.
  final String? email;

  /// The display name (CN), if any.
  final String? name;

  CalendarAnswer? get answer =>
      CalendarAnswer.parse(property.parameter('PARTSTAT'));

  /// The organizer asked for an answer.
  bool get rsvp => property.parameter('RSVP')?.toUpperCase() == 'TRUE';

  /// A meeting room or other resource, not a person.
  bool get isResource {
    final type = property.parameter('CUTYPE')?.toUpperCase();
    return type == 'ROOM' || type == 'RESOURCE';
  }

  /// The name, else the address.
  String get label => name ?? email ?? '';

  /// [label] without the domain, for short lines ("Ana accepted").
  String get shortLabel {
    final n = name;
    if (n != null) return n.split(RegExp(r'\s+')).first;
    return email?.split('@').first ?? '';
  }
}

/// A calendar event sent by mail: an invitation, a cancellation or an
/// answer. Read from the message's text/calendar part (or .ics file).
final class CalendarInvite {
  CalendarInvite._({
    required this.method,
    required this.text,
    required this.calendar,
    required this.event,
    required this.zones,
    required this.start,
    required this.end,
    required this.organizer,
    required this.attendees,
    required this.meetingLink,
  });

  /// Longest description kept (the rest is in the message body anyway).
  static const maxDescription = 400;

  /// Reads [text]. Null when it holds no event (or isn't iCalendar).
  static CalendarInvite? parse(String text, {String? methodHint}) {
    final roots = const ICalParser().parse(text);
    final calendar = roots.where((c) => c.name == 'VCALENDAR').firstOrNull;
    if (calendar == null) return null;
    final events = calendar.components('VEVENT').toList();
    if (events.isEmpty) return null;
    // The series itself rather than one changed occurrence.
    final event =
        events.where((e) => e.property('RECURRENCE-ID') == null).firstOrNull ??
        events.first;
    final zones = CalendarTimeZones(calendar.components('VTIMEZONE'));
    final startProperty = event.property('DTSTART');
    final start = startProperty == null
        ? null
        : CalendarTime.parse(startProperty, zones);
    CalendarTime? end;
    if (event.property('DTEND') case final p?) {
      end = CalendarTime.parse(p, zones);
    } else if (event.property('DURATION') case final p? when start != null) {
      final duration = CalendarTime.parseDuration(p.value);
      if (duration != null && !duration.isNegative) end = start.plus(duration);
    } else if (start != null && start.allDay) {
      end = start.plus(const Duration(days: 1));
    }
    // An end before the start is a broken file: ignore the end.
    if (start != null && end != null && end.wall.isBefore(start.wall)) {
      end = null;
    }
    final method = calendar.property('METHOD')?.value ?? methodHint;
    return CalendarInvite._(
      method: CalendarMethod.parse(method),
      text: text,
      calendar: calendar,
      event: event,
      zones: zones,
      start: start,
      end: end,
      organizer: switch (event.property('ORGANIZER')) {
        final p? => CalendarPerson.read(p),
        null => null,
      },
      attendees: List.unmodifiable([
        for (final p in event.all('ATTENDEE').take(2000))
          ?CalendarPerson.read(p),
      ]),
      meetingLink: _meetingLink(event),
    );
  }

  final CalendarMethod method;

  /// The whole iCalendar text, to save as an .ics file.
  final String text;

  /// The VCALENDAR and the VEVENT shown (for answering).
  final ICalComponent calendar;
  final ICalComponent event;
  final CalendarTimeZones zones;

  final CalendarTime? start;

  /// Exclusive: an all-day event on the 12th ends on the 13th.
  final CalendarTime? end;

  final CalendarPerson? organizer;
  final List<CalendarPerson> attendees;

  /// A Teams, Zoom, Meet... link to join, if the event has one.
  final Uri? meetingLink;

  String? _text(String name) {
    final value = event.property(name)?.text.trim();
    return value == null || value.isEmpty ? null : value;
  }

  String get uid => event.property('UID')?.value.trim() ?? '';

  /// Bumped by the organizer on every real change; answers are per
  /// version.
  int get sequence =>
      int.tryParse(event.property('SEQUENCE')?.value.trim() ?? '') ?? 0;

  /// The title, or null.
  String? get summary => _text('SUMMARY');

  String? get location => _text('LOCATION');

  /// The description, shortened and without the long separators and
  /// joining instructions meeting services add.
  String? get description {
    final raw = _text('DESCRIPTION');
    if (raw == null) return null;
    bool separator(String line) =>
        line.trim().length >= 6 && RegExp(r'^[-_=~:.*\s]+$').hasMatch(line);
    // Teams and Google put their joining instructions between two
    // separator lines; the card has a button for that instead.
    final lines = raw.split('\n');
    final first = lines.indexWhere(separator);
    final last = lines.lastIndexWhere(separator);
    if (first >= 0 && last > first) lines.removeRange(first, last + 1);
    final text =
        [
              for (final line in lines)
                if (!separator(line)) line.trimRight(),
            ]
            .join('\n')
            // Teams writes its links in angle brackets after the words.
            .replaceAll(RegExp(r'<https?://[^>\s]*>'), '')
            .replaceAll(RegExp(r'\n{3,}'), '\n\n')
            .trim();
    if (text.isEmpty) return null;
    if (text.length <= maxDescription) return text;
    final cut = text.substring(0, maxDescription);
    final space = cut.lastIndexOf(RegExp(r'\s'));
    return '${(space > maxDescription * 0.6 ? cut.substring(0, space) : cut).trimRight()}…';
  }

  /// The RRULE, if the event repeats.
  String? get recurrenceRule => event.property('RRULE')?.value.trim();

  /// The organizer cancelled the event (the message, or its status, says
  /// so).
  bool get cancelled =>
      method == CalendarMethod.cancel ||
      event.property('STATUS')?.value.trim().toUpperCase() == 'CANCELLED';

  /// Everyone invited but the organizer and rooms.
  List<CalendarPerson> get guests => [
    for (final a in attendees)
      if (!a.isResource &&
          (a.email == null ||
              a.email!.toLowerCase() != organizer?.email?.toLowerCase()))
        a,
  ];

  /// The attendee who is one of [addresses] (the user's accounts), if any.
  CalendarPerson? attendeeFor(Iterable<String> addresses) {
    final own = {for (final a in addresses) a.toLowerCase()};
    for (final a in attendees) {
      if (a.email case final email? when own.contains(email.toLowerCase())) {
        return a;
      }
    }
    return null;
  }

  /// Whether one of [addresses] organizes the event.
  bool organizedBy(Iterable<String> addresses) {
    final email = organizer?.email?.toLowerCase();
    return email != null && addresses.any((a) => a.toLowerCase() == email);
  }

  /// Identifies this version of the event, for remembering an answer.
  String get answerKey => '$uid#$sequence';

  /// The event can be answered: an invitation with an organizer to answer
  /// to and an id to answer about.
  bool get answerable =>
      method == CalendarMethod.request &&
      !cancelled &&
      uid.isNotEmpty &&
      organizer?.email != null;

  static Uri? _meetingLink(ICalComponent event) {
    // Most specific first: the services' own properties, then the
    // location, then the description.
    final sources = [
      for (final name in [
        'X-MICROSOFT-SKYPETEAMSMEETINGURL',
        'X-GOOGLE-CONFERENCE',
        'CONFERENCE',
        'URL',
        'LOCATION',
        'DESCRIPTION',
        'X-ALT-DESC',
      ])
        for (final p in event.all(name).take(5)) (name, p.text),
    ];
    for (final (name, text) in sources) {
      for (final match in _url.allMatches(text).take(50)) {
        final candidate = match
            .group(0)!
            .replaceAll(RegExp(r'[).,;:!?\]]+$'), '');
        final uri = Uri.tryParse(candidate);
        if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) continue;
        if (MeetingLinks.service(uri) != null) return uri;
        // A location that is only a link is the meeting.
        if (name == 'LOCATION' && text.trim() == candidate) return uri;
      }
    }
    return null;
  }

  static final _url = RegExp(r'''https://[^\s<>"'\\]+''', caseSensitive: false);
}

/// Online meeting services, recognised by their join links.
abstract final class MeetingLinks {
  /// The service's name for [link], or null if it isn't a known one.
  static String? service(Uri link) {
    final host = link.host.toLowerCase();
    bool at(String domain) => host == domain || host.endsWith('.$domain');
    if (at('teams.microsoft.com') || at('teams.live.com')) return 'Teams';
    if (at('zoom.us') || at('zoomgov.com')) return 'Zoom';
    if (host == 'meet.google.com') return 'Google Meet';
    if (at('webex.com')) return 'Webex';
    if (host == 'meet.jit.si') return 'Jitsi';
    if (at('whereby.com')) return 'Whereby';
    if (at('gotomeeting.com') || host == 'meet.goto.com') return 'GoTo';
    if (host == 'app.chime.aws') return 'Chime';
    return null;
  }
}
