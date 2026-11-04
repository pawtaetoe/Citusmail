// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'ical.dart';

/// Works out the UTC offset of a TZID at a clock time: from the
/// VTIMEZONE definitions in the file when it has them (Outlook always
/// sends them), else from a built-in table of common IANA and Windows zone
/// names with their usual daylight-saving rules. The table is a best
/// effort: rules change, and rare zones are missing (their times are then
/// shown as written, with a note).
final class CalendarTimeZones {
  CalendarTimeZones([Iterable<ICalComponent> vtimezones = const []]) {
    for (final zone in vtimezones.take(50)) {
      final id = zone.property('TZID')?.value.trim();
      if (id == null || id.isEmpty) continue;
      final observances = [
        for (final child in zone.children.take(100)) ?_Observance.read(child),
      ];
      if (observances.isNotEmpty) _defined[id] = observances;
    }
  }

  final _defined = <String, List<_Observance>>{};

  /// Whether the file defines the zone [id] itself.
  bool defines(String id) => _defined.containsKey(id);

  /// The offset of [zoneId] at the clock time [wall], or null if unknown.
  Duration? offset(String zoneId, DateTime wall) {
    final defined = _defined[zoneId];
    if (defined != null) return _Observance.offsetAt(defined, wall);
    return builtInOffset(zoneId, wall);
  }

  /// The offset from the built-in table only.
  static Duration? builtInOffset(String zoneId, DateTime wall) {
    final rule = _rule(zoneId);
    if (rule == null) return null;
    return rule.offsetAt(wall);
  }

  /// A short readable name for a zone id: `America/New_York` -> `New York`;
  /// Windows names as they are.
  static String readableName(String zoneId) {
    final iana = _iana.firstMatch(zoneId.trim());
    if (iana != null) {
      return iana.group(1)!.split('/').last.replaceAll('_', ' ');
    }
    return zoneId.trim().replaceAll('"', '');
  }

  static _Rule? _rule(String id) {
    var name = id.trim().replaceAll('"', '');
    // "/mozilla.org/20070129_1/Europe/Berlin", "/Europe/Berlin"
    final iana = _iana.firstMatch(name);
    if (iana != null && _zones.containsKey(iana.group(1)!.toLowerCase())) {
      return _zones[iana.group(1)!.toLowerCase()];
    }
    name = name.toLowerCase();
    if (_zones[name] case final rule?) return rule;
    // Outlook display names: "(UTC-05:00) Eastern Time (US & Canada)".
    final utc = _utcPrefix.firstMatch(name);
    if (utc != null) {
      final minutes =
          int.parse(utc.group(2)!) * 60 + int.parse(utc.group(3) ?? '0');
      final offset = Duration(
        minutes: utc.group(1) == '-' ? -minutes : minutes,
      );
      final dst = name.contains('us & canada')
          ? _Dst.us
          : name.contains(_europe)
          ? _Dst.eu
          : _Dst.none;
      return _Rule(offset, dst);
    }
    return null;
  }

  static final _iana = RegExp(
    r'((?:Africa|America|Antarctica|Asia|Atlantic|Australia|Europe|Indian|Pacific|Etc)/[A-Za-z_+\-]+(?:/[A-Za-z_+\-]+)?)$',
  );
  static final _utcPrefix = RegExp(
    r'^\((?:utc|gmt)(?:([+-])(\d{1,2}):?(\d{2})?)?\)',
  );
  static final _europe = RegExp(
    r'amsterdam|berlin|brussels|paris|madrid|rome|stockholm|vienna|warsaw|prague|budapest|copenhagen|oslo|zurich|dublin|lisbon|london|edinburgh|athens|helsinki|kyiv|kiev|bucharest|sofia|riga|tallinn|vilnius',
  );

  static final Map<String, _Rule> _zones = () {
    final zones = <String, _Rule>{};
    void add(double hours, _Dst dst, List<String> names) {
      final rule = _Rule(Duration(minutes: (hours * 60).round()), dst);
      for (final name in names) {
        zones[name.toLowerCase()] = rule;
      }
    }

    add(0, _Dst.none, [
      'UTC',
      'GMT',
      'Z',
      'Etc/UTC',
      'Etc/GMT',
      'Africa/Abidjan',
      'Atlantic/Reykjavik',
      'Coordinated Universal Time',
      'Greenwich Standard Time',
    ]);
    add(0, _Dst.eu, [
      'Europe/London',
      'Europe/Dublin',
      'Europe/Lisbon',
      'Atlantic/Canary',
      'GMT Standard Time',
    ]);
    add(1, _Dst.eu, [
      'Europe/Paris',
      'Europe/Berlin',
      'Europe/Madrid',
      'Europe/Rome',
      'Europe/Amsterdam',
      'Europe/Brussels',
      'Europe/Vienna',
      'Europe/Stockholm',
      'Europe/Oslo',
      'Europe/Copenhagen',
      'Europe/Zurich',
      'Europe/Prague',
      'Europe/Warsaw',
      'Europe/Budapest',
      'Europe/Belgrade',
      'Europe/Zagreb',
      'Europe/Ljubljana',
      'Europe/Bratislava',
      'Europe/Luxembourg',
      'Europe/Monaco',
      'Europe/Malta',
      'W. Europe Standard Time',
      'Romance Standard Time',
      'Central Europe Standard Time',
      'Central European Standard Time',
    ]);
    add(1, _Dst.none, ['Africa/Lagos', 'Africa/Algiers', 'Africa/Tunis']);
    add(2, _Dst.eu, [
      'Europe/Athens',
      'Europe/Helsinki',
      'Europe/Kyiv',
      'Europe/Kiev',
      'Europe/Bucharest',
      'Europe/Sofia',
      'Europe/Riga',
      'Europe/Tallinn',
      'Europe/Vilnius',
      'Asia/Nicosia',
      'Asia/Jerusalem',
      'Asia/Beirut',
      'E. Europe Standard Time',
      'FLE Standard Time',
      'GTB Standard Time',
      'Israel Standard Time',
    ]);
    add(2, _Dst.none, [
      'Africa/Johannesburg',
      'Africa/Cairo',
      'Africa/Maputo',
      'Europe/Kaliningrad',
      'South Africa Standard Time',
      'Egypt Standard Time',
    ]);
    add(3, _Dst.none, [
      'Europe/Moscow',
      'Europe/Istanbul',
      'Europe/Minsk',
      'Asia/Riyadh',
      'Asia/Qatar',
      'Asia/Baghdad',
      'Africa/Nairobi',
      'Russian Standard Time',
      'Turkey Standard Time',
      'Arab Standard Time',
      'E. Africa Standard Time',
    ]);
    add(3.5, _Dst.none, ['Asia/Tehran', 'Iran Standard Time']);
    add(4, _Dst.none, [
      'Asia/Dubai',
      'Asia/Muscat',
      'Asia/Baku',
      'Asia/Tbilisi',
      'Asia/Yerevan',
      'Arabian Standard Time',
    ]);
    add(4.5, _Dst.none, ['Asia/Kabul']);
    add(5, _Dst.none, [
      'Asia/Karachi',
      'Asia/Tashkent',
      'Asia/Yekaterinburg',
      'Pakistan Standard Time',
    ]);
    add(5.5, _Dst.none, [
      'Asia/Kolkata',
      'Asia/Calcutta',
      'Asia/Colombo',
      'India Standard Time',
    ]);
    add(5.75, _Dst.none, ['Asia/Kathmandu', 'Asia/Katmandu']);
    add(6, _Dst.none, [
      'Asia/Dhaka',
      'Asia/Almaty',
      'Bangladesh Standard Time',
    ]);
    add(6.5, _Dst.none, ['Asia/Yangon', 'Asia/Rangoon']);
    add(7, _Dst.none, [
      'Asia/Bangkok',
      'Asia/Jakarta',
      'Asia/Ho_Chi_Minh',
      'Asia/Saigon',
      'Asia/Novosibirsk',
      'SE Asia Standard Time',
    ]);
    add(8, _Dst.none, [
      'Asia/Singapore',
      'Asia/Shanghai',
      'Asia/Hong_Kong',
      'Asia/Taipei',
      'Asia/Manila',
      'Asia/Kuala_Lumpur',
      'Asia/Makassar',
      'Australia/Perth',
      'China Standard Time',
      'Singapore Standard Time',
      'Taipei Standard Time',
      'W. Australia Standard Time',
    ]);
    add(9, _Dst.none, [
      'Asia/Tokyo',
      'Asia/Seoul',
      'Asia/Jayapura',
      'Tokyo Standard Time',
      'Korea Standard Time',
    ]);
    add(9.5, _Dst.none, ['Australia/Darwin', 'AUS Central Standard Time']);
    add(9.5, _Dst.au, [
      'Australia/Adelaide',
      'Australia/Broken_Hill',
      'Cen. Australia Standard Time',
    ]);
    add(10, _Dst.none, [
      'Australia/Brisbane',
      'Pacific/Guam',
      'Pacific/Port_Moresby',
      'E. Australia Standard Time',
    ]);
    add(10, _Dst.au, [
      'Australia/Sydney',
      'Australia/Melbourne',
      'Australia/Canberra',
      'Australia/Hobart',
      'AUS Eastern Standard Time',
      'Tasmania Standard Time',
    ]);
    add(12, _Dst.nz, ['Pacific/Auckland', 'New Zealand Standard Time']);
    add(12, _Dst.none, ['Pacific/Fiji']);
    add(-1, _Dst.none, ['Atlantic/Cape_Verde']);
    add(-2, _Dst.none, ['America/Noronha', 'Atlantic/South_Georgia']);
    add(-3, _Dst.none, [
      'America/Sao_Paulo',
      'America/Argentina/Buenos_Aires',
      'America/Buenos_Aires',
      'America/Montevideo',
      'E. South America Standard Time',
      'Argentina Standard Time',
    ]);
    add(-3.5, _Dst.us, ['America/St_Johns', 'Newfoundland Standard Time']);
    add(-4, _Dst.us, [
      'America/Halifax',
      'Atlantic/Bermuda',
      'Atlantic Standard Time',
    ]);
    add(-4, _Dst.none, [
      'America/Puerto_Rico',
      'America/Caracas',
      'America/La_Paz',
      'America/Santo_Domingo',
      'SA Western Standard Time',
    ]);
    add(-5, _Dst.us, [
      'America/New_York',
      'America/Toronto',
      'America/Detroit',
      'America/Montreal',
      'America/Indiana/Indianapolis',
      'America/Kentucky/Louisville',
      'US/Eastern',
      'EST5EDT',
      'Eastern Standard Time',
      'US Eastern Standard Time',
    ]);
    add(-5, _Dst.none, [
      'America/Bogota',
      'America/Lima',
      'America/Panama',
      'America/Cancun',
      'America/Jamaica',
      'SA Pacific Standard Time',
    ]);
    add(-6, _Dst.us, [
      'America/Chicago',
      'America/Winnipeg',
      'US/Central',
      'CST6CDT',
      'Central Standard Time',
    ]);
    add(-6, _Dst.none, [
      'America/Mexico_City',
      'America/Regina',
      'America/Guatemala',
      'America/Costa_Rica',
      'Central Standard Time (Mexico)',
      'Canada Central Standard Time',
      'Central America Standard Time',
    ]);
    add(-7, _Dst.us, [
      'America/Denver',
      'America/Edmonton',
      'America/Boise',
      'US/Mountain',
      'MST7MDT',
      'Mountain Standard Time',
    ]);
    add(-7, _Dst.none, ['America/Phoenix', 'US Mountain Standard Time']);
    add(-8, _Dst.us, [
      'America/Los_Angeles',
      'America/Vancouver',
      'America/Tijuana',
      'US/Pacific',
      'PST8PDT',
      'Pacific Standard Time',
    ]);
    add(-9, _Dst.us, ['America/Anchorage', 'Alaskan Standard Time']);
    add(-10, _Dst.none, [
      'Pacific/Honolulu',
      'US/Hawaii',
      'Hawaiian Standard Time',
    ]);
    return zones;
  }();
}

/// The usual daylight-saving rules.
enum _Dst { none, eu, us, au, nz }

final class _Rule {
  const _Rule(this.standard, this.dst);

  final Duration standard;
  final _Dst dst;

  Duration offsetAt(DateTime wall) {
    final y = wall.year;
    final summer = switch (dst) {
      _Dst.none => false,
      // Last Sunday of March to last Sunday of October, 01:00 UTC.
      _Dst.eu => _between(
        wall.subtract(standard),
        _lastSunday(y, 3).add(const Duration(hours: 1)),
        _lastSunday(y, 10).add(const Duration(hours: 1)),
      ),
      // Second Sunday of March 02:00 to first Sunday of November 02:00
      // (01:00 standard time), local.
      _Dst.us => _between(
        wall,
        _nthSunday(y, 3, 2).add(const Duration(hours: 2)),
        _nthSunday(y, 11, 1).add(const Duration(hours: 1)),
      ),
      // Southern: first Sunday of October 02:00 to first Sunday of April
      // 03:00 (02:00 standard time).
      _Dst.au => !_between(
        wall,
        _nthSunday(y, 4, 1).add(const Duration(hours: 2)),
        _nthSunday(y, 10, 1).add(const Duration(hours: 2)),
      ),
      // Last Sunday of September 02:00 to first Sunday of April 03:00.
      _Dst.nz => !_between(
        wall,
        _nthSunday(y, 4, 1).add(const Duration(hours: 2)),
        _lastSunday(y, 9).add(const Duration(hours: 2)),
      ),
    };
    return summer ? standard + const Duration(hours: 1) : standard;
  }

  static bool _between(DateTime t, DateTime from, DateTime until) =>
      !t.isBefore(from) && t.isBefore(until);

  static DateTime _lastSunday(int year, int month) {
    final last = DateTime.utc(year, month + 1, 0);
    return last.subtract(Duration(days: last.weekday % 7));
  }

  static DateTime _nthSunday(int year, int month, int n) {
    final first = DateTime.utc(year, month);
    final firstSunday = first.add(Duration(days: (7 - first.weekday) % 7));
    return firstSunday.add(Duration(days: 7 * (n - 1)));
  }
}

/// A STANDARD or DAYLIGHT part of a VTIMEZONE: from its onsets on, the
/// zone's offset is [to].
final class _Observance {
  _Observance(this.start, this.from, this.to, this.rule, this.dates);

  /// The first onset, as a clock time before the change.
  final DateTime start;
  final Duration from;
  final Duration to;

  /// A yearly rule (`FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU`), parsed.
  final _YearlyRule? rule;

  /// Extra onsets (RDATE).
  final List<DateTime> dates;

  static _Observance? read(ICalComponent c) {
    if (c.name != 'STANDARD' && c.name != 'DAYLIGHT') return null;
    final start = _wall(c.property('DTSTART')?.value);
    final from = _offset(c.property('TZOFFSETFROM')?.value);
    final to = _offset(c.property('TZOFFSETTO')?.value);
    if (start == null || to == null) return null;
    return _Observance(
      start,
      from ?? to,
      to,
      _YearlyRule.parse(c.property('RRULE')?.value),
      [
        for (final p in c.all('RDATE').take(50))
          for (final v in p.value.split(',').take(50)) ?_wall(v),
      ],
    );
  }

  /// The latest onset at or before [wall], looking at this year and the
  /// last.
  DateTime? latestOnset(DateTime wall) {
    DateTime? best;
    void consider(DateTime onset) {
      if (onset.isAfter(wall) || onset.isBefore(start)) return;
      if (best == null || onset.isAfter(best!)) best = onset;
    }

    consider(start);
    dates.forEach(consider);
    final rule = this.rule;
    if (rule != null) {
      for (final year in [wall.year - 1, wall.year]) {
        final onset = rule.onset(year, start);
        if (onset == null) continue;
        if (rule.until case final until? when onset.isAfter(until)) continue;
        consider(onset);
      }
    }
    return best;
  }

  static Duration offsetAt(List<_Observance> observances, DateTime wall) {
    _Observance? current;
    DateTime? at;
    for (final o in observances) {
      final onset = o.latestOnset(wall);
      if (onset != null && (at == null || onset.isAfter(at))) {
        at = onset;
        current = o;
      }
    }
    if (current != null) return current.to;
    // Before every onset: the offset in force before the earliest one.
    final earliest = observances.reduce(
      (a, b) => a.start.isBefore(b.start) ? a : b,
    );
    return earliest.from;
  }

  static DateTime? _wall(String? value) {
    final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})Z?)?$')
        .firstMatch(value?.trim() ?? '');
    if (m == null) return null;
    int n(int g) => int.parse(m.group(g) ?? '0');
    return DateTime.utc(n(1), n(2), n(3), n(4), n(5), n(6));
  }

  static Duration? _offset(String? value) {
    final m = RegExp(r'^([+-])(\d{2})(\d{2})(\d{2})?$')
        .firstMatch(value?.trim() ?? '');
    if (m == null) return null;
    final d = Duration(
      hours: int.parse(m.group(2)!),
      minutes: int.parse(m.group(3)!),
      seconds: int.parse(m.group(4) ?? '0'),
    );
    if (d > const Duration(hours: 18)) return null;
    return m.group(1) == '-' ? -d : d;
  }
}

/// The yearly rules time zones use: a month, and a weekday in it
/// (`BYDAY=-1SU`, `2SU`) or a day of the month, optionally both
/// (`BYDAY=SU;BYMONTHDAY=8,9,10,11,12,13,14`).
final class _YearlyRule {
  _YearlyRule(this.month, this.weekday, this.nth, this.monthDays, this.until);

  final int? month;
  final int? weekday;
  final int nth;
  final List<int> monthDays;
  final DateTime? until;

  static _YearlyRule? parse(String? value) {
    if (value == null) return null;
    final parts = RecurrenceParts.parse(value);
    if (parts['FREQ'] != 'YEARLY') return null;
    final month = int.tryParse(parts['BYMONTH']?.split(',').first ?? '');
    int? weekday;
    var nth = 0;
    final byDay = parts['BYDAY']?.split(',').first;
    if (byDay != null) {
      final m = RegExp(r'^([+-]?\d{1,2})?(MO|TU|WE|TH|FR|SA|SU)$')
          .firstMatch(byDay);
      if (m == null) return null;
      nth = int.tryParse(m.group(1) ?? '') ?? 0;
      weekday = RecurrenceParts.weekdays.indexOf(m.group(2)!) + 1;
    }
    final days = [
      for (final d in (parts['BYMONTHDAY'] ?? '').split(',')) ?int.tryParse(d),
    ];
    final until = _Observance._wall(parts['UNTIL']);
    return _YearlyRule(month, weekday, nth, days, until);
  }

  DateTime? onset(int year, DateTime start) {
    final month = this.month ?? start.month;
    if (month < 1 || month > 12) return null;
    final time = Duration(
      hours: start.hour,
      minutes: start.minute,
      seconds: start.second,
    );
    final last = DateTime.utc(year, month + 1, 0).day;
    final candidates = [
      for (var d = 1; d <= last; d++)
        if ((weekday == null ||
                DateTime.utc(year, month, d).weekday == weekday) &&
            (monthDays.isEmpty || monthDays.contains(d)))
          d,
    ];
    if (candidates.isEmpty) return null;
    final int day;
    if (weekday != null && nth != 0 && monthDays.isEmpty) {
      final i = nth > 0 ? nth - 1 : candidates.length + nth;
      if (i < 0 || i >= candidates.length) return null;
      day = candidates[i];
    } else if (weekday == null && monthDays.isEmpty) {
      day = start.day <= last ? start.day : last;
    } else {
      day = candidates.first;
    }
    return DateTime.utc(year, month, day).add(time);
  }
}

/// An RRULE's parts by name (`FREQ=WEEKLY;BYDAY=MO` -> {FREQ: WEEKLY,
/// BYDAY: MO}), upper case.
abstract final class RecurrenceParts {
  static const weekdays = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

  static Map<String, String> parse(String value) => {
    for (final part in value.split(';').take(30))
      if (part.indexOf('=') case final eq when eq > 0)
        part.substring(0, eq).trim().toUpperCase(): part
            .substring(eq + 1)
            .trim()
            .toUpperCase(),
  };
}
