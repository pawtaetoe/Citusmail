// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'calendar_invite.dart';
import 'calendar_time.dart';
import 'time_zones.dart';

/// How an event's time and repetition read, in plain English:
/// "Thu, 12 Nov · 2:00–3:00 pm", "Repeats weekly on Monday".
///
/// Times are shown in the reader's time zone ([offsetAt], by default this
/// device's); all-day and floating events as written.
final class CalendarText {
  const CalendarText({
    this.use24Hour = false,
    this.offsetAt = CalendarTime.localOffset,
    this.now,
  });

  final bool use24Hour;
  final Duration Function(DateTime utc) offsetAt;

  /// For "this year" (no year shown); now by default.
  final DateTime? now;

  DateTime get _today => now ?? DateTime.now();

  static const _weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  /// "Thu, 12 Nov · 2:00–3:00 pm", "Thu, 12 Nov · All day", or for longer
  /// events "Thu, 12 Nov, 2:00 pm – Fri, 13 Nov, 10:00 am".
  String when(CalendarInvite invite) {
    final start = invite.start;
    if (start == null) return 'No date given';
    final from = start.wallFor(offsetAt);
    final end = invite.end;
    if (start.allDay) {
      final last = end == null
          ? from
          : end.wallFor(offsetAt).subtract(const Duration(days: 1));
      if (!last.isAfter(from)) return '${day(from)} · All day';
      return '${day(from)} – ${day(last)} · All day';
    }
    if (end == null) return '${day(from)} · ${time(from)}';
    final until = end.wallFor(offsetAt);
    return _range(from, until);
  }

  String _range(DateTime from, DateTime until) {
    final sameDay =
        _date(from) == _date(until) ||
        (until.difference(from) < const Duration(days: 1) &&
            until.hour == 0 &&
            until.minute == 0);
    if (!sameDay) {
      return '${day(from)}, ${time(from)} – ${day(until)}, ${time(until)}';
    }
    return '${day(from)} · ${timeRange(from, until)}';
  }

  /// "Thu 12 Nov, 2 pm" (for the message list), or "Thu 12 Nov" for
  /// all-day events.
  String? short(CalendarInvite invite) {
    final start = invite.start;
    if (start == null) return null;
    final from = start.wallFor(offsetAt);
    final date = day(from).replaceFirst(',', '');
    if (start.allDay) return date;
    return '$date, ${time(from, compact: true)}';
  }

  /// When the event's own zone differs from the reader's: where it was
  /// set and its time there. For an unknown zone, that the times are
  /// shown as written. Null when there is nothing to say.
  String? zoneNote(CalendarInvite invite) {
    final start = invite.start;
    final zone = start?.zoneId;
    if (start == null || zone == null) return null;
    final name = CalendarTimeZones.readableName(zone);
    if (start.zoneUnknown) {
      return 'Times as written in the invitation ($name); its time zone '
          'isn\'t known here.';
    }
    final instant = start.instant!;
    final there = start.offset!;
    if (there == offsetAt(instant)) return null;
    final end = invite.end;
    final from = start.wall;
    final until = end?.instant?.add(end.offset ?? there);
    final range = until == null
        ? time(from)
        : _range(from, until).split(' · ').last;
    return 'Shown in your time zone. Set for $name: $range.';
  }

  /// "Thu, 12 Nov" (with the year when it isn't this year).
  String day(DateTime wall) {
    final base =
        '${_weekdays[wall.weekday - 1].substring(0, 3)}, ${wall.day} '
        '${_months[wall.month - 1]}';
    return wall.year == _today.year ? base : '$base ${wall.year}';
  }

  /// "2:00 pm" or "14:00"; [compact] drops ":00" ("2 pm").
  String time(DateTime wall, {bool compact = false}) {
    final m = wall.minute.toString().padLeft(2, '0');
    if (use24Hour) return '${wall.hour.toString().padLeft(2, '0')}:$m';
    final h = wall.hour % 12 == 0 ? 12 : wall.hour % 12;
    final clock = compact && wall.minute == 0 ? '$h' : '$h:$m';
    return '$clock ${wall.hour < 12 ? 'am' : 'pm'}';
  }

  /// "2:00–3:00 pm", "11:30 am–12:30 pm" or "14:00–15:00".
  String timeRange(DateTime from, DateTime until) {
    if (use24Hour) return '${time(from)}–${time(until)}';
    final samePeriod = (from.hour < 12) == (until.hour < 12);
    final start = time(from);
    return samePeriod
        ? '${start.substring(0, start.length - 3)}–${time(until)}'
        : '$start–${time(until)}';
  }

  /// "Repeats weekly on Monday", "Repeats every weekday", "Repeats
  /// monthly on the last Friday, until 12 Dec 2026"... Null if the event
  /// doesn't repeat; just "Repeats" for rules too unusual to describe.
  String? recurrence(CalendarInvite invite) {
    final rule = invite.recurrenceRule;
    if (rule == null || rule.isEmpty) return null;
    final parts = RecurrenceParts.parse(rule);
    final interval = (int.tryParse(parts['INTERVAL'] ?? '') ?? 1).clamp(1, 999);
    final byDay = [
      for (final d in (parts['BYDAY'] ?? '').split(','))
        if (_byDay.firstMatch(d.trim()) case final m?)
          (
            nth: int.tryParse(m.group(1) ?? '') ?? 0,
            day: RecurrenceParts.weekdays.indexOf(m.group(2)!),
          ),
    ];
    final start = invite.start?.wall;
    String every(String unit, String one) =>
        interval == 1 ? one : 'every $interval ${unit}s';
    String days(List<int> list) {
      final names = [for (final d in list) _weekdays[d]];
      if (names.length == 1) return names.single;
      return '${names.take(names.length - 1).join(', ')} and ${names.last}';
    }

    final String text;
    switch (parts['FREQ']) {
      case 'DAILY':
        text = 'Repeats ${every('day', 'daily')}';
      case 'WEEKLY':
        final list = [for (final d in byDay) d.day]..sort();
        if (interval == 1 && list.join() == '01234') {
          text = 'Repeats every weekday';
        } else if (list.isNotEmpty) {
          text = 'Repeats ${every('week', 'weekly')} on ${days(list)}';
        } else if (start != null) {
          text =
              'Repeats ${every('week', 'weekly')} on '
              '${_weekdays[start.weekday - 1]}';
        } else {
          text = 'Repeats ${every('week', 'weekly')}';
        }
      case 'MONTHLY':
        final monthDay = int.tryParse(
          parts['BYMONTHDAY']?.split(',').first ?? '',
        );
        final base = 'Repeats ${every('month', 'monthly')}';
        if (byDay.length == 1 && byDay.single.nth != 0) {
          text =
              '$base on the ${_ordinal(byDay.single.nth)} '
              '${_weekdays[byDay.single.day]}';
        } else if (monthDay != null && monthDay > 0 && monthDay <= 31) {
          text = '$base on day $monthDay';
        } else if (monthDay == -1) {
          text = '$base on the last day';
        } else {
          text = base;
        }
      case 'YEARLY':
        text = 'Repeats ${every('year', 'yearly')}';
      default:
        return 'Repeats';
    }
    final count = int.tryParse(parts['COUNT'] ?? '');
    if (count != null && count > 0) {
      return '$text, ${count == 1 ? 'once' : '$count times'}';
    }
    final until = RegExp(r'^(\d{4})(\d{2})(\d{2})')
        .firstMatch(parts['UNTIL'] ?? '');
    final untilMonth = int.parse(until?.group(2) ?? '0');
    if (until != null && untilMonth >= 1 && untilMonth <= 12) {
      final date = DateTime.utc(
        int.parse(until.group(1)!),
        untilMonth,
        int.parse(until.group(3)!),
      );
      return '$text, until ${date.day} ${_months[date.month - 1]} '
          '${date.year}';
    }
    return text;
  }

  static String _ordinal(int n) => switch (n) {
    1 => 'first',
    2 => 'second',
    3 => 'third',
    4 => 'fourth',
    5 => 'fifth',
    -1 => 'last',
    -2 => 'second to last',
    _ => '$n.',
  };

  static final _byDay = RegExp(r'^([+-]?\d{1,2})?(MO|TU|WE|TH|FR|SA|SU)$');

  static DateTime _date(DateTime t) => DateTime.utc(t.year, t.month, t.day);

  /// "Accepted", "Maybe", "Declined"... as the app says it.
  static String answer(CalendarAnswer answer) => switch (answer) {
    CalendarAnswer.accepted => 'Accepted',
    CalendarAnswer.tentative => 'Maybe',
    CalendarAnswer.declined => 'Declined',
    CalendarAnswer.needsAction => 'Not answered',
    CalendarAnswer.delegated => 'Delegated',
  };
}
