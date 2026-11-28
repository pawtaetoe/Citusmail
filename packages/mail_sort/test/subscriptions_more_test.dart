// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Layouts of subscription, bill and renewal mail seen in real mailboxes,
// with invented companies, people, numbers and amounts.

import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

var _id = 0;

SubscriptionEmail mail(
  String company,
  String subject,
  DateTime at, {
  String text = '',
  String? name,
}) => SubscriptionEmail(
  messageId: MessageId(_id++),
  company: company,
  senderName: name,
  subject: subject,
  text: text,
  at: at,
);

DateTime day(int month, int d, [int year = 2026]) =>
    DateTime.utc(year, month, d);

List<SubscriptionRecord> charges(Subscription s) => [
  for (final r in s.records)
    if (r.event == SubscriptionEvent.charge) r,
];

void main() {
  group('a cancellation without a receipt', () {
    test('a membership cancelled: cancelled, and the day it ends', () {
      final s = SubscriptionFinder.find([
        mail(
          'examplestream.example',
          'Your ExampleStream Premium membership has been canceled',
          day(11, 20),
          name: 'ExampleStream',
          text:
              'Hi Sam, your ExampleStream Premium membership has been '
              'canceled. You will lose your ExampleStream Premium membership '
              'benefits on May 9, 2027. Come back any time.',
        ),
      ], now: day(11, 25)).single;
      expect(s.name, 'ExampleStream');
      expect(s.status, SubscriptionStatus.cancelled);
      expect(s.amount, isNull);
      expect(s.nextCharge, isNull);
      expect(s.endsOn, day(5, 9, 2027));
    });

    test('a subscription the user ended', () {
      final s = SubscriptionFinder.find([
        mail(
          'exampletool.example',
          'Your ExampleTool Subscription Has Ended',
          day(11, 2),
          name: 'Robin from ExampleTool',
          text:
              "Hi Kim, this confirms that you've ended your subscription to "
              'ExampleTool today. Tell us how we could do better.',
        ),
      ], now: day(11, 25)).single;
      expect(s.status, SubscriptionStatus.cancelled);
      expect(s.endsOn, isNull);
    });

    test('nor newsletters, free trials, orders or appointments', () {
      final found = SubscriptionFinder.find([
        mail(
          'news.example',
          'Your newsletter subscription has been cancelled',
          day(11, 2),
          text: 'You will no longer receive our weekly emails.',
        ),
        mail(
          'app.example',
          'Your free trial has been cancelled',
          day(11, 3),
          text: 'Your trial subscription has been cancelled.',
        ),
        mail(
          'food.example',
          'Your order has been cancelled',
          day(11, 4),
          text: 'Your order 1234 was cancelled. Join our membership!',
        ),
        mail(
          'clinic.example',
          'Your appointment has been cancelled',
          day(11, 5),
          text: 'Your appointment on 9 Nov was cancelled. Membership perks',
        ),
      ], now: day(11, 25));
      expect(found, isEmpty);
    });

    test('a cancellation after charges says when it ends', () {
      final s = SubscriptionFinder.find([
        for (final m in [8, 9, 10])
          mail(
            'notes.example',
            'Your ExampleNotes receipt',
            day(m, 22),
            text: 'Your subscription has been renewed. Total \$4.00',
          ),
        mail(
          'notes.example',
          'Your ExampleNotes subscription will be cancelled',
          day(10, 30),
          text:
              'Your ExampleNotes subscription will be cancelled on 22 Nov '
              '2026. No refunds will be issued.',
        ),
      ], now: day(11, 1)).single;
      expect(s.status, SubscriptionStatus.cancelled);
      expect(s.endsOn, day(11, 22));
    });
  });

  group('receipts and bills laid out otherwise', () {
    test('a payment service receipt whose period prints the year once', () {
      final s = SubscriptionFinder.find([
        mail(
          'stripe.com',
          'Your receipt from Example App #3141-5926',
          day(3, 3),
          name: 'Example App',
          text:
              'Receipt from Example App \$7.00 Paid March 3, 2026 '
              'Receipt #3141-5926 Mar 3 – Apr 3, 2026 Pro Qty 1 \$14.00 '
              'Subtotal \$14.00 First-month 50% off for Pro Plan (\$7.00 off) '
              '-\$7.00 Total \$7.00 Amount paid \$7.00',
        ),
      ], now: day(3, 10)).single;
      expect(s.company, 'Example App via stripe.com');
      expect(s.period, BillingPeriod.monthly);
      expect(s.amount, const Money(700, r'$'));
      expect(s.nextCharge, day(4, 3));
    });

    test('periods printed with one year', () {
      final cases = {
        'Mar 3 – Apr 3, 2026': BillingPeriod.monthly,
        'Billing period: 1 October - 31 October 2026': BillingPeriod.monthly,
        'Dec 3 – Jan 3, 2027': BillingPeriod.monthly,
        '5 Jan - 5 Apr 2026': BillingPeriod.quarterly,
      };
      for (final MapEntry(key: text, value: period) in cases.entries) {
        expect(SubscriptionFinder.statedPeriodIn(text), period, reason: text);
      }
    });

    test('a bill period whose last day is included', () {
      expect(
        SubscriptionFinder.statedPeriodIn(
          'Bill period 3 Mar 2026 - 1 Apr 2026',
        ),
        const BillingPeriod.days(30),
      );
    });

    test('a welcome that says what was paid today and when billing starts', () {
      final email = mail(
        'video.example',
        'Welcome to ExampleTube Premium for students',
        day(3, 6),
        text:
            'Hi Sam, your student membership is active. Your card will be '
            'charged monthly starting on Apr 6, 2026. Plan: Student, '
            'monthly. Billing starts: Apr 6, 2026 Price: SGD 4.50 Total '
            'today: SGD 4.50',
      );
      expect(SubscriptionFinder.eventOf(email), SubscriptionEvent.charge);
      final s = SubscriptionFinder.find([email], now: day(3, 10)).single;
      expect(s.cadence, Cadence.monthly);
      expect(s.amount, const Money(450, 'SGD'));
      expect(s.nextCharge, day(4, 6));
    });

    test('a mobile bill deducted from the card each month', () {
      SubscriptionEmail bill(int m, String month) => mail(
        'circlemobile.example',
        'Your ExampleCircle $month mobile bill',
        day(m, 2),
        name: 'ExampleCircle',
        text:
            'Hi Sam, your $month bill for line 80000000 is attached. We\'ve '
            'successfully deducted \$7.00 for this bill from your card, as '
            'we do each month.',
      );
      final failed = mail(
        'circlemobile.example',
        "Your payment didn't go through for your ExampleCircle August "
            'bill',
        day(9, 2),
        text: 'Please update your card.',
      );
      expect(
        SubscriptionFinder.eventOf(bill(7, 'June')),
        SubscriptionEvent.charge,
      );
      expect(SubscriptionFinder.eventOf(failed), SubscriptionEvent.notice);
      final s = SubscriptionFinder.find([
        bill(7, 'June'),
        bill(8, 'July'),
        bill(9, 'August'),
        failed,
      ], now: day(9, 10)).single;
      expect(s.cadence, Cadence.monthly);
      expect(s.amount, const Money(700, r'$'));
      expect(charges(s), hasLength(3));
    });

    test('a postpaid "latest bill is ready" with the total due', () {
      SubscriptionEmail bill(int m, String month) => mail(
        'telco.example',
        'Your latest ExampleTel bill for $month 2026 (account 10000001)',
        day(m, 28),
        text:
            'Hi Sam, your ExampleTel bill of 28 $month 2026 is ready. Total '
            'due: \$64.20. We will deduct the amount from your credit / '
            "debit card on 14 ${month == 'Jan' ? 'Feb' : 'Mar'} 2026.",
      );
      final emails = [bill(1, 'Jan'), bill(2, 'Feb')];
      final found = SubscriptionFinder.find(emails, now: day(3, 1));
      final s = found.single;
      expect(s.cadence, Cadence.monthly);
      expect(s.amount, const Money(6420, r'$'));
      final reminder = Reminders.find(
        emails,
        subscriptions: found,
        now: day(3, 1),
      ).single;
      expect(reminder.kind, ReminderKind.billDue);
      expect(reminder.date, day(3, 14));
      expect(reminder.amount, const Money(6420, r'$'));
    });

    test('a bill in credit: nothing paid, nothing due', () {
      const text =
          'Hi Sam, your ExampleTel bill of 26 Nov 2026 is ready. The total '
          'due for this bill is -\$12.34. Due date: 10 Dec 2026.';
      expect(SubscriptionFinder.amountIn(text), isNull);
      expect(SubscriptionFinder.owesNothing(text), isTrue);
      expect(SubscriptionFinder.owesNothing('Total due: \$12.34'), isFalse);
      // A dash between words and the price is no minus sign.
      expect(
        SubscriptionFinder.amountIn('Monthly charge – \$9.99'),
        const Money(999, r'$'),
      );
      // A discount on a receipt is not the total.
      expect(
        SubscriptionFinder.amountIn(
          'Pro \$20.00 Discount -\$5.00 Total \$15.00',
        ),
        const Money(1500, r'$'),
      );
      final emails = [
        mail(
          'telco.example',
          'Your latest bill for November 2026 is ready',
          day(11, 26),
          text: text,
        ),
      ];
      expect(
        Reminders.find(
          emails,
          subscriptions: SubscriptionFinder.find(emails, now: day(11, 28)),
          now: day(11, 28),
        ),
        isEmpty,
      );
    });
  });

  group('promotions', () {
    test('a bank\'s offer to pay a bill is no bill', () {
      final offer = mail(
        'bank.example',
        'Pay your electricity bill with ExampleBank and earn 5% cashback',
        day(10, 2),
        text: 'Pay your utility bills with your card. Up to \$30 back.',
      );
      expect(SubscriptionFinder.eventOf(offer), SubscriptionEvent.notice);
      expect(SubscriptionFinder.find([offer], now: day(10, 5)), isEmpty);
      // A bill that also offers something is still a bill.
      expect(
        SubscriptionFinder.eventOf(
          mail(
            'isp.example',
            'Your e-Bill is ready - save 10% with GIRO',
            day(10, 2),
          ),
        ),
        SubscriptionEvent.charge,
      );
    });
  });

  group('one brand, two domains', () {
    test('the bill from the biller, the payment from its payments arm', () {
      SubscriptionEmail notice(int m, String mon) => mail(
        'examplepower.example',
        'Your ExamplePower utilities bill for $mon is ready',
        day(m, 4),
        text:
            'Hello, your $mon utilities bill for 1 Example Walk is ready to '
            'view in the app.',
      );
      SubscriptionEmail paid(int m, String amount) => mail(
        'examplepowerpay.example',
        'Auto-debit: payment successful',
        day(m, 15),
        name: 'ExamplePower Pay',
        text:
            'Your utilities bill has been successfully paid by auto-debit. '
            'Amount \$$amount',
      );
      final s = SubscriptionFinder.find([
        notice(10, 'OCT'),
        paid(10, '101.23'),
        notice(11, 'NOV'),
        paid(11, '98.76'),
      ], now: day(11, 20)).single;
      expect(s.company, 'examplepower.example');
      expect(s.billers, {'examplepower.example', 'examplepowerpay.example'});
      expect(s.name, 'ExamplePower Pay');
      // The bills are notices of the payments that followed.
      expect(charges(s).map((r) => r.email.at), [day(11, 15), day(10, 15)]);
      expect(s.cadence, Cadence.monthly);
      expect(s.amount, const Money(9876, r'$'));
      expect(s.nextCharge, day(12, 15));
    });

    test('a bill and the payment of it ten days later are one charge', () {
      final s = SubscriptionFinder.find([
        for (final m in [9, 10])
          mail(
            'isp.example',
            'Your monthly invoice is ready',
            day(m, 1),
            text: 'Amount due: \$30.00',
          ),
        for (final m in [9, 10])
          mail(
            'isp.example',
            'Payment received',
            day(m, 11),
            text: 'Thank you. Amount paid: \$30.00',
          ),
      ], now: day(10, 20)).single;
      expect(charges(s).map((r) => r.email.at), [day(10, 11), day(9, 11)]);
      expect(s.nextCharge, day(11, 11));
    });

    test('unrelated domains stay apart', () {
      final found = SubscriptionFinder.find([
        for (final c in ['alpha.example', 'betapay.example'])
          for (final m in [9, 10])
            mail(c, 'Your subscription receipt', day(m, 3), text: '\$5.00'),
      ], now: day(10, 20));
      expect(found, hasLength(2));
    });
  });

  group('next charge', () {
    test('a renewal a day early: from the last charge, not the one before', () {
      SubscriptionEmail renewed(DateTime at, String period) => mail(
        'mobile.example',
        'Your ExampleMobile plan has renewed',
        at,
        text:
            '| Bill period: $period | Total | \$18.00 | Your plan renews '
            'every 31 days and is automatically charged to your card.',
      );
      final s = SubscriptionFinder.find([
        renewed(day(3, 1), '1 Mar 2026 - 31 Mar 2026'),
        renewed(day(3, 30), '30 Mar 2026 - 29 Apr 2026'),
      ], now: day(3, 31)).single;
      expect(s.period, const BillingPeriod.days(31));
      expect(s.nextCharge, day(4, 30));
    });

    test('a month-long bill period on charges 30 days apart: 30 days', () {
      const months = ['Jun', 'Jul', 'Aug', 'Sep', 'Oct'];
      final dates = [day(6, 12), day(7, 12), day(8, 11), day(9, 10)];
      final s = SubscriptionFinder.find([
        for (final (i, d) in dates.indexed)
          mail(
            'mobile.example',
            'Your ExampleMobile plan has renewed',
            d,
            text:
                'Your ExampleMobile plan has renewed. Invoice. Bill period '
                '${d.day} ${months[i]} 2026 - ${d.day - 1} ${months[i + 1]} '
                '2026 Charge for line 9000 0000 \$23.60',
          ),
      ], now: day(9, 20)).single;
      expect(s.period, const BillingPeriod.days(30));
      expect(s.nextCharge, day(10, 10));
    });

    test('the renewal date in the notice sent with the receipt', () {
      final s = SubscriptionFinder.find([
        mail(
          'telco.example',
          'ExamplePlan Renewal: Your ExamplePlan 80000000 is renewed',
          DateTime.utc(2026, 3, 1, 8),
          text:
              'Your ExamplePlan for line 80000000 is renewed. Your next '
              'renewal date is 03-04-2026.',
        ),
        mail(
          'telco.example',
          'Mobile Service Receipt Notification',
          DateTime.utc(2026, 3, 1, 10),
          text: 'Service period: 4 Mar 2026 - 3 Apr 2026 Amount: \$25.00',
        ),
      ], now: day(3, 5)).single;
      expect(charges(s), hasLength(1));
      expect(s.nextCharge, day(4, 3));
    });

    test('a price change since the last charge is the price', () {
      final s = SubscriptionFinder.find([
        for (final m in [8, 9, 10])
          mail(
            'music.example',
            'Your ExampleMusic receipt',
            day(m, 18),
            text: 'Your subscription has been renewed. Total \$9.49',
          ),
        mail(
          'music.example',
          'Upcoming price increase for your subscription',
          day(10, 25),
          text:
              'We are increasing the price of your subscription from '
              '\$9.49/month to \$10.99/month starting on 18 November 2026.',
        ),
      ], now: day(10, 28)).single;
      expect(s.amount, const Money(1099, r'$'));
    });

    test('what a notice or a promotion names is not a price paid', () {
      final s = SubscriptionFinder.find([
        for (final m in [8, 9, 10])
          mail(
            'notes.example',
            'Your ExampleNotes receipt',
            day(m, 7),
            text: 'Subscription renewed. Total \$5.00',
          ),
        mail(
          'notes.example',
          'Your ExampleNotes subscription will renew soon',
          day(10, 30),
          text:
              'Your subscription will automatically renew on November 7, '
              '2026. Refer a friend for a \$40 voucher.',
        ),
      ], now: day(11, 1)).single;
      final notice = s.records.firstWhere(
        (r) => r.event == SubscriptionEvent.notice,
      );
      expect(notice.amount, isNull);
      expect(s.amount, const Money(500, r'$'));
    });
  });

  group('a paid plan whose subject names no subscription', () {
    test('a trial turned paid: found by its preview, renews when it ends', () {
      const subject = 'Welcome aboard, plusplan member!';
      const text =
          'Hey Sam, your free trial has ended, and you\'re now a paid '
          'plusplan member! Your plan ends 2026/09/14, then renews.';
      bool picked(List<String> words, String s) =>
          words.any((w) => s.toLowerCase().contains(w));
      expect(picked(SubscriptionFinder.subjectWords, subject), isFalse);
      expect(picked(SubscriptionFinder.previewWords, text), isTrue);
      final s = SubscriptionFinder.find([
        mail(
          'fooddelivery.example',
          subject,
          day(8, 11),
          name: 'ExampleFood',
          text: text,
        ),
      ], now: day(8, 20)).single;
      expect(s.status, SubscriptionStatus.active);
      expect(s.nextCharge, day(9, 14));
      expect(s.cadence, Cadence.monthly);
      // A plan that ends because it was cancelled does not renew then.
      expect(
        SubscriptionFinder.renewalDateIn(
          'Your membership has been cancelled. Your plan ends 2026/09/14. '
          'You can renew it any time.',
          day(8, 11),
        ),
        isNull,
      );
    });
  });

  group('an app store', () {
    test('each app it charges for is its own subscription', () {
      SubscriptionEmail play(DateTime at, String subject, String text) =>
          mail('google.com', subject, at, name: 'Google Play', text: text);
      final found = SubscriptionFinder.find([
        for (final m in [8, 9, 10])
          play(
            day(m, 18),
            'Your Google Play Order Receipt from $m 2026',
            'Your subscription from ExampleCorp on Google Play was renewed. '
                'ExampleVideo Premium \$9.49/month Total: \$9.49',
          ),
        play(
          day(10, 22),
          'Upcoming price increase for your ExampleVideo subscription',
          'Google Play ExampleCorp LLC is increasing the price of your '
              "subscription 'ExampleVideo Premium' from \$9.49/month to "
              '\$10.99/month starting on 18 November 2026.',
        ),
        play(
          day(7, 14),
          'Your Google Play Order Receipt from 14 Jul 2026',
          'Thanks for your purchase from Example Games Inc. on Google Play. '
              'Coin bundle \$4.99',
        ),
        play(
          day(7, 22),
          'Your Google Play Order Receipt from 22 Jul 2026',
          'Thanks for your subscription purchase from Example Games Inc. on '
              'Google Play. Your subscription renews on 22 Aug 2026. '
              'Total: \$2.99/month',
        ),
        play(
          day(7, 23),
          'Your Example Puzzle subscription will be cancelled',
          'Your Example Puzzle subscription from Example Games Inc. on '
              'Google Play ends: it will be cancelled on 22 Aug 2026.',
        ),
      ], now: day(10, 28));
      expect(found.map((s) => s.company), [
        'ExampleCorp via Google Play',
        'Example Games via Google Play',
      ]);
      final video = found.first;
      expect(video.name, 'ExampleCorp');
      expect(video.cadence, Cadence.monthly);
      expect(video.amount, const Money(1099, r'$'));
      final game = found.last;
      expect(game.status, SubscriptionStatus.cancelled);
      expect(game.endsOn, day(8, 22));
      // The one-off purchase is not the subscription's.
      expect(charges(game), hasLength(1));
    });
  });
}
