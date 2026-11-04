// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_sync/mail_sync.dart';

/// One ready-made "Remind me if no reply" time.
final class FollowUpChoice {
  const FollowUpChoice(this.kind, this.label, this.at);

  final FollowUpKind kind;
  final String label;

  /// When the message comes back if nobody answered (local time).
  final DateTime at;

  @override
  String toString() => 'FollowUpChoice($label, $at)';
}

enum FollowUpKind { oneDay, threeDays, oneWeek }

/// The "Remind me if no reply" choices for a message sent at a moment:
/// in 1 day, in 3 days, in 1 week, at the same time of day. Days are
/// counted on the calendar, so a clock change doesn't move the time. A
/// picked date comes back at [pickedHour] that morning.
abstract final class FollowUpTimes {
  /// The clock reminders start from (tests set a fixed one).
  static DateTime Function() clock = DateTime.now;

  /// A picked date comes back at 8 in the morning.
  static const pickedHour = 8;

  static List<FollowUpChoice> choicesFrom(DateTime sent) {
    final local = sent.toLocal();
    DateTime after(int days) => DateTime(
      local.year,
      local.month,
      local.day + days,
      local.hour,
      local.minute,
    );
    return [
      FollowUpChoice(FollowUpKind.oneDay, 'In 1 day', after(1)),
      FollowUpChoice(FollowUpKind.threeDays, 'In 3 days', after(3)),
      FollowUpChoice(FollowUpKind.oneWeek, 'In 1 week', after(7)),
    ];
  }

  /// A picked [day], at [pickedHour].
  static DateTime onDay(DateTime day) =>
      DateTime(day.year, day.month, day.day, pickedHour);

  /// Whole calendar days from [from] to [to] (local).
  static int daysBetween(DateTime from, DateTime to) {
    final a = from.toLocal(), b = to.toLocal();
    return DateTime.utc(
      b.year,
      b.month,
      b.day,
    ).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
  }

  /// "today", "yesterday", "3 days ago", "2 weeks ago".
  static String ago(DateTime sent, DateTime now) {
    final days = daysBetween(sent, now);
    return switch (days) {
      <= 0 => 'today',
      1 => 'yesterday',
      < 14 => '$days days ago',
      _ => '${days ~/ 7} weeks ago',
    };
  }
}

/// Follow-ups in words, for lists and notifications.
abstract final class FollowUpWords {
  /// "Ana Costa", "Ana Costa and 1 other", "ana@x.example".
  static String recipients(FollowUp f) {
    if (f.recipients.isEmpty) return '(no recipient)';
    final first = f.recipients.first;
    final name = first.displayName?.trim();
    final who = name == null || name.isEmpty ? first.address : name;
    final more = f.recipients.length - 1;
    return switch (more) {
      0 => who,
      1 => '$who and 1 other',
      _ => '$who and $more others',
    };
  }

  static String subject(FollowUp f) =>
      f.subject.trim().isEmpty ? '(no subject)' : f.subject.trim();

  /// "Sent 3 days ago".
  static String sent(FollowUp f, DateTime now) =>
      'Sent ${FollowUpTimes.ago(f.sentAt, now)}';

  /// "No reply from Ana Costa to “Quote for the kitchen” — sent 3 days
  /// ago".
  static String notification(FollowUp f, DateTime now) =>
      'No reply from ${recipients(f)} to “${subject(f)}” — sent '
      '${FollowUpTimes.ago(f.sentAt, now)}';
}
