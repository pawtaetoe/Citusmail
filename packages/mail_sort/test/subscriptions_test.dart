// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_sort/mail_sort.dart';
import 'package:test/test.dart';

var _id = 0;

SubscriptionEmail mail(
  String company,
  String subject,
  DateTime at, {
  String text = '',
  String? name,
}) => SubscriptionEmail(
  messageId: _id++,
  company: company,
  senderName: name,
  subject: subject,
  text: text,
  at: at,
);

DateTime day(int month, int d, [int year = 2026]) =>
    DateTime.utc(year, month, d);

const _stripeReceipt = '''
Anthropic, PBC
Receipt from Anthropic, PBC
\$202.39
Paid September 28, 2026
Download invoice
Receipt number
2813-4113-5333
Payment method
Mastercard - 0232
Receipt #2813-4113-5333
Sep 28, 2026–Sep 28, 2027
Claude Pro
Qty 1
\$200.00
Unused time on Claude Pro after 28 Sep 2026
Qty 1
-\$14.32
Subtotal
\$185.68
Total excluding tax
\$185.68
GST - Singapore (9%)
\$16.71
Total
\$202.39
Amount paid
\$202.39
''';

void main() {
  final now = DateTime.utc(2026, 11, 1);

  group('amounts', () {
    test('currencies and number shapes', () {
      final cases = {
        'Total: S\$12.98': const Money(1298, 'SGD'),
        'You paid \$9.99 for Premium': const Money(999, r'$'),
        'Amount charged USD 1,234.50': const Money(123450, 'USD'),
        'Prix total 4,99 €': const Money(499, 'EUR'),
        'Price £7': const Money(700, 'GBP'),
        'RM 15.90 per month': const Money(1590, 'MYR'),
      };
      for (final MapEntry(key: text, value: money) in cases.entries) {
        expect(SubscriptionFinder.amountIn(text), money, reason: text);
      }
    });

    test('the total wins over other amounts', () {
      expect(
        SubscriptionFinder.amountIn(
          'Was S\$19.98, discount S\$5.00. Total S\$14.98',
        ),
        const Money(1498, 'SGD'),
      );
    });

    test('the amount paid, not the total before tax', () {
      expect(
        SubscriptionFinder.amountIn(_stripeReceipt),
        const Money(20239, r'$'),
      );
      expect(
        SubscriptionFinder.amountIn('Subtotal S\$10.00\nTotal S\$10.90'),
        const Money(1090, 'SGD'),
      );
    });

    test('billing periods', () {
      expect(
        SubscriptionFinder.billingPeriodIn('Sep 28, 2026–Sep 28, 2027'),
        const Duration(days: 365),
      );
      expect(
        SubscriptionFinder.billingPeriodIn('Period: 1 Oct 2026 - 1 Nov 2026'),
        const Duration(days: 31),
      );
      expect(
        SubscriptionFinder.billingPeriodIn('2026-10-01 to 2026-10-31'),
        const Duration(days: 30),
      );
      expect(SubscriptionFinder.billingPeriodIn('Sep 28, 2026'), isNull);
    });

    test('no amount: null', () {
      expect(
        SubscriptionFinder.amountIn('Thanks for your order 12345'),
        isNull,
      );
      expect(SubscriptionFinder.amountIn(''), isNull);
    });
  });

  group('finding subscriptions', () {
    test('monthly receipts: cadence, amount, next charge', () {
      final found = SubscriptionFinder.find([
        for (final m in [8, 9, 10])
          mail(
            'netflix.com',
            'Your Netflix receipt',
            day(m, 14),
            name: 'Netflix',
            text: 'Your membership has been renewed. Total S\$17.98',
          ),
      ], now: now);
      final s = found.single;
      expect(s.name, 'Netflix');
      expect(s.cadence, Cadence.monthly);
      expect(s.amount, const Money(1798, 'SGD'));
      expect(s.status, SubscriptionStatus.active);
      expect(s.nextCharge, day(11, 13));
      expect(s.monthly, const Money(1798, 'SGD'));
    });

    test('one yearly receipt: cadence from the wording', () {
      final s = SubscriptionFinder.find([
        mail(
          'example-cloud.com',
          'Receipt for your subscription',
          day(3, 2),
          text: 'Pro plan, billed yearly. Total US\$120.00',
        ),
      ], now: now).single;
      expect(s.cadence, Cadence.yearly);
      expect(s.nextCharge, day(3, 2, 2027));
      expect(s.monthly, const Money(1000, 'USD'));
    });

    test('cancelled after the last charge', () {
      final s = SubscriptionFinder.find([
        mail(
          'music.example',
          'Your receipt',
          day(9, 1),
          text: 'subscription \$10',
        ),
        mail(
          'music.example',
          'Your receipt',
          day(10, 1),
          text: 'subscription \$10',
        ),
        mail(
          'music.example',
          'Your subscription has been cancelled',
          day(10, 5),
        ),
      ], now: now).single;
      expect(s.status, SubscriptionStatus.cancelled);
      expect(s.nextCharge, isNull);
    });

    test('no charge for a long while: probably ended', () {
      final s = SubscriptionFinder.find([
        mail('gym.example', 'Membership payment received', day(1, 10)),
        mail('gym.example', 'Membership payment received', day(2, 10)),
      ], now: now).single;
      expect(s.status, SubscriptionStatus.lapsed);
    });

    test('regular charges without the word still count', () {
      final found = SubscriptionFinder.find([
        for (final m in [7, 8, 9, 10])
          mail('telco.example', 'Your invoice is ready', day(m, 3)),
      ], now: now);
      expect(found.single.cadence, Cadence.monthly);
    });

    test('one-off orders and plan talk without payment do not count', () {
      final found = SubscriptionFinder.find([
        // Irregular shop orders.
        mail('shop.example', 'Your order receipt', day(2, 1)),
        mail('shop.example', 'Your order receipt', day(2, 20)),
        mail('shop.example', 'Your order receipt', day(7, 9)),
        // Mentions a plan, nothing paid or started.
        mail('news.example', 'Payment methods for your plan', day(10, 1)),
      ], now: now);
      expect(found, isEmpty);
    });

    test('a receipt with a billing period is a subscription', () {
      final found = SubscriptionFinder.find([
        mail(
          'anthropic.com',
          'Your receipt from Anthropic, PBC #2813-4113-5333',
          day(9, 28),
          text: _stripeReceipt,
          name: 'Anthropic, PBC',
        ),
      ], now: now);
      expect(found, hasLength(1));
      final s = found.single;
      expect(s.name, 'Anthropic, PBC');
      expect(s.cadence, Cadence.yearly);
      expect(s.amount, const Money(20239, r'$'));
      expect(s.status, SubscriptionStatus.active);
      expect(s.nextCharge, day(9, 28, 2027));
    });

    test('a trial does not turn one-off receipts into a subscription', () {
      final found = SubscriptionFinder.find([
        mail(
          'grab.com',
          'Your Grab E-Receipt',
          day(9, 28),
          text: 'Total S\$31.80 GrabFood',
        ),
        mail('grab.com', 'Sorry, your order was cancelled', day(9, 28)),
        mail(
          'grab.com',
          'Your Grab E-Receipt',
          day(10, 4),
          text: 'Total S\$37.80 GrabCar',
        ),
        mail(
          'grab.com',
          'You\'re on the free trial 🎉',
          day(10, 5),
          text: 'GrabUnlimited: S\$59.88 a year after your free trial',
        ),
        mail(
          'grab.com',
          'Your Grab E-Receipt',
          day(10, 5),
          text: 'Total S\$35.08 GrabFood',
        ),
        mail(
          'grab.com',
          'Your Grab E-Receipt',
          day(10, 9),
          text: 'Total S\$18.00 GrabCar',
        ),
      ], now: now);
      // No ride or food receipt counts, and a free trial alone is not a
      // subscription until it charges.
      expect(found, isEmpty);
    });

    test('a free trial counts once it charges', () {
      final trial = [
        mail(
          'foodpanda.sg',
          'Your pandapro free trial has started.',
          day(7, 12),
        ),
        mail('foodpanda.sg', 'Your free trial is ending.', day(8, 9)),
        mail(
          'foodpanda.sg',
          'Your order was canceled.',
          day(9, 10),
          text: 'Total S\$13.99',
        ),
      ];
      expect(SubscriptionFinder.find(trial, now: now), isEmpty);
      final found = SubscriptionFinder.find([
        ...trial,
        mail(
          'foodpanda.sg',
          'Your pandapro subscription receipt',
          day(8, 12),
          text: 'pandapro monthly S\$5.99',
        ),
      ], now: now);
      expect(found.single.amount, const Money(599, 'SGD'));
      expect(found.single.lastCharge, day(8, 12));
    });

    test('phone and broadband bills', () {
      final found = SubscriptionFinder.find([
        mail(
          'myrepublic.net',
          'Your MyRepublic e-Bill is ready!',
          day(10, 29),
          name: 'MyRepublic',
          text:
              'Your e-bill is ready! The monthly bill for your MyRepublic '
              'mobile is now ready! The outstanding amount for your account '
              'C4082197 is: \$6.00',
        ),
        mail(
          'myrepublic.com.sg',
          'Your monthly invoice is ready!',
          day(10, 6),
          name: 'MyRepublic',
          text:
              'Your e-bill is ready! View bill on MyAccount. The outstanding '
              'amount for your account RA2328693 is: \$32.99 PayNow QR',
        ),
      ], now: now);
      expect(found, hasLength(2));
      final mobile = found.firstWhere((s) => s.company == 'myrepublic.net');
      expect(mobile.amount, const Money(600, r'$'));
      expect(mobile.cadence, Cadence.monthly);
      expect(mobile.status, SubscriptionStatus.active);
      final home = found.firstWhere((s) => s.company == 'myrepublic.com.sg');
      expect(home.amount, const Money(3299, r'$'));
      expect(home.cadence, Cadence.monthly);
      expect(
        SubscriptionFinder.subjectWords.any(
          (w) => 'Your MyRepublic e-Bill is ready!'.toLowerCase().contains(w),
        ),
        isTrue,
      );
    });

    test('account statements are not charges', () {
      final found = SubscriptionFinder.find([
        for (final m in [5, 6, 7, 8, 9, 10])
          mail(
            'sgx.com',
            'Your CDP account statement is ready for viewing on SGX Investor '
                'Portal',
            day(m, 4),
            name: 'CDP Online (Do not reply)',
            text:
                'Your latest account statement for CDP Securities Account '
                'ending 7513 is available online via your Portfolio. You may '
                'access your past account statements (up to 24 months) and '
                'notifications (up to 60 days) online, at no charge.',
          ),
        for (final m in [8, 9, 10])
          mail('bank.example', 'Your e-Statement is ready', day(m, 1)),
      ], now: now);
      expect(found, isEmpty);
      expect(
        SubscriptionFinder.eventOf(
          mail('x.example', 'Your monthly statement is ready', day(10, 1)),
        ),
        SubscriptionEvent.notice,
      );
      // A bill that calls itself a statement is still a bill.
      expect(
        SubscriptionFinder.eventOf(
          mail('telco.example', 'Your bill statement is ready', day(10, 1)),
        ),
        SubscriptionEvent.charge,
      );
    });

    test('replies and forwards are not receipts', () {
      final found = SubscriptionFinder.find([
        mail(
          'github.com',
          'Re: [pawtaetoe/Citusmail] Subscriptions: a page per subscription '
              'with every receipt',
          day(10, 30),
          text: 'Your subscription receipt is shown monthly',
        ),
        mail(
          'github.com',
          'Re: [x/y] Subscriptions found (PR #13)',
          day(10, 30),
        ),
        mail(
          'shop.example',
          'Fwd: Your membership receipt',
          day(10, 1),
          text: 'Total S\$9.00 monthly',
        ),
      ], now: now);
      expect(found, isEmpty);
    });

    test('active first, then ended; newest first within each', () {
      final found = SubscriptionFinder.find([
        mail('a.example', 'Subscription receipt', day(10, 20), text: 'monthly'),
        mail('b.example', 'Subscription receipt', day(10, 25), text: 'monthly'),
        mail('c.example', 'Subscription receipt', day(1, 1), text: 'monthly'),
      ], now: now);
      expect(found.map((s) => s.company), [
        'b.example',
        'a.example',
        'c.example',
      ]);
      expect(found.last.status, SubscriptionStatus.lapsed);
    });
  });
}
