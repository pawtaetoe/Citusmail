// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// While a sync stores thousands of summaries, the screen's own
// connection to the database (another isolate) reads and writes without
// waiting for more than one of the sync's small transactions.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

import 'support/fake_imap.dart';

/// The screen: marks a message read and reads a page of the list, again
/// and again, until told to stop; answers the longest waits (µs).
Future<void> _screen(_Screen job) async {
  final store = MailStore.open(job.path, DatabaseKey.fromBytes(job.key));
  final stop = ReceivePort();
  var stopped = false;
  stop.listen((_) => stopped = true);
  job.ready.send(stop.sendPort);
  var longestWrite = 0, longestRead = 0, writes = 0;
  final watch = Stopwatch();
  final mailbox = MailboxId(job.mailbox);
  while (!stopped) {
    watch
      ..reset()
      ..start();
    store.messages.updateFlags(mailbox, [
      (uid: 1, flags: MessageFlags((writes++).isEven ? 1 : 0), modSeq: null),
    ]);
    if (watch.elapsedMicroseconds > longestWrite) {
      longestWrite = watch.elapsedMicroseconds;
    }
    watch
      ..reset()
      ..start();
    store.messages.list(MessageQuery(mailboxIds: [mailbox], limit: 50));
    if (watch.elapsedMicroseconds > longestRead) {
      longestRead = watch.elapsedMicroseconds;
    }
    await Future<void>.delayed(const Duration(milliseconds: 3));
  }
  stop.close();
  store.close();
  job.ready.send([longestWrite, longestRead, writes]);
}

final class _Screen {
  const _Screen(this.path, this.key, this.mailbox, this.ready);

  final String path;
  final List<int> key;
  final int mailbox;
  final SendPort ready;
}

void main() {
  final skip = FakeImap.skipReason;
  if (skip != null) {
    test('needs the test certificates', () {}, skip: skip);
    return;
  }

  test('the screen waits for one small transaction at most while a sync '
      'stores 3,000 summaries', () async {
    final server = await FakeImap.start(condstore: true);
    addTearDown(server.close);
    final directory = Directory.systemTemp.createTempSync('contention_test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final key = DatabaseKey.generate();
    final path = '${directory.path}/mail.db';
    final store = MailStore.open(path, key);
    addTearDown(store.close);
    final account = server.addAccount(store);
    final inbox = server.folders['INBOX']!..add(subject: 'first');
    final engine = SyncEngine(
      store,
      server.connector(),
      classifier: const HeaderRuleClassifier(),
      settings: const SyncSettings(initialWindow: 4000),
    );
    addTearDown(engine.dispose);
    expect(await engine.syncAccount(account.id), isNotNull);
    for (var i = 0; i < 3000; i++) {
      inbox.add(subject: 'Quarterly report number $i', from: 'n$i@x.example');
    }

    final answers = ReceivePort();
    addTearDown(answers.close);
    final replies = StreamIterator(answers);
    await Isolate.spawn(
      _screen,
      _Screen(
        path,
        key.bytes,
        store.mailboxes.inbox(account.id)!.id.value,
        answers.sendPort,
      ),
    );
    expect(await replies.moveNext(), isTrue);
    final stop = replies.current as SendPort;

    final report = await engine.syncAccount(account.id);
    stop.send(null);
    expect(await replies.moveNext(), isTrue);
    final [longestWrite, longestRead, writes] = (replies.current as List)
        .cast<int>();
    printOnFailure(
      'screen: $writes writes, longest ${longestWrite / 1000} ms; longest '
      'read ${longestRead / 1000} ms',
    );
    expect(report!.mailboxes.values.single.added, 3000);
    expect(writes, greaterThan(20), reason: 'it wrote meanwhile');
    // One transaction of 25 summaries takes a few tens of ms; 100 at once
    // and SQLite's own busy wait made it hundreds.
    expect(longestWrite / 1000, lessThan(100));
    expect(longestRead / 1000, lessThan(50));
  });
}
