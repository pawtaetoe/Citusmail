// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'ical.dart';
import 'time_zones.dart';

/// A DTSTART or DTEND as the file gives it: a date (all day), or a time
/// in UTC, in a named time zone, or "floating" (the same clock time
/// wherever you are).
final class CalendarTime {
  const CalendarTime._({
    required this.wall,
    required this.allDay,
    required this.utc,
    this.zoneId,
    this.offset,
  });

  /// A date (all-day event).
  CalendarTime.date(int year, int month, int day)
    : this._(wall: DateTime.utc(year, month, day), allDay: true, utc: false);

  /// A time in UTC.
  CalendarTime.utc(DateTime instant)
    : this._(wall: instant.toUtc(), allDay: false, utc: true);

  /// A clock time in [zoneId], whose UTC [offset] at that time is known
  /// (or null if the zone isn't).
  CalendarTime.zoned(DateTime wall, String zoneId, Duration? offset)
    : this._(
        wall: wall,
        allDay: false,
        utc: false,
        zoneId: zoneId,
        offset: offset,
      );

  /// A clock time with no zone.
  CalendarTime.floating(DateTime wall)
    : this._(wall: wall, allDay: false, utc: false);

  /// The date and clock time as written, held in a UTC [DateTime] (only
  /// its fields mean anything).
  final DateTime wall;
  final bool allDay;
  final bool utc;

  /// The TZID, for times in a named zone.
  final String? zoneId;

  /// The zone's UTC offset at this time; null if the zone is unknown.
  final Duration? offset;

  /// The same clock time wherever the reader is.
  bool get floating => !allDay && !utc && zoneId == null;

  /// A named zone this app couldn't work out: shown as if local.
  bool get zoneUnknown => zoneId != null && offset == null;

  /// The moment in UTC, when it is one (not all-day, floating or in an
  /// unknown zone).
  DateTime? get instant => utc
      ? wall
      : offset != null
      ? wall.subtract(offset!)
      : null;

  /// The clock time for someone whose UTC offset at a moment is
  /// [offsetAt] (by default this device's), in a UTC [DateTime] carrier.
  /// All-day and floating times stay as written.
  DateTime wallFor([Duration Function(DateTime utc)? offsetAt]) {
    final at = instant;
    if (at == null) return wall;
    return at.add((offsetAt ?? localOffset)(at));
  }

  /// This device's offset from UTC at [utc].
  static Duration localOffset(DateTime utc) => utc.toLocal().timeZoneOffset;

  /// [wall] moved by [duration] (for DTSTART + DURATION), keeping the zone.
  CalendarTime plus(Duration duration) => CalendarTime._(
    wall: wall.add(duration),
    allDay:
        allDay && duration.inMicroseconds % Duration.microsecondsPerDay == 0,
    utc: utc,
    zoneId: zoneId,
    offset: offset,
  );

  /// Reads a DATE or DATE-TIME property, resolving its TZID with [zones].
  /// Null if the value is malformed.
  static CalendarTime? parse(ICalProperty property, CalendarTimeZones zones) {
    final value = property.value.trim();
    final isDate =
        property.parameter('VALUE')?.toUpperCase() == 'DATE' ||
        _date.hasMatch(value);
    if (isDate) {
      final m = _date.firstMatch(value) ?? _dateTime.firstMatch(value);
      if (m == null) return null;
      final (y, mo, d) = (
        int.parse(m.group(1)!),
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
      );
      if (!_validDate(y, mo, d)) return null;
      return CalendarTime.date(y, mo, d);
    }
    final m = _dateTime.firstMatch(value);
    if (m == null) return null;
    final parts = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
    if (!_validDate(parts[0], parts[1], parts[2]) ||
        parts[3] > 23 ||
        parts[4] > 59 ||
        parts[5] > 60) {
      return null;
    }
    final wall = DateTime.utc(
      parts[0],
      parts[1],
      parts[2],
      parts[3],
      parts[4],
      parts[5] == 60 ? 59 : parts[5],
    );
    if (m.group(7) != null) return CalendarTime.utc(wall);
    final zone = property.parameter('TZID')?.trim();
    if (zone == null || zone.isEmpty) return CalendarTime.floating(wall);
    return CalendarTime.zoned(wall, zone, zones.offset(zone, wall));
  }

  static bool _validDate(int y, int m, int d) =>
      y >= 1 && y <= 9999 && m >= 1 && m <= 12 && d >= 1 && d <= 31;

  static final _date = RegExp(r'^(\d{4})(\d{2})(\d{2})$');
  static final _dateTime = RegExp(
    r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z)?$',
  );

  /// An iCalendar DURATION (`P1W`, `-PT15M`, `P1DT2H`), or null.
  static Duration? parseDuration(String value) {
    final m = _duration.firstMatch(value.trim().toUpperCase());
    if (m == null || value.trim().length < 3) return null;
    int n(int group) => int.tryParse(m.group(group) ?? '') ?? 0;
    final d = Duration(
      days: n(2) * 7 + n(3),
      hours: n(4),
      minutes: n(5),
      seconds: n(6),
    );
    if (d > const Duration(days: 3660)) return null; // not a real event
    return m.group(1) == '-' ? -d : d;
  }

  static final _duration = RegExp(
    r'^([+-])?P(?:(\d{1,4})W)?(?:(\d{1,5})D)?(?:T(?:(\d{1,6})H)?(?:(\d{1,7})M)?(?:(\d{1,8})S)?)?$',
  );

  /// `20261112T140000Z` for [utc].
  static String formatUtc(DateTime utc) {
    final t = utc.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}'
        'T${two(t.hour)}${two(t.minute)}${two(t.second)}Z';
  }
}
