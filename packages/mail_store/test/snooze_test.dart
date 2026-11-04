// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

import 'support/temp_store.dart';

ImapMailboxInfo folder(String name, {String? use}) => ImapMailboxInfo(
  encodedName: name,
  delimiter: '.',
  attributes: {if (use != null) '\\$use'},
);

MailAddress address(String a, [String? name]) => MailAddress(
  displayName: name,
  localPart: a.split('@').first,
  domain: a.split('@').last,
);

/// "Now" in these tests: a Wednesday morning.
final now = DateTime.utc(2026, 11, 4, 9);

void main() {
  late TempStore temp;
  late MailStore store;
  late Account alice;
  late StoredMailbox inbox, archive;
  var uid = 0;

  setUp(() {
    temp = TempStore.create();
    store = temp.store;
    alice = temp.addAccount();
    final boxes = store.mailboxes.replaceAll(alice.id, [
      folder('INBOX'),
      folder('Sent', use: 'Sent'),
      folder('Archive', use: 'Archive'),
    ]);
    inbox = boxes.firstWhere((b) => b.isInbox);
    archive = boxes.firstWhere((b) => b.specialUse == SpecialUse.archive);
    uid = 0;
  });
  tearDown(() => temp.dispose());

  /// A message arriving in [box] (the inbox) [hours] before [now]
  /// (negative: after).
  StoredMessage mail(
    String subject, {
    String from = 'maria@studio.example',
    double hours = 1,
    StoredMailbox? box,
    String? messageId,
    String? inReplyTo,
    List<String> references = const [],
    MessageFlags flags = MessageFlags.none,
    MessageCategory category = MessageCategory.general,
  }) {
    final mailbox = box ?? inbox;
    final u = ++uid;
    store.messages.upsertSummaries(mailbox.id, [
      MessageSummary(
        uid: u,
        subject: subject,
        receivedAt: now.subtract(Duration(minutes: (hours * 60).round())),
        from: address(from, 'Maria Lopez'),
        messageId: messageId ?? 'm$u@studio.example',
        inReplyTo: inReplyTo,
        references: references,
        flags: flags,
        category: category,
      ),
    ]);
    return store.messages.byUid(mailbox.id, u)!;
  }

  StoredMessage fresh(StoredMessage m) => store.messages.byId(m.id)!;
  List<String?> inboxList() => [
    for (final m in store.messages.list(const MessageQuery.inbox())) m.subject,
  ];
  List<String?> general() => [
    for (final m in store.messages.list(
      const MessageQuery.smart(SmartSection.general),
    ))
      m.subject,
  ];

  group('snoozing', () {
    test('hides the message from the inbox, its section and counts', () {
      mail('Lunch on Friday?', hours: 3);
      final draft = mail('Draft contract for review', hours: 2);
      mail('Photos from the weekend', hours: 1);
      expect(store.messages.sectionCounts()[SmartSection.general]!.unread, 3);

      store.snoozes.snooze(
        draft.messageId!,
        now.add(const Duration(days: 1)),
        now: now,
      );

      expect(fresh(draft).section, SmartSection.snoozed);
      expect(general(), ['Photos from the weekend', 'Lunch on Friday?']);
      expect(inboxList(), ['Photos from the weekend', 'Lunch on Friday?']);
      final counts = store.messages.sectionCounts();
      expect(counts[SmartSection.general]!.unread, 2);
      expect(counts[SmartSection.snoozed]!.unread, 1);
      expect(store.messages.unreadCounts()[inbox.id], 2);
      expect(store.messages.unreadCount(inbox.id), 2);
      expect(store.snoozes.count(), 1);
    });

    test('pinned mail is hidden too, also from the Pins list', () {
      final pinned = mail(
        'Passport renewal',
        flags: MessageFlags.fromImap([r'\Flagged']),
      );
      store.snoozes.snooze(pinned.messageId!, now.add(const Duration(days: 3)));
      expect(fresh(pinned).section, SmartSection.snoozed);
      expect(
        store.messages.list(const MessageQuery(flaggedOnly: true)),
        isEmpty,
      );
    });

    test('only the inbox copy is hidden; other folders keep theirs', () {
      final inInbox = mail('Board minutes', messageId: 'minutes@club.example');
      final copy = mail(
        'Board minutes',
        box: archive,
        messageId: 'minutes@club.example',
      );
      store.snoozes.snooze('minutes@club.example', now.add(Duration(hours: 5)));
      expect(fresh(inInbox).section, SmartSection.snoozed);
      expect(fresh(copy).section, isNot(SmartSection.snoozed));
      expect(
        store.messages.list(MessageQuery(mailboxIds: [archive.id])),
        hasLength(1),
      );
    });

    test('the Snoozed list shows each with when it comes back, soonest '
        'first', () {
      final a = mail('Quarterly report');
      final b = mail('Gym membership renewal');
      store.snoozes.snooze(a.messageId!, now.add(const Duration(days: 2)));
      store.snoozes.snooze(b.messageId!, now.add(const Duration(hours: 4)));
      final list = store.snoozes.list();
      expect(
        [for (final s in list) s.message.subject],
        ['Gym membership renewal', 'Quarterly report'],
      );
      expect(list.first.snooze.until, now.add(const Duration(hours: 4)));
      expect(store.snoozes.nextDue(), now.add(const Duration(hours: 4)));
      expect(store.snoozes.list(accountIds: [alice.id + 1]), isEmpty);
    });

    test('changing the time keeps one snooze', () {
      final m = mail('Dentist appointment');
      store.snoozes.snooze(m.messageId!, now.add(const Duration(hours: 3)));
      store.snoozes.snooze(m.messageId!, now.add(const Duration(days: 4)));
      expect(store.snoozes.all(), hasLength(1));
      expect(
        store.snoozes.all().single.until,
        now.add(const Duration(days: 4)),
      );
    });

    test('a Message-ID is needed', () {
      expect(
        () => store.snoozes.snooze('', now.add(const Duration(hours: 1))),
        throwsArgumentError,
      );
    });

    test('a resync keeps the message snoozed (and back-from-snooze mail '
        'where it came back)', () {
      final m = mail('Invoice 2291');
      store.snoozes.snooze(m.messageId!, now.add(const Duration(hours: 1)));
      // The same message synced again (flags or summary refresh).
      store.messages.upsertSummaries(inbox.id, [
        MessageSummary(
          uid: m.uid,
          subject: 'Invoice 2291',
          receivedAt: m.receivedAt,
          from: m.from,
          messageId: m.messageId,
        ),
      ]);
      expect(fresh(m).section, SmartSection.snoozed);
      store.snoozes.wake(now: now.add(const Duration(hours: 2)));
      store.messages.upsertSummaries(inbox.id, [
        MessageSummary(
          uid: m.uid,
          subject: 'Invoice 2291',
          receivedAt: m.receivedAt,
          from: m.from,
          messageId: m.messageId,
        ),
      ]);
      expect(fresh(m).listedAt, now.add(const Duration(hours: 1)));
    });
  });

  group('waking', () {
    test('nothing comes back before its time', () {
      final m = mail('Concert tickets');
      store.snoozes.snooze(m.messageId!, now.add(const Duration(hours: 3)));
      expect(
        store.snoozes.wake(now: now.add(const Duration(hours: 2))),
        isEmpty,
      );
      expect(fresh(m).section, SmartSection.snoozed);
    });

    test('a due message returns to the top, listed at its return time', () {
      final old = mail('Old newsletter-free note', hours: 48);
      mail('Yesterday evening', hours: 14);
      mail('This morning', hours: 1);
      final until = now.add(const Duration(hours: 2));
      store.snoozes.snooze(old.messageId!, until, now: now);
      // Mail arriving while it is snoozed.
      mail('Arrived while snoozed', hours: -1);

      final woken = store.snoozes.wake(now: now.add(const Duration(hours: 3)));

      expect(woken, hasLength(1));
      expect(woken.single.reason, WakeReason.due);
      expect(woken.single.at, until);
      final back = fresh(old);
      expect(back.section, SmartSection.general);
      expect(back.listedAt, until);
      expect(back.receivedAt, old.receivedAt);
      expect(back.backFromSnooze, isTrue);
      expect(inboxList(), [
        'Old newsletter-free note',
        'Arrived while snoozed',
        'This morning',
        'Yesterday evening',
      ]);
      expect(general().first, 'Old newsletter-free note');
      expect(store.snoozes.all(), isEmpty);
      // Paging continues after it correctly.
      final first = store.messages.list(const MessageQuery.inbox(limit: 1));
      expect(
        store.messages
            .list(MessageQuery.inbox(before: first.single, limit: 10))
            .map((m) => m.subject),
        ['Arrived while snoozed', 'This morning', 'Yesterday evening'],
      );
    });

    test('several due come back in return-time order, each once', () {
      final a = mail('Car insurance quote');
      final b = mail('Book club pick');
      store.snoozes.snooze(a.messageId!, now.add(const Duration(hours: 2)));
      store.snoozes.snooze(b.messageId!, now.add(const Duration(hours: 1)));
      final woken = store.snoozes.wake(now: now.add(const Duration(days: 1)));
      expect(
        [for (final w in woken) w.message.subject],
        ['Book club pick', 'Car insurance quote'],
      );
      expect(
        store.snoozes.wake(now: now.add(const Duration(days: 2))),
        isEmpty,
      );
      expect(inboxList().take(2), ['Car insurance quote', 'Book club pick']);
    });

    test('a reply in the conversation brings it back early', () {
      final question = mail(
        'Venue for the offsite?',
        messageId: 'offsite-1@studio.example',
      );
      store.snoozes.snooze(
        question.messageId!,
        now.add(const Duration(days: 3)),
        now: now,
      );
      // An unrelated message, and a reply that came before the snooze.
      mail('Unrelated', hours: -1);
      mail(
        'Re: Venue for the offsite?',
        hours: 0.5,
        inReplyTo: 'offsite-1@studio.example',
      );
      expect(
        store.snoozes.wake(now: now.add(const Duration(hours: 1))),
        isEmpty,
      );

      mail(
        'Re: Venue for the offsite?',
        hours: -2,
        from: 'tom@studio.example',
        inReplyTo: 'offsite-0@studio.example',
        references: ['offsite-1@studio.example'],
      );
      final at = now.add(const Duration(hours: 3));
      final woken = store.snoozes.wake(now: at);
      expect(woken.single.reason, WakeReason.reply);
      expect(woken.single.at, at);
      expect(fresh(question).section, SmartSection.general);
      expect(fresh(question).listedAt, at);
    });

    test('a reply to the same conversation (a sibling) counts too', () {
      final answer = mail(
        'Re: Holiday rota',
        messageId: 'rota-2@studio.example',
        inReplyTo: 'rota-1@studio.example',
        references: ['rota-1@studio.example'],
      );
      store.snoozes.snooze(
        answer.messageId!,
        now.add(const Duration(days: 1)),
        now: now,
      );
      mail(
        'Re: Holiday rota',
        hours: -1,
        from: 'sam@studio.example',
        messageId: 'rota-3@studio.example',
        inReplyTo: 'rota-1@studio.example',
        references: ['rota-1@studio.example'],
      );
      expect(
        store.snoozes.wake(now: now.add(const Duration(hours: 2))),
        hasLength(1),
      );
    });

    test('a snooze whose message is gone ends quietly', () {
      store.snoozes.snooze('gone@example.com', now.add(Duration(hours: 1)));
      expect(
        store.snoozes.wake(now: now.add(const Duration(hours: 2))),
        isEmpty,
      );
      expect(store.snoozes.all(), isEmpty);
    });

    test('the end is remembered for other devices', () {
      final m = mail('Flight check-in');
      store.snoozes.snooze(m.messageId!, now.add(const Duration(hours: 1)));
      store.snoozes.wake(now: now.add(const Duration(hours: 2)));
      expect(store.appDataSync.tombstones().map((t) => (t.key, t.kind)), [
        (AppDataKeys.snooze(m.messageId!), 'snooze'),
      ]);
    });
  });

  group('cancelling', () {
    test('unsnooze puts it back where it was, not as new', () {
      final m = mail('Tax return documents', hours: 30);
      mail('Newer', hours: 1);
      store.snoozes.snooze(m.messageId!, now.add(const Duration(days: 1)));
      final ended = store.snoozes.cancel(m.messageId!);
      expect(ended, isNotNull);
      expect(fresh(m).section, SmartSection.general);
      expect(fresh(m).backFromSnooze, isFalse);
      expect(inboxList(), ['Newer', 'Tax return documents']);
      expect(store.appDataSync.tombstones(), hasLength(1));
    });

    test('moving or deleting a snoozed message cancels it; Undo puts the '
        'snooze back', () {
      final m = mail('Lease renewal');
      final other = mail('Not snoozed');
      store.snoozes.snooze(m.messageId!, now.add(const Duration(days: 1)));
      final ended = store.snoozes.cancelFor([fresh(m), fresh(other)]);
      expect(ended.map((s) => s.messageId), [m.messageId]);
      expect(store.snoozes.all(), isEmpty);
      store.snoozes.restore(ended.single);
      expect(store.snoozes.all(), ended);
      expect(fresh(m).section, SmartSection.snoozed);
    });
  });

  test('lists stay index reads', () {
    final plan = store.messages
        .debugQueryPlan(const MessageQuery.inbox(), mailboxId: inbox.id)
        .join(' | ');
    expect(plan, contains('USING INDEX'), reason: plan);
    expect(plan, isNot(contains('TEMP B-TREE')), reason: plan);
  });
}
