// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// One ready-made snooze time.
final class SnoozeChoice {
  const SnoozeChoice(this.kind, this.label, this.at);

  final SnoozeChoiceKind kind;
  final String label;

  /// When the message comes back (local time).
  final DateTime at;

  @override
  String toString() => 'SnoozeChoice($label, $at)';
}

enum SnoozeChoiceKind { laterToday, tonight, tomorrow, weekend, nextWeek }

/// The snooze choices offered at a moment, in local time:
///
/// - Later today: in 3 hours, or 6 pm if that is sooner and still ahead
///   (not offered when 3 hours from now is already tomorrow);
/// - Tonight: 8 pm (until it is nearly 8 pm);
/// - Tomorrow: 8 am the next day (in the small hours, 8 am this morning);
/// - This weekend: Saturday 9 am (on Saturday, Sunday 9 am; not offered
///   on Sunday once the morning is gone);
/// - Next week: Monday 8 am.
///
/// Days are counted on the calendar (`DateTime(y, m, d + 1, 8)`), never by
/// adding 24 hours, so a clock change doesn't move 8 am to 7 or 9. A time
/// two choices share is offered once, under the first.
abstract final class SnoozeTimes {
  /// How far ahead a choice must be to be offered.
  static const minimumAhead = Duration(minutes: 15);

  /// Before this hour, "tomorrow morning" means this morning.
  static const smallHoursEnd = 5;

  static List<SnoozeChoice> choicesAt(DateTime now) {
    final local = now.toLocal();
    DateTime on(int dayOffset, int hour) =>
        DateTime(local.year, local.month, local.day + dayOffset, hour);
    bool ahead(DateTime t) => t.isAfter(local.add(minimumAhead));

    final choices = <SnoozeChoice>[];
    void offer(SnoozeChoiceKind kind, String label, DateTime at) {
      if (!ahead(at)) return;
      if (choices.any((c) => c.at == at)) return;
      choices.add(SnoozeChoice(kind, label, at));
    }

    // Later today.
    var later = _roundUp(local.add(const Duration(hours: 3)));
    final sixPm = on(0, 18);
    if (sixPm.isAfter(local.add(minimumAhead)) && sixPm.isBefore(later)) {
      later = sixPm;
    }
    if (_sameDay(later, local)) {
      offer(SnoozeChoiceKind.laterToday, 'Later today', later);
    }

    // Tonight.
    offer(SnoozeChoiceKind.tonight, 'Tonight', on(0, 20));

    // Tomorrow (or, in the small hours, this) morning.
    if (local.hour < smallHoursEnd) {
      offer(SnoozeChoiceKind.tomorrow, 'This morning', on(0, 8));
    } else {
      offer(SnoozeChoiceKind.tomorrow, 'Tomorrow', on(1, 8));
    }

    // This weekend.
    final weekday = local.weekday; // Monday 1 ... Sunday 7
    if (weekday <= DateTime.friday) {
      offer(
        SnoozeChoiceKind.weekend,
        'This weekend',
        on(DateTime.saturday - weekday, 9),
      );
    } else if (weekday == DateTime.saturday) {
      final saturday = on(0, 9);
      offer(
        SnoozeChoiceKind.weekend,
        'This weekend',
        ahead(saturday) ? saturday : on(1, 9),
      );
    } else {
      offer(SnoozeChoiceKind.weekend, 'This weekend', on(0, 9));
    }

    // Next week: the coming Monday (a week on, on a Monday).
    offer(SnoozeChoiceKind.nextWeek, 'Next week', on(8 - weekday, 8));
    return choices;
  }

  /// Up to the next quarter hour, so "in 3 hours" reads as a round time.
  static DateTime _roundUp(DateTime t) {
    final minutes = t.minute % 15 == 0 && t.second == 0 && t.millisecond == 0
        ? t.minute
        : (t.minute ~/ 15 + 1) * 15;
    return DateTime(t.year, t.month, t.day, t.hour, minutes);
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
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

  /// "6:00 PM" today, "Tomorrow 8:00 AM" (or with [tomorrowWord] off,
  /// "Thu 8:00 AM"), "Sat 9:00 AM" within the week, else "Nov 14, 8:00 AM"
  /// (local time). [time] formats the time of day.
  static String describe(
    DateTime when, {
    required DateTime now,
    required String Function(DateTime) time,
    bool tomorrowWord = true,
  }) {
    final at = when.toLocal();
    final local = now.toLocal();
    final today = DateTime(local.year, local.month, local.day);
    final day = DateTime(at.year, at.month, at.day);
    final days = _calendarDays(today, day);
    final clock = time(at);
    if (days == 0) return clock;
    if (days == 1 && tomorrowWord) return 'Tomorrow $clock';
    if (days >= 1 && days < 7) return '${_weekdays[at.weekday - 1]} $clock';
    final date = '${_months[at.month - 1]} ${at.day}';
    return at.year == local.year ? '$date, $clock' : '$date ${at.year}, $clock';
  }

  /// Whole days from [from] to [to] (both midnights), DST-proof.
  static int _calendarDays(DateTime from, DateTime to) => DateTime.utc(
    to.year,
    to.month,
    to.day,
  ).difference(DateTime.utc(from.year, from.month, from.day)).inDays;
}
