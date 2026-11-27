// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Trains the mail model on synthetic mail and writes
/// lib/src/generated/mail_model_weights.g.dart.
///
/// Run from packages/mail_sort:
///   dart run tool/train_mail_model.dart
library;

import 'dart:io';

import 'mail_model/synthetic_mail.dart';
import 'mail_model/trainer.dart';

void main() {
  final watch = Stopwatch()..start();
  final data = syntheticMail();
  final model = train(data);
  final source = generatedSource(model);
  File(generatedPath)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(source);
  stdout.writeln(
    'wrote $generatedPath: ${data.length} emails, '
    '${(source.length / 1024).toStringAsFixed(0)} KB, '
    '${watch.elapsedMilliseconds} ms',
  );
}
