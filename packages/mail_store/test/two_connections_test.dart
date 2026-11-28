// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The UI, the sync worker and the reading helper each open the same
// encrypted database file. While the sync writes batch after batch,
// another connection's reads never wait for it (WAL), and its own writes
// wait at most for the batch being written, never for the whole sync.

import 'dart:async';
import 'dart:isolate';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

import 'support/temp_store.dart';

const _from = MailAddress(
  displayName: 'Ana',
  localPart: 'ana',
  domain: 'x.example',
);

List<MessageSummary> _batch(int start, int count) => [
  for (var i = start; i < start + count; i++)
    MessageSummary(
      uid: i + 1,
      messageId: 'm$i@x.example',
      subject: 'Message number $i about the quarterly report',
      snippet: 'Hello, here is the text of message $i, with a few words.',
      receivedAt: DateTime.utc(2026).add(Duration(minutes: i)),
      from: _from,
      to: const [MailAddress(localPart: 'alice', domain: 'citusmail.test')],
    ),
];

/// Writes [_Write.batches] batches of [_Write.size] summaries, like a
/// sync storing what it fetched.
Future<int> _writer(_Write job) async {
  final store = MailStore.open(job.path, DatabaseKey.fromBytes(job.key));
  final watch = Stopwatch();
  var longest = 0;
  try {
    for (var b = 0; b < job.batches; b++) {
      watch
        ..reset()
        ..start();
      store.messages.upsertSummaries(
        MailboxId(job.mailbox),
        _batch(job.first + b * job.size, job.size),
      );
      if (watch.elapsedMicroseconds > longest) {
        longest = watch.elapsedMicroseconds;
      }
      // The next FETCH from the server (a real one takes longer).
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  } finally {
    store.close();
  }
  return longest;
}

/// [_writer] for [job], capturing nothing else.
Future<int> Function() _writing(_Write job) =>
    () => _writer(job);

final class _Write {
  const _Write(
    this.path,
    this.key,
    this.mailbox,
    this.first,
    this.batches,
    this.size,
  );

  final String path;
  final List<int> key;
  final int mailbox;
  final int first;
  final int batches;
  final int size;
}

void main() {
  late TempStore temp;
  late MailStore store;
  late StoredMailbox inbox;

  setUp(() {
    temp = TempStore.create();
    store = temp.store;
    final account = temp.addAccount();
    inbox = store.mailboxes.replaceAll(account.id, [
      ImapMailboxInfo(encodedName: 'INBOX', delimiter: '/', attributes: {}),
    ]).single;
    for (var start = 0; start < 2000; start += 250) {
      store.messages.upsertSummaries(inbox.id, _batch(start, 250));
    }
  });
  tearDown(() => temp.dispose());

  test('reads never wait for another connection\'s writes, and writes wait '
      'for one batch at most', () async {
    final job = _Write(
      temp.path,
      temp.key.bytes,
      inbox.id.value,
      2000,
      120,
      25,
    );
    final writing = Isolate.run(_writing(job));
    var finished = false;
    var longestBatch = 0;
    unawaited(
      writing
          .then((micros) => longestBatch = micros, onError: (Object _) => 0)
          .whenComplete(() => finished = true),
    );

    final reads = <int>[];
    final writes = <int>[];
    final watch = Stopwatch();
    var i = 0;
    while (!finished) {
      watch
        ..reset()
        ..start();
      // What the mail screen reads: a page of the list and its count.
      final page = store.messages.list(
        MessageQuery(mailboxIds: [inbox.id], limit: 50),
      );
      store.messages.unreadCount(inbox.id);
      reads.add(watch.elapsedMicroseconds);
      expect(page, hasLength(50));
      if (i++ % 10 == 0) {
        // The user marks a message read.
        watch
          ..reset()
          ..start();
        store.messages.updateFlags(inbox.id, [
          (
            uid: 1 + i % 2000,
            flags: const MessageFlags(MessageFlags.seenBit),
            modSeq: null,
          ),
        ]);
        writes.add(watch.elapsedMicroseconds);
      }
      await Future<void>.delayed(Duration.zero);
    }
    await writing;

    reads.sort();
    writes.sort();
    final batchMs = longestBatch / 1000;
    printOnFailure(
      'reads: ${reads.length}, median ${reads[reads.length ~/ 2] / 1000} ms, '
      'longest ${reads.last / 1000} ms; writes: ${writes.length}, longest '
      '${writes.last / 1000} ms; longest batch $batchMs ms',
    );
    expect(reads.length, greaterThan(10), reason: 'read while it wrote');
    // A read takes what it takes alone (a few ms), never a batch.
    expect(reads.last / 1000, lessThan(50));
    // A write waits for the batch being written at most: it looks again
    // every millisecond, so it never misses the gaps between them.
    expect(writes.last / 1000, lessThan(batchMs * 2 + 50));
    expect(store.messages.highestUid(inbox.id), 5000, reason: 'all written');
  });
}
