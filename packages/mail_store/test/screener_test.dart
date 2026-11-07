// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_store/src/repository/section_sql.dart';
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

/// The day the Screener is turned on in these tests.
final turnedOn = DateTime.utc(2026, 10, 10, 9);

void main() {
  late TempStore temp;
  late MailStore store;
  late Account alice;
  late StoredMailbox inbox, sent, junk, trash, archive;
  var uid = 0;

  setUp(() {
    temp = TempStore.create();
    store = temp.store;
    alice = temp.addAccount();
    final boxes = store.mailboxes.replaceAll(alice.id, [
      folder('INBOX'),
      folder('Sent', use: 'Sent'),
      folder('Junk', use: 'Junk'),
      folder('Trash', use: 'Trash'),
      folder('Archive', use: 'Archive'),
    ]);
    StoredMailbox use(SpecialUse u) =>
        boxes.firstWhere((b) => b.specialUse == u);
    inbox = boxes.firstWhere((b) => b.isInbox);
    sent = use(SpecialUse.sent);
    junk = use(SpecialUse.junk);
    trash = use(SpecialUse.trash);
    archive = use(SpecialUse.archive);
    uid = 0;
  });
  tearDown(() => temp.dispose());

  /// A message from [from] arriving in [box] (the inbox), [days] after
  /// the Screener is turned on (negative: before).
  StoredMessage mail(
    String from,
    String subject, {
    double days = 1,
    StoredMailbox? box,
    String? name,
    MessageCategory category = MessageCategory.general,
    MessageFlags flags = MessageFlags.none,
    String? messageId,
    String? inReplyTo,
    List<String> references = const [],
    String? snippet,
  }) {
    final mailbox = box ?? inbox;
    final u = ++uid;
    store.messages.upsertSummaries(mailbox.id, [
      MessageSummary(
        uid: u,
        subject: subject,
        receivedAt: turnedOn.add(Duration(minutes: (days * 24 * 60).round())),
        from: address(from, name),
        category: category,
        flags: flags,
        messageId: messageId ?? '<$u.$from>',
        inReplyTo: inReplyTo,
        references: references,
        snippet: snippet,
      ),
    ]);
    return store.messages.byUid(mailbox.id, u)!;
  }

  /// Something the user sent to [to].
  void wrote(String to, {String? messageId, double days = -30}) {
    final u = ++uid;
    store.messages.upsertSummaries(sent.id, [
      MessageSummary(
        uid: u,
        subject: 'From Alice',
        receivedAt: turnedOn.add(Duration(days: days.round())),
        from: address('alice@citusmail.test'),
        to: [address(to)],
        messageId: messageId ?? '<sent$u@citusmail.test>',
      ),
    ]);
  }

  SmartSection sectionOf(StoredMessage m) => store.messages.byId(m.id)!.section;

  void turnOn() => store.screener.enable(now: turnedOn);

  group('turning it on', () {
    test('is off by default: a new sender goes to the inbox', () {
      expect(store.screener.enabled, isFalse);
      final m = mail('ana@studio.example', 'Portfolio review?');
      expect(sectionOf(m), SmartSection.general);
      expect(store.screener.waitingCount(), 0);
    });

    test('every sender with mail already counts as let in', () {
      // Mail from before, and one that arrived just before turning on.
      final old = mail('bob@friends.example', 'Dinner', days: -40);
      final last = mail('carol@friends.example', 'Hi', days: -0.001);
      final news = mail(
        'news@shop.example',
        'Autumn sale',
        days: -3,
        category: MessageCategory.newsletters,
      );
      turnOn();
      expect(store.screener.enabled, isTrue);
      expect(store.screener.since, turnedOn);
      expect(sectionOf(old), SmartSection.general);
      expect(sectionOf(last), SmartSection.general);
      expect(sectionOf(news), SmartSection.newsletters);
      expect(store.screener.all(), isEmpty, reason: 'no list of history');

      // Their new mail too.
      expect(
        sectionOf(mail('bob@friends.example', 'Next week?')),
        SmartSection.general,
      );
      expect(
        sectionOf(mail('NEWS@shop.example', 'Winter sale')),
        SmartSection.general,
        reason: 'the same address, in another case',
      );
      expect(store.screener.waitingCount(), 0);
    });

    test('mail newer than the clock still counts as history', () {
      // The server's clock is ahead of the device's.
      final ahead = mail('dan@x.example', 'Ahead', days: 0.01);
      turnOn();
      expect(sectionOf(ahead), SmartSection.general);
      expect(store.screener.since!.isAfter(turnedOn), isTrue);
    });
  });

  group('first-time senders', () {
    setUp(turnOn);

    test('wait in the Screener, every email of theirs', () {
      final first = mail(
        'ana@studio.example',
        'Portfolio review?',
        name: 'Ana Ruiz',
        snippet: 'Hi! I saw your talk last week and wondered…',
      );
      final second = mail('ana@studio.example', 'Following up', days: 2);
      expect(sectionOf(first), SmartSection.screener);
      expect(sectionOf(second), SmartSection.screener);
      expect(
        store.messages.list(const MessageQuery.smart(SmartSection.general)),
        isEmpty,
      );

      final waiting = store.screener.waiting();
      expect(waiting, hasLength(1));
      expect(waiting.single.address, 'ana@studio.example');
      expect(waiting.single.name, 'Ana Ruiz');
      expect(waiting.single.first.subject, 'Portfolio review?');
      expect(waiting.single.messages, hasLength(2));
      expect(waiting.single.unread, 2);
      expect(store.screener.waitingCount(), 1);
      expect(store.screener.waitingCount(accountIds: [alice.id + 1]), 0);
    });

    test('the most recent sender is listed first', () {
      mail('ana@studio.example', 'One', days: 1);
      mail('ben@shop.example', 'Two', days: 2);
      expect(store.screener.waiting().map((w) => w.address), [
        'ben@shop.example',
        'ana@studio.example',
      ]);
      expect(store.screener.waitingCount(), 2);
    });

    test('earlier mail in Junk or Trash does not make a sender known', () {
      mail('spam@x.example', 'Old junk', days: -10, box: junk);
      mail('deleted@x.example', 'Old deleted', days: -10, box: trash);
      mail('kept@x.example', 'Old archived', days: -10, box: archive);
      expect(sectionOf(mail('spam@x.example', 'Again')), SmartSection.screener);
      expect(
        sectionOf(mail('deleted@x.example', 'Again')),
        SmartSection.screener,
      );
      expect(sectionOf(mail('kept@x.example', 'Again')), SmartSection.general);
    });

    test('someone the user wrote to is never screened', () {
      wrote('Recruiter@Agency.example');
      final m = mail('recruiter@agency.example', 'Thanks for your reply');
      expect(sectionOf(m), SmartSection.important);
    });

    test('writing to a waiting sender lets them in', () {
      final m = mail('ana@studio.example', 'Portfolio review?');
      expect(sectionOf(m), SmartSection.screener);
      wrote('ana@studio.example', days: 2);
      expect(sectionOf(m), SmartSection.important);
      expect(store.screener.waitingCount(), 0);
    });

    test('the user\'s own addresses are never screened', () {
      final m = mail('ALICE@citusmail.test', 'Note to self');
      expect(sectionOf(m), SmartSection.general);
    });

    test('replies to the user\'s own messages are never screened', () {
      wrote('list@lists.example', messageId: '<q1@citusmail.test>');
      final direct = mail(
        'new.person@lists.example',
        'Re: Question about the release',
        inReplyTo: '<q1@citusmail.test>',
        references: ['<q1@citusmail.test>'],
      );
      // Deeper in the thread: someone replied to a reply to Alice.
      final deeper = mail(
        'other.person@lists.example',
        'Re: Question about the release',
        inReplyTo: '<r7@lists.example>',
        references: ['<q1@citusmail.test>', '<r7@lists.example>'],
      );
      // A thread Alice is not part of.
      final stranger = mail(
        'third.person@lists.example',
        'Re: Something else',
        inReplyTo: '<z9@lists.example>',
        references: ['<z8@lists.example>', '<z9@lists.example>'],
      );
      expect(sectionOf(direct), SmartSection.important);
      expect(sectionOf(deeper), SmartSection.general);
      expect(sectionOf(stranger), SmartSection.screener);
    });

    test('a reply waiting before the user\'s message synced is let out', () {
      final reply = mail(
        'new.person@lists.example',
        'Re: Question',
        inReplyTo: '<r7@lists.example>',
        references: ['<q2@citusmail.test>', '<r7@lists.example>'],
      );
      expect(sectionOf(reply), SmartSection.screener);
      wrote('list@lists.example', messageId: '<q2@citusmail.test>');
      expect(sectionOf(reply), SmartSection.general);
    });

    test('verification codes and pinned mail are never screened', () {
      final code = mail(
        'no-reply@accounts.example',
        'Your sign-in code is 482913',
        category: MessageCategory.codes,
      );
      final pinned = mail(
        'ana@studio.example',
        'Pinned',
        flags: MessageFlags.fromImap([r'\Flagged']),
      );
      expect(sectionOf(code), SmartSection.codes);
      expect(sectionOf(pinned), SmartSection.pinned);
      expect(store.screener.waitingCount(), 0);
    });

    test('blocked senders keep their own behaviour', () {
      store.blocks.block(BlockKind.domain, 'spam.example');
      final m = mail('win@mail.spam.example', 'You won');
      expect(sectionOf(m), SmartSection.general);
      expect(store.screener.waitingCount(), 0);
    });

    test('a reply still counts as one after a move is undone', () {
      final reply = mail(
        'new.person@lists.example',
        'Re: Question',
        inReplyTo: '<r7@lists.example>',
        references: ['<q3@citusmail.test>', '<r7@lists.example>'],
      );
      expect(sectionOf(reply), SmartSection.screener);
      final snapshot = store.messages.snapshot([reply.id]);
      store.messages.removeUids(inbox.id, [reply.uid]);
      final back = store.messages.restore(snapshot)[reply.id]!;
      wrote('list@lists.example', messageId: '<q3@citusmail.test>');
      expect(store.messages.byId(back)!.section, SmartSection.general);
    });

    test('deciding a section probes indexes, never whole tables', () {
      store.screener.decide(
        ScreenerKind.domain,
        'shop.example',
        ScreenerDecision.screenOut,
      );
      store.blocks.block(BlockKind.domain, 'spam.example');
      final plan = store.database
          .select(
            'EXPLAIN QUERY PLAN UPDATE messages SET section = ${SectionSql.expression} WHERE id = ?',
            [1],
          )
          .map((row) => row['detail'] as String)
          .join(' | ');
      // Decisions and blocks: index probes of (kind, value); References:
      // the message's own rows, then the Message-ID index.
      expect(plan, isNot(contains('SCAN d')), reason: plan);
      expect(plan, isNot(contains('SCAN bs')), reason: plan);
      expect(plan, isNot(contains('SCAN s')), reason: plan);
      expect(plan, contains('message_references'), reason: plan);
    });

    test('lists stay index reads with the Screener on', () {
      final plan = store.messages
          .debugQueryPlan(
            const MessageQuery.smart(SmartSection.screener),
            mailboxId: inbox.id,
          )
          .join(' | ');
      expect(plan, contains('messages_by_section'), reason: plan);
    });
  });

  group('decisions', () {
    setUp(turnOn);

    test('Let in: their mail and new mail go to the inbox', () {
      final m = mail('ana@studio.example', 'Portfolio review?');
      final decided = store.screener.decide(
        ScreenerKind.address,
        'Ana@Studio.example',
        ScreenerDecision.letIn,
        now: turnedOn.add(const Duration(days: 2)),
      );
      expect(decided.value, 'ana@studio.example');
      expect(sectionOf(m), SmartSection.general);
      expect(
        sectionOf(mail('ana@studio.example', 'Thanks!', days: 3)),
        SmartSection.general,
      );
      expect(store.screener.waitingCount(), 0);
      expect(store.screener.matching('ANA@studio.example')?.id, decided.id);
    });

    test('Screen out: Newsletters, or Notifications when chosen', () {
      final m = mail('promo@deals.example', 'Exclusive offer');
      final out = store.screener.decide(
        ScreenerKind.address,
        'promo@deals.example',
        ScreenerDecision.screenOut,
      );
      expect(out.decision, ScreenerDecision.screenOut);
      expect(sectionOf(m), SmartSection.newsletters);
      final next = mail('promo@deals.example', 'Last chance', days: 3);
      expect(sectionOf(next), SmartSection.newsletters);

      store.screener.outPlace = ScreenOutPlace.notifications;
      expect(sectionOf(m), SmartSection.notifications);
      expect(sectionOf(next), SmartSection.notifications);
      store.screener.outPlace = ScreenOutPlace.archive;
      expect(store.screener.outPlace, ScreenOutPlace.archive);
      expect(sectionOf(m), SmartSection.newsletters);
      expect(store.screener.screenedOutIds(inbox.id, turnedOn), [
        next.id,
        m.id,
      ]);
      expect(
        store.screener.screenedOutIds(
          inbox.id,
          turnedOn.add(const Duration(days: 2)),
        ),
        [next.id],
      );
    });

    test('a screened-out sender\'s codes and replies still come in', () {
      wrote('promo@deals.example', messageId: '<ask@citusmail.test>', days: 2);
      // (Writing to them would let them in; decide afterwards.)
      store.screener.decide(
        ScreenerKind.address,
        'promo@deals.example',
        ScreenerDecision.screenOut,
      );
      final reply = mail(
        'promo@deals.example',
        'Re: Cancel my order',
        inReplyTo: '<ask@citusmail.test>',
      );
      final code = mail(
        'promo@deals.example',
        'Your code: 1234',
        category: MessageCategory.codes,
      );
      expect(sectionOf(reply), SmartSection.important);
      expect(sectionOf(code), SmartSection.codes);
      expect(store.screener.screenedOutIds(inbox.id, turnedOn), isEmpty);
    });

    test('the whole domain, subdomains too; an address decision wins', () {
      final a = mail('hr@acme.example', 'Welcome aboard');
      final b = mail('it@eu.acme.example', 'Your laptop');
      final c = mail('ceo@acme.example.org', 'Not the same company');
      final d = mail('noreply@acme.example', 'Weekly digest');
      store.screener.decide(
        ScreenerKind.domain,
        'acme.example',
        ScreenerDecision.letIn,
      );
      store.screener.decide(
        ScreenerKind.address,
        'noreply@acme.example',
        ScreenerDecision.screenOut,
      );
      expect(sectionOf(a), SmartSection.general);
      expect(sectionOf(b), SmartSection.general);
      expect(sectionOf(c), SmartSection.screener);
      expect(sectionOf(d), SmartSection.newsletters);
      expect(
        store.screener.matching('noreply@acme.example')!.kind,
        ScreenerKind.address,
      );
      expect(
        store.screener.matching('x@eu.acme.example')!.kind,
        ScreenerKind.domain,
      );
      expect(store.screener.matching('x@acme.example.org'), isNull);
    });

    test('Undo puts the sender back where they were', () {
      final m = mail('ana@studio.example', 'Portfolio review?');
      final letIn = store.screener.decide(
        ScreenerKind.address,
        'ana@studio.example',
        ScreenerDecision.letIn,
        now: turnedOn.add(const Duration(days: 2)),
      );
      store.screener.restore(letIn, null);
      expect(sectionOf(m), SmartSection.screener);
      expect(store.screener.all(), isEmpty);
      // The removal is remembered for the user's other devices.
      expect(
        store.appDataSync.tombstones().map((t) => (t.key, t.kind)),
        contains((
          AppDataKeys.screener(ScreenerKind.address, 'ana@studio.example'),
          'screener',
        )),
      );

      // Changing a decision, then undoing the change.
      final first = store.screener.decide(
        ScreenerKind.address,
        'ana@studio.example',
        ScreenerDecision.letIn,
        now: turnedOn.add(const Duration(days: 3)),
      );
      final changed = store.screener.decide(
        ScreenerKind.address,
        'ana@studio.example',
        ScreenerDecision.screenOut,
        now: turnedOn.add(const Duration(days: 4)),
      );
      expect(changed.id, first.id);
      expect(sectionOf(m), SmartSection.newsletters);
      store.screener.restore(changed, first);
      final back = store.screener.all().single;
      expect(back.decision, ScreenerDecision.letIn);
      expect(back.since, first.since);
      expect(sectionOf(m), SmartSection.general);
    });

    test('deciding the same again keeps the date', () {
      final a = store.screener.decide(
        ScreenerKind.address,
        'ana@studio.example',
        ScreenerDecision.letIn,
        now: DateTime.utc(2026, 10, 11),
      );
      final b = store.screener.decide(
        ScreenerKind.address,
        'ana@studio.example',
        ScreenerDecision.letIn,
        now: DateTime.utc(2026, 10, 20),
      );
      expect(b.since, a.since);
    });

    test('values that are not addresses or domains are refused', () {
      for (final (kind, value) in [
        (ScreenerKind.address, 'not an address'),
        (ScreenerKind.domain, 'shop'),
        (ScreenerKind.domain, 'a@shop.example'),
      ]) {
        expect(
          () => store.screener.decide(kind, value, ScreenerDecision.letIn),
          throwsArgumentError,
          reason: value,
        );
      }
    });

    test('turning it off lets everyone through; decisions are kept', () {
      final waiting = mail('ana@studio.example', 'Portfolio review?');
      final out = mail('promo@deals.example', 'Offer');
      store.screener.decide(
        ScreenerKind.address,
        'promo@deals.example',
        ScreenerDecision.screenOut,
      );
      store.screener.disable();
      expect(store.screener.enabled, isFalse);
      expect(sectionOf(waiting), SmartSection.general);
      expect(sectionOf(out), SmartSection.general);
      expect(store.screener.all(), hasLength(1));

      // On again later: Ana now has earlier mail, so she counts as let in;
      // the screened-out sender stays out.
      store.screener.enable(now: turnedOn.add(const Duration(days: 5)));
      expect(sectionOf(waiting), SmartSection.general);
      expect(sectionOf(out), SmartSection.newsletters);
    });
  });
}
