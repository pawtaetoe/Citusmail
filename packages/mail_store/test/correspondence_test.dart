// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

import 'support/temp_store.dart';

/// What the writing hints read about one address.
void main() {
  late TempStore temp;
  late MailStore store;
  late Map<String, StoredMailbox> boxes;
  late CorrespondenceRepository mail;

  setUp(() {
    temp = TempStore.create();
    store = temp.store;
    final account = temp.addAccount();
    final list = store.mailboxes.replaceAll(account.id, [
      for (final (name, use) in [
        ('INBOX', null),
        ('Sent', r'\Sent'),
        ('Drafts', r'\Drafts'),
        ('[Gmail]/All Mail', r'\All'),
      ])
        ImapMailboxInfo(encodedName: name, delimiter: '/', attributes: {?use}),
    ]);
    boxes = {for (final b in list) b.encodedName: b};
    mail = CorrespondenceRepository(store.database);
  });
  tearDown(() => temp.dispose());

  const maya = MailAddress(
    displayName: 'Maya Lin',
    localPart: 'maya',
    domain: 'example.com',
  );
  const me = MailAddress(localPart: 'me', domain: 'mine.example');

  StoredMessage add(
    String box,
    int uid, {
    required DateTime at,
    String? id,
    String? replyTo,
    List<String> references = const [],
    MailAddress from = maya,
    List<MailAddress> to = const [me],
    String? date,
    String? listId,
  }) {
    store.messages.upsertSummaries(boxes[box]!.id, [
      MessageSummary(
        uid: uid,
        receivedAt: at,
        sentAt: at,
        messageId: id,
        inReplyTo: replyTo,
        references: references,
        from: from,
        to: to,
        listId: listId,
        headers: {
          'date': [?date],
        },
      ),
    ]);
    return store.messages.byUid(boxes[box]!.id, uid)!;
  }

  group('recent dates', () {
    test('from the kept header, newest first, each message once', () {
      add(
        'INBOX',
        1,
        at: DateTime.utc(2026, 11, 1),
        id: 'a@x',
        date: 'Sun, 1 Nov 2026 09:00:00 +0100',
      );
      add(
        'INBOX',
        2,
        at: DateTime.utc(2026, 11, 2),
        id: 'b@x',
        date: 'Mon, 2 Nov 2026 09:00:00 -0800',
      );
      // Gmail's copy of the same message.
      add(
        '[Gmail]/All Mail',
        9,
        at: DateTime.utc(2026, 11, 2),
        id: 'b@x',
        date: 'Mon, 2 Nov 2026 09:00:00 -0800',
      );
      // The user's own mail and drafts are not theirs.
      add(
        'Sent',
        1,
        at: DateTime.utc(2026, 11, 3),
        from: me,
        to: [maya],
        date: 'Tue, 3 Nov 2026 09:00:00 +0900',
      );
      final dates = mail.recentDates('MAYA@example.com');
      expect([for (final d in dates) d.offset.inHours], [-8, 1]);
    });

    test('from the start of a downloaded message when not kept', () {
      final m = add('INBOX', 1, at: DateTime.utc(2026, 11, 1));
      store.messages.saveBody(
        m.id,
        utf8.encode(
          'From: Maya <maya@example.com>\r\n'
          'Date: Sun, 1 Nov 2026 23:40:00 +0530\r\n'
          'Subject: Hi\r\n\r\nHello',
        ),
        searchableText: 'Hello',
      );
      add('INBOX', 2, at: DateTime.utc(2026, 11, 2)); // nothing to read
      expect(mail.recentDates('maya@example.com').single.offset.inMinutes, 330);
    });

    test('at most the limit', () {
      for (var i = 1; i <= 14; i++) {
        add(
          'INBOX',
          i,
          at: DateTime.utc(2026, 11, i),
          id: '$i@x',
          date: 'Sun, 1 Nov 2026 09:00:00 +0100',
        );
      }
      expect(mail.recentDates('maya@example.com', limit: 10), hasLength(10));
    });
  });

  group('reply delays', () {
    test('from the user\'s message to their answer, by In-Reply-To', () {
      add(
        'Sent',
        1,
        at: DateTime.utc(2026, 11, 1, 9),
        id: 's1@me',
        from: me,
        to: [maya],
      );
      add(
        'INBOX',
        1,
        at: DateTime.utc(2026, 11, 1, 11),
        id: 'r1@x',
        replyTo: 's1@me',
      );
      // The same answer in All Mail counts once.
      add(
        '[Gmail]/All Mail',
        5,
        at: DateTime.utc(2026, 11, 1, 11),
        id: 'r1@x',
        replyTo: 's1@me',
      );
      // An answer to someone else's message doesn't count.
      add('INBOX', 2, at: DateTime.utc(2026, 11, 2), id: 'o@x');
      add(
        'INBOX',
        3,
        at: DateTime.utc(2026, 11, 2, 1),
        id: 'r2@x',
        replyTo: 'o@x',
      );
      expect(mail.replyDelays('maya@example.com'), [const Duration(hours: 2)]);
    });

    test('by References when there is no In-Reply-To: the newest before', () {
      add(
        'Sent',
        1,
        at: DateTime.utc(2026, 11, 1, 9),
        id: 's1@me',
        from: me,
        to: [maya],
      );
      add(
        'Sent',
        2,
        at: DateTime.utc(2026, 11, 1, 12),
        id: 's2@me',
        from: me,
        to: [maya],
      );
      add(
        'INBOX',
        1,
        at: DateTime.utc(2026, 11, 1, 13),
        id: 'r@x',
        references: ['s1@me', 's2@me'],
      );
      expect(mail.replyDelays('maya@example.com'), [const Duration(hours: 1)]);
    });
  });

  test('knows: any stored message, but not a draft', () {
    add(
      'Drafts',
      1,
      at: DateTime.utc(2026, 11, 1),
      from: me,
      to: [const MailAddress(localPart: 'maya', domain: 'exmaple.com')],
    );
    expect(mail.knows('maya@exmaple.com'), isFalse);
    add('INBOX', 1, at: DateTime.utc(2026, 11, 1));
    expect(mail.knows('Maya@Example.com'), isTrue);
  });

  test('a list is the address its List-Id names', () {
    const list = MailAddress(localPart: 'dev', domain: 'lists.example.org');
    add(
      'INBOX',
      1,
      at: DateTime.utc(2026, 11, 1),
      to: [
        list,
        const MailAddress(localPart: 'sam', domain: 'x.example'),
      ],
      listId: 'dev.lists.example.org',
    );
    expect(mail.isList('dev@lists.example.org'), isTrue);
    // A member who posts there, and others on the same message, are not.
    expect(mail.isList('maya@example.com'), isFalse);
    expect(mail.isList('sam@x.example'), isFalse);
  });

  test('the name they sign with', () {
    add('INBOX', 1, at: DateTime.utc(2026, 11, 1));
    expect(mail.nameOf('maya@example.com'), 'Maya Lin');
    expect(mail.nameOf('nobody@example.com'), isNull);
  });
}
