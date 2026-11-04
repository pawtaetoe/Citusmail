// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'snooze_times.dart';

/// One ready-made "Send later" time.
final class SendLaterChoice {
  const SendLaterChoice(this.kind, this.label, this.at);

  final SendLaterKind kind;
  final String label;

  /// When the message goes out (local time).
  final DateTime at;

  @override
  String toString() => 'SendLaterChoice($label, $at)';
}

enum SendLaterKind { morning, afternoon, monday }

/// The "Send later" choices offered at a moment, in local time:
///
/// - Tomorrow morning: 8 am the next day;
/// - Tomorrow afternoon: 1 pm the next day;
/// - Monday morning: the coming Monday at 8 am (not offered on a Monday
///   morning, nor when it is the same as tomorrow morning).
///
/// In the small hours (before 5 am, as for snoozing) "tomorrow" means the
/// day that is starting: "This morning" and "This afternoon". Days are
/// counted on the calendar, so a clock change doesn't move 8 am.
abstract final class SendLaterTimes {
  /// The clock scheduling starts from (tests set a fixed one).
  static DateTime Function() clock = DateTime.now;

  static List<SendLaterChoice> choicesAt(DateTime now) {
    final local = now.toLocal();
    DateTime on(int dayOffset, int hour) =>
        DateTime(local.year, local.month, local.day + dayOffset, hour);
    bool ahead(DateTime t) => t.isAfter(local.add(SnoozeTimes.minimumAhead));

    final choices = <SendLaterChoice>[];
    void offer(SendLaterKind kind, String label, DateTime at) {
      if (!ahead(at)) return;
      if (choices.any((c) => c.at == at)) return;
      choices.add(SendLaterChoice(kind, label, at));
    }

    final smallHours = local.hour < SnoozeTimes.smallHoursEnd;
    final day = smallHours ? 0 : 1;
    offer(
      SendLaterKind.morning,
      smallHours ? 'This morning' : 'Tomorrow morning',
      on(day, 8),
    );
    offer(
      SendLaterKind.afternoon,
      smallHours ? 'This afternoon' : 'Tomorrow afternoon',
      on(day, 13),
    );

    final weekday = local.weekday; // Monday 1 ... Sunday 7
    final mondayMorning = weekday == DateTime.monday && local.hour < 12;
    if (!mondayMorning) {
      offer(SendLaterKind.monday, 'Monday morning', on(8 - weekday, 8));
    }
    return choices;
  }
}
