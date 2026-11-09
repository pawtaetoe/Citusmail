// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

final now = DateTime.utc(2026, 11, 4, 12);
var _id = 0;

MailAddress address(String a, [String? name]) => MailAddress(
  displayName: name,
  localPart: a.split('@').first,
  domain: a.split('@').last,
);

/// [count] emails from [from], the first [opened] of them opened, one a
/// day going back from yesterday.
List<SenderMail> emails(
  String from, {
  String? name,
  required int count,
  int opened = 0,
  String? domain,
  MessageCategory category = MessageCategory.newsletters,
  bool unsubscribe = false,
  int startDaysAgo = 1,
}) => [
  for (var i = 0; i < count; i++)
    SenderMail(
      messageId: _id++,
      from: address(from, name),
      domain: domain ?? from.split('@').last,
      at: now.subtract(Duration(days: startDaysAgo + i)),
      opened: i < opened,
      category: category,
      canUnsubscribe: unsubscribe,
    ),
];

void main() {
  group('ranking', () {
    // A realistic inbox: a shop's daily deals nobody reads, a weekly
    // newspaper read most weeks, a bank's alerts, a one-off survey.
    final mail = [
      ...emails(
        'deals@mail.megastore.example',
        name: 'MegaStore Deals',
        domain: 'megastore.example',
        count: 40,
        opened: 1,
        unsubscribe: true,
      ),
      ...emails(
        'weekly@paper.example',
        name: 'The Weekly Paper',
        count: 12,
        opened: 10,
        unsubscribe: true,
      ),
      ...emails(
        'alerts@bank.example',
        name: 'Bank',
        count: 20,
        opened: 15,
        category: MessageCategory.notifications,
      ),
      ...emails(
        'survey@feedback.example',
        name: 'Tell us how we did',
        count: 1,
      ),
      ...emails('hello@startup.example', name: 'Startup', count: 4),
    ];

    test('most mail first', () {
      final groups = SenderCleanup.group(mail, now: now);
      expect(groups.map((g) => g.name), [
        'MegaStore Deals',
        'Bank',
        'The Weekly Paper',
        'Startup',
        'Tell us how we did',
      ]);
      final deals = groups.first;
      expect(deals.count, 40);
      expect(deals.opened, 1);
      expect(deals.kind, SenderKind.newsletter);
      expect(deals.canUnsubscribe, isTrue);
      expect(deals.last, now.subtract(const Duration(days: 1)));
      expect(groups[1].kind, SenderKind.notification);
      expect(groups[1].canUnsubscribe, isFalse);
    });

    test('least opened, with a minimum volume', () {
      final groups = SenderCleanup.sort(
        SenderCleanup.group(mail, now: now),
        SenderOrder.leastOpened,
      );
      // The single unread survey (0% opened) does not top the list: one
      // email says nothing. Startup's four unread ones do.
      expect(groups.map((g) => g.name), [
        'Startup',
        'MegaStore Deals',
        'Bank',
        'The Weekly Paper',
        'Tell us how we did',
      ]);
    });

    test('summary counts only senders rarely opened, with enough mail', () {
      final groups = SenderCleanup.group(mail, now: now);
      expect(SenderCleanup.rarelyOpenedTotal(groups), (emails: 44, senders: 2));
    });

    test('mail older than three months is not counted', () {
      final groups = SenderCleanup.group([
        ...emails('news@old.example', count: 5, startDaysAgo: 100),
        ...emails('news@old.example', count: 2),
      ], now: now);
      expect(groups.single.count, 2);
    });

    test('mostly personal mail is not bulk', () {
      final group = SenderCleanup.group([
        ...emails(
          'jane@club.example',
          count: 3,
          category: MessageCategory.general,
        ),
        ...emails('jane@club.example', count: 1),
      ], now: now).single;
      expect(group.kind, SenderKind.other);
      expect(group.isBulk, isFalse);
    });
  });

  group('exclusions', () {
    test('own addresses and people written to are left out', () {
      final groups = SenderCleanup.group(
        [
          ...emails('Alice@Citusmail.test', count: 9),
          ...emails('carol@friends.example', count: 6),
          ...emails('news@shop.example', count: 3),
        ],
        now: now,
        own: {'alice@citusmail.test'},
        writtenTo: {'carol@friends.example'},
      );
      expect(groups.map((g) => g.key), ['news@shop.example']);
    });

    test('kept senders are left out', () {
      final groups = SenderCleanup.group(
        [
          ...emails('news@shop.example', count: 3),
          ...emails('noreply@bank.example', count: 3),
        ],
        now: now,
        kept: {'@bank.example'},
      );
      expect(groups.map((g) => g.key), ['news@shop.example']);
    });

    test('pinned messages are never acted on', () {
      StoredMessage stored(int id, {bool pinned = false}) => StoredMessage(
        id: id,
        mailboxId: 1,
        accountId: 1,
        uid: id,
        receivedAt: now,
        size: 100,
        flags: MessageFlags.fromImap([if (pinned) r'\Flagged']),
        hasAttachments: false,
        category: MessageCategory.newsletters,
        categorySource: CategorySource.rule,
      );
      final picked = SenderCleanup.actionable([
        stored(1),
        stored(2, pinned: true),
        stored(3),
      ]);
      expect(picked.map((m) => m.id), [1, 3]);
    });
  });

  group('from the store\'s totals', () {
    SenderStats totals(
      String from, {
      String? name,
      required int count,
      int opened = 0,
      int newsletters = 0,
      int daysAgo = 1,
      int? unsubscribeId,
      int? unsubscribeDaysAgo,
    }) => SenderStats(
      from: address(from, name),
      count: count,
      opened: opened,
      newsletters: newsletters,
      notifications: 0,
      last: now.subtract(Duration(days: daysAgo)),
      newestId: _id++,
      unsubscribeId: unsubscribeId,
      unsubscribeAt: unsubscribeDaysAgo == null
          ? null
          : now.subtract(Duration(days: unsubscribeDaysAgo)),
    );
    String registrable(String domain) =>
        domain.split('.').reversed.take(2).toList().reversed.join('.');

    test('the same groups, counts and ranking as from the mail itself', () {
      final groups = SenderCleanup.groupSenders(
        [
          totals(
            'noreply@mail.bank.example',
            name: 'Bank',
            count: 6,
            opened: 6,
            unsubscribeId: 70,
            unsubscribeDaysAgo: 9,
          ),
          totals(
            'alerts@bank.example',
            name: 'Bank Alerts',
            count: 10,
            opened: 2,
            daysAgo: 2,
            unsubscribeId: 71,
            unsubscribeDaysAgo: 3,
          ),
          totals(
            'deals@megastore.example',
            name: 'MegaStore',
            count: 40,
            opened: 1,
            newsletters: 40,
          ),
          totals('me@citusmail.test', count: 3),
          totals('friend@x.example', count: 5),
        ],
        domainOf: registrable,
        own: {'me@citusmail.test'},
        writtenTo: {'friend@x.example'},
      );
      expect(groups.map((g) => g.key), [
        'deals@megastore.example',
        '@bank.example',
      ]);
      final bank = groups.last;
      expect(bank.byDomain, isTrue);
      expect(bank.addresses, [
        'alerts@bank.example',
        'noreply@mail.bank.example',
      ]);
      expect(bank.name, 'Bank Alerts', reason: 'the name on most mail');
      expect(bank.count, 16);
      expect(bank.opened, 8);
      expect(bank.kind, SenderKind.other, reason: 'not newsletters');
      expect(bank.last, now.subtract(const Duration(days: 1)));
      expect(bank.unsubscribeId, 71, reason: 'the newest with the header');
      expect(bank.messageIds, isEmpty);
      final deals = groups.first;
      expect(deals.kind, SenderKind.newsletter);
      expect(deals.openRate, 1 / 40);
      expect(SenderCleanup.isRarelyOpened(deals), isTrue);
      expect(
        SenderCleanup.sort(groups, SenderOrder.leastOpened).first.key,
        'deals@megastore.example',
      );
    });

    test('kept senders are left out', () {
      final groups = SenderCleanup.groupSenders(
        [totals('deals@megastore.example', count: 4)],
        domainOf: registrable,
        kept: {'deals@megastore.example'},
      );
      expect(groups, isEmpty);
    });
  });

  group('grouping', () {
    test('a company\'s no-reply senders are grouped by domain', () {
      final groups = SenderCleanup.group([
        ...emails(
          'no-reply@accounts.cloudco.example',
          name: 'CloudCo',
          domain: 'cloudco.example',
          count: 5,
          category: MessageCategory.notifications,
        ),
        ...emails(
          'notifications@cloudco.example',
          name: 'CloudCo',
          domain: 'cloudco.example',
          count: 3,
          category: MessageCategory.notifications,
          unsubscribe: true,
        ),
        // A person at the same company keeps their own row.
        ...emails(
          'sam@cloudco.example',
          name: 'Sam',
          domain: 'cloudco.example',
          count: 2,
          category: MessageCategory.general,
        ),
      ], now: now);
      expect(groups.map((g) => g.key), [
        '@cloudco.example',
        'sam@cloudco.example',
      ]);
      final company = groups.first;
      expect(company.byDomain, isTrue);
      expect(company.label, 'cloudco.example');
      expect(company.name, 'CloudCo');
      expect(company.count, 8);
      expect(company.addresses, [
        'no-reply@accounts.cloudco.example',
        'notifications@cloudco.example',
      ]);
      expect(company.canUnsubscribe, isTrue);
    });

    test('ordinary senders of one company stay apart', () {
      final groups = SenderCleanup.group([
        ...emails('deals@shop.example', count: 2),
        ...emails('news@shop.example', count: 2),
      ], now: now);
      expect(groups.map((g) => g.key).toSet(), {
        'deals@shop.example',
        'news@shop.example',
      });
      expect(groups.every((g) => !g.byDomain), isTrue);
    });

    test('a look-alike word in the address is not a no-reply sender', () {
      expect(
        SenderCleanup.keyOf(address('alertsteam@x.example'), 'x.example'),
        'alertsteam@x.example',
      );
      expect(
        SenderCleanup.keyOf(address('DoNotReply@Bank.example'), 'bank.example'),
        '@bank.example',
      );
    });

    test('the name used most is shown', () {
      final group = SenderCleanup.group([
        ...emails('news@shop.example', name: 'Shop', count: 3),
        ...emails('news@shop.example', name: 'Shop Sale!', count: 1),
      ], now: now).single;
      expect(group.name, 'Shop');
    });
  });
}
