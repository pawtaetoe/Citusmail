// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_extract/mail_extract.dart';
import 'package:mail_store/mail_store.dart';

import 'appointments.dart';
import 'due_dates.dart';
import 'subscriptions.dart' show SubscriptionFinder;
import 'trips.dart';

/// What an event is, to pick an icon and a word for it.
enum EventKind {
  /// A guided tour or an experience: a factory, a distillery, a tasting,
  /// a walk, a cruise.
  tour,

  /// A concert or a gig.
  concert,

  /// Theatre, a musical, comedy, dance, opera.
  show,

  /// A film at the cinema.
  movie,

  /// A match, a race, a game.
  sport,

  /// A festival.
  festival,

  /// An exhibition, a museum, a gallery, an attraction's entry.
  exhibition,

  /// A class, a workshop, a talk, a conference.
  workshop,

  /// A meeting: a calendar invitation, a video call.
  meeting,

  /// A job interview.
  interview,

  /// Anything else with a ticket.
  other,
}

/// One email that may be about an event: a ticket, a booked tour, a
/// calendar invitation, a video call.
final class EventEmail {
  const EventEmail({
    required this.messageId,
    required this.sender,
    required this.senderName,
    required this.subject,
    required this.text,
    required this.at,
    this.reservations = const [],
    this.appointments = const [],
    this.invite,
    this.links = const [],
    this.bulk = false,
  });

  /// The stored message, to open it.
  final MessageId messageId;

  /// The sender's registrable domain (`ticketmaster.com`).
  final String sender;

  /// The sender's display name, if any ("Ticketmaster").
  final String? senderName;
  final String subject;

  /// What is known of the body: the preview, or the whole text once the
  /// message was downloaded. May be empty.
  final String text;
  final DateTime at;

  /// schema.org reservations in its HTML (see mail_extract): an
  /// `EventReservation` is read here; flights, stays and tables are the
  /// Trips page's.
  final List<ReservationInfo> reservations;

  /// schema.org appointments in its HTML: then it is for the
  /// Appointments page.
  final List<AppointmentInfo> appointments;

  /// The calendar event it carries, if any.
  final AppointmentInvite? invite;

  /// Its links, with their words.
  final List<MailLink> links;

  /// Sorted as a newsletter or promotion: not read.
  final bool bulk;
}

/// One email, as understood.
final class EventRecord {
  const EventRecord({
    required this.email,
    required this.kind,
    this.title,
    this.start,
    this.end,
    this.venue,
    this.link,
    this.reference,
    this.uid,
    this.cancels = false,
    this.changes = false,
    this.links = const [],
  });

  final EventEmail email;
  final EventKind kind;

  /// What it is ("Harbour Walk", "Q4 planning").
  final String? title;

  /// When it is, as the email gives it (the new time for a change).
  final PlaceTime? start;
  final PlaceTime? end;

  /// Where: the venue's name or address.
  final String? venue;

  /// The video call's link (Zoom, Google Meet, Teams, Webex).
  final Uri? link;

  /// The booking, order or ticket number, as the email writes it.
  final String? reference;

  /// The calendar event's id, when it came with one.
  final String? uid;

  /// It says the event was cancelled.
  final bool cancels;

  /// It says the event moved.
  final bool changes;

  /// Links to the tickets, to manage the booking.
  final List<MailLink> links;
}

/// An event found in the mail, with every email about it.
final class Event {
  Event._({
    required this.key,
    required this.records,
    required this.cancelled,
    required this.changed,
    this.previousStart,
  });

  /// Stable across loads: used to hide it.
  final String key;

  /// Its emails, oldest first.
  final List<EventRecord> records;

  /// The latest news is that it was cancelled.
  final bool cancelled;

  /// It moved after it was booked.
  final bool changed;

  /// When it was before it moved.
  final PlaceTime? previousStart;

  T? _newest<T>(T? Function(EventRecord r) of) {
    for (final r in records.reversed) {
      if (of(r) case final v?) return v;
    }
    return null;
  }

  /// The record that says when it is: the newest that gives a time (a
  /// reminder that gives only the day keeps the booking's time).
  EventRecord get _timed => EventFinder._timed(records);

  PlaceTime get start => _timed.start!;
  PlaceTime? get end => _timed.end;

  /// What it is called: the newest calendar event's name (a meeting may
  /// be renamed), else the first email's that names it (the booking; a
  /// later "Your event has moved" says less), else the sender's name.
  String get title =>
      records.reversed
          .where((r) => r.uid != null && r.title != null)
          .firstOrNull
          ?.title ??
      records.map((r) => r.title).nonNulls.firstOrNull ??
      records.last.email.senderName ??
      EventFinder.word(kind);

  /// What it is: the first email's that says more than "other".
  EventKind get kind =>
      records
          .map((r) => r.kind)
          .where((k) => k != EventKind.other)
          .firstOrNull ??
      EventKind.other;

  String? get venue => _newest((r) => r.venue);

  /// The video call's link, if it happens online.
  Uri? get link => _newest((r) => r.link);

  /// It happens online (a video call).
  bool get online => link != null;

  String? get reference => _newest((r) => r.reference);

  /// The sender's registrable domain.
  String get sender => records.last.email.sender;

  /// The newest email.
  EventRecord get latest => records.last;

  /// Links from its emails, the newest first, one per label.
  List<MailLink> get links {
    final seen = <String>{};
    return [
      for (final r in records.reversed)
        for (final l in r.links)
          if (seen.add(l.label.toLowerCase())) l,
    ];
  }

  /// When it is over: its end, else a while after it starts (an hour for
  /// a meeting, two for the rest; a date alone, that whole day).
  DateTime get endsAt {
    final s = start;
    final e = end;
    if (e != null && e.compareTo(s) > 0) {
      return e.hasTime ? e.instant : e.instant.add(const Duration(days: 1));
    }
    if (!s.hasTime) return s.instant.add(const Duration(days: 1));
    final meeting = kind == EventKind.meeting || kind == EventKind.interview;
    return s.instant.add(Duration(hours: meeting ? 1 : 2));
  }

  @override
  String toString() => 'Event($key)';
}

/// Reads events from the words of ticket and booking emails and from
/// calendar invitations. Careful: an email is an event only when it says
/// it was booked ("Your booking is confirmed", "Here are your tickets",
/// "Thank you for registering"), says what kind of thing it is (a tour,
/// a concert, a film) or carries a video call's link, and gives a date.
abstract final class EventText {
  static RegExp _re(String pattern) => RegExp(pattern, caseSensitive: false);

  /// Subjects of mail that speaks of events without being a booking:
  /// sales, announcements, recommendations, reviews.
  static final notAnEvent = _re(
    r'\b(?:on sale|pre-?sales?|just announced|announcing|new (?:dates?|shows?|events?)|'
    r'events? (?:near|for) you|(?:what.?s|happening) (?:on|near)|recommended|'
    r'you might (?:like|enjoy)|picked for you|don.?t miss|last chance|limited time|'
    r'newsletter|digest|deals?|offers?|save up to|promo(?:tion|s|code)?|discount|'
    r'win|giveaway|survey|feedback|rate your|review|how was|tell us|share your|'
    r'this week(?:end)? in|line-?up|coming soon|early bird|get (?:your )?tickets|'
    r'buy tickets|book now|book (?:your|today)|grab (?:your|a)|register now|'
    r'sign up (?:now|today)|save the date|invitation to|invited to (?:attend|join)|'
    r'webinar series|free trial|upgrade)\b|\d+% off',
  );

  /// "Get your tickets", "Buy tickets": said in every promotion.
  static final _sales = _re(
    r'\b(?:get|buy|grab|book|find|secure) (?:your |more )?(?:tickets?|seats?)\b',
  );

  /// Words that the email confirms a booking, a ticket or a registration,
  /// or recalls one.
  static final _booked = _re(
    r'\b(?:bookings?|orders?|reservations?|registrations?|purchases?|tickets?|seats?|'
    r'interviews?|tours?|experiences?|activit(?:y|ies)|visits?)\b'
    r'[^.\n]{0,40}?\b(?:is |has been |are |have been )?'
    r'(?:confirmed|completed?|successful|received)\b|'
    r'\bthank(?:s| you) for (?:booking|purchasing|buying|registering|signing up|'
    r'your (?:booking|order|purchase|reservation|registration))\b|'
    r'\b(?:here (?:are|is) your|this is your|your) (?:e-?|mobile |digital |'
    r'admission |movie |entry |event )?(?:tickets?|passes|e-?tickets?|admission)\b|'
    r"\byou(?:'re| are) (?:going|registered|booked|all set|confirmed)\b|"
    r'\b(?:booking|order|confirmation|reservation|ticket|registration) '
    r'(?:id|ref(?:erence)?|number|no\.?|code|#)|'
    r'\bconfirmation (?:id|number|no\.?|code)\b|'
    r'\b(?:is|starts?) (?:in \d+ days?|tomorrow|today)\b|'
    r'\bpresent (?:your|this) (?:tickets?|order number|qr ?code|e-?tickets?|booking)\b|'
    r'\bscan (?:the|this|your) (?:qr|bar) ?code\b|'
    r'\bdate of (?:the )?(?:event|visit|show|performance|tour)\b|'
    r'\b(?:event|show|performance) (?:date|time)\b|'
    r'\bseats?:\s*[A-Z]?\d|'
    r'\binterviews?\b[^.\n]{0,40}?\b(?:is |has been )?(?:scheduled|arranged|booked)\b|'
    r'\binvit(?:e|ed|ing) you (?:to|for) an? (?:\w+ )?interview\b',
  );

  /// Words of something you go to, by kind; the first that matches counts.
  /// A world tour is a concert; a class is a workshop.
  static final _kinds = <(EventKind, RegExp)>[
    (
      EventKind.interview,
      _re(
        r'\binterviews?\b(?!\s+(?:skills?|tips|prep\w*|questions|guide|workshop|training))',
      ),
    ),
    (
      EventKind.movie,
      _re(
        r'\b(?:cinemas?|movies?|films?|screenings?|imax|4dx|tix|'
        r'cineplex|multiplex|odeon|vue|cineworld|amc|regal)\b',
      ),
    ),
    (EventKind.festival, _re(r'\bfestival\w*|\bfest\b|\bcarnival\b')),
    (
      EventKind.concert,
      _re(
        r'\b(?:concerts?|gigs?|music|orchestra|symphon\w*|philharmonic|'
        r'recital|choir|world tour|arena tour|\d{4} tour|dj set|live in concert)\b',
      ),
    ),
    (
      EventKind.sport,
      _re(
        r'\b(?:match(?:day)?|vs\.?|stadium|kick-?off|grand prix|race day|'
        r'championships?|league|cup final|game day|football|soccer|rugby|'
        r'cricket|tennis|basketball|baseball|hockey|marathon|formula 1|f1)\b',
      ),
    ),
    (
      EventKind.show,
      _re(
        r'\b(?:theat(?:re|er)s?|musicals?|ballet|opera|comedy|stand-?up|'
        r'circus|cabaret|matin[eé]e|playhouse|the show|showtime|performances?)\b',
      ),
    ),
    (
      EventKind.exhibition,
      _re(
        r'\b(?:exhibitions?|exhibits?|museums?|galler(?:y|ies)|expo|zoo|'
        r'aquarium|theme park|attractions?|observation deck|botanic\w* gardens?|'
        r'planetarium)\b',
      ),
    ),
    (
      EventKind.tour,
      _re(
        r'\b(?:tours?|guided|experiences?|tastings?|distillery|brewery|winery|'
        r'factory|excursions?|day trip|sightseeing|cruise|walking|safari|'
        r'escape rooms?|activit(?:y|ies)|kayak\w*|snorkel\w*|zipline|'
        r'hot air balloon)\b',
      ),
    ),
    (
      EventKind.workshop,
      _re(
        r'\b(?:workshops?|atelier|masterclass(?:es)?|classes|course|seminars?|'
        r'conferences?|summit|meetups?|webinars?|talks?|lectures?|bootcamp|'
        r'briefing)\b',
      ),
    ),
    (
      EventKind.meeting,
      _re(
        r'\b(?:meetings?|calls?|sync|stand-?up|1:1|one-on-one|catch-?up|'
        r'zoom|microsoft teams|google meet|webex)\b',
      ),
    ),
  ];

  /// Words that it is an event, whatever its kind.
  static final _eventWords = _re(
    r'\b(?:events?|venue|doors open|admission|entry|showtime|performance|'
    r'activit(?:y|ies)|meeting point)\b',
  );

  /// What kind of event its [head] (the title, the subject, the sender's
  /// name) says, else its [text].
  static EventKind kindOf(String head, {String text = ''}) {
    for (final words in [head, _cap(text, 4000)]) {
      for (final (kind, re) in _kinds) {
        if (re.hasMatch(words)) return kind;
      }
    }
    return EventKind.other;
  }

  // ---------------------------------------------------------- meetings

  /// A video call's address: Zoom, Google Meet, Microsoft Teams, Webex.
  static final _meetingUrl = RegExp(
    r'https://(?:[\w-]+\.)*(?:zoom\.us/(?:j|w|my|s|wc)/|'
    r'meet\.google\.com/[a-z]{3,4}-|teams\.microsoft\.com/l/meetup-join|'
    r'teams\.live\.com/meet|webex\.com/(?:meet|join|[\w.-]+/j\.php|wbxmjs))'
    r'''[^\s<>"'\)\]]*''',
    caseSensitive: false,
  );

  /// Whether [url] joins a video call.
  static bool isMeetingLink(Uri url) => _meetingUrl.hasMatch(url.toString());

  /// The video call link in [text] or [links], if any.
  static Uri? meetingLinkIn(String text, [List<MailLink> links = const []]) {
    for (final l in links) {
      if (l.url.scheme == 'https' && isMeetingLink(l.url)) return l.url;
    }
    final m = _meetingUrl.firstMatch(_cap(text, 20000));
    return m == null ? null : Uri.tryParse(m[0]!);
  }

  // ------------------------------------------------- cancelled, moved

  static final _cancelledSubject = _re(
    r'\bcancell?ed\b|\bcancell?ation\b(?!\s+(?:policy|terms|fee|charges?))|'
    r'\bcalled off\b',
  );
  static final _cancelled = _re(
    r'\b(?:events?|shows?|concerts?|performances?|tours?|bookings?|orders?|'
    r'tickets?|meetings?|registrations?|screenings?|match|sessions?|'
    r'experiences?|reservations?)\b[^.\n]{0,60}?'
    r'\b(?:has been|have been|was|were|is|is now)\s+(?:cancell?ed|called off)\b|'
    r"\bwe(?:'ve| have) (?:had to )?cancell?ed\b|"
    r'\bcancell?ation (?:confirmation|confirmed)\b',
  );

  /// "Free cancellation up to 48 hours before": said in every booking.
  static final _cancellationTerms = _re(
    r'\b(?:free|no|flexible|easy|late) cancell?ation\b|\bcancell?ation '
    r'(?:policy|fee|charges?|deadline|terms|is free|before)\b|'
    r'\bcancell?ation\s+(?:up to|until|within|no later)\b|'
    r'\bif (?:you )?(?:wish|need|want) to (?:\w+ (?:or|and) )?cancel\b|'
    r'\bcancel(?:led)? (?:at least|up to|no later)\b|'
    r'\bcancel your (?:registration|booking)\b',
  );

  /// Whether it says the event was cancelled.
  static bool saysCancelled(String subject, String text) {
    final s = subject.replaceAll(_cancellationTerms, '');
    if (_cancelledSubject.hasMatch(s)) return true;
    return _cancelled.hasMatch(
      _cap(text, 6000).replaceAll(_cancellationTerms, ''),
    );
  }

  static final _changedSubject = _re(
    r'\b(?:re-?scheduled|postponed|moved|new (?:date|time)|date change|'
    r'time change|changed|updated invitation|event updated)\b',
  );
  static final _changed = _re(
    r'\b(?:events?|shows?|concerts?|performances?|tours?|bookings?|meetings?|'
    r'sessions?|match|screenings?)\b[^.\n]{0,40}?'
    r'\b(?:has been|was|is now|have been)\s+(?:re-?scheduled|moved|postponed|changed)\b|'
    r'\b(?:re-?scheduled|moved|postponed) (?:to|until)\b|\bnew (?:date|time)\b',
  );

  /// Whether it says the event moved.
  static bool saysChanged(String subject, String text) =>
      _changedSubject.hasMatch(subject) || _changed.hasMatch(_cap(text, 6000));

  // ------------------------------------------------------- dates, times

  static final _dateLabel = _re(
    r'^\s*(?:date(?: of (?:the )?(?:event|visit|show|performance|tour))?|'
    r'(?:event|show|visit|tour|performance) date|when|day)\s*[:\-]\s*(.+)$',
  );
  static final _timeLabel = _re(
    r'\b(?:start(?:s|ing)?(?: time| at)?|time|show ?time|session|doors(?: open)?|'
    r'begins?|event time)\s*[:\-]\s*',
  );
  static final _duration = _re(
    r'\bduration\s*[:\-]?\s*(\d{1,2}(?:[.,]\d)?)\s*(hours?|hrs?|h|minutes?|mins?)\b',
  );
  static final _startLabel = RegExp(
    r'^\s*start(?:s|ing)?(?: time| at)?\s*[:\-]\s*\d',
    caseSensitive: false,
    multiLine: true,
  );
  static final _inDays = _re(r'\b(?:is|starts?) in (\d{1,2}) days?\b');

  /// When the event is in [text] (written at [sent]): a date and a time
  /// close together ("Saturday, March 14, 2026 at 2:00pm"), else a
  /// labelled date and a labelled time ("Date of Event: 5 May 2026",
  /// "Start time: 10:30"), else "is in 2 days" (the day alone).
  static ({PlaceTime start, PlaceTime? end})? whenIn(
    String text,
    DateTime sent, {
    bool changed = false,
    bool cancelled = false,
  }) {
    // "Start time: 10:30" says it best (an "Arrival: 10:15" may sit
    // closer to the date).
    var when = _startLabel.hasMatch(_cap(text, 20000))
        ? _labelled(text, sent, cancelled: cancelled)
        : null;
    if (when != null && !when.start.hasTime) when = null;
    when ??= AppointmentText.whenIn(
      text,
      sent,
      changed: changed,
      cancelled: cancelled,
    );
    when ??= _labelled(text, sent, cancelled: cancelled);
    if (when == null) {
      final m = _inDays.firstMatch(_cap(text, 4000));
      if (m != null) {
        final local = sent.toLocal();
        final d = DateTime.utc(
          local.year,
          local.month,
          local.day + int.parse(m[1]!),
        );
        when = (
          start: PlaceTime(d.year, d.month, d.day, hasTime: false),
          end: null,
        );
      }
    }
    if (when == null) return null;
    if (when.end == null && when.start.hasTime) {
      if (_duration.firstMatch(_cap(text, 20000)) case final m?) {
        final n = double.parse(m[1]!.replaceAll(',', '.'));
        final minutes = m[2]!.toLowerCase().startsWith('m')
            ? n.round()
            : (n * 60).round();
        if (minutes > 0 && minutes <= 24 * 60) {
          final s = when.start;
          final w = s.wall.add(Duration(minutes: minutes));
          return (
            start: s,
            end: PlaceTime(
              w.year,
              w.month,
              w.day,
              hour: w.hour,
              minute: w.minute,
              offset: s.offset,
            ),
          );
        }
      }
    }
    return when;
  }

  static ({PlaceTime start, PlaceTime? end})? _labelled(
    String text,
    DateTime sent, {
    required bool cancelled,
  }) {
    final lines = _cap(text, 20000).split('\n').take(400).toList();
    DateTime? day;
    for (final line in lines) {
      final m = _dateLabel.firstMatch(line);
      if (m == null) continue;
      final d = DueDates.datesIn(m[1]!, reference: sent).firstOrNull;
      if (d != null) {
        day = d.date;
        break;
      }
    }
    if (day == null) return null;
    if (!cancelled &&
        day.isBefore(DateTime.utc(sent.year, sent.month, sent.day - 1))) {
      return null;
    }
    ({int hour, int minute})? start;
    ({int hour, int minute})? end;
    for (final line in lines) {
      final m = _timeLabel.firstMatch(line);
      if (m == null) continue;
      final rest = line.substring(m.end);
      final times = AppointmentText.timesIn(rest);
      if (times.isEmpty || times.first.at > 2) continue;
      start = (hour: times.first.hour, minute: times.first.minute);
      if (times.length > 1 &&
          RegExp(r'^\s*(?:-|–|—|to|until)\s*$')
              .hasMatch(rest.substring(times[0].end, times[1].at))) {
        end = (hour: times[1].hour, minute: times[1].minute);
      }
      // "Start time" is the one; an earlier "Arrival" or "Doors" yields.
      if (RegExp(r'^\s*start', caseSensitive: false).hasMatch(line)) break;
    }
    if (start == null) {
      return (
        start: PlaceTime(day.year, day.month, day.day, hasTime: false),
        end: null,
      );
    }
    final s = PlaceTime(
      day.year,
      day.month,
      day.day,
      hour: start.hour,
      minute: start.minute,
    );
    final e = end == null
        ? null
        : PlaceTime(
            day.year,
            day.month,
            day.day,
            hour: end.hour,
            minute: end.minute,
          );
    return (start: s, end: e != null && e.compareTo(s) > 0 ? e : null);
  }

  // ----------------------------------------------------------- details

  static final _titleLabel = _re(
    r'^\s*(?:event(?: name)?|experience|tour|activity|show|film|movie|'
    r'performance|production|title|programme|program|topic|meeting|session|'
    r'webinar)\s*[:\-]\s*(.+)$',
  );
  static final _quotedTitle = _re(
    r'(?:tickets? (?:for|to)|booking (?:for|of)|register(?:ing|ed)? for|'
    r'reservation for|order for|booked|signed up for)\s+(?:the\s+)?'
    r'[«“"‘]([^»”"’\n]{3,90})[»”"’]',
  );
  static final _registeredFor = _re(
    r'\b(?:thank you for registering|you(?:.re| are|.ve| have) registered|'
    r'registration (?:is )?confirmed) for (?:the )?([^.\n]{3,90}?)\s*(?:[.!\n]|$)',
  );

  /// What the event is called, as the email gives it: a labelled line
  /// ("Experience: Harbour Walk"), a name in quotes after "tickets for",
  /// "registering for X", else the subject, tidied.
  static String? titleIn(String subject, String text) {
    final sample = _cap(text, 20000);
    for (final line in sample.split('\n').take(300)) {
      final v = _cleanTitle(_titleLabel.firstMatch(line)?[1]);
      if (v != null && !_looksLikeWhen(v)) return v;
    }
    if (_cleanTitle(_quotedTitle.firstMatch(sample)?[1]) case final t?) {
      return t;
    }
    if (_cleanTitle(_registeredFor.firstMatch(sample)?[1]) case final t?) {
      return t;
    }
    final fromSubject = titleOfSubject(subject);
    if (fromSubject != null && !_bookingWords.hasMatch(fromSubject)) {
      return fromSubject;
    }
    return _nameAboveWhen(sample) ?? fromSubject;
  }

  static final _bookingWords = _re(
    r'\b(?:confirm\w*|tickets?|tix|booking|order|reservation|receipt|'
    r'purchase|dear|thank|id|number)\b',
  );

  /// A ticket's name on the line above its date and time ("STARLIGHT
  /// ODYSSEY", "(PG13)", "19 Dec 2026 06:40 PM Hall 3"), past a rating.
  static String? _nameAboveWhen(String text) {
    final lines = [
      for (final l in text.split('\n').take(200))
        l
            .replaceAll(RegExp(r'[|*]'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim(),
    ];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (DueDates.datesIn(line).isEmpty ||
          AppointmentText.timesIn(line).isEmpty) {
        continue;
      }
      for (var j = i - 1; j >= 0 && j >= i - 4; j--) {
        final above = lines[j];
        if (above.isEmpty) continue;
        // A rating: "(PG13)", "M18".
        if (RegExp(r'^\(?[A-Z0-9+\-]{1,6}\)?$').hasMatch(above)) continue;
        if (_bookingWords.hasMatch(above) ||
            RegExp(r'[.!?:]$').hasMatch(above) ||
            RegExp(
              r'\b(?:scan|qr|seat|hall|hello|hi|your)\b',
              caseSensitive: false,
            ).hasMatch(above)) {
          return null;
        }
        return _cleanTitle(above);
      }
      return null;
    }
    return null;
  }

  static final _subjectNoise = _re(
    r'^(?:(?:re|fwd?|updated invitation|invitation|updated|reminder|'
    r'confirmed|confirmation|booking confirmed|booking confirmation|'
    r'order confirmation|your (?:e-?|movie |mobile )?(?:tickets?|tix)(?: for| to)?|'
    r'(?:e-?)?tickets? (?:for|to)|'
    r'your booking(?: is confirmed)?(?: for)?|your order(?: for)?|'
    r'registration confirmed(?: for)?|you.re (?:going|registered)(?: to| for)?|'
    r'cancell?ed(?: event)?|canceled event|event cancell?ed|'
    r'new event|accepted|declined)\b\s*[:\-–|]*\s*)+',
  );

  /// [subject] without "Your booking is confirmed –", "Invitation:",
  /// " @ Thu 12 Nov 3pm", " is in 2 days". Null when nothing is left
  /// that names it.
  static String? titleOfSubject(String subject) {
    final quoted = RegExp('[«“"]([^»”"]{3,80})[»”"]').firstMatch(subject);
    if (quoted != null) return _cleanTitle(quoted[1]);
    var s = subject
        .replaceFirst(_subjectNoise, '')
        // Google Calendar: "Title @ Thu 12 Nov 2026 3pm - 4pm (GMT+8)".
        .replaceFirst(RegExp(r'\s+@\s+.*$'), '')
        .replaceFirst(
          RegExp(
            r'\s+(?:is (?:in \d+ days?|tomorrow|today|coming up)|'
            r'(?:is|are|has been|have been) (?:confirmed|cancell?ed|'
            r're-?scheduled|moved|postponed))\.?$',
            caseSensitive: false,
          ),
          '',
        )
        .replaceFirst(
          RegExp(
            r'(?:\s+[\-–|]|\s*:)\s*(?:booking |order |registration )?'
            r'(?:confirmed|confirmation|tickets?|cancell?ed)\.?$',
            caseSensitive: false,
          ),
          '',
        );
    s = s.trim();
    final words = s.replaceAll(
      RegExp(
        r'\b(?:your|the|a|an|is|has|been|booking|order|tickets?|confirmed|'
        r'confirmation|received|thank|thanks|you|for|reminder|dear|here|are|'
        r'events?|shows?|meeting|rescheduled|moved|postponed|cancell?ed|'
        r'updated?|changed?)\b|'
        r'[^\w]',
        caseSensitive: false,
      ),
      '',
    );
    if (words.length < 3) return null;
    return _cleanTitle(s);
  }

  static bool _looksLikeWhen(String v) =>
      DueDates.datesIn(v).isNotEmpty && v.length < 40;

  static String? _cleanTitle(String? value) {
    final v = value
        ?.replaceAll('*', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceFirst(RegExp(r'[.,;:\s]+$'), '')
        .trim();
    if (v == null || v.length < 3 || v.length > 90) return null;
    if (!RegExp(r'\p{L}{2}', unicode: true).hasMatch(v)) return null;
    // An all-capitals name reads better in title case.
    if (v == v.toUpperCase() && v.length > 4) {
      return v
          .toLowerCase()
          .split(' ')
          .map(
            (w) => w.isEmpty
                ? w
                : (w.length <= 2 && w != 'vr' && w != 'dj'
                      ? w
                      : '${w[0].toUpperCase()}${w.substring(1)}'),
          )
          .join(' ')
          .replaceFirstMapped(RegExp(r'^\w'), (m) => m[0]!.toUpperCase());
    }
    return v;
  }

  static final _venueLabel = _re(
    r'^\s*(?:venue|location|event location|where|place|address|cinema|'
    r'theat(?:re|er)|meeting point|stadium|arena)\s*[:\-]\s*(.+)$',
  );

  /// Where it is: a labelled venue, else a line that reads like an
  /// address. Not a link.
  static String? venueIn(String text) {
    for (final line in _cap(text, 20000).split('\n').take(300)) {
      final m = _venueLabel.firstMatch(line);
      if (m == null) continue;
      final v = m[1]!
          .replaceAll('*', '')
          .replaceAll(RegExp(r'<https?://[^>]*>|https?://\S+'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .replaceFirst(RegExp(r'[.,;:\s]+$'), '')
          .trim();
      if (v.length >= 3 &&
          v.length <= 140 &&
          RegExp('[A-Za-z]{2}').hasMatch(v)) {
        return v;
      }
    }
    final p = AppointmentText.placeIn(text);
    if (p != null && p.contains('://')) return null;
    return p;
  }

  /// Whether [email]'s words read like a booked event: it confirms a
  /// booking, a ticket or a registration (or recalls one), and it is not
  /// a promotion.
  static bool readsLikeBooked(EventEmail email) {
    if (email.bulk || notAnEvent.hasMatch(email.subject)) return false;
    final head = _cap(
      '${email.subject}\n${email.text}',
      6000,
    ).replaceAll(_sales, '');
    return _booked.hasMatch(head) || saysCancelled(email.subject, email.text);
  }

  /// Whether [subject] and [text] name an event: its kind, the word
  /// "event", or a video call's link.
  static bool namesAnEvent(String subject, String text, {Uri? link}) =>
      link != null ||
      kindOf(subject, text: text) != EventKind.other ||
      _eventWords.hasMatch('$subject\n${_cap(text, 4000)}');

  static String _cap(String s, int n) => s.length > n ? s.substring(0, n) : s;
}

/// Finds events in ticket and booking mail and in calendar invitations,
/// on the device: from schema.org `EventReservation` markup, a calendar
/// event, or the words of a confirmation; and puts each one's emails
/// together (a reminder, a change, a cancellation). An appointment stays
/// an appointment, and flights, stays and tables stay on Trips.
abstract final class EventFinder {
  /// Subject words of mail worth looking at (also used to pick it from
  /// the store).
  static const subjectWords = [
    'ticket',
    'tix',
    'tour',
    'booking',
    'booked',
    'confirm',
    'order',
    'reservation',
    'registration',
    'registered',
    'registering',
    'invitation',
    'event',
    'concert',
    'show',
    'movie',
    'film',
    'cinema',
    'screening',
    'match',
    'festival',
    'exhibition',
    'museum',
    'admission',
    'experience',
    'workshop',
    'class',
    'meeting',
    'webinar',
    'interview',
    'cancel',
    'reschedul',
    'postpone',
    'reminder',
    'days',
    'tomorrow',
    "you're going",
  ];

  static final _subject = RegExp(
    r'\b(?:e-?tickets?|tickets?|tix|tours?|booking|booked|confirm\w*|'
    r'reservation|registration|registered|invitation|events?|concerts?|'
    r'shows?|movies?|films?|cinema|screening|match|festival|exhibition|'
    r'museum|admission|experience|workshop|meeting|webinar|interview|'
    r'cancell?ed|re-?scheduled|postponed|is in \d+ days?)\b',
    caseSensitive: false,
  );

  /// Whether [subject] (and the start of the text, [preview]) reads like
  /// an event, worth downloading.
  static bool looksLikeEvent(String subject, {String preview = ''}) {
    if (SubscriptionFinder.isReplyOrForward(subject)) return false;
    if (EventText.notAnEvent.hasMatch(subject)) return false;
    if (TripFinder.looksLikeBooking(subject) &&
        RegExp(
          r'\b(?:flights?|hotel|stay|train|bus|car|table|itinerary|boarding)\b',
          caseSensitive: false,
        ).hasMatch(subject)) {
      return false;
    }
    if (_subject.hasMatch(subject) &&
        EventText.namesAnEvent(subject, preview)) {
      return true;
    }
    if (RegExp(
      r'\b(?:your|e-?|mobile) ?tickets?\b',
      caseSensitive: false,
    ).hasMatch(subject)) {
      return true;
    }
    // "Your order has been received", with "tickets for «…»"
    // in its preview.
    final head = '$subject\n$preview';
    return EventText._booked.hasMatch(head.replaceAll(EventText._sales, '')) &&
        EventText.kindOf(head) != EventKind.other;
  }

  /// [email] as the appointments finder sees it.
  static AppointmentEmail _asAppointment(EventEmail e) => AppointmentEmail(
    messageId: e.messageId,
    sender: e.sender,
    senderName: e.senderName,
    subject: e.subject,
    text: e.text,
    at: e.at,
    appointments: e.appointments,
    reservations: [
      for (final r in e.reservations)
        if (r is! EventReservationInfo) r,
    ],
    invite: e.invite,
    links: e.links,
    bulk: e.bulk,
  );

  /// [email], as understood, or null when it says nothing of an event
  /// (or it is an appointment, or a trip's).
  static EventRecord? read(EventEmail email) {
    if (SubscriptionFinder.isReplyOrForward(email.subject)) return null;
    if (email.bulk) return null;
    // Flights, stays, trains and tables: the Trips page's.
    if (email.reservations.any((r) => r is! EventReservationInfo)) return null;
    final events = [
      for (final r in email.reservations)
        if (r case final EventReservationInfo e when e.start != null) e,
    ];
    if (events.isNotEmpty) return _fromMarkup(email, events.first);
    // A clinic, a salon, a garage: the Appointments page's.
    if (email.appointments.isNotEmpty) return null;
    if (AppointmentFinder.read(_asAppointment(email)) != null) return null;
    if (email.invite case final i?) return _fromInvite(email, i);
    return _fromWords(email);
  }

  static EventRecord _fromMarkup(EventEmail email, EventReservationInfo e) {
    final words = '${email.subject}\n${email.text}';
    final cancels =
        e.status == ReservationStatus.cancelled ||
        EventText.saysCancelled(email.subject, email.text);
    final title = e.eventName ?? EventText.titleIn(email.subject, email.text);
    final venue = e.venue;
    final where = [
      ?venue?.name,
      if (venue?.address case final a? when a != venue?.name) a,
    ].join(', ');
    final link = EventText.meetingLinkIn(email.text, email.links);
    return EventRecord(
      email: email,
      kind: EventText.kindOf(
        [?title, email.subject, email.senderName ?? ''].join('\n'),
        text: email.text,
      ),
      title: title,
      start: e.start,
      end: e.end,
      venue: where.isNotEmpty
          ? where
          : (venue?.locality ?? EventText.venueIn(email.text)),
      link: link,
      reference:
          e.reservationNumber ??
          e.ticketNumber ??
          AppointmentText.referenceIn(words),
      cancels: cancels,
      changes: !cancels && EventText.saysChanged(email.subject, email.text),
      links: [
        if (e.url case final u?) MailLink('Manage booking', u),
        ..._links(email),
      ],
    );
  }

  /// A calendar invitation: a meeting among colleagues, an online
  /// interview, a talk (a business's booking is the Appointments page's).
  static EventRecord? _fromInvite(EventEmail email, AppointmentInvite i) {
    final start = i.start;
    if (i.reply || start == null) return null;
    final title = _clean(i.summary) ?? EventText.titleOfSubject(email.subject);
    final description = i.description ?? '';
    final location = i.location;
    final locationLink = location == null
        ? null
        : EventText.meetingLinkIn(location);
    final link =
        i.meetingLink ??
        locationLink ??
        EventText.meetingLinkIn('$description\n${email.text}', email.links);
    final head = [?title, email.subject].join('\n');
    final kind = switch (EventText.kindOf(head, text: description)) {
      // A calendar file for a ticket: what it is for.
      EventKind.other || EventKind.workshop when link != null =>
        EventText.kindOf(head) == EventKind.workshop
            ? EventKind.workshop
            : EventKind.meeting,
      EventKind.other => EventKind.meeting,
      final k => k,
    };
    final cancels =
        i.cancelled ||
        RegExp(
          r'^(?:cancell?ed(?: event)?|canceled event|event cancell?ed)\s*:',
          caseSensitive: false,
        ).hasMatch(email.subject);
    return EventRecord(
      email: email,
      kind: kind,
      title: title,
      start: start,
      end: i.end,
      venue: location == null || location.contains('://')
          ? null
          : _clean(location, max: 140),
      link: link,
      uid: i.uid.isEmpty ? null : i.uid,
      cancels: cancels,
      changes:
          !cancels &&
          (i.sequence > 0 ||
              RegExp(
                r'^updated invitation\b',
                caseSensitive: false,
              ).hasMatch(email.subject) ||
              EventText.saysChanged(email.subject, email.text)),
      links: _links(email),
    );
  }

  /// A ticket, a booked tour, a registration, from its words.
  static EventRecord? _fromWords(EventEmail email) {
    if (!EventText.readsLikeBooked(email)) return null;
    final link = EventText.meetingLinkIn(email.text, email.links);
    if (!EventText.namesAnEvent(email.subject, email.text, link: link)) {
      return null;
    }
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
    final cancels = EventText.saysCancelled(email.subject, email.text);
    final changes =
        !cancels && EventText.saysChanged(email.subject, email.text);
    final when = EventText.whenIn(
      words,
      email.at,
      changed: changes,
      cancelled: cancels,
    );
    // A cancellation may name no date: it is matched with the sender's
    // next event.
    if (when == null && !cancels) return null;
    final title = EventText.titleIn(email.subject, email.text);
    final kind = EventText.kindOf(
      [?title, email.subject, email.senderName ?? ''].join('\n'),
      text: email.text,
    );
    // A meeting needs its link or a calendar file: words alone are too
    // often an agenda or a newsletter.
    if (kind == EventKind.meeting && link == null) return null;
    final online = link != null && kind == EventKind.meeting;
    return EventRecord(
      email: email,
      kind: kind,
      title: title,
      start: when?.start,
      end: when?.end,
      venue: online ? null : EventText.venueIn(email.text),
      link: link,
      // Meeting ids and passcodes are not booking references.
      reference: link != null ? null : AppointmentText.referenceIn(words),
      cancels: cancels,
      changes: changes,
      links: _links(email),
    );
  }

  static String? _clean(String? value, {int max = 90}) {
    final v = value?.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (v == null || v.length < 2 || v.length > max) return null;
    return v;
  }

  static final _linkWords = RegExp(
    r'\b(?:view|manage|download|open|show|get|see|print)\b[^\n]{0,20}\b'
    r'(?:tickets?|e-?tickets?|booking|order|reservation|pass(?:es)?)\b|'
    r'^\s*(?:your )?(?:admission |e-?|mobile )?tickets?\s*(?:→|>)?\s*$|'
    r'^\s*(?:join(?: the)? (?:meeting|call|webinar|event|zoom meeting|'
    r'with google meet|microsoft teams meeting)|join now|get directions|'
    r'directions)\s*$',
    caseSensitive: false,
  );

  /// The email's links to its tickets or to join, at most four.
  static List<MailLink> _links(EventEmail email) {
    final seen = <String>{};
    return [
      for (final l in email.links)
        if (l.url.scheme == 'https' &&
            l.label.length <= 40 &&
            _linkWords.hasMatch(l.label.trim()) &&
            seen.add(l.label.trim().toLowerCase()))
          MailLink(
            l.label.replaceAll(RegExp(r'\s*[→>]\s*$'), '').trim(),
            l.url,
          ),
    ].take(4).toList();
  }

  /// The word for an event of [kind] ("Concert").
  static String word(EventKind kind) => switch (kind) {
    EventKind.tour => 'Tour',
    EventKind.concert => 'Concert',
    EventKind.show => 'Show',
    EventKind.movie => 'Film',
    EventKind.sport => 'Match',
    EventKind.festival => 'Festival',
    EventKind.exhibition => 'Exhibition',
    EventKind.workshop => 'Workshop',
    EventKind.meeting => 'Meeting',
    EventKind.interview => 'Interview',
    EventKind.other => 'Event',
  };

  /// The record that says when an event is: the newest with a date and
  /// not a cancellation (a reminder that gives the day alone keeps an
  /// earlier email's time on that day).
  static EventRecord _timed(List<EventRecord> records) {
    final dated = records.reversed
        .where((r) => r.start != null && !r.cancels)
        .toList();
    if (dated.isEmpty) {
      return records.reversed.firstWhere((r) => r.start != null);
    }
    final newest = dated.first;
    if (newest.start!.hasTime) return newest;
    return dated
            .where((r) => r.start!.hasTime && r.start!.day == newest.start!.day)
            .firstOrNull ??
        newest;
  }

  /// The events in [emails] (any order), the soonest first: emails about
  /// the same event (one calendar event, one booking reference, or the
  /// same sender and time or name and day, and a change, cancellation or
  /// reminder of it) are one event. The newest time counts.
  static List<Event> find(Iterable<EventEmail> emails) {
    final records = [for (final e in emails) ?read(e)]
      ..sort((a, b) {
        final byAt = a.email.at.compareTo(b.email.at);
        return byAt != 0
            ? byAt
            : a.email.messageId.value.compareTo(b.email.messageId.value);
      });

    final groups = <List<EventRecord>>[];
    for (final r in records) {
      final group = _match(groups, r);
      if (group != null) {
        group.add(r);
        continue;
      }
      if (r.start == null) continue;
      groups.add([r]);
    }
    return [for (final g in groups) _event(g)]
      ..sort((a, b) => a.start.compareTo(b.start));
  }

  static String _norm(String? s) => (s ?? '').toLowerCase().replaceAll(
    RegExp(r'[^\p{L}\p{N}]', unicode: true),
    '',
  );

  static List<EventRecord>? _match(
    List<List<EventRecord>> groups,
    EventRecord r,
  ) {
    if (r.uid case final uid?) {
      for (final g in groups) {
        if (g.any((x) => x.uid == uid)) return g;
      }
      // Another calendar event: not the same, whatever the time.
      return null;
    }
    final mine = [
      for (final g in groups)
        if (g.first.email.sender == r.email.sender) g,
    ];
    if (r.reference case final ref?) {
      for (final g in mine) {
        if (g.any((x) => x.reference?.toUpperCase() == ref.toUpperCase())) {
          return g;
        }
      }
    }
    final start = r.start;
    if (start != null) {
      for (final g in mine.reversed) {
        final s = _timed(g).start!;
        if (start.hasTime && s.hasTime && s.compareTo(start) == 0) return g;
        // A reminder: the same name on the same day.
        if (s.day == start.day &&
            _norm(r.title).isNotEmpty &&
            g.any((x) => _norm(x.title) == _norm(r.title))) {
          return g;
        }
      }
    }
    // A change or a cancellation of the sender's next event.
    if (r.changes || r.cancels) {
      final soon = r.email.at.subtract(const Duration(days: 1));
      for (final g in mine.reversed) {
        final s = _timed(g).start!;
        if (!s.instant.isAfter(soon)) continue;
        if (r.cancels && start != null && start.day != s.day) continue;
        return g;
      }
    }
    return null;
  }

  static Event _event(List<EventRecord> records) {
    final cancelled = records.last.cancels;
    final timed = [
      for (final r in records)
        if (r.start != null && !r.cancels && r.start!.hasTime) r.start!,
    ];
    final previous = timed.isEmpty
        ? null
        : timed.reversed
              .skip(1)
              .where((s) => s.compareTo(timed.last) != 0)
              .firstOrNull;
    final first = records.first;
    final id =
        first.uid ??
        first.reference ??
        _isoDay(records.firstWhere((r) => r.start != null).start!);
    return Event._(
      key: 'ev:${first.email.sender}:$id'.replaceAll(RegExp(r'[,\s]'), '_'),
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
