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
