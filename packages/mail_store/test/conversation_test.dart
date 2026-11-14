// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

import 'support/temp_store.dart';

/// The conversation a message is in, for summarising a whole thread.
void main() {
  late TempStore temp;
  late MailStore store;
  late Account account;
  late Map<String, StoredMailbox> boxes;

  setUp(() {
    temp = TempStore.create();
    store = temp.store;
    account = temp.addAccount();
    final list = store.mailboxes.replaceAll(account.id, [
      for (final (name, use) in [
        ('INBOX', null),
        ('Sent', r'\Sent'),
        ('Trash', r'\Trash'),
        ('[Gmail]/All Mail', r'\All'),
      ])
        ImapMailboxInfo(encodedName: name, delimiter: '/', attributes: {?use}),
    ]);
    boxes = {for (final b in list) b.encodedName: b};
  });
  tearDown(() => temp.dispose());

  StoredMessage add(
    String box,
    int uid,
    String id, {
    String? replyTo,
    List<String> references = const [],
    String subject = 'Dinner on Friday',
    int day = 1,
  }) {
    store.messages.upsertSummaries(boxes[box]!.id, [
      MessageSummary(
        uid: uid,
        receivedAt: DateTime.utc(2026, 11, day, 9),
        sentAt: DateTime.utc(2026, 11, day, 9),
        subject: subject,
        messageId: id,
        inReplyTo: replyTo,
        references: references,
        from: const MailAddress(localPart: 'bob', domain: 'x.example'),
      ),
    ]);
    return store.messages.byUid(boxes[box]!.id, uid)!;
  }

  test('the messages before and after, oldest first, each once', () {
    final first = add('INBOX', 1, 'a@x', day: 1);
    // Alice's reply, in Sent and (Gmail) All Mail.
    final reply = add(
      'Sent',
      1,
      'b@x',
      replyTo: 'a@x',
      references: ['a@x'],
      subject: 'Re: Dinner on Friday',
      day: 2,
    );
    add(
      '[Gmail]/All Mail',
      7,
      'b@x',
      replyTo: 'a@x',
      references: ['a@x'],
      day: 2,
    );
    final answer = add(
      'INBOX',
      2,
      'c@x',
      replyTo: 'b@x',
      references: ['a@x', 'b@x'],
      subject: 'Re: Dinner on Friday',
      day: 3,
    );
    // Unrelated mail, and a deleted reply.
    add('INBOX', 3, 'other@x', subject: 'Dinner on Friday', day: 2);
    add('Trash', 1, 'd@x', replyTo: 'c@x', references: ['a@x', 'c@x'], day: 4);

    List<int> ids(StoredMessage m) => [
      for (final c in store.messages.conversation(m)) c.id,
    ];
    final expected = [first.id, reply.id, answer.id];
    expect(ids(first), expected);
    expect(ids(reply), expected);
    expect(ids(answer), expected);
  });

  test('a message on its own is its own conversation', () {
    final alone = add('INBOX', 1, 'alone@x');
    expect(store.messages.conversation(alone).map((m) => m.id), [alone.id]);
    // Even from Trash, the message itself is there.
    final deleted = add('Trash', 2, 'gone@x', replyTo: 'alone@x');
    expect(store.messages.conversation(deleted).map((m) => m.id), [
      alone.id,
      deleted.id,
    ]);
  });

  test('a long conversation: the newest, always with the message', () {
    final root = add('INBOX', 1, 'r@x', day: 1);
    for (var i = 2; i <= 30; i++) {
      add('INBOX', i, 'r$i@x', replyTo: 'r@x', references: ['r@x'], day: i);
    }
    final newest = store.messages.conversation(
      store.messages.byUid(boxes['INBOX']!.id, 30)!,
      limit: 5,
    );
    expect(newest.map((m) => m.uid), [26, 27, 28, 29, 30]);
    final fromRoot = store.messages.conversation(root, limit: 5);
    expect(fromRoot, hasLength(5));
    expect(fromRoot.map((m) => m.id), contains(root.id));
  });
}
