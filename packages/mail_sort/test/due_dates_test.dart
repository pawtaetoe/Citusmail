// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_sort/mail_sort.dart';
import 'package:test/test.dart';

DateTime day(int month, int d, [int year = 2026]) =>
    DateTime.utc(year, month, d);

/// Received at noon where the tests run, so the calendar day is clear.
DateTime received(int month, int d, [int year = 2026]) =>
    DateTime(year, month, d, 12);

void main() {
  group('dates', () {
    test('common formats', () {
      final cases = {
        '15 Nov 2026': day(11, 15),
        '15th November, 2026': day(11, 15),
        '1st of December 2026': day(12, 1),
        'Nov 15, 2026': day(11, 15),
        'November 5th 2026': day(11, 5),
        'Sept 3, 2026': day(9, 3),
        '15/11/2026': day(11, 15),
        '05/11/2026': day(11, 5), // day first: 5 November
        '15-11-2026': day(11, 15),
        '15.11.26': day(11, 15),
        '11/15/2026': day(11, 15), // can only be month first
        '2026-11-15': day(11, 15),
      };
      for (final MapEntry(key: text, value: date) in cases.entries) {
        expect(DueDates.datesIn('Date: $text.').map((d) => d.date), [
          date,
        ], reason: text);
      }
    });

    test('a date without a year takes the one nearest after the email', () {
      expect(
        DueDates.datesIn('due 15 Nov', reference: received(11, 3)).single.date,
        day(11, 15),
      );
      expect(
        DueDates.datesIn('due Jan 5', reference: received(12, 20)).single.date,
        day(1, 5, 2027),
      );
      // Without a reference it can't be told.
      expect(DueDates.datesIn('due 15 Nov'), isEmpty);
    });

    test('not dates', () {
      for (final text in [
        '31/02/2026',
        'Account 12/34/5678',
        'Version 1.2.3',
        'Call 6123 4567',
        'Pay S\$15.11 by card',
        'Order 2026-1234',
      ]) {
        expect(DueDates.datesIn(text), isEmpty, reason: text);
      }
    });
  });

  group('due dates', () {
    test('labelled due dates', () {
      final cases = {
        'Please pay by 15 Nov 2026 to avoid a late fee.': day(11, 15),
        'Payment due date: 15/11/2026': day(11, 15),
        'Due date\n20 Nov 2026': day(11, 20),
        'Amount due S\$84.20, due by Nov 20, 2026': day(11, 20),
        'Your bill of \$42.10 is due on 2026-11-18.': day(11, 18),
        'Kindly make payment on or before 18 November 2026.': day(11, 18),
      };
      for (final MapEntry(key: text, value: date) in cases.entries) {
        expect(
          DueDates.dueDateIn(text, received: received(11, 1)),
          date,
          reason: text,
        );
      }
    });

    test('the bill date and the period are not the due date', () {
      const bill = '''
Bill date: 01 Nov 2026
Billing period: 1 Oct 2026 - 31 Oct 2026
Total amount due: S\$84.20
Due date: 20 Nov 2026
''';
      expect(DueDates.dueDateIn(bill, received: received(11, 1)), day(11, 20));
      // A table: the labels on one line, the dates on the next.
      const table = 'Bill Date   Due Date\n01 Nov 2026   21 Nov 2026';
      expect(DueDates.dueDateIn(table, received: received(11, 1)), day(11, 21));
      expect(
        DueDates.dueDateIn(
          'Statement date 01 Nov 2026. Paid on 3 Oct 2026, thank you.',
          received: received(11, 1),
        ),
        isNull,
      );
    });

    test('within N days of receiving this email', () {
      expect(
        DueDates.dueDateIn(
          'Please pay your bill within 7 days of receiving this email to '
          'avoid any service interruption.',
          received: received(10, 29),
        ),
        day(11, 5),
      );
      expect(
        DueDates.dueDateIn(
          'Payment is required within fourteen (14) days.',
          received: received(11, 1),
        ),
        day(11, 15),
      );
      expect(
        DueDates.dueDateIn(
          'Your bill is due tomorrow.',
          received: received(11, 1),
        ),
        day(11, 2),
      );
    });

    test('no due date', () {
      for (final text in [
        'Your e-bill is ready. The outstanding amount is \$6.00.',
        'Thank you for your payment of \$32.99 on 3 Nov 2026.',
        'Your statement for October 2026 is ready.',
        '',
      ]) {
        expect(
          DueDates.dueDateIn(text, received: received(11, 3)),
          isNull,
          reason: text,
        );
      }
    });
  });

  group('trials', () {
    test('an end date the email gives', () {
      final cases = {
        'Your free trial ends on 12 Nov 2026.': day(11, 12),
        'Your trial will end on November 12, 2026. After that, S\$5.99/month.':
            day(11, 12),
        "You won't be charged until 12/11/2026.": day(11, 12),
        'Your first payment of S\$59.88 will be charged on 2026-11-12.': day(
          11,
          12,
        ),
      };
      for (final MapEntry(key: text, value: date) in cases.entries) {
        expect(
          DueDates.trialEndIn(text, received: received(11, 1)),
          date,
          reason: text,
        );
      }
    });

    test('the start date is not the end', () {
      expect(
        DueDates.trialEndIn(
          'Your free trial started on 1 Nov 2026 and ends on 15 Nov 2026.',
          received: received(11, 1),
        ),
        day(11, 15),
      );
      expect(
        DueDates.trialEndIn(
          'Your free trial started on 1 Nov 2026.',
          received: received(11, 1),
        ),
        isNull,
      );
    });

    test('ends in N days, tomorrow', () {
      expect(
        DueDates.trialEndIn(
          'Your pandapro free trial ends in 3 days.',
          received: received(11, 1),
        ),
        day(11, 4),
      );
      expect(
        DueDates.trialEndIn(
          'Heads up: your trial ends tomorrow.',
          received: received(11, 1),
        ),
        day(11, 2),
      );
    });

    test('the start plus its length', () {
      final cases = {
        'Enjoy your 14-day free trial of pandapro.': day(11, 15),
        'Your 7 day trial has started.': day(11, 8),
        'Get 1 month free, then S\$5.99/month.': day(12, 1),
        'Your first month free starts today.': day(12, 1),
        'Try 30 days for free.': day(12, 1),
      };
      for (final MapEntry(key: text, value: date) in cases.entries) {
        expect(
          DueDates.trialEndIn(text, received: received(11, 1)),
          date,
          reason: text,
        );
      }
      expect(
        DueDates.trialEndIn(
          'Your free trial has started.',
          received: received(11, 1),
        ),
        isNull,
      );
    });
  });
}
