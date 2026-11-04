// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_extract/mail_extract.dart';

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
  final int messageId;

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
    r'\d+% off',
  );

  // ---------------------------------------------------------- references

  static final _referenceLabel = _re(
    r'\b(?:booking (?:reference|ref\.?|code|number|no\.?|id)|'
    r'confirmation (?:code|number|no\.?|#)|'
    r'reservation (?:code|number|no\.?|id|#)|record locator|PNR|'
    r'itinerary(?: number| no\.?)?\s*#?|booking id)'
    r'(?:\s*\([\w ]{2,20}\))?\s*(?:is\s*)?[:#.]?\s*#?\s*([A-Za-z0-9][A-Za-z0-9-]{4,15})\b',
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
  /// reference", "confirmation code" or "PNR". A reference of letters
  /// only must be 6 long (an airline's PNR).
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
    r'\brescheduled\b|\bnew (?:departure|arrival|flight) times?\b',
  );

  /// Whether the email says the booking changed.
  static bool saysChanged(String subject, String text) =>
      _changed.hasMatch(subject) || _changed.hasMatch(_cap(text, 3000));

  // ------------------------------------------------------- dates, times

  static const _monthNames =
      r'(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|'
      r'aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?';
  static const _weekdayNames =
      r'(?:(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*\.?,?\s+)?';

  static final _dateDayMonth = _re(
    '\\b$_weekdayNames(\\d{1,2})(?:st|nd|rd|th)?\\s+$_monthNames'
    '(?:,?\\s+(\\d{4}))?\\b',
  );
  static final _dateMonthDay = _re(
    '\\b$_weekdayNames$_monthNames\\s+(\\d{1,2})(?:st|nd|rd|th)?\\b'
    '(?:,?\\s+(\\d{4}))?',
  );
  static final _dateIso = RegExp(r'\b(\d{4})-(\d{2})-(\d{2})\b');

  static const _months = [
    'jan',
    'feb',
    'mar',
    'apr',
    'may',
    'jun',
    'jul',
    'aug',
    'sep',
    'oct',
    'nov',
    'dec',
  ];

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

    int month(String name) =>
        _months.indexOf(name.toLowerCase().substring(0, 3)) + 1;
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
      if (_operatedBy.hasMatch(before)) continue;
      final labelled = _flightLabel.hasMatch(before);
      final code = m[1]!;
      if (!labelled) {
        if (_notAirlines.contains(code) || TravelPlaces.airline(code) == null) {
          continue;
        }
        final near = sample.substring(
          m.start - 80 < 0 ? 0 : m.start - 80,
          m.end + 80 > sample.length ? sample.length : m.end + 80,
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
      final route = _route(window) ?? _route(before);
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
  static LodgingReservationInfo? stayIn(TripEmail email, {String? reference}) {
    final text = _cap(email.text, 20000);
    final checkIn = _dayAfter(_checkIn, text, email.at);
    final checkOut = _dayAfter(_checkOut, text, email.at);
    if (checkIn == null || checkOut == null) return null;
    final nights = checkOut.day.difference(checkIn.day).inDays;
    if (nights < 1 || nights > 60) return null;

    String? clean(String? name) {
      final n = name?.replaceFirst(_nameEnd, '').trim();
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

  // ----------------------------------------------------------- reading

  /// The bookings [email]'s words describe (none for bulk mail or offers,
  /// or without a booking reference).
  static List<ReservationInfo> read(TripEmail email, {bool changed = false}) {
    if (email.bulk || notABooking.hasMatch(email.subject)) return const [];
    final words = '${email.subject}\n${email.text}';
    final reference = referencesIn(words).firstOrNull;
    if (reference == null) return const [];
    final flights = flightsIn(
      words,
      sent: email.at,
      reference: reference,
      changed: changed,
    );
    if (flights.isNotEmpty) return flights;
    if (stayIn(email, reference: reference) case final s?) return [s];
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
  ];

  static final _bookingSubject = RegExp(
    r'\b(?:flights?|booking|reservation|itinerary|e-?tickets?|tickets?|'
    r'hotel|check-?in|boarding pass|trip|stay|table for|train|bus|'
    r'car (?:rental|hire)|rental car|schedule change|cancel+ed|cancel+ation)\b',
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
        final g = group ?? _Group(key, info.kind);
        if (group == null) groups.add(g);
        g.keys.add(key);
        if (ref != null) g.references.add(ref);
        g.infos.add(info);
        g.statuses.add(r.cancels || info.status == ReservationStatus.cancelled);
        if (!g.records.contains(r)) g.records.add(r);
        if (r.changes) g.changed = true;
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
