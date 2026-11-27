// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_extract/mail_extract.dart';
import 'package:mail_store/mail_store.dart';

import 'subscriptions.dart' show SubscriptionFinder;
import 'travel_places.dart';

/// One email that may be about a booking: a flight or hotel confirmation,
/// a ticket, a table, a change or a cancellation.
final class TripEmail {
  const TripEmail({
    required this.messageId,
    required this.sender,
    required this.senderName,
    required this.subject,
    required this.text,
    required this.at,
    this.reservations = const [],
    this.bulk = false,
  });

  /// The stored message, to open it.
  final MessageId messageId;

  /// The sender's registrable domain (`singaporeair.com`).
  final String sender;

  /// The sender's display name, if any ("Singapore Airlines").
  final String? senderName;
  final String subject;

  /// What is known of the body: the preview, or the whole text once the
  /// message was downloaded. May be empty.
  final String text;
  final DateTime at;

  /// schema.org reservations in the email's HTML (see mail_extract),
  /// when its body is on the device.
  final List<ReservationInfo> reservations;

  /// Sorted as a newsletter or promotion: its words are not read (flight
  /// deals name flights and dates too).
  final bool bulk;
}

/// One email, as understood.
final class TripRecord {
  const TripRecord({
    required this.email,
    this.reservations = const [],
    this.references = const {},
    this.cancels = false,
    this.changes = false,
  });

  final TripEmail email;

  /// The bookings it describes: from its markup, else from its words.
  final List<ReservationInfo> reservations;

  /// Booking references it names ("Booking reference: XKQZPL").
  final Set<String> references;

  /// It says the booking was cancelled.
  final bool cancels;

  /// It says the booking changed ("schedule change").
  final bool changes;
}

/// A booking found in the mail: a flight segment, a stay, a train or bus
/// trip, a rental car, a table or an event ticket.
final class Booking {
  Booking._({
    required this.key,
    required this.records,
    required this.infos,
    required this.cancelled,
    required this.changed,
    this.previousStart,
  });

  /// Stable across loads (the kind, its number or name, and its first
  /// day): used to hide it.
  final String key;

  /// Its emails, oldest first.
  final List<TripRecord> records;

  /// What each email said about it, oldest first. The newest counts.
  final List<ReservationInfo> infos;

  /// The latest news is that it was cancelled.
  final bool cancelled;

  /// Its times changed after it was booked, or an email said it changed.
  final bool changed;

  /// When it was to start before the change, if that moved.
  final PlaceTime? previousStart;

  /// The latest details.
  ReservationInfo get info => infos.last;
  ReservationKind get kind => info.kind;
  PlaceTime get start => info.start!;
  PlaceTime? get end => info.end;

  /// The booking reference: the newest given, else one its emails name.
  String? get reference =>
      infos.reversed.map((i) => i.reservationNumber).nonNulls.firstOrNull ??
      records.expand((r) => r.references).firstOrNull;

  /// Who it is for, as the newest email gives it.
  String? get underName =>
      infos.reversed.map((i) => i.underName).nonNulls.firstOrNull;

  /// The airline, hotel site, rental company..., as the newest email gives
  /// it.
  String? get provider =>
      infos.reversed.map((i) => i.provider).nonNulls.firstOrNull;

  /// When it is over: its end, else its start (for a date alone, that
  /// whole day).
  DateTime get endsAt {
    final last = end ?? start;
    return last.hasTime
        ? last.instant
        : last.instant.add(const Duration(days: 1));
  }

  /// The city it leaves from (a flight, train, bus or car), if known.
  String? get fromCity => TripFinder.cityOf(info.from);

  /// The city it goes to, or where it is (a stay, a table, an event).
  String? get city => _travels
      ? TripFinder.cityOf(info.to) ?? TripFinder.cityOf(info.from)
      : TripFinder.cityOf(info.from);

  bool get _travels => switch (kind) {
    ReservationKind.flight ||
    ReservationKind.train ||
    ReservationKind.bus => true,
    _ => false,
  };

  /// A flight, train or bus: it takes you somewhere.
  bool get isTravel => _travels;

  @override
  String toString() => 'Booking($key)';
}

/// Bookings close in time and place: "Tokyo, 12–18 Dec" with the flight
/// there, the hotel and the flight back.
final class Trip {
  Trip._(this.bookings, this.destinations);

  /// Oldest first.
  final List<Booking> bookings;

  /// Cities it goes to, away from home, in order ("Tokyo", "Kyoto").
  /// Empty when no city is known.
  final List<String> destinations;

  /// The first booking's key.
  String get key => bookings.first.key;

  PlaceTime get start => bookings.first.start;

  /// When its last booking is over.
  DateTime get endsAt =>
      bookings.map((b) => b.endsAt).reduce((a, b) => a.isAfter(b) ? a : b);

  /// The last day, at the place.
  DateTime get lastDay {
    var last = bookings.first;
    for (final b in bookings) {
      if (b.endsAt.isAfter(last.endsAt)) last = b;
    }
    return (last.end ?? last.start).day;
  }

  /// Every booking in it was cancelled.
  bool get cancelled => bookings.every((b) => b.cancelled);
}

/// Reads bookings from the words of confirmation emails without markup:
/// airline and hotel confirmations. Careful: a booking is listed only
/// with a booking reference next to words such as "booking reference",
/// and for a flight, a flight number, a route and a date; for a stay,
/// check-in and check-out dates and the place's name.
abstract final class TripText {
  static RegExp _re(String pattern) => RegExp(pattern, caseSensitive: false);

  /// Subjects of mail that is about bookings without being one: offers,
  /// statements, reviews.
  static final notABooking = _re(
    r'\b(?:deals?|sale|offers?|save up to|fares? from|from (?:S\$|US\$|\$|€|£)|'
    r'promo(?:tion|s)?|miles|points|statement|newsletter|rate your|review|'
    r'how was|survey|feedback|tell us|inspiration|ideas|win|earn)\b|'
    r'\d+% off|\bsave\s+(?:up to\s+)?\d+\s?%|'
    // Visas and travel permits: about a trip, not a booking.
    r'\b(?:e-?visa|visa|travel authori[sz]ation|eta application)\b|'
    r'\bapplication (?:approved|received|granted|submitted)\b|'
    // Season tickets and railcards: no journey.
    r'\bseason ticket|\brenew(?:al|ed)?\b|\b(?:rail|travel)cards?\b',
  );

  // ---------------------------------------------------------- references

  static final _referenceLabel = _re(
    r'\b(?:booking (?:reference|ref\.?|code|number|no\.?|id|confirmation)|'
    r'buchungs(?:code|nummer)|reservierungsnummer|ticketcode|'
    r'confirmation (?:code|number|no\.?|#)|'
    r'reservation (?:code|number|no\.?|id|#)|record locator|PNR|'
    r'itinerary(?: number| no\.?)?\s*#?|booking id)'
    r'(?:\s*\([\w ]{2,20}\))?\s*(?:is\s*)?[:#.]?\s*#?\s*'
    // The code, maybe on the next line, maybe in groups of four digits
    // ("0428 3315 6092 7781").
    r'(\d{4}(?:[ ]\d{4}){2,4}(?![ ]?\d)|[A-Za-z0-9][A-Za-z0-9-]{4,15})\b',
  );

  static const _notReferences = {
    'NUMBER',
    'PLEASE',
    'BELOW',
    'ABOVE',
    'DETAILS',
    'CONFIRMED',
  };

  /// Booking references in [text], each next to a word such as "booking
  /// reference", "confirmation code" or "PNR", or on the line after it.
  /// A reference of letters only must be 6 long (an airline's PNR); one
  /// of digits in groups of four keeps its spaces.
  static List<String> referencesIn(String text) {
    final found = <String>[];
    for (final m in _referenceLabel.allMatches(_cap(text, 30000))) {
      final r = m[1]!;
      if (r != r.toUpperCase() || _notReferences.contains(r)) continue;
      final letters = RegExp('[A-Z]').allMatches(r).length;
      final digits = RegExp(r'\d').allMatches(r).length;
      final ok = switch ((letters, digits)) {
        (_, 0) => r.length == 6,
        (0, _) => r.length >= 6,
        _ => r.length >= 5,
      };
      if (ok && !found.contains(r)) found.add(r);
    }
    return found;
  }

  // ------------------------------------------------- cancelled or changed

  static final _cancelledSubject = _re(r'\bcancel+(?:ed|ation)\b');
  static final _cancelledText = _re(
    r'\b(?:booking|reservation|flight|stay|trip|ticket|table)s?\b[^.\n]{0,40}'
    r'\b(?:has been|have been|was|were|is|is now)\s+cancel+ed\b|'
    r'\bwe(?:.ve| have) cancel+ed your\b|\bcancel+ation (?:confirmation|confirmed)\b',
  );

  /// "Free cancellation", "cancellation policy": said in every booking.
  static final _cancellationTerms = _re(
    r'\b(?:free|no|flexible|easy) cancel+ation\b|\bcancel+ation (?:policy|fee|'
    r'charges?|deadline|terms|is free|before)\b|\bcancel+ation\s+(?:up to|until)\b',
  );

  /// Whether the email says the booking was cancelled.
  static bool saysCancelled(String subject, String text) {
    final s = subject.replaceAll(_cancellationTerms, '');
    if (_cancelledSubject.hasMatch(s)) return true;
    return _cancelledText.hasMatch(_cap(text, 6000));
  }

  static final _changed = _re(
    r'\bschedule (?:change|update)|\b(?:flight|time|itinerary|booking|reservation) '
    r'(?:change|changed|update|updated|modified|amended)\b|'
    r'\b(?:has|have) been (?:changed|modified|amended|rescheduled)\b|'
    r'\brescheduled\b|\bnew (?:departure|arrival|flight) times?\b|'
    r'\bnew (?:check-?in |stay |travel )?dates\b',
  );

  /// Whether the email says the booking changed.
  static bool saysChanged(String subject, String text) =>
      _changed.hasMatch(subject) || _changed.hasMatch(_cap(text, 3000));

  /// A stay changed: said in the subject, or said of the booking itself
  /// in the text (not "to change your booking, ..." in every email).
  static final _stayChangedSubject = _re(
    r'\b(?:has|have) been (?:changed|modified|amended|updated)\b|'
    r'\b(?:booking|reservation|stay) (?:change|changed|modified|amended|updated)\b|'
    r'\b(?:change|modification|amendment) (?:confirmation|confirmed)\b|'
    r'\bnew dates\b',
  );
  static final _stayChangedText = _re(
    r'\b(?:booking|reservation|stay|dates)\b[^.\n]{0,30}\b(?:has|have) been '
    r'(?:changed|modified|amended|updated)\b|'
    r'\b(?:change|modification|amendment) (?:confirmation|confirmed)\b|'
    r'\bnew (?:check-?in |stay )?dates\b',
  );

  /// Whether the email says a stay was changed (new dates, a modified
  /// booking), rather than booked.
  static bool saysStayChanged(String subject, String text) =>
      _stayChangedSubject.hasMatch(subject) ||
      _stayChangedText.hasMatch(_cap(text, 3000));

  // ------------------------------------------------------- dates, times

  static const _monthNames =
      r'(jan(?:uary|uar)?|jän(?:ner)?|feb(?:ruary|ruar)?|mar(?:ch)?|märz?|'
      r'apr(?:il)?|may|mai|june?|juni|july?|juli|aug(?:ust)?|'
      r'sep(?:t(?:ember)?)?|oct(?:ober)?|okt(?:ober)?|nov(?:ember)?|'
      r'dec(?:ember)?|dez(?:ember)?)\.?';
  static const _weekdayNames =
      r'(?:(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*\.?,?\s+)?';

  static final _dateDayMonth = _re(
    '\\b$_weekdayNames(\\d{1,2})(?:st|nd|rd|th|\\.)?\\s+$_monthNames'
    '(?:,?\\s+(\\d{4}))?\\b',
  );
  static final _dateMonthDay = _re(
    '\\b$_weekdayNames$_monthNames\\s+(\\d{1,2})(?:st|nd|rd|th)?\\b'
    '(?:,?\\s+(\\d{4}))?',
  );
  static final _dateIso = RegExp(r'\b(\d{4})-(\d{2})-(\d{2})\b');

  /// "02.08.2026", "2.8.2026": day first, as in most of Europe.
  static final _dateDots = RegExp(
    r'(?<![\d.])(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})(?![\d.]*\d)',
  );

  static const _months = {
    'jan': 1,
    'jän': 1,
    'feb': 2,
    'mar': 3,
    'mär': 3,
    'apr': 4,
    'may': 5,
    'mai': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'okt': 10,
    'nov': 11,
    'dec': 12,
    'dez': 12,
  };

  /// The dates written in [text], by where they start. Without a year,
  /// the next such day from [sent] (a booking is for later).
  static List<({int at, int end, DateTime day})> datesIn(
    String text,
    DateTime sent,
  ) {
    final local = sent.toLocal();
    final from = DateTime(local.year, local.month, local.day - 2);
    DateTime? day(int? y, int month, int d) {
      if (d < 1 || d > 31) return null;
      var date = DateTime(y ?? from.year, month, d);
      if (date.month != month) return null;
      if (y == null && date.isBefore(from)) {
        date = DateTime(from.year + 1, month, d);
      }
      return date;
    }

    int month(String name) => _months[name.toLowerCase().substring(0, 3)]!;
    final found = <({int at, int end, DateTime day})>[];
    void add(int at, int end, DateTime? d) {
      if (d == null) return;
      if (found.any((f) => at < f.end && f.at < end)) return;
      found.add((at: at, end: end, day: d));
    }

    for (final m in _dateIso.allMatches(text)) {
      final mo = int.parse(m[2]!);
      if (mo < 1 || mo > 12) continue;
      add(m.start, m.end, day(int.parse(m[1]!), mo, int.parse(m[3]!)));
    }
    for (final m in _dateDots.allMatches(text)) {
      final mo = int.parse(m[2]!);
      if (mo < 1 || mo > 12) continue;
      final y = int.parse(m[3]!);
      add(m.start, m.end, day(y < 100 ? 2000 + y : y, mo, int.parse(m[1]!)));
    }
    for (final m in _dateDayMonth.allMatches(text)) {
      add(
        m.start,
        m.end,
        day(int.tryParse(m[3] ?? ''), month(m[2]!), int.parse(m[1]!)),
      );
    }
    for (final m in _dateMonthDay.allMatches(text)) {
      add(
        m.start,
        m.end,
        day(int.tryParse(m[3] ?? ''), month(m[1]!), int.parse(m[2]!)),
      );
    }
    return found..sort((a, b) => a.at.compareTo(b.at));
  }

  static final _time = _re(
    r'(?<![\d:.])([01]?\d|2[0-3]):([0-5]\d)(?::\d\d)?'
    r'(?:\s*([ap])\.?\s?m\b\.?)?(?!\d)(\s*\(?\+1\)?)?',
  );

  /// The clock times in [text] ("23:35", "3:00 PM", "07:30 +1").
  static List<({int at, int hour, int minute, bool nextDay})> timesIn(
    String text,
  ) => [
    for (final m in _time.allMatches(text))
      if (_hour(int.parse(m[1]!), m[3]) case final h?)
        (at: m.start, hour: h, minute: int.parse(m[2]!), nextDay: m[4] != null),
  ];

  static int? _hour(int h, String? ampm) {
    if (ampm == null) return h;
    if (h < 1 || h > 12) return null;
    final pm = ampm.toLowerCase() == 'p';
    return h % 12 + (pm ? 12 : 0);
  }

  // ----------------------------------------------------------- flights

  static final _flightNumber = RegExp(
    r'(?<![\w:./-])([A-Z]{2}|[A-Z]\d|\d[A-Z])\s?(\d{1,4})(?![\w:/-])',
  );
  static final _flightWord = _re(r'\bflights?\b');
  static final _flightLabel = _re(r'\bflight(?: no\.?| number| #)?\s*:?\s*$');
  static final _operatedBy = _re(
    r'\b(?:operated|marketed) by\b[^\n]{0,30}$|\bcodeshare\b[^\n]{0,20}$',
  );

  /// An aircraft's maker or a label for it: "Airbus A380" is not Aegean
  /// Airlines (A3) flight 80.
  static final _aircraft = _re(
    r'\b(?:airbus|boeing|embraer|bombardier|aircraft(?: type)?|equipment)'
    r'[\s:]*$',
  );

  /// Two letters that are more often words or units than airlines.
  static const _notAirlines = {
    'AM',
    'PM',
    'ID',
    'UK',
    'NO',
    'TO',
    'AT',
    'ON',
    'IN',
    'OF',
    'BY',
    'UP',
    'US',
    'OR',
    'IT',
    'SA',
    'MS',
    'LA',
    'CA',
    'GB',
    'MB',
    'KB',
    'TV',
    'PC',
  };

  static final _routeCodes = RegExp(
    r'\b([A-Z]{3})\s*(?:→|->|>|–|—|-|to)\s*([A-Z]{3})\b',
  );
  static final _namedAirport = RegExp(
    r"([A-Z][\w'.-]*(?:[ \t]+[A-Z][\w'.-]*){0,3})?[ \t]*\(([A-Z]{3})\)",
  );
  static final _airportLabel = _re(
    r'^(?:depart(?:s|ure|ing)?|arriv(?:e|es|al|ing)|from|to|origin|destination)\s+',
  );
  static final _newTimes = _re(
    r'\b(?:new|now|revised|updated)(?: (?:departure|flight|schedule|times?))*\b',
  );

  /// The flights in [text]: each flight number with its route, date and
  /// times. [changed]: the email gives old and new times; the new ones
  /// count.
  static List<FlightReservationInfo> flightsIn(
    String text, {
    required DateTime sent,
    String? reference,
    bool changed = false,
  }) {
    final sample = _cap(text, 30000);
    final numbers = <RegExpMatch>[];
    for (final m in _flightNumber.allMatches(sample)) {
      final before = sample.substring(
        m.start - 40 < 0 ? 0 : m.start - 40,
        m.start,
      );
      if (_operatedBy.hasMatch(before) || _aircraft.hasMatch(before)) continue;
      final labelled = _flightLabel.hasMatch(before);
      final code = m[1]!;
      if (!labelled) {
        if (_notAirlines.contains(code) || TravelPlaces.airline(code) == null) {
          continue;
        }
        // A flight number in a cell of its own: the table's "Flight"
        // heading may be further away.
        final reach = _aloneOnLine(sample, m.start, m.end) ? 200 : 80;
        final near = sample.substring(
          m.start - reach < 0 ? 0 : m.start - reach,
          m.end + reach > sample.length ? sample.length : m.end + reach,
        );
        if (!_flightWord.hasMatch(near)) continue;
      }
      numbers.add(m);
    }
    final flights = <FlightReservationInfo>[];
    for (final (i, m) in numbers.indexed) {
      final end = i + 1 < numbers.length
          ? numbers[i + 1].start
          : (m.end + 500).clamp(0, sample.length);
      final window = sample.substring(m.end, end);
      final before = sample.substring(
        i > 0 ? numbers[i - 1].end : (m.start - 200).clamp(0, m.start),
        m.start,
      );
      final route =
          _route(window) ??
          _tableRoute(_cap(window, 400)) ??
          _route(before) ??
          _tableRoute(before);
      if (route == null) continue;
      final dates = datesIn(window, sent);
      final beforeDates = datesIn(before, sent);
      var timesFrom = 0;
      if (changed) {
        final label = _newTimes.allMatches(window).lastOrNull;
        if (label != null && timesIn(window.substring(label.end)).isNotEmpty) {
          timesFrom = label.end;
        }
      }
      final times = timesIn(window).where((t) => t.at >= timesFrom).toList();
      DateTime? dayBefore(int at) =>
          dates.where((d) => d.at < at).lastOrNull?.day;
      final firstDay =
          (times.isEmpty ? null : dayBefore(times.first.at)) ??
          dates.firstOrNull?.day ??
          beforeDates.lastOrNull?.day;
      if (firstDay == null) continue;
      PlaceTime at(
        DateTime day,
        ({int at, int hour, int minute, bool nextDay}) t,
      ) => PlaceTime(
        day.year,
        day.month,
        day.day,
        hour: t.hour,
        minute: t.minute,
      );
      final departure = times.isEmpty
          ? PlaceTime(
              firstDay.year,
              firstDay.month,
              firstDay.day,
              hasTime: false,
            )
          : at(firstDay, times.first);
      PlaceTime? arrival;
      if (times.length > 1) {
        final t = times[1];
        var day = dayBefore(t.at) ?? firstDay;
        if (day.isBefore(firstDay)) day = firstDay;
        final sameDay = day == firstDay;
        final earlier =
            t.hour * 60 + t.minute < times.first.hour * 60 + times.first.minute;
        if (sameDay && (t.nextDay || earlier)) {
          day = DateTime(day.year, day.month, day.day + 1);
        }
        arrival = at(day, t);
      }
      final code = m[1]!;
      final number = '$code ${m[2]}';
      if (flights.any(
        (f) =>
            f.flightNumber == number && f.departureTime?.day == departure.day,
      )) {
        continue;
      }
      flights.add(
        FlightReservationInfo(
          reservationNumber: reference,
          provider: TravelPlaces.airline(code),
          flightNumber: number,
          airlineCode: code,
          departureAirport: route.from,
          arrivalAirport: route.to,
          departureTime: departure,
          arrivalTime: arrival,
        ),
      );
    }
    return flights;
  }

  /// Whether [start]–[end] is all of its line in [text], but for spaces.
  static bool _aloneOnLine(String text, int start, int end) {
    final lineStart = text.lastIndexOf('\n', start) + 1;
    var lineEnd = text.indexOf('\n', end);
    if (lineEnd < 0) lineEnd = text.length;
    return text.substring(lineStart, start).trim().isEmpty &&
        text.substring(end, lineEnd).trim().isEmpty;
  }

  /// "SIN → NRT", "Singapore (SIN) to Tokyo Narita (NRT)".
  static ({ReservationPlace from, ReservationPlace to})? _route(String text) {
    final named = _namedAirport.allMatches(text).toList();
    if (named.length >= 2 && named[0][2] != named[1][2]) {
      ReservationPlace place(RegExpMatch m) {
        final name = m[1]?.replaceFirst(_airportLabel, '').trim();
        return ReservationPlace(
          name: name == null || name.isEmpty ? null : name,
          code: m[2],
        );
      }

      return (from: place(named[0]), to: place(named[1]));
    }
    for (final m in _routeCodes.allMatches(text)) {
      if (m[1] != m[2] &&
          TravelPlaces.isAirport(m[1]!) &&
          TravelPlaces.isAirport(m[2]!)) {
        return (
          from: ReservationPlace(code: m[1]),
          to: ReservationPlace(code: m[2]),
        );
      }
    }
    return null;
  }

  /// An airport code standing alone in a table cell: at the end of its
  /// line, or followed by a time ("SIN 22:05", "SIN\n22:05").
  static final _codeCell = RegExp(
    r'(?<![A-Za-z0-9])([A-Z]{3})(?![A-Za-z0-9])[ \t]*'
    r'(?=\r?\n|\||\t|$|(?:[01]?\d|2[0-3]):[0-5]\d(?!\d))',
  );

  /// The word before such a code, on its line, if any: a place's name
  /// ("Singapore SIN"), a label ("Departure:"), a time, a number or an
  /// arrow; never a word in capitals ("THE SIN") or in prose ("at SIN").
  static final _beforeCode = RegExp(
    r"^(?:[A-Z][a-z][\w'.-]*:?|\d{1,2}:\d{2}|\d{1,4}|\(?\+\d\)?|[→>–—-])$",
  );

  /// The route of a confirmation laid out as a table, its cells one per
  /// line or side by side: "Singapore SIN 22:05 … London LHR 05:15",
  /// "SIN\n22:05\nLHR". Two different airports the app knows, each in a
  /// cell of its own; the first is where it leaves from.
  static ({ReservationPlace from, ReservationPlace to})? _tableRoute(
    String text,
  ) {
    final codes = <String>[];
    for (final m in _codeCell.allMatches(text)) {
      final code = m[1]!;
      if (!TravelPlaces.isAirport(code)) continue;
      final lineStart = text.lastIndexOf(RegExp(r'[\n|\t]'), m.start) + 1;
      final before = text.substring(lineStart, m.start).trim();
      if (before.isNotEmpty &&
          !_beforeCode.hasMatch(before.split(RegExp(r'\s+')).last)) {
        continue;
      }
      if (!codes.contains(code)) codes.add(code);
      if (codes.length == 2) {
        return (
          from: ReservationPlace(code: codes[0]),
          to: ReservationPlace(code: codes[1]),
        );
      }
    }
    return null;
  }

  // ------------------------------------------------------------- stays

  static final _checkIn = _re(
    r'\bcheck[- ]?in(?: date)?\b[\s:–-]*(?:from\s+)?',
  );
  static final _checkOut = _re(
    r'\bcheck[- ]?out(?: date)?\b[\s:–-]*(?:until\s+|by\s+)?',
  );

  /// Sites that book stays for hotels: their name is not the hotel's.
  static const _bookingSites = {
    'booking.com',
    'agoda.com',
    'airbnb.com',
    'expedia.com',
    'hotels.com',
    'trip.com',
    'traveloka.com',
    'klook.com',
    'hostelworld.com',
    'vrbo.com',
  };

  static final _staySubject = [
    _re(r'\b(?:stay|booking|reservation) (?:is )?confirmed (?:at|for)\s+(.+)$'),
    _re(r'\b(?:confirmation|confirmed)(?: for| at|:)\s+(.+)$'),
    _re(r'\byour (?:stay|booking|reservation) at\s+(.+)$'),
    _re(r'\b(?:booking|reservation) confirmation\s*[-–:|]\s*(.+)$'),
  ];

  /// "Osaka View Hotel Honmachi has been booked": the name, said first.
  static final _staySubjectFirst = _re(
    r'^(?:[\[【(][^\]】)]{1,40}[\]】)]\s*|[^:]{1,30}:\s+)?'
    r'(.+?)\s+(?:has|have)\s+been\s+'
    r'(?:booked|confirmed|reserved|changed|modified|updated|amended)\b',
  );

  /// Not a place's name: "Your booking has been confirmed".
  static final _notAName = _re(
    r'^(?:your|my|our|this|a)\b|'
    r'\b(?:booking|reservation|order|payment|flight|ticket|request)s?\b',
  );

  /// What a subject says of the booking after the place's name: "has
  /// been booked", "is confirmed", ": reservation changed".
  static final _statusTail = _re(
    r'\s+(?:has|have)\s+been\s+(?:booked|confirmed|reserved|changed|'
    r'modified|updated|amended|cancel+ed|rebooked)\b.*$|'
    r'\s+(?:is|are|was|were)\s+(?:now\s+)?(?:booked|confirmed|reserved|'
    r'changed|modified|updated|amended|cancel+ed)\b.*$|'
    r'\s*[:,]?\s+(?:booking|reservation|stay)\s+(?:is\s+)?(?:confirmed|'
    r'changed|modified|updated|amended|cancel+ed)\b.*$',
  );

  /// Where a change email gives the new dates, after the old ones.
  static final _newDates = _re(
    r'\b(?:new|updated|revised|changed|current)\s+(?:booking\s+|reservation\s+|'
    r'stay\s+)?(?:dates?|details|check-?in)\b|\bafter (?:the )?change\b|'
    r'\bchanged to\b',
  );
  static final _stayLabel = _re(
    r'^\s*(?:hotel|property|accommodation|hotel name|your hotel|where)\s*:\s*(.+)$',
  );
  static final _addressLabel = _re(r'^\s*(?:address|location)\s*:\s*(.+)$');
  static final _goingTo = RegExp(
    r"\b(?:going|trip) to ([A-Z][\w'-]+(?: [A-Z][\w'-]+)?)",
  );
  static final _nameEnd = RegExp(
    r'\s*(?:\(|\s[-–|]\s|[!.]$|,\s*(?:booking|confirmation|itinerary)).*$',
    caseSensitive: false,
  );

  /// A stay in [email]'s words: check-in and check-out dates and the
  /// place's name, or null.
  /// [changed]: the email says the stay changed; dates after "New
  /// dates" count over the old ones before them.
  static LodgingReservationInfo? stayIn(
    TripEmail email, {
    String? reference,
    bool changed = false,
  }) {
    final text = _cap(email.text, 20000);
    var checkIn = _dayAfter(_checkIn, text, email.at);
    var checkOut = _dayAfter(_checkOut, text, email.at);
    if (changed) {
      if (_newDates.allMatches(text).lastOrNull case final label?) {
        final rest = text.substring(label.end);
        final newIn = _dayAfter(_checkIn, rest, email.at);
        final newOut = _dayAfter(_checkOut, rest, email.at);
        if (newIn != null && newOut != null) {
          checkIn = newIn;
          checkOut = newOut;
        }
      }
    }
    if (checkIn == null || checkOut == null) return null;
    final nights = checkOut.day.difference(checkIn.day).inDays;
    if (nights < 1 || nights > 60) return null;

    String? clean(String? name) {
      final n = name
          ?.replaceFirst(_statusTail, '')
          .replaceFirst(_nameEnd, '')
          .trim();
      if (n == null || n.length < 3 || n.length > 80) return null;
      if (!RegExp('[A-Za-z]{3}').hasMatch(n)) return null;
      // A date or a reference is not a name.
      if (datesIn(n, email.at).isNotEmpty ||
          referencesIn('PNR $n').isNotEmpty) {
        return null;
      }
      return n;
    }

    final broker = _bookingSites.contains(email.sender.toLowerCase());
    String? name;
    for (final re in _staySubject) {
      if (clean(re.firstMatch(email.subject)?[1]) case final n?) {
        name = n;
        break;
      }
    }
    if (name == null) {
      if (clean(_staySubjectFirst.firstMatch(email.subject)?[1]) case final n?
          when !_notAName.hasMatch(n)) {
        name = n;
      }
    }
    if (name == null) {
      for (final line in text.split('\n').take(200)) {
        if (clean(_stayLabel.firstMatch(line)?[1]) case final n?) {
          name = n;
          break;
        }
      }
    }
    if (name == null && !broker) name = clean(email.senderName);
    String? address;
    for (final line in text.split('\n').take(300)) {
      if (_addressLabel.firstMatch(line)?[1]?.trim() case final a?
          when a.length > 5) {
        address = a;
        break;
      }
    }
    final going = _goingTo.firstMatch('${email.subject}\n$text')?[1];
    final city =
        (name == null ? null : TravelPlaces.cityIn(name)) ??
        (address == null ? null : TravelPlaces.cityIn(address)) ??
        (going == null ? null : TravelPlaces.cityIn(going) ?? going) ??
        TravelPlaces.cityIn(email.subject);
    if (name == null && city == null) return null;
    return LodgingReservationInfo(
      reservationNumber: reference,
      provider: broker ? email.senderName : null,
      hotel: ReservationPlace(
        name: name ?? 'Stay in $city',
        address: address,
        locality: city,
      ),
      checkin: checkIn,
      checkout: checkOut,
    );
  }

  /// The date (and time, close after it) right after [label].
  static PlaceTime? _dayAfter(RegExp label, String text, DateTime sent) {
    for (final m in label.allMatches(text)) {
      final rest = text.substring(m.end, (m.end + 80).clamp(0, text.length));
      final date = datesIn(rest, sent).firstOrNull;
      if (date == null || date.at > 25) continue;
      final d = date.day;
      final after = rest.substring(date.end);
      final time = timesIn(after).firstOrNull;
      if (time != null && time.at < 30) {
        return PlaceTime(
          d.year,
          d.month,
          d.day,
          hour: time.hour,
          minute: time.minute,
        );
      }
      return PlaceTime(d.year, d.month, d.day, hasTime: false);
    }
    return null;
  }

  // ------------------------------------------------------- trains, coaches

  /// Railways and the sites that sell their tickets, by the first label of
  /// the sender's domain (`oebb` for oebb.at).
  static const _railSenders = {
    'avantiwestcoast',
    'oebb',
    'nightjet',
    'westbahn',
    'lner',
    'gwr',
    'trainline',
    'thetrainline',
    'sncf',
    'sncf-connect',
    'oui',
    'sbb',
    'bahn',
    'db',
    'dbregio',
    'eurostar',
    'renfe',
    'trenitalia',
    'italotreno',
    'italo',
    'ns',
    'nsinternational',
    'raileurope',
    'nationalrail',
    'scotrail',
    'crosscountrytrains',
    'tpexpress',
    'northernrailway',
    'southeasternrailway',
    'thameslinkrailway',
    'greateranglia',
    'chilternrailways',
    'eastmidlandsrailway',
    'westmidlandsrailway',
    'lumo',
    'grandcentralrail',
    'hulltrains',
    'sleeper',
    'splitmyfare',
    'trainpal',
    'regiojet',
    'cd',
    'sj',
    'vy',
    'irishrail',
    'amtrak',
    'viarail',
    'ktmb',
    'korail',
    'thsrc',
    'smart-ex',
    'eki-net',
    'westjr',
  };

  /// Coach companies, by the first label of their domain.
  static const _coachSenders = {
    'flixbus',
    'nationalexpress',
    'megabus',
    'citylink',
    'easybook',
    'busbud',
    'redbus',
    'alsa',
    'eurolines',
  };

  /// What to call the company when the email gives no sender name.
  static const _operators = {
    'avantiwestcoast': 'Avanti West Coast',
    'oebb': 'ÖBB',
    'lner': 'LNER',
    'gwr': 'GWR',
    'trainline': 'Trainline',
    'thetrainline': 'Trainline',
    'sncf': 'SNCF',
    'sncf-connect': 'SNCF Connect',
    'sbb': 'SBB',
    'bahn': 'Deutsche Bahn',
    'db': 'Deutsche Bahn',
    'eurostar': 'Eurostar',
    'renfe': 'Renfe',
    'trenitalia': 'Trenitalia',
    'italotreno': 'Italo',
    'ns': 'NS',
    'flixbus': 'FlixBus',
    'nationalexpress': 'National Express',
    'megabus': 'Megabus',
  };

  static final _railName = _re(
    r'(?<![a-z])(?:rail(?:ways?)?|trains|bahn|ÖBB|OEBB|SNCF|SBB|Eurostar|'
    r'Trenitalia|Italo|Renfe|LNER|GWR|Avanti West Coast|Trainline|Nightjet|'
    r'ScotRail|Amtrak)(?![a-z])',
  );
  static final _jrName = RegExp(r'(?<![A-Za-z])JR(?![A-Za-z])');
  static final _coachName = _re(
    r'(?<![a-z])(?:flixbus|national express|megabus|citylink|coach(?:es)?|'
    r'bus(?:es)?)(?![a-z])',
  );

  /// Words of rail travel, in English and German.
  static final _railWords = _re(
    r'\b(?:trains?|rail(?:way)?|coach|carriage|platform|zug|bahn|gleis|'
    r'wagen|railjet|nightjet|intercity|sitzplatz)\b',
  );
  static final _busWords = _re(r'\b(?:bus|coach station|by coach)\b');
  static final _trainOnlyWords = _re(r'\b(?:trains?|rail(?:way)?|zug|bahn)\b');

  /// Subjects about rail travel that is not a journey: season tickets,
  /// railcards, refunds, compensation, surveys.
  static final _notAJourney = _re(
    r'\bseason\b|\brenew|\b(?:rail|travel)cards?\b|klimaticket|jahreskarte|'
    r'monatskarte|wochenkarte|vorteilscard|\bdelay repay\b|compensation|'
    r'\brefund|\bclaim\b|\bsurvey\b|\bfeedback\b',
  );

  /// Lines whose dates are not the journey's: when it was bought, until
  /// when a ticket is valid, when to renew it; with the next line when
  /// the label ends its line ("Booking date:" above "25. May 2026").
  static final _notJourneyLine = RegExp(
    r'^.*\b(?:booked on|booking date|date booked|order date|ordered on|'
    r'purchase date|purchased on|date of purchase|date of issue|issued on|'
    r'issue date|kaufdatum|buchungsdatum|bestelldatum|ausstellungsdatum|'
    r'ausgestellt am|gekauft am|payment date|paid on|transaction date|'
    r'valid until|valid to|gültig bis|expires|expiry|renew\w*|due)\b'
    r'(?:[^\n]*:[ \t]*\r?\n.*|.*)$',
    multiLine: true,
    caseSensitive: false,
  );

  /// One word of a station's name ("Euston", "Hbf", "Saint-Lazare",
  /// "Frankfurt(Main)Hbf", "d'Austerlitz").
  static const _stationWord = r"(?:d'|l')?[A-ZÀ-Þ][\wÀ-ɏ'’()./-]*";
  static const _stationName =
      '$_stationWord(?:[ \\t]+(?:(?:de|du|des|la|le|am|im|an der|upon|on|'
      'sur|del|di|bei)[ \\t]+)?$_stationWord){0,4}';
  static const _legTime =
      r'(?:[ \t]+(?:ab|an|dep\.?|arr\.?))?[ \t]+'
      r'(\(?(?:[01]?\d|2[0-3]):[0-5]\d\)?)';
  static const _legSeparator =
      r'(?:[ \t]*(?:\r?\n[ \t]*)?(?:→|⟶|➝|->|–|—)[ \t]*(?:\r?\n[ \t]*)?|'
      r'[ \t]+[->][ \t]+|[ \t]+(?:to|nach|naar|till)[ \t]+|'
      r'[ \t]*\r?\n[ \t]*to[ \t]+)';

  /// "London Euston to Manchester Piccadilly", "Wien Hbf → Salzburg Hbf",
  /// "Zürich HB > Bolzano/Bozen", "Wien Hbf ab 08:30 → Salzburg Hbf an
  /// 10:52", "Glasgow Central (08:00) to London Euston (13:38)", or over
  /// two lines: "Glasgow Central" above "to London Euston".
  static final _leg = RegExp(
    '($_stationName)(?:$_legTime)?$_legSeparator($_stationName)(?:$_legTime)?',
  );
  static final _stationAt = RegExp(_stationName);

  /// "From: London Euston", "Von / From: Wien Hbf", the name maybe on the
  /// next line (a table's cells).
  static final _fromLabel = RegExp(
    r'^[ \t]*(?:(?:from|von|departure station|departing from|leaving from|'
    r'origin|abfahrtsbahnhof|startbahnhof)[ \t]*/?[ \t]*)+:?[ \t]*'
    r'(?:\r?\n[ \t]*)?',
    multiLine: true,
    caseSensitive: false,
  );
  static final _toLabel = RegExp(
    r'^[ \t]*(?:(?:to|nach|arrival station|arriving at|destination|'
    r'zielbahnhof|ziel)[ \t]*/?[ \t]*)+:?[ \t]*(?:\r?\n[ \t]*)?',
    multiLine: true,
    caseSensitive: false,
  );

  /// Words that come before a station's name without being part of it.
  static final _notStationWords = _re(
    r'^(?:(?:your|journey|outward|outbound|return|inbound|from|to|von|nach|'
    r'hinfahrt|rückfahrt|ticket|train|zug|route|reise|trip|leg)\b[:\s]*)+',
  );

  /// Words that come after it, on the same line.
  static final _afterStation = _re(
    r'\s+(?:depart\w*|arriv\w*|abfahrt|ankunft|coach\s+[a-z0-9]{1,2}|'
    r'carriage|seat|platform|train|zug|wagen|platz|gleis|class|klasse|'
    r'standard|first|outward|return|single|advance|off-peak|anytime|ticket|'
    r'via|valid|dep|arr)\b.*$',
  );

  /// Ends of station names: the place before it is a town even when the
  /// app does not know it ("Innsbruck Hbf").
  static final _stationEnd = _re(
    r'\s+(?:hbf|hb|hauptbahnhof|bahnhof|bhf|westbahnhof|ostbahnhof|südbahnhof|'
    r'central|centraal|centrale|euston|piccadilly|st\.? pancras'
    r"(?: international)?|king'?s cross|paddington|station|termini)$",
  );

  /// The train or coach ("RJX 862", "ICE 1003", "TGV 9241").
  static final _trainNumber = RegExp(
    r'(?<![\w-])(ICE|IC|EC|ECE|EN|NJ|RJX|RJ|TGV|IR|IRE|RE|REX|ES|AVE|FR|FA|'
    r'EST|THA|WB)\s?(\d{2,5})(?![\w-])',
  );

  /// A ticket number, often in groups of four ("0919 1410 7516 0291").
  static final _ticketNumber = _re(
    r'\bticket(?:nummer|code|nr\.?|\s*(?:number|no\.?|code|nr\.?))?\b'
    r'[^\d\n]{0,25}?(\d{4}(?:[ ]\d{4}){2,4}|\d{10,20})(?!\d)',
  );

  /// A ticket number in [text] ("Ticket number: 0919 1410 7516 0291",
  /// "ÖBB ticket – 0919 1410 7516 0291"), or null.
  static String? ticketNumberIn(String text) =>
      _ticketNumber.firstMatch(_cap(text, 20000))?[1];

  /// The kind of transport [email] is about: a train or a coach, from its
  /// sender, else from its words ([byWords]); or null.
  static ({ReservationKind kind, bool byWords})? _transitOf(TripEmail email) {
    final label = email.sender.toLowerCase().split('.').first;
    final name = email.senderName ?? '';
    final rail =
        _railSenders.contains(label) ||
        label.startsWith('jr') ||
        _railName.hasMatch(name) ||
        _jrName.hasMatch(name);
    if (rail) return (kind: ReservationKind.train, byWords: false);
    if (_coachSenders.contains(label) || _coachName.hasMatch(name)) {
      return (kind: ReservationKind.bus, byWords: false);
    }
    final sample = _cap('${email.subject}\n${email.text}', 8000);
    if (!_railWords.hasMatch(sample)) return null;
    final bus = _busWords.hasMatch(sample) && !_trainOnlyWords.hasMatch(sample);
    return (
      kind: bus ? ReservationKind.bus : ReservationKind.train,
      byWords: true,
    );
  }

  /// [raw] read as a station: a known city's ("London Euston", "Wien
  /// Hbf") or a name ending like a station's ("Innsbruck Hbf"); else null.
  /// Of names given two ways ("Bolzano/Bozen", "Glasgow Central/Queen
  /// St"), the first.
  static ReservationPlace? _station(String raw) {
    var name = raw
        .replaceFirst(RegExp(r'(?<=[\wÀ-ɏ])/(?=[A-ZÀ-Þ]).*$'), '')
        .replaceFirst(_notStationWords, '')
        .replaceFirst(_afterStation, '')
        .replaceFirst(RegExp(r'[\s.,;:/(-]+$'), '')
        .trim();
    if (name.length < 3 || name.length > 50) return null;
    if (name == name.toUpperCase()) {
      // "LONDON EUSTON", as on a ticket.
      name = name
          .toLowerCase()
          .split(' ')
          .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
          .join(' ');
    }
    final known = TravelPlaces.cityIn(name);
    if (known != null) return ReservationPlace(name: name, locality: known);
    if (name.startsWith(RegExp(r'Gare\b'))) {
      return ReservationPlace(name: name, locality: 'Paris');
    }
    final m = _stationEnd.firstMatch(name);
    if (m == null) return null;
    final town = name.substring(0, m.start).trim();
    if (town.length < 3) return null;
    return ReservationPlace(name: name, locality: town);
  }

  /// The journeys written in [text]: where each is in it, its stations
  /// and, when written beside them, its times.
  static List<_Leg> _legsIn(String text) {
    final legs = <_Leg>[];
    for (final m in _leg.allMatches(text)) {
      final from = _station(m[1]!);
      final to = _station(m[3]!);
      if (from == null || to == null || from.name == to.name) continue;
      legs.add((
        start: m.start,
        end: m.end,
        from: from,
        to: to,
        departs: m[2],
        arrives: m[4],
      ));
    }
    if (legs.isNotEmpty) return legs;
    // "From: London Euston … To: Manchester Piccadilly".
    for (final f in _fromLabel.allMatches(text)) {
      final fromName = _stationAt.matchAsPrefix(text, f.end);
      if (fromName == null) continue;
      final from = _station(fromName[0]!);
      if (from == null) continue;
      final rest = text.substring(
        fromName.end,
        (fromName.end + 300).clamp(0, text.length),
      );
      for (final t in _toLabel.allMatches(rest)) {
        final toName = _stationAt.matchAsPrefix(rest, t.end);
        if (toName == null) continue;
        final to = _station(toName[0]!);
        if (to == null || to.name == from.name) continue;
        legs.add((
          start: f.start,
          end: fromName.end + toName.end,
          from: from,
          to: to,
          departs: null,
          arrives: null,
        ));
        break;
      }
    }
    return legs;
  }

  /// The train or coach journeys in [email]'s words: each route between
  /// two stations or towns, with its date (written near it, else the
  /// subject's) and its times when given. Only for mail from a railway
  /// or a coach company, or about trains in more than one word.
  static List<TransitReservationInfo> trainsIn(
    TripEmail email, {
    String? reference,
  }) {
    final transit = _transitOf(email);
    if (transit == null || _notAJourney.hasMatch(email.subject)) {
      return const [];
    }
    final text = _cap(email.text, 20000).replaceAllMapped(
      _notJourneyLine,
      (m) => m[0]!.replaceAll(RegExp(r'[^\r\n]'), ' '),
    );
    final legs = _legsIn(text);
    if (legs.isEmpty) return const [];
    if (transit.byWords) {
      // Words alone: more than one of them, or a station's name.
      final words = {
        for (final m in _railWords.allMatches(_cap(text, 8000)))
          m[0]!.toLowerCase().replaceFirst(RegExp(r's$'), ''),
      };
      final station = legs.any(
        (l) =>
            _stationEnd.hasMatch(l.from.name!) ||
            _stationEnd.hasMatch(l.to.name!),
      );
      if (words.length < 2 && !station) return const [];
    }
    final local = email.at.toLocal();
    final earliest = DateTime(local.year, local.month, local.day - 1);
    final latest = earliest.add(const Duration(days: 400));
    final subjectDay = datesIn(email.subject, email.at).firstOrNull?.day;
    final label = email.sender.toLowerCase().split('.').first;
    final provider = email.senderName ?? _operators[label];

    final out = <TransitReservationInfo>[];
    for (final (i, leg) in legs.indexed) {
      final lo = i > 0 ? legs[i - 1].end : 0;
      final hi = i + 1 < legs.length ? legs[i + 1].start : text.length;
      final before = text.substring(
        leg.start - 250 > lo ? leg.start - 250 : lo,
        leg.start,
      );
      final after = text.substring(
        leg.end,
        leg.end + 400 < hi ? leg.end + 400 : hi,
      );
      final dateBefore = datesIn(before, email.at).lastOrNull;
      final datesAfter = datesIn(after, email.at);
      final gapBefore = dateBefore == null
          ? null
          : before.length - dateBefore.end;
      final gapAfter = datesAfter.firstOrNull?.at;
      DateTime? day;
      var near = after;
      var nearBefore = '';
      if (dateBefore != null && (gapAfter == null || gapBefore! <= gapAfter)) {
        day = dateBefore.day;
        // A date after it is the next journey's.
        if (datesAfter.isNotEmpty) near = after.substring(0, datesAfter[0].at);
        nearBefore = before.substring(dateBefore.end);
      } else if (datesAfter.isNotEmpty) {
        day = datesAfter[0].day;
        if (datesAfter.length > 1) near = after.substring(0, datesAfter[1].at);
      } else if (i == 0) {
        day = subjectDay;
      }
      if (day == null || day.isBefore(earliest) || day.isAfter(latest)) {
        continue;
      }
      final times = [
        if (leg.departs case final d?) ...timesIn(d),
        if (leg.arrives case final a?) ...timesIn(a),
      ];
      if (times.isEmpty) {
        times.addAll(timesIn(near));
        if (times.isEmpty) times.addAll(timesIn(nearBefore));
      }
      PlaceTime at(
        DateTime d,
        ({int at, int hour, int minute, bool nextDay}) t,
      ) => PlaceTime(d.year, d.month, d.day, hour: t.hour, minute: t.minute);
      final departure = times.isEmpty
          ? PlaceTime(day.year, day.month, day.day, hasTime: false)
          : at(day, times.first);
      PlaceTime? arrival;
      if (times.length > 1) {
        final t = times[1];
        final earlier =
            t.hour * 60 + t.minute < times.first.hour * 60 + times.first.minute;
        arrival = at(
          t.nextDay || earlier
              ? DateTime(day.year, day.month, day.day + 1)
              : day,
          t,
        );
      }
      if (out.any(
        (o) =>
            o.from?.name == leg.from.name &&
            o.to?.name == leg.to.name &&
            o.start?.day == departure.day,
      )) {
        continue;
      }
      final number =
          _trainNumber.firstMatch(near) ?? _trainNumber.firstMatch(nearBefore);
      out.add(
        TransitReservationInfo(
          kind: transit.kind,
          reservationNumber: reference,
          provider: provider,
          number: number == null ? null : '${number[1]} ${number[2]}',
          departureStation: leg.from,
          arrivalStation: leg.to,
          departureTime: departure,
          arrivalTime: arrival,
        ),
      );
    }
    return out;
  }

  // ----------------------------------------------------------- reading

  /// The bookings [email]'s words describe (none for bulk mail or offers,
  /// or without a booking reference; a railway's ticket number will do).
  static List<ReservationInfo> read(TripEmail email, {bool changed = false}) {
    if (email.bulk || notABooking.hasMatch(email.subject)) return const [];
    final words = '${email.subject}\n${email.text}';
    final reference = referencesIn(words).firstOrNull;
    final railway = _transitOf(email)?.byWords == false;
    if (reference == null) {
      if (!railway) return const [];
      final ticket = ticketNumberIn(words);
      if (ticket == null) return const [];
      return trainsIn(email, reference: ticket);
    }
    if (railway) {
      final trains = trainsIn(email, reference: reference);
      if (trains.isNotEmpty) return trains;
    }
    final flights = flightsIn(
      words,
      sent: email.at,
      reference: reference,
      changed: changed,
    );
    if (flights.isNotEmpty) return flights;
    final stay = stayIn(
      email,
      reference: reference,
      changed: changed || saysStayChanged(email.subject, email.text),
    );
    if (stay != null) return [stay];
    if (!railway) return trainsIn(email, reference: reference);
    return const [];
  }

  static String _cap(String s, int n) => s.length > n ? s.substring(0, n) : s;
}

/// Finds bookings in confirmation mail, on the device (from schema.org
/// markup when the email has it, else from its words) and puts them
/// together into trips.
abstract final class TripFinder {
  /// Subject words of mail worth looking at (also used to pick it from
  /// the store).
  static const subjectWords = [
    'flight',
    'booking',
    'reservation',
    'itinerary',
    'trip',
    'travel',
    'hotel',
    'stay',
    'check-in',
    'check in',
    'ticket',
    'boarding',
    'schedule change',
    'cancel',
    'table',
    'rental',
    'car hire',
    'train',
    'bus ',
    'journey',
    'going to',
    'buchung',
    'fahrkarte',
  ];

  static final _bookingSubject = RegExp(
    r'\b(?:flights?|booking|reservation|itinerary|e-?tickets?|tickets?|'
    r'hotel|check-?in|boarding pass|trip|stay|table for|train|bus|'
    r'car (?:rental|hire)|rental car|schedule change|cancel+ed|cancel+ation|'
    r'buchung\w*|fahrkarten?)\b',
    caseSensitive: false,
  );

  /// Whether [subject] reads like a booking, worth downloading.
  static bool looksLikeBooking(String subject) =>
      !SubscriptionFinder.isReplyOrForward(subject) &&
      !TripText.notABooking.hasMatch(subject) &&
      _bookingSubject.hasMatch(subject);

  /// Bookings close together: the next one this close after a trip's end
  /// joins it, if it is in the same place.
  static const tripGap = Duration(days: 3);

  /// A flight, train or bus leaving a trip's place this long after the
  /// trip's last booking still belongs to it (the way back).
  static const stayAway = Duration(days: 30);

  /// [email], as understood: its markup, else its words.
  static TripRecord read(TripEmail email) {
    final words = '${email.subject}\n${email.text}';
    final markup = email.reservations;
    final changes =
        !email.bulk && TripText.saysChanged(email.subject, email.text);
    final cancels =
        (markup.isNotEmpty &&
            markup.every((r) => r.status == ReservationStatus.cancelled)) ||
        (!email.bulk && TripText.saysCancelled(email.subject, email.text));
    return TripRecord(
      email: email,
      reservations: markup.isNotEmpty
          ? markup
          : TripText.read(email, changed: changes),
      references: email.bulk ? const {} : TripText.referencesIn(words).toSet(),
      cancels: cancels,
      changes: changes,
    );
  }

  /// The city of [place]: an airport's, its town, or a city its name or
  /// address names.
  static String? cityOf(ReservationPlace? place) {
    if (place == null) return null;
    if (place.code case final c?) {
      if (TravelPlaces.cityOfAirport(c) case final city?) return city;
    }
    if (place.locality case final l? when l.trim().isNotEmpty) {
      return TravelPlaces.cityIn(l) ?? l.trim();
    }
    return TravelPlaces.cityIn([place.name, place.address].nonNulls.join(' '));
  }

  /// What makes a booking the same in another email: its kind, its
  /// number or name, and its first day.
  static String? naturalKey(ReservationInfo info) {
    final start = info.start;
    if (start == null) return null;
    final d = start.day;
    final day =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    String norm(String? s) =>
        (s ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final id = switch (info) {
      FlightReservationInfo(:final flightNumber) => 'f:${norm(flightNumber)}',
      TransitReservationInfo(:final number, :final from, :final to) =>
        '${info.kind.name}:${number != null ? norm(number) : '${norm(from?.label)}-${norm(to?.label)}'}',
      LodgingReservationInfo(:final hotel) => 's:${norm(hotel?.name)}',
      RentalCarReservationInfo(:final provider, :final pickupLocation) =>
        'c:${norm(provider ?? pickupLocation?.label)}',
      FoodEstablishmentReservationInfo(:final restaurant) =>
        'r:${norm(restaurant?.name)}',
      EventReservationInfo(:final eventName) => 'e:${norm(eventName)}',
    };
    return '$id:$day';
  }

  /// The bookings in [emails] (any order), oldest first: emails about
  /// the same flight on the same day, or the same stay, table or ticket,
  /// are one booking.
  static List<Booking> bookings(Iterable<TripEmail> emails) {
    final records = [
      for (final e in emails)
        if (!SubscriptionFinder.isReplyOrForward(e.subject)) read(e),
    ]..sort((a, b) => a.email.at.compareTo(b.email.at));

    final groups = <_Group>[];
    for (final r in records) {
      final touched = <_Group>{};
      // A stay changed under a new reference: the email says so.
      final stayChanged =
          !r.email.bulk &&
          TripText.saysStayChanged(r.email.subject, r.email.text);
      for (final info in r.reservations) {
        final key = naturalKey(info);
        if (key == null) continue;
        final ref = info.reservationNumber?.toUpperCase();
        final travel =
            info is FlightReservationInfo || info is TransitReservationInfo;
        final group =
            groups.where((g) => g.keys.contains(key)).firstOrNull ??
            (travel || ref == null
                ? null
                : groups
                      .where(
                        (g) =>
                            g.kind == info.kind && g.references.contains(ref),
                      )
                      .firstOrNull);
        final g =
            group ??
            (info is LodgingReservationInfo && stayChanged
                ? _changedStay(groups, info)
                : null) ??
            _Group(key, info.kind);
        if (!groups.contains(g)) groups.add(g);
        g.keys.add(key);
        if (ref != null) g.references.add(ref);
        g.infos.add(info);
        g.statuses.add(r.cancels || info.status == ReservationStatus.cancelled);
        if (!g.records.contains(r)) g.records.add(r);
        if (r.changes || (stayChanged && info is LodgingReservationInfo)) {
          g.changed = true;
        }
        touched.add(g);
      }
      // A cancellation or change that names the booking but describes no
      // part of it: every booking with that reference.
      if (touched.isEmpty && (r.cancels || r.changes)) {
        final refs = {for (final x in r.references) x.toUpperCase()};
        for (final g in groups) {
          if (g.references.intersection(refs).isEmpty) continue;
          if (!g.records.contains(r)) g.records.add(r);
          if (r.cancels) g.statuses.add(true);
          if (r.changes) g.changed = true;
        }
      }
    }

    return [
      for (final g in groups)
        Booking._(
          key: g.key.replaceAll(',', ' '),
          records: List.unmodifiable(g.records),
          infos: List.unmodifiable(g.infos),
          cancelled: g.statuses.last,
          changed: g.changed || _moved(g.infos),
          previousStart: _previous(g.infos),
        ),
    ]..sort((a, b) => a.start.compareTo(b.start));
  }

  static bool _moved(List<ReservationInfo> infos) => _previous(infos) != null;

  /// The stay [changed] changes: the latest at the same place whose
  /// nights overlap or adjoin its new ones (moved, made longer or
  /// shorter). Two stays back to back are two bookings unless an email
  /// says it changed one.
  static _Group? _changedStay(
    List<_Group> groups,
    LodgingReservationInfo changed,
  ) {
    String norm(String? s) =>
        (s ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final name = norm(changed.hotel?.name);
    final start = changed.checkin?.day;
    final end = changed.checkout?.day;
    if (name.isEmpty || start == null || end == null) return null;
    return groups.where((g) {
      final last = g.infos.last;
      if (last is! LodgingReservationInfo || g.statuses.last) return false;
      if (norm(last.hotel?.name) != name) return false;
      final s = last.checkin?.day;
      final e = last.checkout?.day;
      return s != null && e != null && !start.isAfter(e) && !end.isBefore(s);
    }).lastOrNull;
  }

  /// The start before the latest one, if it moved.
  static PlaceTime? _previous(List<ReservationInfo> infos) {
    final latest = infos.last.start;
    for (final i in infos.reversed.skip(1)) {
      final s = i.start;
      if (s == null || latest == null) continue;
      if (s.hasTime && latest.hasTime && s.wall != latest.wall) return s;
      if (s.day != latest.day) return s;
    }
    return null;
  }

  /// [bookings] put together into trips, oldest first. A booking joins
  /// the trip before it when it starts within [tripGap] of its end and
  /// is in the same place, leaves from it, or brings you home. Home is
  /// where most flights, trains and buses leave from.
  static List<Trip> trips(List<Booking> bookings) {
    final sorted = [...bookings]..sort((a, b) => a.start.compareTo(b.start));
    final home = homeOf(sorted);
    String? away(String? city) =>
        city == null || _same(city, home) ? null : city;
    Set<String> placesOf(Booking b) => {
      ?away(b.city)?.toLowerCase(),
      if (b.isTravel) ?away(b.fromCity)?.toLowerCase(),
    };

    final trips =
        <
          ({List<Booking> list, Set<String> places, DateTime end, bool closed})
        >[];
    for (final b in sorted) {
      final places = placesOf(b);
      final atHome = places.isEmpty && (b.city != null || b.fromCity != null);
      final last = trips.lastOrNull;
      var joins = false;
      if (last != null && !last.closed && !atHome) {
        final close = !b.start.instant.isAfter(last.end.add(tripGap));
        // Leaving the place the trip went to: you were there until then.
        final leaving =
            b.isTravel &&
            last.places.contains(away(b.fromCity)?.toLowerCase()) &&
            !b.start.instant.isAfter(last.end.add(stayAway));
        if (leaving) {
          joins = true;
        } else if (close) {
          if (places.isEmpty) {
            // Nowhere known: only during the trip or right after it.
            joins = !b.start.instant.isAfter(
              last.end.add(const Duration(days: 1)),
            );
          } else {
            joins =
                places.intersection(last.places).isNotEmpty ||
                (b.isTravel && _same(b.city, home));
          }
        }
      }
      if (joins) {
        final end = b.endsAt.isAfter(last!.end) ? b.endsAt : last.end;
        trips[trips.length - 1] = (
          list: [...last.list, b],
          places: {...last.places, ...places},
          end: end,
          closed: b.isTravel && _same(b.city, home),
        );
      } else {
        trips.add((
          list: [b],
          places: places,
          end: b.endsAt,
          closed: atHome || (b.isTravel && _same(b.city, home)),
        ));
      }
    }
    return [
      for (final t in trips)
        Trip._(List.unmodifiable(t.list), _destinations(t.list, home)),
    ];
  }

  /// Where most flights, trains and buses leave from; for a tie, the
  /// first one's.
  static String? homeOf(List<Booking> bookings) {
    final counts = <String, int>{};
    String? first;
    for (final b in bookings) {
      if (!b.isTravel) continue;
      final c = b.fromCity;
      if (c == null) continue;
      first ??= c;
      counts[c] = (counts[c] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    final top = counts.values.reduce((a, b) => a > b ? a : b);
    return counts[first] == top
        ? first
        : counts.entries.firstWhere((e) => e.value == top).key;
  }

  /// The cities a trip goes to: where its flights arrive and its stays
  /// are, else where its flights leave from; never home.
  static List<String> _destinations(List<Booking> list, String? home) {
    final out = <String>[];
    void add(String? c) {
      if (c == null || _same(c, home)) return;
      if (out.any((o) => _same(o, c))) return;
      out.add(c);
    }

    for (final b in list) {
      add(b.city);
    }
    if (out.isEmpty) {
      for (final b in list) {
        add(b.fromCity);
      }
    }
    return out;
  }

  static bool _same(String? a, String? b) =>
      a != null && b != null && a.toLowerCase() == b.toLowerCase();
}

typedef _Leg = ({
  int start,
  int end,
  ReservationPlace from,
  ReservationPlace to,
  String? departs,
  String? arrives,
});

final class _Group {
  _Group(this.key, this.kind);

  final String key;
  final ReservationKind kind;
  final keys = <String>{};
  final references = <String>{};
  final infos = <ReservationInfo>[];
  final records = <TripRecord>[];

  /// Per email: whether it said cancelled.
  final statuses = <bool>[];
  var changed = false;
}
