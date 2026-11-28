// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Instant mail runs its own sync engine in the app's process. While the
// app's engine syncs, it pauses, so the device holds one set of mail
// connections per account, not two.

import 'dart:async';

import 'package:citusmail/src/background/background_mail.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> calls;
  late Completer<void> stopping;
  late DeferToApp deferral;

  setUp(() {
    calls = [];
    stopping = Completer<void>()..complete();
    deferral = DeferToApp(
      start: () => calls.add('start'),
      stop: () async {
        calls.add('stop');
        await stopping.future;
        calls.add('stopped');
      },
    );
  });

  test('runs only while the app is not syncing', () async {
    await deferral.appSyncing(true);
    expect(calls, isEmpty, reason: 'the app syncs: never started');
    expect(deferral.running, isFalse);
    await deferral.appSyncing(false);
    expect(calls, ['start']);
    expect(deferral.running, isTrue);
    await deferral.appSyncing(true);
    expect(calls, ['start', 'stop', 'stopped']);
    expect(deferral.running, isFalse);
  });

  test('the same news twice changes nothing', () async {
    await deferral.appSyncing(false);
    await deferral.appSyncing(false);
    await deferral.appSyncing(true);
    await deferral.appSyncing(true);
    expect(calls, ['start', 'stop', 'stopped']);
  });

  test('starts again only once it has stopped', () async {
    await deferral.appSyncing(false);
    stopping = Completer<void>();
    final stop = deferral.appSyncing(true);
    final start = deferral.appSyncing(false);
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['start', 'stop'], reason: 'still stopping');
    stopping.complete();
    await Future.wait([stop, start]);
    expect(calls, ['start', 'stop', 'stopped', 'start']);
    expect(deferral.running, isTrue);
  });
}
