// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mail_sort/mail_sort.dart';
import 'package:test/test.dart';

const qatar = MailSample(
  address: 'booking@qatarairways.example',
  senderName: 'Qatar Airways',
  subject: 'Booking Confirmed',
  text:
      'Booking reference\nR7KQ2D\n\nQR 017\nDOH\n08:05\n|\nLHR\n13:20\n'
      'Sun, 06 Dec 2026\nE-ticket 157 2419983310',
);

const oebb = MailSample(
  address: 'tickets@oebb.at',
  senderName: 'ÖBB',
  subject: 'Ihr Ticket: Wien Hbf – Salzburg Hbf',
  text:
      'Hinfahrt 05.12.2026\nWien Hbf ab 09:28\nSalzburg Hbf an 11:52\n'
      'RJX 662, Wagen 27, Platz 45\nTicketcode 4K7XQ2\nPreis 19,90 €',
);

const grabRide = MailSample(
  address: 'no-reply@grab.example',
  senderName: 'Grab',
  subject: 'Your Grab E-Receipt',
  text:
      'Hope you enjoyed your ride! Pick-up 8:12 PM Orchard Road, drop-off '
      '8:41 PM Tiong Bahru. Total S\$12.40. Paid by Mastercard.',
);

const gojekRide = MailSample(
  address: 'no-reply@gojek.example',
  senderName: 'Gojek',
  subject: 'Your Gojek E-Receipt',
  text:
      'Thanks for riding with Gojek! Pick-up 7:02 PM Raffles Place, '
      'drop-off 7:25 PM Holland Village. Total S\$18.90. Paid by Visa.',
);

const receipt = MailSample(
  address: 'invoice+statements@stripe.example',
  senderName: 'Notewise',
  subject: 'Your receipt from Notewise #2291-4410',
  text:
      'Receipt from Notewise. Amount paid US\$20.00. Notewise Pro '
      'subscription, 1 month. Next billing date 2 Dec.',
);

void main() {
  group('features', () {
    test('the same email always gives the same vector, of length one', () {
      final a = MailModelFeatures.of(qatar);
      final b = MailModelFeatures.of(qatar);
      expect(a.buckets, b.buckets);
      expect(a.values, b.values);
      var sum = 0.0;
      for (var i = 0; i < a.length; i++) {
        sum += a.values[i] * a.values[i];
        if (i > 0) expect(a.buckets[i], greaterThan(a.buckets[i - 1]));
        expect(a.buckets[i], inInclusiveRange(0, MailModelFeatures.buckets));
      }
      expect(sum, closeTo(1, 1e-9));
    });

    test('words, pairs, sender and structure', () {
      final f = MailModelFeatures.named(qatar);
      expect(f, containsAll(['s:booking', 'sb:booking_confirmed']));
      expect(f, containsAll(['d:qatarairways.example', 'n:qatar']));
      // Codes and times in their own cells, a reference, an e-ticket.
      expect(
        f,
        containsAll([
          'c:airport:2',
          'c:airport-cell:2',
          'c:time:2',
          'c:labelled-ref',
          'c:flight-no',
          'k:e-ticket',
        ]),
      );
      final o = MailModelFeatures.named(oebb);
      expect(o, containsAll(['d:oebb.at', 'dl:oebb', 'n:obb']));
      expect(
        o,
        containsAll(['c:station:4+', 'c:train-no', 'k:travel', 'c:amount']),
      );
      final award = MailModelFeatures.named(
        const MailSample(
          subject: 'Your redemption booking',
          text: 'Avios used: 26,000. Invoice attached.',
        ),
      );
      expect(award, containsAll(['k:redemption', 'k:invoice']));
    });

    test('accents folded, numbers by their shape', () {
      final f = MailModelFeatures.named(
        const MailSample(subject: 'Réservation 12345 für Zürich', text: ''),
      );
      expect(f, containsAll(['s:reservation', 's:###', 's:zurich']));
    });

    test('only the start of a long text is read', () {
      final long = MailSample(
        subject: 'Long',
        text: List.generate(5000, (i) => 'word$i w${i}x').join(' '),
      );
      expect(MailModelFeatures.of(long).length, lessThan(2000));
    });
  });

  group('model', () {
    final model = MailModel.standard;

    test('chances add up to one', () {
      for (final s in [qatar, oebb, grabRide, receipt]) {
        final p = model.classify(s);
        final sum = MailClass.values.fold(0.0, (n, c) => n + p[c]);
        expect(sum, closeTo(1, 1e-9));
        expect(p.kinds.keys, MailKind.values);
      }
    });

    test('reads what the rules miss', () {
      expect(model.classify(qatar).best, MailClass.flight);
      expect(model.classify(oebb).best, MailClass.train);
      expect(model.classify(oebb).bookingType, BookingType.train);
      expect(model.isA(MailKind.booking, oebb), isTrue);
      expect(model.isA(MailKind.subscription, receipt), isTrue);
      expect(model.kindOf(grabRide)[MailKind.subscription], lessThan(0.5));
    });

    test('the weights are small', () {
      // Base64 text, as shipped; the decoded weights are a quarter less.
      expect(MailModel.shippedBytes, lessThan(400 * 1024));
    });

    test('the weights are stored and read back exactly', () {
      final r = math.Random(4);
      final w = Int8List(64 * 3);
      for (var i = 0; i < w.length; i++) {
        if (r.nextInt(3) == 0) w[i] = r.nextInt(255) - 127;
      }
      final back = MailModel.decodeWeights(
        MailModel.encodeWeights(w, buckets: 64, classes: 3),
        buckets: 64,
        classes: 3,
      );
      expect(back, w);
    });

    test('fast enough for thousands of emails', () {
      // As on the device: most emails only by their preview, some
      // downloaded (and read up to MailModelFeatures.bodyChars).
      final body = List.filled(
        24,
        'Your booking reference ZK8P4Q. Departs 08:30 from Wien Hbf, '
        'total €42.00 on 12 Dec. ',
      ).join('\n');
      final samples = [
        for (var i = 0; i < 5000; i++)
          MailSample(
            address: 'shop$i@example.com',
            senderName: 'Shop $i',
            subject: 'Your booking #$i is confirmed',
            text: i.isEven ? body : body.substring(0, 240),
          ),
      ];
      model.classify(samples.first);
      final watch = Stopwatch()..start();
      for (final s in samples) {
        model.classify(s);
      }
      // About 0.1 ms for a whole email and 15 µs for a preview, on a
      // laptop.
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });

  group('learning', () {
    final model = MailModel.standard;

    test('nothing learned: the model as shipped', () {
      final learning = MailLearning();
      expect(learning.isEmpty, isTrue);
      expect(
        model.withLearning(learning).classify(grabRide)[MailClass.none],
        model.classify(grabRide)[MailClass.none],
      );
    });

    test('"Not a subscription" counts against similar emails', () {
      final learning = MailLearning()..reject(MailKind.subscription, grabRide);
      final taught = model.withLearning(learning);
      double sub(MailModel m, MailSample s) =>
          m.kindOf(s)[MailKind.subscription]!;
      expect(sub(taught, grabRide), lessThan(sub(model, grabRide)));
      expect(sub(taught, gojekRide), lessThan(sub(model, gojekRide)));
      // Less so for one less alike, and not for other kinds.
      expect(
        sub(model, receipt) - sub(taught, receipt),
        lessThan(sub(model, gojekRide) - sub(taught, gojekRide)),
      );
      expect(learning.adjustment(MailKind.delivery, gojekRide), 0);
      expect(
        learning.adjustment(MailKind.subscription, grabRide),
        closeTo(-MailLearning.step, 0.2),
      );
    });

    test('Undo takes it back exactly', () {
      final learning = MailLearning()
        ..reject(MailKind.subscription, grabRide)
        ..reject(MailKind.subscription, grabRide, undo: true);
      expect(learning.isEmpty, isTrue);
      expect(learning.adjustment(MailKind.subscription, gojekRide), 0);
    });

    test('"List again" undoes the rejection in the model', () {
      final learning = MailLearning()
        ..reject(MailKind.booking, oebb)
        ..confirm(MailKind.booking, oebb);
      expect(learning.adjustment(MailKind.booking, oebb), 0);
      // The classifier keeps both, as it always did.
      expect(learning.hasCorrections(MailKind.booking), isTrue);
    });

    test('the veto works exactly as the classifier does', () {
      final classifier = MailTypeClassifier()
        ..reject(MailKind.subscription, grabRide)
        ..confirm(MailKind.subscription, receipt, weight: 0.5);
      final learning = MailLearning()
        ..reject(MailKind.subscription, grabRide)
        ..confirm(MailKind.subscription, receipt, weight: 0.5);
      expect(learning.veto.toText(), classifier.toText());
      expect(
        learning.veto.rejects(MailKind.subscription, gojekRide),
        classifier.rejects(MailKind.subscription, gojekRide),
      );
      // Read by today's loader, the stored text is the classifier's.
      final stored = learning.toText();
      expect(MailTypeClassifier.fromText(stored).toText(), classifier.toText());
    });

    test('stored, and read back the same', () {
      final learning = MailLearning()
        ..reject(MailKind.subscription, grabRide)
        ..reject(MailKind.booking, receipt)
        ..confirm(MailKind.booking, qatar);
      final text = learning.toText();
      final back = MailLearning.fromText(text);
      expect(back.toText(), text);
      for (final kind in MailKind.values) {
        expect(
          back.adjustment(kind, gojekRide),
          learning.adjustment(kind, gojekRide),
        );
      }
      // A few kilobytes for a few corrections.
      expect(text.length, lessThan(8000));
    });

    test('corrections stored before the model keep their effect', () {
      final old = MailTypeClassifier()..reject(MailKind.subscription, grabRide);
      final text = old.toText();
      final learning = MailLearning.fromText(text);
      // The veto is what it was.
      expect(learning.veto.toText(), text);
      expect(
        learning.veto.rejects(MailKind.subscription, gojekRide),
        old.rejects(MailKind.subscription, gojekRide),
      );
      // And the model learns from it too.
      expect(
        learning.adjustment(MailKind.subscription, gojekRide),
        lessThan(-0.5),
      );
      expect(learning.adjustment(MailKind.delivery, gojekRide), 0);
      // Kept when stored again, with new corrections next to it.
      learning.reject(MailKind.delivery, receipt);
      final again = MailLearning.fromText(learning.toText());
      expect(
        again.adjustment(MailKind.subscription, gojekRide),
        closeTo(learning.adjustment(MailKind.subscription, gojekRide), 1e-12),
      );
      expect(again.adjustment(MailKind.delivery, receipt), lessThan(-1));
    });

    test('adjustments for other features: the classifier holds them all', () {
      final learning = MailLearning()..reject(MailKind.subscription, grabRide);
      final other = learning.toText().replaceFirst(
        ';xv:${MailModelFeatures.version}',
        ';xv:1',
      );
      final back = MailLearning.fromText(other);
      expect(back.veto.toText(), learning.veto.toText());
      expect(back.adjustment(MailKind.subscription, gojekRide), lessThan(-0.5));
    });

    test('nothing, or something unreadable: nothing learned', () {
      expect(MailLearning.fromText(null).isEmpty, isTrue);
      expect(MailLearning.fromText('').isEmpty, isTrue);
      expect(MailLearning.fromText('v9;s:4:4:').isEmpty, isTrue);
      expect(MailLearning.fromText('v1;xv:2;xs:zz/!').isEmpty, isTrue);
    });

    test('cleared', () {
      final learning = MailLearning.fromText(
        (MailTypeClassifier()..reject(MailKind.booking, oebb)).toText(),
      )..reject(MailKind.booking, qatar);
      learning.clear();
      expect(learning.isEmpty, isTrue);
      expect(MailLearning.fromText(learning.toText()).isEmpty, isTrue);
    });
  });

  group('ranking candidates', () {
    test('the travel date, not the day of booking', () {
      const text =
          'Booked on 1 Nov 2026. Payment received.\n'
          'Outbound: Departure 12 Dec 2026 08:30 from Wien Hbf.\n'
          'Valid until 13 Dec 2026.';
      final dates = RegExp(r'\d{1,2} \w{3} \d{4}');
      final candidates = [
        for (final m in dates.allMatches(text))
          Candidate(m[0]!, text: text, start: m.start, end: m.end),
      ];
      final ranked = KeywordRanker.travelDate.rank(candidates);
      expect(ranked.first.candidate.value, '12 Dec 2026');
      expect(ranked.last.candidate.value, isNot('12 Dec 2026'));
      expect(KeywordRanker.travelDate.best(candidates)!.value, '12 Dec 2026');
      expect(KeywordRanker.travelDate.best(<Candidate<String>>[]), isNull);
    });
  });
}
