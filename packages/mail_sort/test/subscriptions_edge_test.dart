// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Plan changes announced without a receipt, one company's several lines
// or accounts, and sister domains of one brand; with invented companies,
// numbers, amounts and dates.

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
  group('a plan change without a receipt', () {
    test('an introductory price that ends: the new price from that day', () {
      final notice = mail(
        'streamly.example',
        'Your introductory price is ending',
        day(12, 10),
        name: 'Streamly',
        text:
            'Hi Robin, your introductory price ends. From 1 Jan your plan is '
            '\$12.99/month unless you cancel.',
      );
      expect(SubscriptionFinder.eventOf(notice), SubscriptionEvent.notice);
      final s = SubscriptionFinder.find([notice], now: day(12, 12)).single;
      expect(s.company, 'streamly.example');
      expect(s.name, 'Streamly');
      expect(s.status, SubscriptionStatus.active);
      expect(s.amount, const Money(1299, r'$'));
      expect(s.cadence, Cadence.monthly);
      expect(s.nextCharge, day(1, 1, 2027));
      expect(s.priceChange?.to, const Money(1299, r'$'));
      expect(s.priceChange?.on, day(1, 1, 2027));
      expect(charges(s), isEmpty);
      // Once the day has gone by: the month after.
      expect(
        SubscriptionFinder.find([
          notice,
        ], now: day(1, 9, 2027)).single.nextCharge,
        day(2, 1, 2027),
      );
    });

    test('a plan that will renew, and one whose price will increase', () {
      final found = SubscriptionFinder.find([
        mail(
          'cloudbox.example',
          'Your CloudBox plan renews soon',
          day(1, 10, 2027),
          name: 'CloudBox',
          text:
              'Your CloudBox Plus plan will automatically renew on 3 March '
              '2027 for \$59.88 per year.',
        ),
        mail(
          'lingo.example',
          'An update to your membership',
          day(12, 1),
          name: 'Lingo',
          text:
              'Your membership will increase to €8.99 per month from 15 '
              'January 2027.',
        ),
      ], now: day(1, 20, 2027));
      final box = found.firstWhere((s) => s.company == 'cloudbox.example');
      expect(box.amount, const Money(5988, r'$'));
      expect(box.cadence, Cadence.yearly);
      expect(box.nextCharge, day(3, 3, 2027));
      // A renewal is no price change.
      expect(box.priceChange, isNull);
      final lingo = found.firstWhere((s) => s.company == 'lingo.example');
      expect(lingo.amount, const Money(899, 'EUR'));
      expect(lingo.cadence, Cadence.monthly);
      expect(lingo.priceChange?.on, day(1, 15, 2027));
      // 15 Jan has gone by: a month later.
      expect(lingo.nextCharge, day(2, 15, 2027));
    });

    test('promotions with a price and a date are no subscription', () {
      final offers = [
        (
          'Subscribe to Streamly Premium',
          'Subscribe now: Premium for \$12.99/month from 1 Jan.',
        ),
        (
          'Try Premium',
          'Try Premium today. From 1 Jan your plan is \$12.99/month unless '
              'you cancel.',
        ),
        (
          'Your Premium awaits',
          'Start your free trial today. Your plan will automatically renew '
              'at \$12.99/month on 1 Jan unless you cancel.',
        ),
        (
          'Last chance',
          'Sign up before 1 Jan and your plan will be \$12.99/month.',
        ),
        (
          'Half price for you',
          '50% off: your plan will be \$6.49/month until 1 Jan, unless you '
              'cancel.',
        ),
        (
          'Our yearly plan',
          'Save with the yearly plan: it will renew at \$99.00/year on 1 Jan.',
        ),
        (
          'Holiday deal',
          'A deal for the holidays: your plan will be \$4.99/month from 1 Jan.',
        ),
        (
          'The December newsletter',
          'Events from 1 Jan: tickets \$12.99. Read more in our newsletter.',
        ),
      ];
      for (final (subject, text) in offers) {
        final email = mail(
          'streamly.example',
          subject,
          day(12, 10),
          name: 'Streamly',
          text: text,
        );
        expect(SubscriptionFinder.planChangeOf(email), isNull, reason: text);
        expect(
          SubscriptionFinder.find([email], now: day(12, 12)),
          isEmpty,
          reason: text,
        );
      }
    });

    test('wording without an amount or a date is no subscription', () {
      final found = SubscriptionFinder.find([
        mail(
          'streamly.example',
          'Your plan',
          day(12, 10),
          text: 'Your plan will automatically renew unless you cancel.',
        ),
        mail(
          'cloudbox.example',
          'Your plan',
          day(12, 10),
          text: 'Your plan will automatically renew at \$59.88/year.',
        ),
        mail(
          'lingo.example',
          'Your plan',
          day(12, 10),
          text: 'Your plan will automatically renew on 3 Jan 2027.',
        ),
      ], now: day(12, 12));
      expect(found, isEmpty);
    });

    test('a notice long gone by: probably ended', () {
      final s = SubscriptionFinder.find([
        mail(
          'streamly.example',
          'Your plan is changing',
          day(1, 10),
          text:
              'Your plan will change to \$12.99/month from 1 Feb 2026 unless '
              'you cancel.',
        ),
      ], now: day(11, 1)).single;
      expect(s.status, SubscriptionStatus.lapsed);
      expect(s.nextCharge, isNull);
    });

    test('with receipts: the announced price, and when it applies', () {
      final s = SubscriptionFinder.find([
        for (final m in [9, 10, 11])
          mail(
            'streamly.example',
            'Your Streamly receipt',
            day(m, 5),
            text: 'Subscription renewed. Total \$9.99',
          ),
        mail(
          'streamly.example',
          'Your price is changing',
          day(11, 20),
          text:
              'From 5 Jan your plan will change to \$11.99/month. Nothing '
              'else changes.',
        ),
      ], now: day(11, 25)).single;
      expect(s.amount, const Money(1199, r'$'));
      expect(s.priceChange?.to, const Money(1199, r'$'));
      expect(s.priceChange?.on, day(1, 5, 2027));
      // The next charge is still the plan's own.
      expect(s.nextCharge, day(12, 5));
    });
  });

  group('one company, several lines or accounts', () {
    test('the line or account an email names', () {
      final cases = {
        'Your mobile number ending 4821 has renewed': '4821',
        'Number: ****4821': '4821',
        'Account no. …1234 is ready': '1234',
        'Account no. ...1234 is ready': '1234',
        'for your account ending 1234': '1234',
        'Service number: 9123 4821': '4821',
        'Charge for line 9xxx 4821 \$23.60': '4821',
        'Your latest bill, Account No. 50217731 is ready': '7731',
        'Billing account number: ****7731': '7731',
        'Check your bill history for mobile number 9123 4821 anytime': '4821',
        'Pay bill for 50217731 \$40.00': '7731',
      };
      for (final MapEntry(key: text, value: line) in cases.entries) {
        expect(
          SubscriptionFinder.lineOf(
            mail('telco.example', '', day(1, 1), text: text),
          ),
          line,
          reason: text,
        );
      }
      for (final text in [
        'Paid with card ending 4821',
        'Card number: ****4821',
        'Invoice number 12345678',
        'Bill no. 260228004110120',
        'Call our service line 1800 555 0199',
        'GST Reg. no: MR12345678',
        'Your bill for November 2026 is ready',
      ]) {
        expect(
          SubscriptionFinder.lineOf(
            mail('telco.example', '', day(1, 1), text: text),
          ),
          isNull,
          reason: text,
        );
      }
      expect(
        SubscriptionFinder.billerOfKey('telco.example#4821'),
        'telco.example',
      );
      expect(SubscriptionFinder.lineOfKey('telco.example#4821'), '4821');
      expect(SubscriptionFinder.billerOfKey('telco.example'), 'telco.example');
      expect(SubscriptionFinder.lineOfKey('Acme #1 via stripe.com'), isNull);
    });

    test('a postpaid account and a prepaid line: two subscriptions', () {
      final found = SubscriptionFinder.find([
        for (final (m, amount) in [(9, '48.20'), (10, '51.75'), (11, '46.10')])
          mail(
            'telco.example',
            'Your ExampleTel bill is ready',
            day(m, 3),
            name: 'ExampleTel',
            text:
                'Your bill for account no. …7731 is ready. Total due: '
                '\$$amount',
          ),
        for (final m in [9, 10, 11])
          mail(
            'telco.example',
            'Your ExampleTel Prepaid plan has renewed',
            day(m, 20),
            name: 'ExampleTel Prepaid',
            text:
                'Your plan for mobile number ending 4821 has renewed. Total '
                '\$15.00',
          ),
      ], now: day(11, 25));
      expect(found.map((s) => s.company).toSet(), {
        'telco.example#7731',
        'telco.example#4821',
      });
      final postpaid = found.firstWhere((s) => s.line == '7731');
      expect(postpaid.name, 'ExampleTel ·7731');
      expect(postpaid.biller, 'telco.example');
      expect(postpaid.variable, isTrue);
      expect(charges(postpaid), hasLength(3));
      final prepaid = found.firstWhere((s) => s.line == '4821');
      expect(prepaid.name, 'ExampleTel Prepaid ·4821');
      expect(prepaid.amount, const Money(1500, r'$'));
      expect(prepaid.cadence, Cadence.monthly);
      expect(prepaid.nextCharge, day(12, 20));
    });

    test('mail naming no line joins the line of its own sender name', () {
      final found = SubscriptionFinder.find([
        for (final (m, total) in [
          (9, '\$38.40'),
          (10, '\$41.05'),
          (11, '-\$6.20'),
        ])
          mail(
            'telco.example',
            'ExampleTel. Your latest bill, Account No. 50217731 is ready',
            day(m, 26),
            name: 'ExampleTel',
            text: 'The total due for this bill is $total.',
          ),
        mail(
          'telco.example',
          'Payment received for your latest bill',
          day(10, 30),
          name: 'ExampleTel',
          text: 'Thank you. Amount paid: \$41.05',
        ),
        // Another brand of the company, on the same domain, naming no
        // line: its own subscription.
        for (final m in [9, 10, 11])
          mail(
            'telco.example',
            'Your Zappy plan has renewed',
            day(m, 28),
            name: 'Zappy by ExampleTel',
            text:
                'Your Zappy plan has renewed. Plan \$18.00 Total \$18.00. '
                'Your plan renews every month.',
          ),
      ], now: day(11, 30));
      expect(found.map((s) => s.company).toSet(), {
        'telco.example#7731',
        'telco.example',
      });
      final bills = found.firstWhere((s) => s.line == '7731');
      expect(bills.name, 'ExampleTel ·7731');
      // The payment is the bill's line's.
      expect(
        bills.records.map((r) => r.email.subject),
        contains('Payment received for your latest bill'),
      );
      // A bill in credit is no price.
      expect(bills.amount?.minor, isNot(620));
      expect(bills.amount?.minor, anyOf(3840, 4105, (3840 + 4105) ~/ 2));
      final zappy = found.firstWhere((s) => s.company == 'telco.example');
      expect(zappy.name, 'Zappy by ExampleTel');
      expect(zappy.amount, const Money(1800, r'$'));
      expect(zappy.cadence, Cadence.monthly);
    });

    test('one line, and the rest of its mail with it: as before', () {
      final s = SubscriptionFinder.find([
        for (final m in [9, 10, 11])
          mail(
            'telco.example',
            'Your ExampleTel mobile bill is ready',
            day(m, 3),
            name: 'ExampleTel',
            text: 'Your bill for account no. …7731. Total due: \$30.00',
          ),
        mail(
          'telco.example',
          'Payment received',
          day(10, 10),
          name: 'ExampleTel',
          text: 'Amount paid: \$30.00',
        ),
      ], now: day(11, 20)).single;
      expect(s.company, 'telco.example');
      expect(s.line, isNull);
      expect(s.name, 'ExampleTel');
    });

    test('cards and sender names alone do not split', () {
      final found = SubscriptionFinder.find([
        for (final (m, card, name) in [
          (9, '1111', 'ExampleTel'),
          (10, '2222', 'ExampleTel Billing'),
          (11, '1111', 'ExampleTel Care'),
        ])
          mail(
            'telco.example',
            'Your monthly invoice',
            day(m, 3),
            name: name,
            text:
                'Invoice number 1234567$m. Paid with card ending $card. '
                'Total \$30.00',
          ),
      ], now: day(11, 20));
      expect(found.single.company, 'telco.example');
    });

    test('each line\'s bill is its own reminder; hidden ones stay hidden', () {
      final emails = [
        for (final (line, amount, m) in [
          ('7731', '40.00', 10),
          ('4821', '25.00', 10),
          ('7731', '42.00', 11),
          ('4821', '25.00', 11),
        ])
          mail(
            'telco.example',
            'Your ExampleTel mobile bill is ready',
            day(m, 20),
            name: 'ExampleTel',
            text:
                'Your bill for account no. …$line is ready. Amount due: '
                '\$$amount. Please pay by ${m == 11 ? '2 Dec 2026' : '2 Nov 2026'}.',
          ),
      ];
      final found = SubscriptionFinder.find(emails, now: day(11, 25));
      expect(found.map((s) => s.company).toSet(), {
        'telco.example#7731',
        'telco.example#4821',
      });
      final reminders = Reminders.find(
        emails,
        subscriptions: found,
        now: day(11, 25),
      );
      expect(reminders.map((r) => (r.kind, r.company, r.amount)).toSet(), {
        (ReminderKind.billDue, 'telco.example#7731', const Money(4200, r'$')),
        (ReminderKind.billDue, 'telco.example#4821', const Money(2500, r'$')),
      });
      expect(reminders.map((r) => r.name).toSet(), {
        'ExampleTel ·7731',
        'ExampleTel ·4821',
      });
    });

    test('a line hidden by its company: no renewal reminder', () {
      final emails = [
        for (final (line, m) in [
          ('7731', 9),
          ('4821', 9),
          ('7731', 10),
          ('4821', 10),
        ])
          mail(
            'telco.example',
            'Your ExampleTel plan has renewed',
            day(m, 28),
            name: 'ExampleTel',
            text:
                'Your plan for mobile number ending $line has renewed. Total '
                '\$${line == '7731' ? '120.00' : '60.00'}. Your plan renews '
                'every 3 months.',
          ),
      ];
      final found = SubscriptionFinder.find(emails, now: day(12, 25));
      expect(found, hasLength(2));
      final shown = Reminders.find(
        emails,
        subscriptions: found,
        now: day(12, 25),
      );
      expect(shown.map((r) => r.company).toSet(), {
        'telco.example#7731',
        'telco.example#4821',
      });
      expect(
        Reminders.find(
          emails,
          subscriptions: found,
          now: day(12, 25),
          hidden: {'telco.example'},
        ),
        isEmpty,
      );
    });
  });

  group('sister domains', () {
    test('two brands alike in name, unrelated, stay apart', () {
      final found = SubscriptionFinder.find([
        for (final m in [9, 10])
          mail(
            'brandpay.example',
            'Your BrandPay wallet subscription receipt',
            day(m, 3),
            name: 'BrandPay Wallet',
            text: 'Thanks for using BrandPay. Monthly fee \$4.00 paid.',
          ),
        for (final m in [9, 10])
          mail(
            'brand.example2',
            'Your Brand Studio membership receipt',
            day(m, 12),
            name: 'Brand Studio',
            text: 'Brand Studio membership renewed. Total \$25.00',
          ),
      ], now: day(10, 20));
      expect(found.map((s) => s.company).toSet(), {
        'brandpay.example',
        'brand.example2',
      });
      expect(found.every((s) => s.billers.isEmpty), isTrue);
    });

    test('the same sender name on both domains: one company', () {
      final s = SubscriptionFinder.find([
        mail(
          'examplegym.example',
          'Your membership invoice is ready',
          day(10, 1),
          name: 'ExampleGym',
          text: 'Invoice for October. Amount due: \$45.00',
        ),
        mail(
          'examplegympay.example',
          'Payment successful',
          day(10, 5),
          name: 'ExampleGym',
          text: 'Paid by direct debit. Amount \$45.00',
        ),
      ], now: day(10, 20)).single;
      expect(s.billers, {'examplegym.example', 'examplegympay.example'});
    });
  });
}
