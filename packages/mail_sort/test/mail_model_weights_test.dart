// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// The shipped weights are what the trainer makes from its synthetic
/// mail: retrain (`dart run tool/train_mail_model.dart`) after changing
/// the features, the generator or the trainer.
library;

import 'dart:io';

import 'package:mail_sort/mail_sort.dart';
import 'package:test/test.dart';

import '../tool/mail_model/synthetic_mail.dart';
import '../tool/mail_model/trainer.dart';

void main() {
  test('the synthetic mail is the same for the same seed', () {
    String text(List<SynthMail> mail) => [
      for (final m in mail.take(400))
        [
          m.label.name,
          m.sample.address,
          m.sample.subject,
          m.sample.text,
        ].join('|'),
    ].join('\n');
    expect(
      text(syntheticMail(perClass: 40)),
      text(syntheticMail(perClass: 40)),
    );
    expect(
      text(syntheticMail(seed: 1, perClass: 40)),
      isNot(text(syntheticMail(perClass: 40))),
    );
  });

  test('every class has its synthetic mail', () {
    final mail = syntheticMail(perClass: 20);
    for (final c in MailClass.values) {
      expect(mail.where((m) => m.label == c), isNotEmpty, reason: c.name);
    }
  });

  test(
    'the generated weights are up to date with the trainer and its data',
    () {
      final source = trainAndGenerate();
      final shipped = File(generatedPath).readAsStringSync();
      expect(
        shipped == source,
        isTrue,
        reason:
            '$generatedPath is out of date: run '
            '`dart run tool/train_mail_model.dart` in packages/mail_sort.',
      );
      // Well under a megabyte.
      expect(shipped.length, lessThan(400 * 1024));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
