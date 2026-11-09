// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

MailAddress _address(String a, [String? name]) => MailAddress(
  displayName: name,
  localPart: a.split('@').first,
  domain: a.split('@').last,
);

/// Monday 2 November 2026, 10:00 UTC: Tan asks a builder for a quote.
final sentAt = DateTime.utc(2026, 11, 2, 10);

void main() {
  late Directory directory;
  late MailStore store;
  late Account account;
  late StoredMailbox inbox, sent, archive, junk;
  late FollowUpReminders followUps;
  var uid = 100;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('follow_ups');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
    account = store.accounts.add(
      NewAccount(
        email: 'tan.wei@citusmail.test',
        username: 'tan',
        imap: ServerSettings(
          host: 'h.example',
          port: 993,
          security: ConnectionSecurity.implicitTls,
        ),
        smtp: ServerSettings(
          host: 'h.example',
          port: 465,
          security: ConnectionSecurity.implicitTls,
        ),
      ),
    );
    final boxes = store.mailboxes.replaceAll(account.id, [
      ImapMailboxInfo(
        encodedName: 'INBOX',
        delimiter: '/',
        attributes: const {},
      ),
      ImapMailboxInfo(
        encodedName: 'Sent',
        delimiter: '/',
        attributes: const {r'\Sent'},
      ),
      ImapMailboxInfo(
        encodedName: 'Archive',
        delimiter: '/',
        attributes: const {r'\Archive'},
      ),
      ImapMailboxInfo(
        encodedName: 'Junk',
        delimiter: '/',
        attributes: const {r'\Junk'},
      ),
    ]);
    for (final b in boxes) {
      store.mailboxes.saveSyncState(
        b.id,
        const MailboxSyncState(uidValidity: 7),
      );
    }
    StoredMailbox box(String name) =>
        boxes.firstWhere((b) => b.encodedName == name);
    inbox = box('INBOX');
    sent = box('Sent');
    archive = box('Archive');
    junk = box('Junk');
    followUps = FollowUpReminders(store);
    // The sent message, as synced from the Sent folder.
    store.messages.upsertSummaries(sent.id, [
      MessageSummary(
        uid: 1,
        receivedAt: sentAt,
        sentAt: sentAt,
        subject: 'Quote for the kitchen',
        from: _address('tan.wei@citusmail.test', 'Tan Wei'),
        to: [_address('ana@buildright.example', 'Ana Costa')],
        cc: [_address('office@buildright.example')],
        messageId: 'quote.kitchen@citusmail.test',
        flags: MessageFlags.fromImap([r'\Seen']),
      ),
    ]);
  });

  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  StoredMessage sentMessage() => store.messages.byUid(sent.id, 1)!;

  FollowUp remindIn(Duration d) =>
      followUps.remind(followUps.forMessage(sentMessage(), sentAt.add(d)));

  void receive(
    String subject, {
    StoredMailbox? into,
    DateTime? at,
    String from = 'ana@buildright.example',
    String? inReplyTo,
    List<String> references = const [],
    Map<String, List<String>> headers = const {},
  }) => store.messages.upsertSummaries((into ?? inbox).id, [
    MessageSummary(
      uid: uid++,
      receivedAt: at ?? sentAt.add(const Duration(days: 1)),
      subject: subject,
      from: _address(from),
      messageId: 'm$uid@elsewhere.example',
      inReplyTo: inReplyTo,
      references: references,
      headers: headers,
    ),
  ]);

  test('a follow-up from a sent message keeps who it went to', () {
    final f = remindIn(const Duration(days: 3));
    expect(f.subject, 'Quote for the kitchen');
    expect(f.accountId, account.id);
    expect(f.sentAt, sentAt);
    expect(f.due, DateTime.utc(2026, 11, 5, 10));
    expect(
      [for (final r in f.recipients) r.address],
      ['ana@buildright.example', 'office@buildright.example'],
    );
    expect(f.recipients.first.displayName, 'Ana Costa');
    // Kept in the settings store, read back the same.
    final read = FollowUpReminders(store).find('quote.kitchen@citusmail.test')!;
    expect(read.due, f.due);
    expect(read.recipients, f.recipients);
    expect(followUps.sentCopy(read)?.id, sentMessage().id);
    expect(followUps.nextDue(), f.due);
  });

  test('the list is decoded again only when it changed', () {
    final first = remindIn(const Duration(days: 3));
    final list = followUps.all();
    expect(followUps.all(), same(list), reason: 'nothing changed');
    expect(followUps.waiting().single.messageId, first.messageId);
    expect(() => list.add(first), throwsUnsupportedError);

    followUps.cancel(first.messageId);
    expect(followUps.all(), isEmpty);
    remindIn(const Duration(days: 4));
    expect(followUps.all(), isNot(same(list)));
    expect(followUps.all().single.due, isNot(list.single.due));
  });

  test('comes back once when its time comes without a reply', () {
    remindIn(const Duration(days: 3));
    expect(followUps.check(now: DateTime.utc(2026, 11, 4, 9)).isEmpty, isTrue);
    expect(followUps.waiting(), hasLength(1));

    final result = followUps.check(now: DateTime.utc(2026, 11, 5, 10, 1));
    expect(result.returned.single.messageId, 'quote.kitchen@citusmail.test');
    expect(result.returned.single.returnedAt, DateTime.utc(2026, 11, 5, 10));
    expect(followUps.waiting(), isEmpty);
    expect(followUps.returned(), hasLength(1));
    expect(followUps.nextDue(), isNull);
    // Once only: another check (the background job) finds nothing new.
    expect(followUps.check(now: DateTime.utc(2026, 11, 5, 11)).isEmpty, isTrue);

    // Notified once.
    expect(followUps.claimUnnotified(), hasLength(1));
    expect(followUps.claimUnnotified(), isEmpty);

    // "Done": gone.
    expect(followUps.cancel('quote.kitchen@citusmail.test'), isNotNull);
    expect(followUps.all(), isEmpty);
  });

  test('a reply ends it quietly, also after it came back', () {
    remindIn(const Duration(days: 3));
    receive(
      'RE: Quote for the kitchen',
      inReplyTo: 'quote.kitchen@citusmail.test',
      references: ['quote.kitchen@citusmail.test'],
    );
    final result = followUps.check(now: DateTime.utc(2026, 11, 3));
    expect(result.returned, isEmpty);
    expect(result.answered.single.messageId, 'quote.kitchen@citusmail.test');
    expect(followUps.all(), isEmpty);

    // Back with "No reply yet", then Ana answers: it goes.
    remindIn(const Duration(days: 3));
    store.messages.removeUids(inbox.id, store.messages.uids(inbox.id));
    followUps.check(now: DateTime.utc(2026, 11, 6));
    expect(followUps.returned(), hasLength(1));
    receive(
      'Re: Quote for the kitchen',
      at: DateTime.utc(2026, 11, 6, 8),
      inReplyTo: 'quote.kitchen@citusmail.test',
    );
    expect(
      followUps.check(now: DateTime.utc(2026, 11, 6, 9)).answered,
      hasLength(1),
    );
    expect(followUps.all(), isEmpty);
  });

  test('an answer filed in another folder counts; one in Junk does not', () {
    remindIn(const Duration(days: 3));
    receive(
      'Re: Quote for the kitchen',
      into: junk,
      inReplyTo: 'quote.kitchen@citusmail.test',
    );
    expect(followUps.check(now: DateTime.utc(2026, 11, 3)).isEmpty, isTrue);
    receive(
      'Re: Quote for the kitchen',
      into: archive,
      from: 'office@buildright.example',
      references: ['quote.kitchen@citusmail.test'],
    );
    expect(
      followUps.check(now: DateTime.utc(2026, 11, 3)).answered,
      hasLength(1),
    );
  });

  test('out-of-office, your own nudge and other mail do not end it', () {
    remindIn(const Duration(days: 3));
    // Ana is away.
    receive(
      'Automatic reply: Quote for the kitchen',
      inReplyTo: 'quote.kitchen@citusmail.test',
      headers: {
        'auto-submitted': ['auto-replied'],
      },
    );
    // An older auto-responder, without Auto-Submitted.
    receive(
      'Re: Quote for the kitchen',
      from: 'office@buildright.example',
      inReplyTo: 'quote.kitchen@citusmail.test',
      headers: {
        'x-autoreply': ['yes'],
      },
    );
    // Tan nudges, copying himself.
    receive(
      'Re: Quote for the kitchen',
      from: 'tan.wei@citusmail.test',
      inReplyTo: 'quote.kitchen@citusmail.test',
    );
    // Ana writes about something else.
    receive('Invoice 0041 for the bathroom tiles');
    receive(
      'Re: Bathroom tiles',
      inReplyTo: 'tiles@citusmail.test',
      references: ['tiles@citusmail.test'],
    );
    // A forum digest with the same words.
    receive(
      'Re: Quote for the kitchen - is 9k too much?',
      from: 'renovators@lists.diy.example',
      headers: {
        'list-id': ['<renovators.lists.diy.example>'],
      },
    );
    // A reply that arrived before Tan's message was sent.
    receive(
      'Re: Quote for the kitchen',
      at: sentAt.subtract(const Duration(minutes: 5)),
      inReplyTo: 'quote.kitchen@citusmail.test',
    );
    final result = followUps.check(now: DateTime.utc(2026, 11, 5, 11));
    expect(result.answered, isEmpty);
    expect(result.returned, hasLength(1));
  });

  test('cancel, undo, and moving to a new Message-ID', () {
    final f = remindIn(const Duration(days: 1));
    final ended = followUps.cancel(f.messageId)!;
    expect(followUps.all(), isEmpty);
    followUps.restore(ended);
    expect(followUps.find(f.messageId)?.due, f.due);

    // "Send later" sent it under a new Message-ID, two hours later.
    followUps.move(
      f.messageId,
      'new-id@citusmail.test',
      shift: const Duration(hours: 2),
    );
    expect(followUps.find(f.messageId), isNull);
    final moved = followUps.find('new-id@citusmail.test')!;
    expect(moved.due, f.due.add(const Duration(hours: 2)));
    expect(moved.sentAt, sentAt.add(const Duration(hours: 2)));

    // Setting it again starts over (no longer returned).
    followUps.check(now: DateTime.utc(2026, 11, 10));
    expect(followUps.returned(), hasLength(1));
    followUps.remind(moved.copyWith(due: DateTime.utc(2026, 11, 12)));
    expect(followUps.waiting(), hasLength(1));
    expect(followUps.returned(), isEmpty);
  });

  test('a damaged stored list reads as empty', () {
    store.settings.write('followUps.list', '{not json');
    expect(followUps.all(), isEmpty);
    store.settings.write('followUps.list', '[{"id": 3}, "x"]');
    expect(followUps.all(), isEmpty);
  });
}
