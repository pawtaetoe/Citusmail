// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Mail stored with older sorting rules is sorted again after start-up,
// once the mail screen is up, not while the user looks at a spinner.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mail_sort/mail_sort.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;

  setUp(() async {
    app = await TestApp.create();
    app.store.settings.write(Resorter.versionKey, 'older rules');
  });
  tearDown(() => app.dispose());

  String? version() => app.store.settings.read(Resorter.versionKey);

  testWidgets('after the first frame and a pause, in small batches', (
    tester,
  ) async {
    int? looked;
    var changes = 0;
    app.services.resorted.addListener(() => changes++);
    unawaited(app.services.resortWhenIdle().then((n) => looked = n));

    await tester.pump();
    expect(version(), 'older rules', reason: 'nothing before the first frame');
    await tester.pump(const Duration(seconds: 1));
    expect(version(), 'older rules', reason: 'the app is still starting');

    await tester.pump(const Duration(seconds: 1));
    for (var i = 0; i < 50 && looked == null; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(looked, greaterThan(0));
    expect(version(), isNot('older rules'));
    expect(changes, 1, reason: 'the lists are read again');
  });

  testWidgets('closing the app first: tried again next time', (tester) async {
    int? looked;
    unawaited(app.services.resortWhenIdle().then((n) => looked = n));
    await tester.pump();
    await tester.runAsync(app.services.dispose);
    await tester.pump(const Duration(seconds: 3));
    expect(looked, 0);
    expect(app.services.resorted.value, 0);
  });
}
