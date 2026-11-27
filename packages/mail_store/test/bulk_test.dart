// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Thousands of messages from one sender: removed, put back and marked
// read without work that grows with how much mail that sender sent.

import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

import 'support/temp_store.dart';

void main() {
  late TempStore temp;
  late MailStore store;
  late StoredMailbox inbox;
  setUp(() {
    temp = TempStore.create();
    store = temp.store;
    final account = temp.addAccount();
    inbox = store.mailboxes.replaceAll(account.id, [
      ImapMailboxInfo(
        encodedName: 'INBOX',
        delimiter: '/',
        attributes: const {},
      ),
    ]).single;
  });
  tearDown(() => temp.dispose());

  const from = MailAddress(
    displayName: 'Trading',
    localPart: 'alerts',
    domain: 'broker.example',
  );

  /// [count] messages from [from], UIDs 1, 3, 5...
  void seed(int count) {
    for (var start = 0; start < count; start += 250) {
      store.messages.upsertSummaries(inbox.id, [
        for (var i = start; i < start + 250 && i < count; i++)
          MessageSummary(
            uid: 2 * i + 1,
            messageId: 'trade$i@broker.example',
            references: ['order$i@broker.example'],
            subject: 'Trade confirmation $i',
            receivedAt: DateTime.utc(2025).add(Duration(hours: i)),
            from: from,
            to: const [
              MailAddress(localPart: 'alice', domain: 'citusmail.test'),
            ],
            headers: const {
              'list-id': ['<trades.broker.example>'],
            },
          ),
      ]);
    }
  }

  test('"written to this sender?" skips the sender\'s own From rows', () {
    final plan = [
      for (final row in store.database.select(
        'EXPLAIN QUERY PLAN SELECT 1 FROM message_addresses a '
        "WHERE a.address = ? COLLATE NOCASE AND a.kind IN ('to', 'cc', 'bcc')",
        ['alerts@broker.example'],
      ))
        row['detail'] as String,
    ];
    expect(
      plan.join('\n'),
      contains('message_addresses_by_address_kind (address=? AND kind=?)'),
    );
  });

  test('3,000 messages from one sender go and come back whole, in parts', () {
    seed(3000);
    final ids = store.messages.uids(inbox.id).map((uid) {
      return store.messages.byUid(inbox.id, uid)!.id;
    }).toList();
    store.messages.saveBody(
      ids.first,
      Uint8List.fromList([1, 2, 3]),
      searchableText: 'uniquebodyword',
    );
    final snapshot = store.messages.snapshot(ids);
    expect(snapshot.bodyBytes, 3);

    final removing = Stopwatch()..start();
    store.messages.removeUids(inbox.id, store.messages.uids(inbox.id));
    removing.stop();
    expect(store.messages.uids(inbox.id), isEmpty);
    expect(store.messages.search('confirmation'), isEmpty);

    final parts = snapshot.split(400);
    expect(parts, hasLength(8));
    expect(parts.map((p) => p.messages.length).last, 200);
    expect(
      MessageSnapshot.join(parts).messages.map((r) => r['id']),
      snapshot.messages.map((r) => r['id']),
    );
    final restoring = Stopwatch()..start();
    for (final part in parts) {
      store.messages.restore(part);
    }
    restoring.stop();
    // For the record.
    // ignore: avoid_print
    print(
      'removing 3,000: ${removing.elapsedMilliseconds} ms, '
      'putting back: ${restoring.elapsedMilliseconds} ms',
    );

    expect(store.messages.uids(inbox.id), hasLength(3000));
    final last = store.messages.byUid(inbox.id, 5999)!;
    expect(last.id, ids.last);
    expect(last.subject, 'Trade confirmation 2999');
    expect(
      store.messages.addresses(last.id, 'to').single.address,
      'alice@citusmail.test',
    );
    expect(store.messages.headers(last.id), {
      'list-id': ['<trades.broker.example>'],
    });
    expect(store.messages.body(ids.first), [1, 2, 3]);
    expect(store.messages.search('uniquebodyword').single.id, ids.first);
    expect(
      store.database
          .select('SELECT count(*) FROM message_search')
          .single
          .columnAt(0),
      3000,
    );
  });

  test('a message whose id was taken meanwhile comes back with a new one', () {
    seed(2);
    final last = store.messages.byUid(inbox.id, 3)!;
    final snapshot = store.messages.snapshot([last.id]);
    store.messages.removeUids(inbox.id, [3]);
    // New mail took the id (SQLite gives the highest one again).
    store.messages.upsertSummaries(inbox.id, [
      MessageSummary(uid: 9, receivedAt: DateTime.utc(2026), from: from),
    ]);
    expect(store.messages.byUid(inbox.id, 9)!.id, last.id);
    final back = store.messages.restore(snapshot);
    final newId = back[last.id]!;
    expect(newId, isNot(last.id));
    expect(store.messages.byUid(inbox.id, 3)!.id, newId);
    expect(store.messages.addresses(newId, 'to'), hasLength(1));
    expect(store.messages.search('confirmation'), hasLength(2));
  });
}
