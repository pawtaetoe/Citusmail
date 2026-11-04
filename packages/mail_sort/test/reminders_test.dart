// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_sort/mail_sort.dart';
import 'package:test/test.dart';

var _id = 0;

/// Received at noon where the tests run, so the calendar day is clear.
DateTime at(int month, int d, [int year = 2026]) =>
    DateTime(year, month, d, 12);

DateTime day(int month, int d, [int year = 2026]) =>
    DateTime.utc(year, month, d);

SubscriptionEmail mail(
  String company,
  String subject,
  DateTime when, {
  String text = '',
  String? name,
}) => SubscriptionEmail(
  messageId: _id++,
  company: company,
  senderName: name,
  subject: subject,
  text: text,
  at: when,
);

const _myRepublic = '''
Your e-bill is ready!
Hi Tan,
The monthly bill for your MyRepublic mobile is now ready! The outstanding
amount for your account C4082197 is: \$6.00
View bill on MyAccount
To avoid any service interruption, please pay your bill within 7 days of
receiving this email.
PayNow QR / Credit card / GIRO
''';

const _utility = '''
SP Group
Your bill for October 2026 is ready.
Bill date: 03 Nov 2026
Billing period: 01 Oct 2026 - 31 Oct 2026
Previous balance: S\$0.00
Current charges: S\$118.40
Total amount due: S\$118.40
Due date: 20 Nov 2026
Pay via SP app, PayNow or GIRO.
''';

const _pandaStarted = '''
Welcome to pandapro!
Your 14-day free trial starts today. Enjoy free delivery on all orders
and exclusive deals. After your trial, pandapro is S\$5.99/month unless
you cancel.
''';

const _pandaEnding = '''
Your pandapro free trial ends on 12 Nov 2026.
Keep saving with pandapro: then S\$59.88/year, billed annually. You can
cancel anytime in the app.
''';

List<Reminder> find(
  List<SubscriptionEmail> emails, {
  required DateTime now,
  bool monthly = false,
}) => Reminders.find(
  emails,
  subscriptions: SubscriptionFinder.find(emails, now: now),
  now: now,
  monthlyRenewals: monthly,
);

void main() {
  group('bills', () {
    test('MyRepublic: within 7 days of receiving the email', () {
      final bill = mail(
        'myrepublic.net',
        'Your MyRepublic e-Bill is ready!',
        at(10, 31),
        name: 'MyRepublic',
        text: _myRepublic,
      );
      final r = find([bill], now: at(11, 4)).single;
      expect(r.kind, ReminderKind.billDue);
      expect(r.name, 'MyRepublic');
      expect(r.date, day(11, 7));
      expect(r.amount, const Money(600, r'$'));
      expect(r.messageId, bill.messageId);
      expect(r.daysFrom(at(11, 4)), 3);
      expect(r.key, 'billDue:myrepublic.net:2026-11-07');
    });

    test('a utility bill with a due date, not the bill date', () {
      final r = find([
        mail(
          'spgroup.com.sg',
          'Your SP Group bill is ready',
          at(11, 3),
          name: 'SP Group',
          text: _utility,
        ),
      ], now: at(11, 8)).single;
      expect(r.date, day(11, 20));
      expect(r.amount, const Money(11840, 'SGD'));
    });

    test('too far ahead, or past by more than a few days', () {
      final bill = mail(
        'spgroup.com.sg',
        'Your SP Group bill is ready',
        at(11, 3),
        text: _utility,
      );
      // Due 20 Nov: shown from 6 Nov, until 23 Nov.
      expect(find([bill], now: at(11, 5)), isEmpty);
      expect(find([bill], now: at(11, 6)), hasLength(1));
      expect(find([bill], now: at(11, 23)).single.daysFrom(at(11, 23)), -3);
      expect(find([bill], now: at(11, 24)), isEmpty);
    });

    test('a payment after the bill covers it', () {
      final bill = mail(
        'myrepublic.net',
        'Your MyRepublic e-Bill is ready!',
        at(10, 31),
        name: 'MyRepublic',
        text: _myRepublic,
      );
      // From another of its domains, the same name.
      final paid = mail(
        'myrepublic.com.sg',
        'Payment Received - Thank You',
        at(11, 2),
        name: 'MyRepublic',
        text: 'We have received your payment of \$6.00.',
      );
      expect(find([bill, paid], now: at(11, 4)), isEmpty);
      // A payment before the bill doesn't.
      final before = mail(
        'myrepublic.net',
        'Successful payment',
        at(10, 2),
        text: 'Thank you for your payment of \$32.99.',
      );
      expect(find([bill, before], now: at(11, 4)), hasLength(1));
      // Nor a failed one.
      final failed = mail(
        'myrepublic.net',
        'Payment unsuccessful',
        at(11, 2),
        text: 'Your payment of \$6.00 was declined.',
      );
      expect(find([bill, failed], now: at(11, 4)), hasLength(1));
    });

    test('only the newest bill of a company', () {
      final old = mail(
        'spgroup.com.sg',
        'Your SP Group bill is ready',
        at(10, 20),
        text: 'Total amount due: S\$99.00\nDue date: 9 Nov 2026',
      );
      final newer = mail(
        'spgroup.com.sg',
        'Your SP Group bill is ready',
        at(11, 3),
        text: _utility,
      );
      expect(find([old, newer], now: at(11, 8)).map((r) => r.date), [
        day(11, 20),
      ]);
    });

    test('not bills', () {
      final now = at(11, 4);
      final emails = [
        // Bank and CDP statements, even with a "payment due date".
        mail(
          'dbs.com',
          'Your DBS Credit Card e-Statement is ready',
          at(11, 1),
          text: 'Minimum payment S\$50.00. Payment due date: 20 Nov 2026',
        ),
        mail(
          'sgx.com',
          'Your CDP account statement is ready for viewing',
          at(11, 1),
          text: 'Your latest account statement is available online.',
        ),
        // A receipt.
        mail(
          'singtel.com',
          'Payment received for your bill',
          at(11, 2),
          text: 'We received S\$45.00 on 2 Nov 2026. Due date: 15 Nov 2026',
        ),
        // A paid invoice.
        mail(
          'stripe.com',
          'Your invoice from Acme',
          at(11, 2),
          text: 'Amount paid \$20.00. Date due November 10, 2026.',
        ),
        // A bill that says nothing of when it's due.
        mail(
          'm1.com.sg',
          'Your M1 bill is ready',
          at(11, 1),
          text: 'Your bill of S\$42.00 is ready to view.',
        ),
        // A discussion of a bill.
        mail(
          'gmail.com',
          'Re: electricity bill',
          at(11, 2),
          text: 'Due date: 15 Nov 2026, can you pay?',
        ),
        // Past due long ago.
        mail(
          'starhub.com',
          'Your StarHub bill',
          at(9, 1),
          text: 'Amount due S\$60.00. Please pay by 21 Sep 2026.',
        ),
      ];
      expect(find(emails, now: now), isEmpty);
    });
  });

  group('free trials', () {
    test('pandapro: started, then ending, with the price after', () {
      final started = mail(
        'foodpanda.sg',
        'Your pandapro free trial has started.',
        at(10, 29),
        name: 'foodpanda',
        text: _pandaStarted,
      );
      // From the start: 14 days.
      var r = find([started], now: at(11, 4)).single;
      expect(r.kind, ReminderKind.trialEnds);
      expect(r.name, 'pandapro');
      expect(r.date, day(11, 12));
      expect(r.amount, const Money(599, 'SGD'));
      expect(r.cadence, Cadence.monthly);

      final ending = mail(
        'foodpanda.sg',
        'Your free trial is ending.',
        at(11, 9),
        name: 'foodpanda',
        text: _pandaEnding,
      );
      r = find([started, ending], now: at(11, 10)).single;
      expect(r.date, day(11, 12));
      expect(r.amount, const Money(5988, 'SGD'));
      expect(r.cadence, Cadence.yearly);
      expect(r.messageId, ending.messageId);
      expect(r.name, 'pandapro', reason: 'from the earlier subject');
      // Still not a subscription.
      expect(
        SubscriptionFinder.find([started, ending], now: at(11, 10)),
        isEmpty,
      );
    });

    test('a charge ends the trial', () {
      final started = mail(
        'foodpanda.sg',
        'Your pandapro free trial has started.',
        at(10, 29),
        text: _pandaStarted,
      );
      final charged = mail(
        'foodpanda.sg',
        'Your pandapro subscription receipt',
        at(11, 3),
        text: 'pandapro monthly S\$5.99',
      );
      expect(find([started, charged], now: at(11, 4)), isEmpty);
      // A food order is not that charge.
      final order = mail(
        'foodpanda.sg',
        'Your order has been placed',
        at(11, 3),
        text: 'Order total S\$23.40',
      );
      expect(find([started, order], now: at(11, 4)), hasLength(1));
    });

    test('cancelled, ended, or no end known', () {
      final started = mail(
        'foodpanda.sg',
        'Your pandapro free trial has started.',
        at(10, 29),
        text: _pandaStarted,
      );
      final cancelled = mail(
        'foodpanda.sg',
        'Your pandapro trial was cancelled',
        at(11, 1),
      );
      expect(find([started, cancelled], now: at(11, 4)), isEmpty);
      expect(find([started], now: at(11, 13)), isEmpty, reason: 'ended');
      expect(
        find([
          mail('x.example', 'Your free trial has started', at(11, 1)),
        ], now: at(11, 4)),
        isEmpty,
      );
    });

    test('the Grab sample: price a year after the trial', () {
      final r = find([
        mail(
          'grab.com',
          'You\'re on the free trial 🎉',
          at(11, 1),
          name: 'Grab',
          text:
              'GrabUnlimited: 1 month free. S\$59.88 a year after your free '
              'trial.',
        ),
      ], now: at(11, 20)).single;
      expect(r.name, 'Grab');
      expect(r.date, day(12, 1));
      expect(r.amount, const Money(5988, 'SGD'));
      expect(r.cadence, Cadence.yearly);
    });
  });

  group('renewals', () {
    List<SubscriptionEmail> netflix() => [
      mail(
        'netflix.com',
        'Your Netflix membership has been renewed',
        at(11, 9, 2025),
        name: 'Netflix',
        text: 'Annual plan. Amount charged S\$203.88. Your plan renews yearly.',
      ),
    ];

    List<SubscriptionEmail> spotify() => [
      for (final m in [8, 9, 10])
        mail(
          'spotify.com',
          'Your Spotify Premium receipt',
          at(m, 7),
          name: 'Spotify',
          text: 'Premium Individual. Total S\$11.98 per month.',
        ),
    ];

    test('a yearly renewal within a week', () {
      final r = find(netflix(), now: at(11, 4)).single;
      expect(r.kind, ReminderKind.renewal);
      expect(r.name, 'Netflix');
      expect(r.amount, const Money(20388, 'SGD'));
      expect(r.cadence, Cadence.yearly);
      expect(r.daysFrom(at(11, 4)), inInclusiveRange(4, 6));
      // A month before: not yet.
      expect(find(netflix(), now: at(10, 4)), isEmpty);
    });

    test('monthly renewals only when asked', () {
      final now = at(11, 4);
      expect(find(spotify(), now: now), isEmpty);
      final r = find(spotify(), now: now, monthly: true).single;
      expect(r.name, 'Spotify');
      expect(r.amount, const Money(1198, 'SGD'));
    });

    test('not for a hidden one, nor a varying bill', () {
      final emails = netflix();
      expect(
        Reminders.find(
          emails,
          subscriptions: SubscriptionFinder.find(emails, now: at(11, 4)),
          now: at(11, 4),
          hidden: {'netflix.com'},
        ),
        isEmpty,
      );
      final sp = [
        for (final (m, amount) in [
          (7, 90.44),
          (8, 126.16),
          (9, 73.17),
          (10, 132.01),
        ])
          mail(
            'spdigital.sg',
            '<Recurring Payment> Successful Payment',
            at(m, 5),
            text: 'Amount paid \$$amount',
          ),
      ];
      expect(find(sp, now: at(11, 2), monthly: true), isEmpty);
    });
  });

  test('soonest first, bills and trials and renewals together', () {
    final emails = [
      mail(
        'spgroup.com.sg',
        'Your SP Group bill is ready',
        at(11, 3),
        text: _utility,
      ),
      mail(
        'myrepublic.net',
        'Your MyRepublic e-Bill is ready!',
        at(10, 31),
        name: 'MyRepublic',
        text: _myRepublic,
      ),
      mail(
        'foodpanda.sg',
        'Your pandapro free trial has started.',
        at(10, 29),
        text: _pandaStarted,
      ),
      mail(
        'netflix.com',
        'Your Netflix membership has been renewed',
        at(11, 10, 2025),
        name: 'Netflix',
        text: 'Annual plan. Amount charged S\$203.88.',
      ),
    ];
    expect(find(emails, now: at(11, 6)).map((r) => r.kind), [
      ReminderKind.billDue, // 7 Nov
      ReminderKind.renewal, // ~10 Nov
      ReminderKind.trialEnds, // 12 Nov
      ReminderKind.billDue, // 20 Nov
    ]);
  });
}
