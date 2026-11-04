// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_sort/mail_sort.dart';
import 'package:test/test.dart';

MailSample github(String subject, String text, {String name = 'Mei Chen'}) =>
    MailSample(
      address: 'notifications@github.com',
      domain: 'github.com',
      senderName: name,
      subject: subject,
      text:
          '$text\n\n—\nReply to this email directly, view it on GitHub, or '
          'unsubscribe. You are receiving this because you were mentioned.',
      bulk: true,
    );

MailSample receipt(String company, String domain, String plan) => MailSample(
  address: 'invoice+statements@mail.$domain',
  domain: domain,
  senderName: company,
  subject: 'Your receipt from $company #2841-3317',
  text:
      'Receipt from $company. Amount paid \$20.00. Date paid Oct 1, 2026. '
      '$plan, Oct 1 – Nov 1, 2026. Payment method Visa - 4242.',
);

void main() {
  final notification = github(
    '[acme/payments] Invoice PDF is missing the tax line (#311)',
    'The invoice PDF for annual subscriptions drops the GST line.',
  );
  final lookAlike = github(
    '[acme/web] Billing page shows the wrong plan (#902)',
    'On the billing page the plan name is cached after a renewal.',
    name: 'Dana Ortiz',
  );
  final anthropic = receipt('Anthropic, PBC', 'anthropic.com', 'Claude Pro');

  group('features', () {
    test('the same email always gives the same features', () {
      expect(MailFeatures.of(notification), MailFeatures.of(notification));
    });

    test('a fixed number of buckets, whatever the length', () {
      final long = MailSample(
        subject: 'Long',
        text: List.generate(5000, (i) => 'word$i x${i * 7}').join(' '),
      );
      final features = MailFeatures.of(long);
      expect(
        features.every((f) => f.$1 >= 0 && f.$1 < MailFeatures.buckets),
        isTrue,
      );
      // Only the start of the text is read.
      expect(features.length, lessThan(MailFeatures.bodyChars ~/ 4));
    });

    test('flags: an amount, a tracking number, a date, a reply', () {
      Set<int> of(MailSample s) => {for (final (b, _) in MailFeatures.of(s)) b};
      final plain = of(const MailSample(subject: 'Hello', text: 'Hi there'));
      final flagged = of(
        const MailSample(
          subject: r'Re: Hello',
          text: r'Total $12.00, tracking number 1Z999AA10123456784, 3 Dec',
        ),
      );
      expect(flagged.length - plain.length, greaterThanOrEqualTo(4));
    });
  });

  group('with nothing learned', () {
    test('never rejects anything', () {
      final classifier = MailTypeClassifier();
      for (final kind in MailKind.values) {
        for (final sample in [
          notification,
          lookAlike,
          anthropic,
          for (final seed in MailTypeSeeds.all) seed.sample,
        ]) {
          expect(classifier.rejects(kind, sample), isFalse);
        }
        expect(classifier.rejectsItem(kind, [notification]), isFalse);
      }
      expect(classifier.isEmpty, isTrue);
    });

    test('the made-up examples give sensible priors', () {
      final classifier = MailTypeClassifier();
      expect(
        classifier.score(MailKind.subscription, anthropic),
        greaterThan(0),
      );
      expect(classifier.score(MailKind.subscription, lookAlike), lessThan(0));
      expect(classifier.score(MailKind.delivery, anthropic), lessThan(0));
    });
  });

  group('learning from "Not a subscription"', () {
    test('similar GitHub notifications are no longer picked up', () {
      final classifier = MailTypeClassifier()
        ..reject(MailKind.subscription, notification);
      expect(classifier.rejects(MailKind.subscription, lookAlike), isTrue);
      // Only for that kind.
      expect(classifier.rejects(MailKind.delivery, lookAlike), isFalse);
    });

    test('real receipts from elsewhere stay', () {
      final classifier = MailTypeClassifier()
        ..reject(MailKind.subscription, notification)
        ..reject(
          MailKind.subscription,
          const MailSample(
            address: 'no-reply@grab.com',
            senderName: 'Grab',
            subject: 'Your Grab E-Receipt',
            text:
                'Hope you enjoyed your ride! GrabCar. Pick-up 8:12 PM '
                r'Orchard Road. Total S$12.40. Ride more with a GrabUnlimited '
                'membership.',
          ),
        );
      for (final sample in [
        anthropic,
        receipt('Kitepad', 'stripe.com', 'Kitepad Plus (monthly)'),
        const MailSample(
          address: 'billing@myrepublic.com.sg',
          senderName: 'MyRepublic',
          subject: 'Your MyRepublic e-bill for October 2026',
          text:
              r'Your e-bill is ready. Amount due S$49.95 by 21 Oct 2026. '
              'Fibre broadband monthly plan.',
        ),
      ]) {
        expect(
          classifier.rejects(MailKind.subscription, sample),
          isFalse,
          reason: sample.subject,
        );
      }
    });

    test('Undo takes it back exactly', () {
      final classifier = MailTypeClassifier()
        ..reject(MailKind.subscription, notification)
        ..reject(MailKind.subscription, notification, undo: true);
      expect(classifier.hasCorrections(MailKind.subscription), isFalse);
      expect(classifier.rejects(MailKind.subscription, lookAlike), isFalse);
      expect(classifier.isEmpty, isTrue);
    });

    test('an item goes when most of its emails are rejected', () {
      final classifier = MailTypeClassifier()
        ..reject(MailKind.subscription, notification);
      expect(
        classifier.rejectsItem(MailKind.subscription, [lookAlike, lookAlike]),
        isTrue,
      );
      expect(
        classifier.rejectsItem(MailKind.subscription, [lookAlike, anthropic]),
        isFalse,
      );
    });

    test('emails the user kept count for the kind', () {
      final classifier = MailTypeClassifier()
        ..reject(MailKind.subscription, notification);
      final before = classifier.score(MailKind.subscription, lookAlike);
      classifier.confirm(MailKind.subscription, lookAlike);
      expect(
        classifier.score(MailKind.subscription, lookAlike),
        greaterThan(before),
      );
    });
  });

  group('stored', () {
    test('compactly, and read back the same', () {
      final classifier = MailTypeClassifier()
        ..reject(MailKind.subscription, notification)
        ..reject(MailKind.delivery, anthropic)
        ..confirm(MailKind.subscription, anthropic, weight: 0.5);
      final text = classifier.toText();
      expect(text.length, lessThan(4000));
      final back = MailTypeClassifier.fromText(text);
      expect(back.toText(), text);
      for (final kind in MailKind.values) {
        expect(
          back.score(kind, lookAlike),
          closeTo(classifier.score(kind, lookAlike), 1e-9),
        );
        expect(back.hasCorrections(kind), classifier.hasCorrections(kind));
      }
    });

    test('nothing, or something unreadable: nothing learned', () {
      expect(MailTypeClassifier.fromText(null).isEmpty, isTrue);
      expect(MailTypeClassifier.fromText('').isEmpty, isTrue);
      expect(MailTypeClassifier.fromText('v1;s:4:zz:1/x').isEmpty, isTrue);
      expect(MailTypeClassifier.fromText('v9;s:4:4:').isEmpty, isTrue);
    });

    test('cleared', () {
      final classifier = MailTypeClassifier()
        ..reject(MailKind.subscription, notification)
        ..clear();
      expect(classifier.isEmpty, isTrue);
      expect(MailTypeClassifier.fromText(classifier.toText()).isEmpty, isTrue);
    });
  });

  test('fast enough for thousands of emails', () {
    final classifier = MailTypeClassifier()
      ..reject(MailKind.subscription, notification);
    final text = List.filled(60, 'Your order total is S\$42.00 today.').join();
    final watch = Stopwatch()..start();
    for (var i = 0; i < 3000; i++) {
      classifier.rejects(
        MailKind.subscription,
        MailSample(
          address: 'shop$i@example.com',
          subject: 'Your receipt #$i',
          text: text,
        ),
      );
    }
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
  });
}
