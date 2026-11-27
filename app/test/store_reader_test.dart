// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Long reads in a helper isolate with its own connection: what the UI
// committed is read there, results and errors come back, and stopping
// closes it.

import 'dart:async';
import 'dart:isolate';

import 'package:citusmail/src/services/store_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

StoreTask<(String?, int)> _subjects() => (store) {
  final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
  final list = store.messages.list(MessageQuery(mailboxIds: [inbox.id]));
  return (Isolate.current.debugName, list.length);
};

StoreTask<int> _fails() =>
    (store) => throw const FormatException('no');

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create(readsInIsolate: true));
  tearDown(() => app.dispose());

  test('runs in its own isolate and reads what the UI wrote', () async {
    final reads = app.services.reads;
    expect(runsInIsolate(reads), isTrue);
    final (where, before) = await reads.run(_subjects());
    expect(where, 'store reader');
    final inbox = app.store.mailboxes.inbox(
      app.store.accounts.all().single.id,
    )!;
    app.store.messages.upsertSummaries(inbox.id, [
      MessageSummary(uid: 77, receivedAt: DateTime.utc(2026, 11)),
    ]);
    expect((await reads.run(_subjects())).$2, before + 1);
  });

  test('errors come back as they were thrown', () async {
    await expectLater(
      app.services.reads.run(_fails()),
      throwsA(isA<FormatException>()),
    );
  });

  test('inline: on this isolate, with the store', () async {
    final reads = StoreReader.inline(app.store);
    expect(runsInIsolate(reads), isFalse);
    expect((await reads.run(_subjects())).$1, Isolate.current.debugName);
  });

  testWidgets('stopping in a widget test, after a task', (tester) async {
    await tester.runAsync(() => app.services.reads.run(_subjects()));
  });

  testWidgets('stopping in a widget test, after a task started in fake time', (
    tester,
  ) async {
    var done = false;
    unawaited(app.services.reads.run(_subjects()).then((_) => done = true));
    for (var i = 0; i < 50 && !done; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(done, isTrue);
  });

  test('a database it cannot open: on this isolate instead', () async {
    final reads = StoreReader.isolate(
      '${app.directory.path}/mail.db',
      DatabaseKey.generate(),
      fallback: app.store,
    );
    // A wrong key: it falls back to this isolate.
    expect((await reads.run(_subjects())).$2, greaterThan(0));
    await reads.dispose();
  });
}
