// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/features/reader/ui/reader_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Lets real isolates (the sync worker, message parsing) finish: the old
/// fixed pause, then on until no email is still loading, so a busy
/// machine doesn't fail a test that a quiet one passes (at most 5 s).
Future<void> settleMail(WidgetTester tester) async {
  final loading = find.descendant(
    of: find.byType(ReaderPane),
    matching: find.byType(CircularProgressIndicator),
  );
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 400)),
  );
  await tester.pump(const Duration(milliseconds: 200));
  for (var i = 0; i < 46 && loading.evaluate().isNotEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}
