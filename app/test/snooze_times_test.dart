// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/mail/snooze_times.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, DateTime> at(DateTime now) => {
    for (final c in SnoozeTimes.choicesAt(now)) c.label: c.at,
  };

  test('a weekday morning: every choice, at its time', () {
    // Wednesday 4 November 2026, 9:10.
    final choices = at(DateTime(2026, 11, 4, 9, 10));
    expect(choices, {
      'Later today': DateTime(2026, 11, 4, 12, 15),
      'Tonight': DateTime(2026, 11, 4, 20),
      'Tomorrow': DateTime(2026, 11, 5, 8),
      'This weekend': DateTime(2026, 11, 7, 9),
      'Next week': DateTime(2026, 11, 9, 8),
    });
  });

  test('later today is 6 pm when that is sooner and still ahead', () {
    expect(
      at(DateTime(2026, 11, 4, 16))['Later today'],
      DateTime(2026, 11, 4, 18),
    );
    // 6 pm is too close: three hours from now instead.
    expect(
      at(DateTime(2026, 11, 4, 17, 50))['Later today'],
      DateTime(2026, 11, 4, 21),
    );
    // On the quarter hour already: not rounded further.
    expect(
      at(DateTime(2026, 11, 4, 10, 30))['Later today'],
      DateTime(2026, 11, 4, 13, 30),
    );
  });

  test('late at night: no "later today" or "tonight"', () {
    final choices = at(DateTime(2026, 11, 4, 22, 30));
    expect(choices.keys, isNot(contains('Later today')));
    expect(choices.keys, isNot(contains('Tonight')));
    expect(choices['Tomorrow'], DateTime(2026, 11, 5, 8));
    // Just before 8 pm, tonight is too close to offer.
    expect(at(DateTime(2026, 11, 4, 19, 50)).keys, isNot(contains('Tonight')));
  });

  test('in the small hours, "this morning" means 8 am today', () {
    final choices = at(DateTime(2026, 11, 5, 1, 30));
    expect(choices['This morning'], DateTime(2026, 11, 5, 8));
    expect(choices.keys, isNot(contains('Tomorrow')));
    expect(choices['Later today'], DateTime(2026, 11, 5, 4, 30));
    expect(choices['Tonight'], DateTime(2026, 11, 5, 20));
  });

  test('weekend days', () {
    // Friday: Saturday 9 am.
    expect(
      at(DateTime(2026, 11, 6, 15))['This weekend'],
      DateTime(2026, 11, 7, 9),
    );
    // Saturday morning: this morning at 9.
    expect(
      at(DateTime(2026, 11, 7, 7))['This weekend'],
      DateTime(2026, 11, 7, 9),
    );
    // Saturday afternoon: Sunday at 9.
    expect(
      at(DateTime(2026, 11, 7, 14))['This weekend'],
      DateTime(2026, 11, 8, 9),
    );
    // Sunday afternoon: the weekend is nearly over, so not offered; and
    // "next week" is tomorrow morning, offered once (as Tomorrow).
    final sunday = at(DateTime(2026, 11, 8, 14));
    expect(sunday.keys, isNot(contains('This weekend')));
    expect(sunday['Tomorrow'], DateTime(2026, 11, 9, 8));
    expect(sunday.keys, isNot(contains('Next week')));
    // Monday: next week is a week on.
    expect(
      at(DateTime(2026, 11, 9, 9))['Next week'],
      DateTime(2026, 11, 16, 8),
    );
  });

  test('across a month and a year', () {
    final choices = at(DateTime(2026, 12, 31, 10));
    expect(choices['Tomorrow'], DateTime(2027, 1, 1, 8));
    expect(choices['This weekend'], DateTime(2027, 1, 2, 9));
    expect(choices['Next week'], DateTime(2027, 1, 4, 8));
  });

  test('every hour of a year: on the hour in local time, ahead, and each '
      'time once (clock changes included)', () {
    for (
      var t = DateTime(2026);
      t.year == 2026;
      t = t.add(const Duration(minutes: 37))
    ) {
      final choices = SnoozeTimes.choicesAt(t);
      expect(choices, isNotEmpty, reason: '$t');
      expect(choices.map((c) => c.at).toSet(), hasLength(choices.length));
      for (final c in choices) {
        expect(
          c.at.isAfter(t.add(SnoozeTimes.minimumAhead)),
          isTrue,
          reason: '$t $c',
        );
        switch (c.kind) {
          case SnoozeChoiceKind.tomorrow || SnoozeChoiceKind.nextWeek:
            expect((c.at.hour, c.at.minute), (8, 0), reason: '$t $c');
          case SnoozeChoiceKind.weekend:
            expect((c.at.hour, c.at.minute), (9, 0), reason: '$t $c');
            expect(c.at.weekday, greaterThanOrEqualTo(DateTime.saturday));
          case SnoozeChoiceKind.tonight:
            expect((c.at.hour, c.at.minute), (20, 0), reason: '$t $c');
          case SnoozeChoiceKind.laterToday:
            expect(c.at.day, t.day, reason: '$t $c');
        }
        if (c.kind == SnoozeChoiceKind.nextWeek) {
          expect(c.at.weekday, DateTime.monday);
        }
      }
    }
  });

  test('describing a time', () {
    final now = DateTime(2026, 11, 4, 9);
    String describe(DateTime t, {bool tomorrowWord = true}) =>
        SnoozeTimes.describe(
          t,
          now: now,
          tomorrowWord: tomorrowWord,
          time: (t) => '${t.hour}:${t.minute.toString().padLeft(2, '0')}',
        );
    expect(describe(DateTime(2026, 11, 4, 18)), '18:00');
    expect(describe(DateTime(2026, 11, 5, 8)), 'Tomorrow 8:00');
    expect(describe(DateTime(2026, 11, 5, 8), tomorrowWord: false), 'Thu 8:00');
    expect(describe(DateTime(2026, 11, 7, 9)), 'Sat 9:00');
    expect(describe(DateTime(2026, 11, 14, 8)), 'Nov 14, 8:00');
    expect(describe(DateTime(2027, 2, 1, 8)), 'Feb 1 2027, 8:00');
  });
}
