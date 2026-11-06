// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_extract/mail_extract.dart';

import 'due_dates.dart';
import 'subscriptions.dart' show SubscriptionFinder;
import 'trips.dart';

/// What an appointment is for, to pick an icon and a word for it.
enum AppointmentKind {
  /// A doctor, dentist, clinic, hospital, vaccination, physio, optician.
  health,

  /// A haircut, salon, barber, spa, nails, massage.
  beauty,

  /// A car service, MOT, tyres, a garage.
  car,

  /// A home repair or visit: a plumber, an engineer, an installation.
  home,

  /// A government office or a bank: passport, visa, licence, branch.
  official,

  /// A job interview.
  interview,

  /// A school: parent-teacher meetings.
  school,

  /// A class or lesson.
  lesson,

  /// A delivery with a booked slot.
  delivery,

  /// Anything else booked.
  other,
}

/// A link in an email, with its words ("Manage booking").
final class MailLink {
  const MailLink(this.label, this.url);

  final String label;

  /// `https` only.
  final Uri url;

  @override
  bool operator ==(Object other) =>
      other is MailLink && other.label == label && other.url == url;

  @override
  int get hashCode => Object.hash(label, url);

  @override
  String toString() => '$label <$url>';
}

/// A calendar event (.ics) an email carries, as the app read it: what the
/// appointments finder needs of it.
final class AppointmentInvite {
  const AppointmentInvite({
    required this.uid,
    this.sequence = 0,
    this.summary,
    this.location,
    this.description,
    this.start,
    this.end,
    this.cancelled = false,
    this.reply = false,
    this.organizerEmail,
    this.organizerName,
    this.guests = 0,
    this.meetingLink,
  });

  final String uid;

  /// Bumped on every change: the highest is the newest.
  final int sequence;
  final String? summary;
  final String? location;
  final String? description;
  final PlaceTime? start;
  final PlaceTime? end;

  /// The event was cancelled.
  final bool cancelled;

  /// An answer to an invitation (accepted, declined), not an event.
  final bool reply;
  final String? organizerEmail;
  final String? organizerName;

  /// How many people are invited, the organizer and rooms aside.
  final int guests;

  /// A video call link (Zoom, Teams, Meet).
  final Uri? meetingLink;
}

/// One email that may be about an appointment.
final class AppointmentEmail {
  const AppointmentEmail({
    required this.messageId,
    required this.sender,
    required this.senderName,
    required this.subject,
    required this.text,
    required this.at,
    this.appointments = const [],
    this.reservations = const [],
    this.invite,
    this.links = const [],
    this.bulk = false,
  });

  /// The stored message, to open it.
  final int messageId;

  /// The sender's registrable domain (`brightsmile.co.uk`).
  final String sender;

  /// The sender's display name, if any ("Bright Smile Dental").
  final String? senderName;
  final String subject;

  /// What is known of the body: the preview, or the whole text once the
  /// message was downloaded. May be empty.
  final String text;
  final DateTime at;

  /// schema.org appointments in its HTML (see mail_extract).
  final List<AppointmentInfo> appointments;

  /// schema.org flights, stays, tables and tickets in its HTML: then it is
  /// for the Trips page, not this one.
  final List<ReservationInfo> reservations;

  /// The calendar event it carries, if any.
  final AppointmentInvite? invite;

  /// Its links, with their words.
  final List<MailLink> links;

  /// Sorted as a newsletter or promotion: not read.
  final bool bulk;
}

/// One email, as understood.
final class AppointmentRecord {
  const AppointmentRecord({
    required this.email,
    required this.kind,
    this.start,
    this.end,
    this.business,
    this.service,
    this.place,
    this.online = false,
    this.reference,
    this.uid,
    this.cancels = false,
    this.changes = false,
    this.reminds = false,
    this.links = const [],
  });

  final AppointmentEmail email;
  final AppointmentKind kind;

  /// When it is, as the email gives it (the new time for a change).
  final PlaceTime? start;
  final PlaceTime? end;

  /// Who it is with: the clinic, salon, garage, office.
  final String? business;

  /// What it is for ("Scale and polish").
  final String? service;

  /// Where: an address or a place's name.
  final String? place;
  final bool online;
  final String? reference;

  /// The calendar event's id, when it came with one.
  final String? uid;

  /// It says the appointment was cancelled.
  final bool cancels;

  /// It says the appointment was moved.
  final bool changes;

  /// A reminder of it ("Your appointment is tomorrow").
  final bool reminds;

  /// Links to manage it, add it to a calendar...
  final List<MailLink> links;
}

/// An appointment found in the mail, with every email about it.
final class Appointment {
  Appointment._({
    required this.key,
    required this.records,
    required this.cancelled,
    required this.changed,
    this.previousStart,
  });

  /// Stable across loads: used to hide it, and to remind of it once.
  final String key;

  /// Its emails, oldest first.
  final List<AppointmentRecord> records;

  /// The latest news is that it was cancelled.
  final bool cancelled;

  /// It was moved after it was booked.
  final bool changed;

  /// When it was before it moved.
  final PlaceTime? previousStart;

  T? _newest<T>(T? Function(AppointmentRecord r) of) {
    for (final r in records.reversed) {
      if (of(r) case final v?) return v;
    }
    return null;
  }

  /// The newest record that says when it is (not a cancellation's, unless
  /// only that one does).
  AppointmentRecord get _timed =>
      records.reversed
          .where((r) => r.start != null && !r.cancels)
          .firstOrNull ??
      records.reversed.firstWhere((r) => r.start != null);

  PlaceTime get start => _timed.start!;
  PlaceTime? get end => _timed.end;

  String? get business => _newest((r) => r.business);
  String? get service => _newest((r) => r.service);
  String? get place => _newest((r) => r.place);

  /// It happens online: the newest email that says where says so.
  bool get online {
    for (final r in records.reversed) {
      if (r.online) return true;
      if (r.place != null) return false;
    }
    return false;
  }

  String? get reference => _newest((r) => r.reference);

  /// What it is for: the first email's that says more than "other".
  AppointmentKind get kind =>
      records
          .map((r) => r.kind)
          .where((k) => k != AppointmentKind.other)
          .firstOrNull ??
      AppointmentKind.other;

  /// The sender's registrable domain.
  String get sender => records.last.email.sender;

  /// The newest email.
  AppointmentRecord get latest => records.last;

  /// Links from its emails, the newest first, one per label.
  List<MailLink> get links {
    final seen = <String>{};
    return [
      for (final r in records.reversed)
        for (final l in r.links)
          if (seen.add(l.label.toLowerCase())) l,
    ];
  }

  /// What to call it: the business, else what it is for, else the
  /// kind's word ("Dentist").
  String get title => business ?? service ?? AppointmentFinder.word(this);

  /// When it is over: its end, else an hour after it starts (for a date
  /// alone, that whole day).
  DateTime get endsAt {
    final s = start;
    final e = end;
    if (e != null && e.compareTo(s) > 0) {
      return e.hasTime ? e.instant : e.instant.add(const Duration(days: 1));
    }
    return s.hasTime
        ? s.instant.add(const Duration(hours: 1))
        : s.instant.add(const Duration(days: 1));
  }

  @override
  String toString() => 'Appointment($key)';
}

/// Reads appointments from the words of booking emails: a confirmation
/// with a date and a time ("Your appointment is confirmed for Tue 12 Nov
/// at 3:30 PM"), a change, a cancellation or a reminder.
abstract final class AppointmentText {
  static RegExp _re(String pattern) => RegExp(pattern, caseSensitive: false);

  /// Subjects of mail that speaks of booking without being a booking:
  /// offers, "book now", "schedule a demo", surveys.
  static final notAnAppointment = _re(
    r'\b(?:deals?|sale|offers?|save up to|promo(?:tion|s)?|newsletter|'
    r'rate your|review|how was|survey|feedback|tell us|win|'
    r'book now|book (?:a|your|online|today)|schedule (?:a|your) (?:demo|call)|'
    r'(?:book|request|get|see) a (?:free )?demo|webinar|last chance|'
    r"don'?t miss|limited time|it'?s time (?:for|to)|due for (?:a|your)|"
    r'time to book)\b|\d+% off|'
    r'\b(?:invitation|updated invitation|accepted|declined|tentative):',
  );

  /// Words that the email confirms, moves, cancels or recalls a booking.
  static final _confirms = _re(
    r'\b(?:appointments?|bookings?|reservations?|visit|consultation|session|'
    r'class|lesson|slot|service|interview|check-?up|vaccination|treatment|'
    r'meeting|delivery)\b[^.\n]{0,50}?\b(?:is |has been |have been |was |are |is now )?'
    r'(?:confirmed|booked|scheduled|reserved)\b|'
    r'\b(?:appointments?|bookings?|visit|consultation|session|class|lesson|'
    r'slot|interview)\b[^.\n]{0,50}?\b(?:is |has been |have been |was |is now )?'
    r'(?:re-?scheduled|moved|changed|cancell?ed)\b|'
    r'\b(?:confirm(?:ing|ation of)?|reminder (?:of|for|about)|reminding you of) '
    r'your (?:upcoming )?(?:appointment|booking|visit|consultation|session|class|'
    r'lesson|slot|interview)\b|'
    r'\byour (?:upcoming )?(?:appointment|booking|visit|consultation|session|class|'
    r'lesson|interview|slot)\b[^.\n]{0,80}?\b(?:is|will be|starts?) '
    r'(?:on|at|for|tomorrow|today|in)\b|'
    r"\byou(?:'re| are) (?:booked|confirmed|all set|scheduled)\b|"
    r'\b(?:appointment|booking|interview|class) (?:confirmation|confirmed|reminder|details)\b|'
    r'\binvit(?:e|ed|ing) you (?:to|for) an? (?:\w+ )?interview\b|'
    r'\bparent[- ]teacher (?:meeting|conference)\b',
  );

  /// Mail about meetings among colleagues, events and shows.
  static final _meeting = _re(
    r'\b(?:meeting|sync|stand-?up|1:1|one-on-one|catch-?up|call|review|'
    r'workshop|webinar|all-?hands|demo)\b',
  );

  /// Strong words: it is an appointment even when it says "meeting".
  static final _appointmentWords = _re(
    r'\b(?:appointments?|consultation|check-?up|vaccination|interview|'
    r'parent[- ]teacher|haircut|treatment|slot)\b',
  );

  /// The Trips page's: travel, tables, tickets.
  static final _tripWords = _re(
    r'\b(?:flights?|hotel|stay|check-?out|itinerary|boarding|trains?|'
    r'bus|car (?:rental|hire)|rental car|e-?tickets?|tickets?|concert|'
    r'table for|tables?|restaurant|dinner|lunch|brunch|dining|party of|'
    r'guests?|seats?)\b',
  );

  /// The words of a table, a ticket or a trip.
  static final _tripText = _re(
    r'\b(?:table for \d+|party of \d+|e-?tickets?|your tickets?|'
    r'seat (?:number|no)|seats? \d+[A-Z]?|flight (?:number|no)|check-?out)\b',
  );

  /// Shipping mail with no booked slot.
  static final _shipping = _re(
    r'\b(?:out for delivery|has shipped|have shipped|been shipped|dispatched|'
    r'on its way|estimated delivery|arriving|tracking number|track your)\b',
  );
  static final _slot = _re(
    r'\b(?:delivery|installation|collection) (?:slot|window|appointment|date)\b|'
    r'\b(?:delivery|installation) (?:is |has been )?(?:booked|scheduled)\b|'
    r'\byour slot\b',
  );

  static final _cancelled = _re(
    r'\b(?:appointment|booking|reservation|visit|consultation|session|class|'
    r'lesson|slot|interview|service)s?\b[^.\n]{0,60}?'
    r'\b(?:has been|have been|was|were|is|is now)\s+cancell?ed\b|'
    r"\bwe(?:'ve| have) cancell?ed your\b|\bcancell?ation (?:confirmation|confirmed)\b|"
    r'\byou(?: have|.ve) cancell?ed\b',
  );
  static final _cancelledSubject = _re(r'\bcancell?(?:ed|ation)\b');

  /// "Cancel up to 24 hours before": said in every booking.
  static final _cancellationTerms = _re(
    r'\b(?:free|no|flexible|easy|late) cancell?ation\b|\bcancell?ation '
    r'(?:policy|fee|charges?|deadline|terms|is free|before)\b|'
    r'\bcancell?ation\s+(?:up to|until|within)\b',
  );

  static final _changed = _re(
    r'\b(?:re-?scheduled|re-?booked|moved|changed|amended|updated|new (?:date|time))\b',
  );

  static final _reminder = _re(
    r'\breminder\b|\b(?:is|starts?|see you) (?:tomorrow|today)\b|'
    r'\bcoming up\b|\bupcoming (?:appointment|visit|booking)\b',
  );

  /// Whether the email says the appointment was cancelled.
  static bool saysCancelled(String subject, String text) {
    final s = subject.replaceAll(_cancellationTerms, '');
    if (_cancelledSubject.hasMatch(s)) return true;
    return _cancelled.hasMatch(
      _cap(text, 6000).replaceAll(_cancellationTerms, ''),
    );
  }

  /// Whether it says the appointment moved.
  static bool saysChanged(String subject, String text) =>
      _changed.hasMatch(subject) ||
      _re(
        r'\b(?:appointment|booking|visit|session|class|interview)s?\b[^.\n]{0,40}?'
        r'\b(?:has been|was|is now|have been)\s+(?:re-?scheduled|moved|changed|amended)\b|'
        r'\b(?:re-?scheduled|moved) (?:to|for)\b',
      ).hasMatch(_cap(text, 6000));

  /// Whether it is a reminder of an appointment.
  static bool saysReminder(String subject, String text) =>
      _reminder.hasMatch(subject) ||
      _re(
        r'\b(?:a )?(?:friendly )?reminder (?:of|for|about|that)\b|'
        r'\byour (?:appointment|booking|visit|session|class) is (?:tomorrow|today)\b',
      ).hasMatch(_cap(text, 3000));

  // ------------------------------------------------------- dates, times

  static final _time = _re(
    r'(?<![\d:.,/-])([01]?\d|2[0-3])(?:([:.])([0-5]\d))?\s*'
    r'((?:a\.?\s?m|p\.?\s?m)\b\.?)?(?![\d:/])(?:\s*(?:hrs|h)\b)?',
  );

  /// The clock times in [text]: "3:30 PM", "3.30pm", "3pm", "15:30".
  /// A number alone is no time.
  static List<({int at, int end, int hour, int minute})> timesIn(String text) {
    final found = <({int at, int end, int hour, int minute})>[];
    for (final m in _time.allMatches(text)) {
      final ampm = m[4];
      final hasMinutes = m[3] != null;
      if (ampm == null && (!hasMinutes || m[2] != ':')) continue;
      var h = int.parse(m[1]!);
      if (ampm != null) {
        if (h < 1 || h > 12) continue;
        final pm = ampm.toLowerCase().startsWith('p');
        h = h % 12 + (pm ? 12 : 0);
      }
      // The end of "3:30 PM" without the trailing space.
      var end = m.end;
      while (end > m.start && text[end - 1] == ' ') {
        end--;
      }
      found.add((
        at: m.start,
        end: end,
        hour: h,
        minute: hasMinutes ? int.parse(m[3]!) : 0,
      ));
    }
    return found;
  }

  static final _relativeDay = _re(r'\b(today|tomorrow|tonight)\b');

  /// Words before an old date in a change ("moved from", "was").
  static final _oldLabel = _re(
    r'\b(?:from|was|previously|originally|original|old|instead of|'
    r'no longer)\b[^\n]{0,12}$',
  );

  /// Words before the new date in a change ("moved to", "new time").
  static final _newLabel = _re(
    r'\b(?:to|now|new (?:date|time|appointment)|re-?scheduled (?:to|for)|'
    r'moved to|changed to)\b[^\n]{0,14}$',
  );

  /// Every date written with a time close by in [text], in order: "Tue 12
  /// Nov at 3:30 PM", "3:30 PM on 12/11/2026", "Date: 14/11/2026 Time:
  /// 10:15", "tomorrow at 3pm". [sent] gives years, and "tomorrow".
  static List<({int at, PlaceTime start, PlaceTime? end})> momentsIn(
    String text,
    DateTime sent,
  ) {
    final dates = <({int start, int end, DateTime day})>[
      for (final d in DueDates.datesIn(text, reference: sent))
        (start: d.start, end: d.end, day: d.date),
    ];
    final local = sent.toLocal();
    for (final m in _relativeDay.allMatches(text)) {
      if (dates.any((d) => m.start < d.end && d.start < m.end)) continue;
      final add = m[1]!.toLowerCase() == 'tomorrow' ? 1 : 0;
      dates.add((
        start: m.start,
        end: m.end,
        day: DateTime.utc(local.year, local.month, local.day + add),
      ));
    }
    dates.sort((a, b) => a.start.compareTo(b.start));
    final times = timesIn(text);
    final used = <int>{};
    final found = <({int at, PlaceTime start, PlaceTime? end})>[];
    for (final d in dates) {
      // A time after the date, close by ("12 Nov 2026 at 3:30 PM",
      // "Date: 14/11/2026\nTime: 10:15"), else just before it ("3:30 PM
      // on Tue 12 Nov").
      final after = times
          .where(
            (t) =>
                !used.contains(t.at) &&
                t.at >= d.end &&
                t.at - d.end <= 32 &&
                !text.substring(d.end, t.at).contains('\n\n'),
          )
          .firstOrNull;
      final before = after != null
          ? null
          : times
                .where(
                  (t) =>
                      !used.contains(t.at) &&
                      t.end <= d.start &&
                      d.start - t.end <= 16 &&
                      !text.substring(t.end, d.start).contains('\n'),
                )
                .lastOrNull;
      final t = after ?? before;
      if (t == null) continue;
      used.add(t.at);
      PlaceTime at(int hour, int minute) => PlaceTime(
        d.day.year,
        d.day.month,
        d.day.day,
        hour: hour,
        minute: minute,
      );
      // "10:00 – 11:00", "10am to 11am": the end.
      final next = times
          .where((x) => x.at > t.at && x.at - t.end <= 6)
          .where(
            (x) => RegExp(
              r'^\s*(?:-|–|—|to|until)\s*$',
              caseSensitive: false,
            ).hasMatch(text.substring(t.end, x.at)),
          )
          .firstOrNull;
      if (next != null) used.add(next.at);
      final start = at(t.hour, t.minute);
      final end = next == null ? null : at(next.hour, next.minute);
      found.add((
        at: d.start < t.at ? d.start : t.at,
        start: start,
        end: end != null && end.compareTo(start) > 0 ? end : null,
      ));
    }
    found.sort((a, b) => a.at.compareTo(b.at));
    return found;
  }

  /// When the appointment is in [text]: for a change, the new time; else
  /// the first time from where the email confirms it, else the first one.
  static ({PlaceTime start, PlaceTime? end})? whenIn(
    String text,
    DateTime sent, {
    bool changed = false,
    bool cancelled = false,
  }) {
    final moments = momentsIn(text, sent);
    if (moments.isEmpty) return null;
    String before(int at) => text.substring((at - 40).clamp(0, at), at);
    var usable = [
      for (final m in moments)
        // Not one in the past when booked (a footer's "sent on"), but a
        // cancellation may name any.
        if (cancelled ||
            !m.start.instant.isBefore(sent.subtract(const Duration(hours: 2))))
          m,
    ];
    if (usable.isEmpty) return null;
    if (changed) {
      final fresh = [
        for (final m in usable)
          if (_newLabel.hasMatch(before(m.at))) m,
      ];
      if (fresh.isNotEmpty) {
        return (start: fresh.last.start, end: fresh.last.end);
      }
      final notOld = [
        for (final m in usable)
          if (!_oldLabel.hasMatch(before(m.at))) m,
      ];
      if (notOld.isNotEmpty) usable = notOld;
      // The new time is usually the last one given.
      if (usable.length > 1) {
        return (start: usable.last.start, end: usable.last.end);
      }
    }
    final confirmed = _confirms.firstMatch(text)?.start;
    final from = confirmed == null
        ? null
        : usable.where((m) => m.at >= confirmed).firstOrNull;
    final pick = from ?? usable.first;
    return (start: pick.start, end: pick.end);
  }

  // ----------------------------------------------------------- details

  static final _referenceLabel = _re(
    r'\b(?:appointment|booking|reservation|confirmation|reference|ref|order)\.?'
    r'(?:\s+(?:id|no\.?|number|code|ref(?:erence)?\.?|#))?\s*[:#]\s*#?\s*'
    r'([A-Z0-9][A-Z0-9-]{3,19})\b',
  );

  /// The booking reference in [text] ("Booking ref: SDC-48213",
  /// "Appointment ID: P-7781-2210"). It has a digit.
  static String? referenceIn(String text) {
    final sample = _cap(text, 20000);
    if (TripText.referencesIn(sample).firstOrNull case final r?) return r;
    for (final m in _referenceLabel.allMatches(sample)) {
      final r = m[1]!;
      if (r != r.toUpperCase() || !RegExp(r'\d').hasMatch(r)) continue;
      return r;
    }
    return null;
  }

  static final _serviceLabel = _re(
    r'^\s*(?:services?|treatments?|appointment type|type of appointment|'
    r'appointment for|reason for (?:your )?visit|class|course|procedure|'
    r'what)\s*:\s*(.+)$',
  );
  static final _placeLabel = _re(
    r'^\s*(?:address|location|where|venue|place|clinic|branch|centre|center|'
    r'meeting point|clinic address|salon address)\s*:\s*(.+)$',
  );

  /// An address line without a label: a street, a unit, a postcode.
  static final _addressLike = RegExp(
    r"^\s*\d{1,5}[A-Za-z]?,?\s+[A-Z][\w'.-]*(?:\s+[A-Z][\w'.-]*){0,4}\s+"
    r'(?:Road|Rd|Street|St|Avenue|Ave|Lane|Ln|Drive|Dr|Way|Close|Crescent|'
    r'Boulevard|Blvd|Place|Pl|Square|Sq|Terrace|Court|Ct|Highway|Hwy|'
    r'Parade|Central|Walk|Park)\b.*$|'
    r'#\d{1,2}-\d{2,4}|\bSingapore \d{6}\b|'
    r'\b[A-Z]{1,2}\d[A-Z\d]? \d[A-Z]{2}$',
    multiLine: true,
  );
  static final _online = _re(
    r'\b(?:video (?:call|consultation|appointment|visit|session)|online '
    r'(?:appointment|consultation|session|class|lesson|interview)|'
    r'tele-?(?:consult(?:ation)?|health|medicine)|zoom|microsoft teams|'
    r'google meet|join (?:the|your) (?:video|call|session))\b',
  );

  /// What it is for, from a label ("Treatment: Scale and polish").
  static String? serviceIn(String text) {
    for (final line in _cap(text, 20000).split('\n').take(200)) {
      if (_clean(_serviceLabel.firstMatch(line)?[1]) case final s?) return s;
    }
    return null;
  }

  /// Where it is: a labelled address, else a line that reads like one.
  static String? placeIn(String text) {
    final lines = _cap(text, 20000).split('\n').take(300).toList();
    for (final line in lines) {
      final p = _clean(_placeLabel.firstMatch(line)?[1], max: 140);
      if (p != null) return p;
    }
    for (final line in lines) {
      if (line.length > 140) continue;
      if (_addressLike.hasMatch(line)) {
        final p = _clean(line, max: 140);
        if (p != null) return p;
      }
    }
    return null;
  }

  /// Whether it happens online (a video call).
  static bool saysOnline(String text) => _online.hasMatch(_cap(text, 6000));

  /// The business in words: "Your appointment at Hair by Mia is
  /// confirmed", "Booking with Northside Motors".
  static final _businessIn = RegExp(
    r'\b(?:[Aa]ppointment|[Bb]ooking|[Vv]isit|[Rr]eservation|[Ss]ession|'
    r'[Cc]lass|[Cc]onsultation|[Ii]nterview)s?\b'
    r'(?: is confirmed| confirmed| reminder)?\s+(?:at|with)\s+'
    r"((?:the )?[A-Z0-9][\w'&.-]*(?:\s+(?:[A-Z0-9&][\w'&.-]*|by|of|and|the|de|"
    r'la|at|on|for)){0,6})',
  );

  static String? businessIn(String text) {
    final m = _businessIn.firstMatch(_cap(text, 4000));
    var name = m?[1]?.trim();
    if (name == null) return null;
    // "Hair by Mia on Sat": up to the date words.
    name = name
        .replaceFirst(
          RegExp(r'\s+(?:on|at|for|is|has|by|and|the|of|from|with)$'),
          '',
        )
        .replaceFirst(
          RegExp(r'\s+(?:on|at|for)\s+(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun|\d).*$'),
          '',
        )
        .trim();
    // "Dr Patel" is a person, not a business; "the" alone is nothing.
    if (name.length < 3 || RegExp(r'^(?:Dr|Mr|Mrs|Ms)\b').hasMatch(name)) {
      return null;
    }
    if (RegExp(r'^(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun|\d)').hasMatch(name)) {
      return null;
    }
    return name;
  }

  static String? _clean(String? value, {int max = 80}) {
    final v = value
        ?.replaceAll(RegExp(r'\s+'), ' ')
        .replaceFirst(RegExp(r'[.,;:\s]+$'), '')
        .trim();
    if (v == null || v.length < 2 || v.length > max) return null;
    if (!RegExp('[A-Za-z]{2}').hasMatch(v)) return null;
    return v;
  }

  // -------------------------------------------------------------- kinds

  static final _kinds = <(AppointmentKind, RegExp)>[
    (AppointmentKind.interview, _re(r'\binterviews?\b')),
    (
      AppointmentKind.school,
      _re(
        r"\bparent[- ]teacher\b|\bparents'? evening\b|\bschool\b|\bteacher\b",
      ),
    ),
    (AppointmentKind.delivery, _slot),
    (
      AppointmentKind.car,
      _re(
        r'\bcar service\b|\bvehicle\b|\bMOT\b|\bgarage\b|\btyres?\b|\btires?\b|'
        r'\bservicing\b|\bmechanic\b|\boil change\b|\bautocentre\b|\bmotors\b|'
        r'\bwheel alignment\b',
      ),
    ),
    (
      AppointmentKind.health,
      _re(
        r'\bdent(?:ist|al)\b|\bdoctor\b|\bGP\b|\bclinic\b|\bhospital\b|'
        r'\bmedical\b|\bvaccin\w*|\bimmuni[sz]ation\b|\bflu (?:jab|shot)\b|'
        r'\bphysio\w*|\boptician\b|\boptometrist\b|\beye test\b|\bpharmacy\b|'
        r'\bhealth ?(?:check|screening)\b|\bblood test\b|\bx-?ray\b|\bscan\b|'
        r'\btherap(?:y|ist)\b|\bpolyclinic\b|\bsurgery\b|\bdr\.? [A-Z]',
      ),
    ),
    (
      AppointmentKind.beauty,
      _re(
        r'\bhair\w*|\bsalon\b|\bbarber\w*|\bspa\b|\bnails?\b|\bmanicure\b|'
        r'\bpedicure\b|\bmassage\b|\bfacial\b|\bbeauty\b|\blash(?:es)?\b|'
        r'\bskin fade\b|\bshave\b|\bcuts\b|\bgrooming\b|'
        r'\bbrows?\b|\bwax(?:ing)?\b|\bblow ?dry\b',
      ),
    ),
    (
      AppointmentKind.home,
      _re(
        r'\bplumb\w*|\belectrician\b|\bengineer\b|\btechnician\b|\brepairs?\b|'
        r'\binstallation\b|\bboiler\b|\bappliance\b|\bhandyman\b|'
        r'\bcleaning\b|\bpest control\b|\baircon\b|\bservicing visit\b',
      ),
    ),
    (
      AppointmentKind.official,
      _re(
        r'\bpassport\b|\bvisa\b|\bembassy\b|\bconsulate\b|\blicen[cs]e\b|'
        r'\bgovernment\b|\bcouncil\b|\bimmigration\b|\bICA\b|\bDMV\b|'
        r'\btax office\b|\bregistry\b|\btown hall\b|\bbank\b|\bbranch\b|'
        r'\bmortgage\b|\bnotary\b|\bresidence permit\b|\bbiometrics?\b',
      ),
    ),
    (
      AppointmentKind.lesson,
      _re(
        r'\bclass(?:es)?\b|\blessons?\b|\bcourse\b|\btutor\w*|\byoga\b|'
        r'\bpilates\b|\bfitness\b|\bgym\b|\bswim\w*|\bpersonal training\b',
      ),
    ),
  ];

  /// What an appointment is about: its [head] (the business, the
  /// service, the subject, the sender's name) first, then its [text].
  static AppointmentKind kindOf(
    String head, {
    String text = '',
    String sender = '',
  }) {
    if (sender.contains('.gov') || sender.startsWith('gov.')) {
      return AppointmentKind.official;
    }
    for (final words in [head, _cap(text, 3000)]) {
      for (final (kind, re) in _kinds) {
        if (re.hasMatch(words)) return kind;
      }
    }
    return AppointmentKind.other;
  }

  // ----------------------------------------------------------- reading

  /// Whether [email]'s words read like a booked appointment: it confirms,
  /// moves, cancels or recalls one, and is not about travel, a table, a
  /// ticket, a shipment or a meeting among colleagues.
  static bool readsLikeAppointment(AppointmentEmail email) {
    if (email.bulk || notAnAppointment.hasMatch(email.subject)) return false;
    if (SubscriptionFinder.isReplyOrForward(email.subject)) return false;
    final head = _cap('${email.subject}\n${email.text}', 6000);
    if (!_confirms.hasMatch(head) && !_cancelled.hasMatch(head)) return false;
    if (_tripWords.hasMatch(email.subject) &&
        !_appointmentWords.hasMatch(email.subject)) {
      return false;
    }
    if (_tripText.hasMatch(_cap(email.text, 3000))) return false;
    if (_shipping.hasMatch(head) && !_slot.hasMatch(head)) return false;
    if (_meeting.hasMatch(email.subject) &&
        !_appointmentWords.hasMatch(email.subject)) {
      return false;
    }
    return true;
  }

  static String _cap(String s, int n) => s.length > n ? s.substring(0, n) : s;
}

/// Finds appointments in booking mail, on the device: from schema.org
/// markup, a calendar event from a business, or the words of a
/// confirmation; and puts each one's emails together (a change, a
/// cancellation, a reminder).
abstract final class AppointmentFinder {
  /// Subject words of mail worth looking at (also used to pick it from
  /// the store).
  static const subjectWords = [
    'appointment',
    'booking',
    'booked',
    'reservation',
    'confirm',
    'reminder',
    'schedule',
    'cancel',
    'visit',
    'consultation',
    'interview',
    'class',
    'lesson',
    'session',
    'service',
    'slot',
    'parent-teacher',
    'parent teacher',
    'invitation',
    "you're booked",
  ];

  static final _subject = RegExp(
    r'\b(?:appointments?|booking|booked|reservation|confirm\w*|reminder|'
    r're-?scheduled|scheduled|cancell?ed|cancell?ation|visit|consultation|'
    r'interview|class|lesson|session|service|slot|parent[- ]teacher)\b',
    caseSensitive: false,
  );

  /// Whether [subject] reads like an appointment, worth downloading.
  static bool looksLikeAppointment(String subject) =>
      !SubscriptionFinder.isReplyOrForward(subject) &&
      !AppointmentText.notAnAppointment.hasMatch(subject) &&
      // Flights, stays, tables: the Trips page's (a "reservation" is
      // most often a table).
      (AppointmentText._appointmentWords.hasMatch(subject) ||
          !TripFinder.looksLikeBooking(
            subject.replaceAll(
              RegExp(
                r'\b(?:booking|cancell?ed|cancell?ation)\b',
                caseSensitive: false,
              ),
              '',
            ),
          )) &&
      _subject.hasMatch(subject);

  /// Sites that book for many businesses: their name is not the
  /// business's.
  static const bookingSites = {
    'fresha.com',
    'booksy.com',
    'setmore.com',
    'acuityscheduling.com',
    'squareup.com',
    'square.site',
    'vagaro.com',
    'mindbodyonline.com',
    'zocdoc.com',
    'doctolib.fr',
    'doctolib.de',
    'treatwell.co.uk',
    'treatwell.com',
    'simplybook.me',
    'gettimely.com',
    'phorest.com',
    'healthengine.com.au',
    'practo.com',
    'appointy.com',
    'calendly.com',
    'styleseat.com',
    'schedulicity.com',
    'classpass.com',
    'timify.com',
  };

  /// [email], as understood, or null when it says nothing of an
  /// appointment.
  static AppointmentRecord? read(AppointmentEmail email) {
    if (SubscriptionFinder.isReplyOrForward(email.subject)) return null;
    // Travel, tables and tickets belong to Trips.
    if (email.reservations.isNotEmpty) return null;
    if (email.appointments.firstOrNull case final a? when !email.bulk) {
      return _fromMarkup(email, a);
    }
    if (email.invite case final i?) {
      return _fromInvite(email, i);
    }
    if (!AppointmentText.readsLikeAppointment(email)) return null;
    final trip = TripEmail(
      messageId: email.messageId,
      sender: email.sender,
      senderName: email.senderName,
      subject: email.subject,
      text: email.text,
      at: email.at,
    );
    if (TripText.read(trip).isNotEmpty) return null;
    final words = '${email.subject}\n${email.text}';
    final cancels = AppointmentText.saysCancelled(email.subject, email.text);
    final changes =
        !cancels && AppointmentText.saysChanged(email.subject, email.text);
    final when = AppointmentText.whenIn(
      words,
      email.at,
      changed: changes,
      cancelled: cancels,
    );
    final reference = AppointmentText.referenceIn(words);
    // A cancellation may name neither a time nor a reference: it is then
    // matched with the sender's next appointment.
    if (when == null && !cancels) return null;
    final business = _business(email);
    final service = AppointmentText.serviceIn(email.text);
    return AppointmentRecord(
      email: email,
      kind: AppointmentText.kindOf(
        [?business, ?service, email.senderName ?? '', email.subject].join('\n'),
        text: email.text,
        sender: email.sender,
      ),
      start: when?.start,
      end: when?.end,
      business: business,
      service: service,
      place: AppointmentText.placeIn(email.text),
      online: AppointmentText.saysOnline(words),
      reference: reference,
      cancels: cancels,
      changes: changes,
      reminds:
          !cancels &&
          !changes &&
          AppointmentText.saysReminder(email.subject, email.text),
      links: _links(email),
    );
  }

  static AppointmentRecord _fromMarkup(
    AppointmentEmail email,
    AppointmentInfo a,
  ) {
    final words = '${email.subject}\n${email.text}';
    final cancels =
        a.status == ReservationStatus.cancelled ||
        AppointmentText.saysCancelled(email.subject, email.text);
    final changes =
        !cancels && AppointmentText.saysChanged(email.subject, email.text);
    final place = a.place;
    // A reservation for a business (a garage, a clinic) names the
    // business, not a service.
    final business = a.provider ?? place?.name ?? _business(email);
    final service = a.name != business && a.name != place?.name ? a.name : null;
    final where = [
      if (place?.name case final n? when n != business) n,
      ?place?.address,
    ].join(', ');
    return AppointmentRecord(
      email: email,
      kind: AppointmentText.kindOf(
        [?business, ?service, email.senderName ?? '', email.subject].join('\n'),
        text: email.text,
        sender: email.sender,
      ),
      start: a.start,
      end: a.end,
      business: business,
      service: service,
      place: place == null
          ? (a.online ? null : AppointmentText.placeIn(email.text))
          : where.isNotEmpty
          ? where
          : place.locality,
      online: a.online,
      reference: a.reservationNumber ?? AppointmentText.referenceIn(words),
      cancels: cancels,
      changes: changes,
      reminds:
          !cancels &&
          !changes &&
          AppointmentText.saysReminder(email.subject, email.text),
      links: [
        if (a.url case final u?) MailLink('Manage booking', u),
        ..._links(email),
      ],
    );
  }

  /// A calendar event from a business: a booking it sends, not a meeting
  /// among colleagues (many guests, or words such as "sync" and
  /// "review" without "appointment").
  static AppointmentRecord? _fromInvite(
    AppointmentEmail email,
    AppointmentInvite i,
  ) {
    final start = i.start;
    if (i.reply || start == null || email.bulk) return null;
    if (i.guests > 2) return null;
    final title = i.summary ?? '';
    final words = [
      email.subject,
      title,
      i.description ?? '',
      email.text,
    ].join('\n');
    final head = '${email.subject}\n$title';
    // Strong words, or the email confirms a booking.
    final booked =
        AppointmentText._appointmentWords.hasMatch(head) ||
        (AppointmentText.readsLikeAppointment(
              AppointmentEmail(
                messageId: email.messageId,
                sender: email.sender,
                senderName: email.senderName,
                subject: email.subject.replaceFirst(
                  RegExp(r'^(?:updated )?invitation:\s*', caseSensitive: false),
                  '',
                ),
                text: '$title\n${i.description ?? ''}\n${email.text}',
                at: email.at,
              ),
            ) &&
            !AppointmentText._meeting.hasMatch(title));
    if (!booked) return null;
    if (AppointmentText._meeting.hasMatch(title) &&
        !AppointmentText._appointmentWords.hasMatch(head)) {
      return null;
    }
    // "Flu vaccination at Raffles Medical": the business after "at".
    final at = RegExp(r'^(.+?)\s+(?:at|with)\s+(.+)$').firstMatch(title);
    final business =
        _brokerBusiness(email) ??
        (at != null ? at[2]!.trim() : null) ??
        _senderBusiness(email) ??
        i.organizerName;
    final location = i.location;
    final online =
        i.meetingLink != null ||
        (location != null &&
            RegExp(
              r'^https://|\bonline\b|\bvideo\b|\bzoom\b|\bteams\b',
              caseSensitive: false,
            ).hasMatch(location));
    return AppointmentRecord(
      email: email,
      kind: AppointmentText.kindOf(
        [?business, title, email.senderName ?? '', email.subject].join('\n'),
        text: words,
        sender: email.sender,
      ),
      start: start,
      end: i.end,
      business: business,
      service: at != null
          ? at[1]!.trim()
          : (title.isNotEmpty && title != business ? title : null),
      place: online ? null : location,
      online: online,
      reference: AppointmentText.referenceIn(words),
      uid: i.uid.isEmpty ? null : i.uid,
      cancels: i.cancelled,
      changes:
          !i.cancelled &&
          (i.sequence > 0 ||
              AppointmentText.saysChanged(email.subject, email.text)),
      reminds: AppointmentText.saysReminder(email.subject, ''),
      links: _links(email),
    );
  }

  static String? _business(AppointmentEmail email) =>
      _brokerBusiness(email) ??
      _senderBusiness(email) ??
      AppointmentText.businessIn('${email.subject}\n${email.text}');

  /// For a booking site's email, the business it names.
  static String? _brokerBusiness(AppointmentEmail email) {
    if (!bookingSites.contains(email.sender.toLowerCase())) return null;
    return AppointmentText.businessIn('${email.subject}\n${email.text}');
  }

  /// The sender's name, without "no-reply" or "Appointments".
  static String? _senderBusiness(AppointmentEmail email) {
    if (bookingSites.contains(email.sender.toLowerCase())) return null;
    final name = email.senderName
        ?.replaceAll(
          RegExp(
            r'\b(?:no-?reply|do not reply|donotreply|bookings?|appointments?|'
            r'reservations?|notifications?|team|reminders?)\b',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(RegExp(r'^[\s\-–|:,]+|[\s\-–|:,]+$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (name == null || name.length < 2) return null;
    // An address as the name says nothing.
    if (name.contains('@')) return null;
    return name;
  }

  static final _linkWords = RegExp(
    r'\b(?:manage|reschedule|re-?book|cancel|change|view|modify|amend|'
    r'confirm)\b[^\n]{0,24}\b(?:appointment|booking|reservation|visit|'
    r'class|session|slot)s?\b|'
    r'\badd to (?:my |your )?(?:google |apple |outlook |i)?(?:calendar|cal)\b|'
    r'^\s*(?:reschedule|cancel|manage|get directions|directions|check in online|'
    r'join (?:video|online|the call)|add to calendar)\s*$',
    caseSensitive: false,
  );

  /// The email's links to manage the appointment or add it to a
  /// calendar, at most four.
  static List<MailLink> _links(AppointmentEmail email) {
    final seen = <String>{};
    return [
      for (final l in email.links)
        if (l.url.scheme == 'https' &&
            l.label.length <= 40 &&
            _linkWords.hasMatch(l.label.trim()) &&
            seen.add(l.label.trim().toLowerCase()))
          MailLink(_tidy(l.label), l.url),
    ].take(4).toList();
  }

  static String _tidy(String label) {
    final t = label.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t == t.toUpperCase() && t.length > 3
        ? '${t[0]}${t.substring(1).toLowerCase()}'
        : t;
  }

  /// The word for an appointment of [a]'s kind ("Dentist" for a
  /// dentist's email).
  static String word(Appointment a) {
    final words = [
      for (final r in a.records)
        [?r.service, ?r.business, r.email.subject, r.email.text].join('\n'),
    ].join('\n');
    return switch (a.kind) {
      AppointmentKind.health
          when RegExp(
            r'\bdent(?:ist|al)\b',
            caseSensitive: false,
          ).hasMatch(words) =>
        'Dentist',
      AppointmentKind.health
          when RegExp(r'\bvaccin', caseSensitive: false).hasMatch(words) =>
        'Vaccination',
      AppointmentKind.health => 'Doctor',
      AppointmentKind.beauty => 'Salon',
      AppointmentKind.car => 'Car service',
      AppointmentKind.home => 'Home visit',
      AppointmentKind.official => 'Appointment',
      AppointmentKind.interview => 'Interview',
      AppointmentKind.school => 'School',
      AppointmentKind.lesson => 'Class',
      AppointmentKind.delivery => 'Delivery',
      AppointmentKind.other => 'Appointment',
    };
  }

  /// The appointments in [emails] (any order), the soonest first: emails
  /// about the same appointment (one calendar event, one booking
  /// reference, or the same sender and time, and a change, cancellation
  /// or reminder of it) are one appointment. The newest time counts.
  static List<Appointment> find(Iterable<AppointmentEmail> emails) {
    final records = [for (final e in emails) ?read(e)]
      ..sort((a, b) {
        final byAt = a.email.at.compareTo(b.email.at);
        return byAt != 0
            ? byAt
            : a.email.messageId.compareTo(b.email.messageId);
      });

    final groups = <_Group>[];
    for (final r in records) {
      final group = _match(groups, r);
      if (group != null) {
        group.records.add(r);
        continue;
      }
      if (r.start == null) continue;
      groups.add(_Group(r));
    }

    return [
      for (final g in groups)
        if (g.records.any((r) => r.start != null)) _appointment(g),
    ]..sort((a, b) => a.start.compareTo(b.start));
  }

  static _Group? _match(List<_Group> groups, AppointmentRecord r) {
    final mine = [
      for (final g in groups)
        if (_sameBusiness(g, r)) g,
    ];
    if (r.uid case final uid?) {
      for (final g in groups) {
        if (g.records.any((x) => x.uid == uid)) return g;
      }
    }
    if (r.reference case final ref?) {
      for (final g in mine) {
        if (g.records.any(
          (x) => x.reference?.toUpperCase() == ref.toUpperCase(),
        )) {
          return g;
        }
      }
    }
    final start = r.start;
    if (start != null) {
      for (final g in mine.reversed) {
        if (_sameTime(g.start, start)) return g;
      }
    }
    // A change or a cancellation of the sender's next appointment.
    if (r.changes || r.cancels) {
      final soon = r.email.at.subtract(const Duration(days: 1));
      for (final g in mine.reversed) {
        if (g.start.instant.isAfter(soon)) {
          // A cancellation naming another day is about another one.
          if (r.cancels && start != null && start.day != g.start.day) {
            continue;
          }
          return g;
        }
      }
    }
    return null;
  }

  static bool _sameBusiness(_Group g, AppointmentRecord r) {
    if (g.sender != r.email.sender) return false;
    final a = _norm(g.business);
    final b = _norm(r.business);
    return a.isEmpty || b.isEmpty || a == b;
  }

  static bool _sameTime(PlaceTime a, PlaceTime b) {
    if (a.day != b.day) return false;
    if (!a.hasTime || !b.hasTime) return true;
    return a.instant == b.instant || a.wall == b.wall;
  }

  static String _norm(String? s) =>
      (s ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  static Appointment _appointment(_Group g) {
    final records = g.records;
    // The latest news on whether it happens: a cancellation, or a booking
    // or change after it.
    var cancelled = false;
    for (final r in records) {
      if (r.cancels) {
        cancelled = true;
      } else if (r.start != null && !r.reminds) {
        cancelled = false;
      }
    }
    final timed = [
      for (final r in records)
        if (r.start != null && !r.cancels) r.start!,
    ];
    // When it was before it last moved.
    final previous = timed.isEmpty
        ? null
        : timed.reversed
              .skip(1)
              .where((s) => !_sameTime(s, timed.last))
              .firstOrNull;
    final first = records.first;
    final id =
        first.uid ??
        first.reference ??
        _isoDay(records.firstWhere((r) => r.start != null).start!);
    return Appointment._(
      key: 'ap:${first.email.sender}:$id'.replaceAll(RegExp(r'[,\s]'), '_'),
      records: List.unmodifiable(records),
      cancelled: cancelled,
      changed: previous != null || records.any((r) => r.changes),
      previousStart: previous,
    );
  }

  static String _isoDay(PlaceTime t) {
    final w = t.wall;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${w.year}-${two(w.month)}-${two(w.day)}T${two(w.hour)}${two(w.minute)}';
  }
}

final class _Group {
  _Group(AppointmentRecord first) : records = [first];

  final List<AppointmentRecord> records;

  String get sender => records.first.email.sender;

  String? get business => records.map((r) => r.business).nonNulls.firstOrNull;

  /// When it is now: the newest time not cancelled.
  PlaceTime get start =>
      records.reversed
          .where((r) => r.start != null && !r.cancels)
          .firstOrNull
          ?.start ??
      records.reversed.firstWhere((r) => r.start != null).start!;
}
