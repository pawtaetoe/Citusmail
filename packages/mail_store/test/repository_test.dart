// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

import 'support/temp_store.dart';

ImapMailboxInfo folder(String name, {String? use}) => ImapMailboxInfo(
  encodedName: name,
  delimiter: '.',
  attributes: {if (use != null) '\\$use'},
);

MessageSummary summary(
  int uid, {
  String? subject,
  DateTime? at,
  MessageCategory category = MessageCategory.general,
  MessageFlags flags = MessageFlags.none,
  MailAddress? from,
  String? listId,
}) => MessageSummary(
  uid: uid,
  subject: subject ?? 'Message $uid',
  receivedAt: at ?? DateTime.utc(2026, 10, 1).add(Duration(minutes: uid)),
  category: category,
  listId: listId,
  flags: flags,
  from:
      from ??
      MailAddress(
        displayName: 'Sender $uid',
        localPart: 'sender$uid',
        domain: 'x.example',
      ),
);

void main() {
  late TempStore temp;
  late MailStore store;
  setUp(() {
    temp = TempStore.create();
    store = temp.store;
  });
  tearDown(() => temp.dispose());

  group('accounts', () {
    test('add, read, update and order', () {
      final a = temp.addAccount('alice@fmail.test');
      final b = temp.addAccount('bob@fmail.test');
      expect(store.accounts.all().map((x) => x.email), [
        'alice@fmail.test',
        'bob@fmail.test',
      ]);
      expect(a.keychainKey, 'account-${a.id}');
      store.accounts.update(
        Account(
          id: b.id,
          email: b.email,
          displayName: 'Bob',
          username: 'bob',
          imap: b.imap,
          smtp: ServerSettings(
            host: 'smtp.x.example',
            port: 587,
            security: ConnectionSecurity.startTls,
          ),
          sortOrder: -1,
          createdAt: b.createdAt,
        ),
      );
      final updated = store.accounts.byId(b.id)!;
      expect(updated.displayName, 'Bob');
      expect(updated.smtp.security, ConnectionSecurity.startTls);
      expect(store.accounts.all().first.id, b.id, reason: 'sort order');
    });

    test('the same address twice (any case) is refused', () {
      temp.addAccount('alice@fmail.test');
      expect(
        () => temp.addAccount('ALICE@fmail.test'),
        throwsA(isA<DuplicateAccountException>()),
      );
    });

    test('invalid settings are rejected before storing', () {
      expect(
        () => ServerSettings(
          host: 'bad host',
          port: 993,
          security: ConnectionSecurity.implicitTls,
        ),
        throwsArgumentError,
      );
      expect(
        () => ServerSettings(
          host: 'x.example',
          port: 0,
          security: ConnectionSecurity.implicitTls,
        ),
        throwsArgumentError,
      );
      expect(
        () => ServerSettings(
          host: 'x.example\r\nEVIL',
          port: 993,
          security: ConnectionSecurity.implicitTls,
        ),
        throwsArgumentError,
      );
    });

    test('removing an account removes everything stored for it', () {
      final a = temp.addAccount();
      final inbox = store.mailboxes.replaceAll(a.id, [folder('INBOX')]).single;
      store.messages.upsertSummaries(inbox.id, [summary(1)]);
      store.outbox.enqueue(
        a.id,
        SetFlagsAction(
          mailboxId: inbox.id,
          uidValidity: 1,
          uids: [1],
          add: [r'\Seen'],
        ),
      );
      store.accounts.remove(a.id);
      for (final table in [
        'mailboxes',
        'messages',
        'message_addresses',
        'message_headers',
        'outbox',
        'message_search',
      ]) {
        expect(
          store.database
              .select('SELECT count(*) FROM $table')
              .first
              .columnAt(0),
          0,
          reason: table,
        );
      }
    });
  });

  group('mailboxes', () {
    late Account account;
    setUp(() => account = temp.addAccount());

    test('special folders are chosen by flag, not name (Namecheap layout)', () {
      store.mailboxes.replaceAll(account.id, [
        folder('INBOX'),
        folder('INBOX.Junk'),
        folder('INBOX.spam', use: 'Junk'),
        folder('INBOX.Sent', use: 'Sent'),
      ]);
      expect(
        store.mailboxes.bySpecialUse(account.id, SpecialUse.junk)!.encodedName,
        'INBOX.spam',
      );
      expect(
        store.mailboxes.bySpecialUse(account.id, SpecialUse.sent)!.encodedName,
        'INBOX.Sent',
      );
      expect(store.mailboxes.inbox(account.id)!.encodedName, 'INBOX');
      expect(
        store.mailboxes.bySpecialUse(account.id, SpecialUse.trash),
        isNull,
      );
    });

    test('replaceAll adds, updates and removes, keeping sync state', () {
      final first = store.mailboxes.replaceAll(account.id, [
        folder('INBOX'),
        folder('Old'),
      ]);
      final inbox = first.firstWhere((m) => m.isInbox);
      final old = first.firstWhere((m) => m.encodedName == 'Old');
      store.mailboxes.saveSyncState(
        inbox.id,
        MailboxSyncState(
          uidValidity: 7,
          uidNext: 10,
          highestModSeq: 99,
          lastSyncAt: DateTime.utc(2026),
        ),
      );
      store.messages.upsertSummaries(old.id, [summary(1)]);

      final second = store.mailboxes.replaceAll(account.id, [
        folder('INBOX'),
        folder('New', use: 'Archive'),
      ]);
      expect(
        second.map((m) => m.encodedName),
        unorderedEquals(['INBOX', 'New']),
      );
      final kept = store.mailboxes.byId(inbox.id)!;
      expect(kept.syncState.uidValidity, 7);
      expect(kept.syncState.highestModSeq, 99);
      expect(
        store.messages.uids(old.id),
        isEmpty,
        reason: 'folder gone, so are its messages',
      );
    });

    test('a new UIDVALIDITY drops the cached messages of that folder only', () {
      final folders = store.mailboxes.replaceAll(account.id, [
        folder('INBOX'),
        folder('Other'),
      ]);
      final inbox = folders.firstWhere((m) => m.isInbox),
          other = folders.firstWhere((m) => !m.isInbox);
      store.messages.upsertSummaries(inbox.id, [summary(1), summary(2)]);
      store.messages.upsertSummaries(other.id, [summary(1)]);
      store.mailboxes.saveSyncState(
        inbox.id,
        const MailboxSyncState(uidValidity: 1, highestModSeq: 5),
      );
      store.mailboxes.resetForUidValidity(inbox.id, 2);
      expect(store.messages.uids(inbox.id), isEmpty);
      expect(store.messages.uids(other.id), [1]);
      final state = store.mailboxes.byId(inbox.id)!.syncState;
      expect(state.uidValidity, 2);
      expect(state.highestModSeq, isNull);
    });
  });

  group('messages', () {
    late Account account;
    late StoredMailbox inbox;
    setUp(() {
      account = temp.addAccount();
      inbox = store.mailboxes.replaceAll(account.id, [folder('INBOX')]).single;
    });

    test('upsert is idempotent and updates in place', () {
      store.messages.upsertSummaries(inbox.id, [summary(1), summary(2)]);
      store.messages.upsertSummaries(inbox.id, [
        summary(1, subject: 'Changed'),
        summary(2),
      ]);
      expect(store.messages.uids(inbox.id), [1, 2]);
      expect(store.messages.byUid(inbox.id, 1)!.subject, 'Changed');
    });

    test('addresses, selected headers and flags round-trip', () {
      store.messages.upsertSummaries(inbox.id, [
        MessageSummary(
          uid: 1,
          receivedAt: DateTime.utc(2026),
          from: const MailAddress(
            displayName: 'Ana',
            localPart: 'ana',
            domain: 'x.example',
          ),
          to: const [
            MailAddress(localPart: 'a', domain: 'x.example'),
            MailAddress(localPart: 'b', domain: 'x.example'),
          ],
          flags: MessageFlags.fromImap([r'\Seen', r'\Flagged', r'$Forwarded']),
          headers: const {
            'List-Unsubscribe': ['<https://x.example/u>'],
            'list-id': ['<l.x.example>'],
          },
        ),
      ]);
      final m = store.messages.byUid(inbox.id, 1)!;
      expect(m.from!.displayName, 'Ana');
      expect(store.messages.addresses(m.id, 'to').map((a) => a.address), [
        'a@x.example',
        'b@x.example',
      ]);
      expect(store.messages.headers(m.id), {
        'list-id': ['<l.x.example>'],
        'list-unsubscribe': ['<https://x.example/u>'],
      });
      expect(m.flags.seen && m.flags.flagged && !m.flags.answered, isTrue);
      expect(m.flags.toImap(), {r'\Seen', r'\Flagged', r'$Forwarded'});

      store.messages.updateFlags(inbox.id, [
        (uid: 1, flags: MessageFlags.none, modSeq: 42),
      ]);
      final updated = store.messages.byId(m.id)!;
      expect(updated.flags.seen, isFalse);
      expect(updated.modSeq, 42);
    });

    test('removing UIDs removes everything about those messages', () {
      store.messages.upsertSummaries(inbox.id, [
        summary(1, subject: 'findme quarterly'),
        summary(2),
      ]);
      final id = store.messages.byUid(inbox.id, 1)!.id;
      store.messages.saveBody(
        id,
        Uint8List.fromList(utf8.encode('raw')),
        searchableText: 'body words',
      );
      store.messages.removeUids(inbox.id, [1]);
      expect(store.messages.uids(inbox.id), [2]);
      expect(store.messages.body(id), isNull);
      expect(store.messages.search('quarterly'), isEmpty);
      expect(store.messages.highestUid(inbox.id), 2);
    });

    test('unified inbox across accounts, by category, with keyset paging', () {
      final bob = temp.addAccount('bob@fmail.test');
      final bobFolders = store.mailboxes.replaceAll(bob.id, [
        folder('INBOX'),
        folder('Archive'),
      ]);
      final bobInbox = bobFolders.firstWhere((m) => m.isInbox);
      final bobArchive = bobFolders.firstWhere((m) => !m.isInbox);
      store.messages.upsertSummaries(inbox.id, [
        for (var i = 1; i <= 30; i++)
          summary(
            i,
            category: i.isEven
                ? MessageCategory.newsletters
                : MessageCategory.general,
          ),
      ]);
      store.messages.upsertSummaries(bobInbox.id, [
        for (var i = 1; i <= 30; i++)
          summary(
            i,
            at: DateTime.utc(2026, 9, 1).add(Duration(hours: i)),
            category: MessageCategory.newsletters,
          ),
      ]);
      store.messages.upsertSummaries(bobArchive.id, [
        summary(1, category: MessageCategory.newsletters),
      ]);

      final seen = <int>[];
      StoredMessage? cursor;
      while (true) {
        final page = store.messages.list(
          MessageQuery(
            inboxesOnly: true,
            category: MessageCategory.newsletters,
            before: cursor,
            limit: 7,
          ),
        );
        if (page.isEmpty) break;
        seen.addAll(page.map((m) => m.id));
        cursor = page.last;
      }
      expect(
        seen,
        hasLength(15 + 30),
        reason: 'all inbox newsletters, archive excluded',
      );
      expect(
        seen.toSet(),
        hasLength(seen.length),
        reason: 'no duplicates across pages',
      );
      final all = store.messages.list(
        const MessageQuery(
          inboxesOnly: true,
          category: MessageCategory.newsletters,
          limit: 500,
        ),
      );
      expect(
        all.map((m) => m.id).toList(),
        seen,
        reason: 'newest first, same order as paging',
      );
      expect(
        all.first.accountId,
        account.id,
        reason: 'alice\'s October mail is newer than bob\'s September mail',
      );
    });

    test('unread filter and count', () {
      store.messages.upsertSummaries(inbox.id, [
        summary(1, flags: MessageFlags.fromImap([r'\Seen'])),
        summary(2),
        summary(3),
      ]);
      expect(store.messages.unreadCount(inbox.id), 2);
      expect(
        store.messages
            .list(MessageQuery(mailboxIds: [inbox.id], unreadOnly: true))
            .map((m) => m.uid),
        [3, 2],
      );
    });

    group('search', () {
      setUp(() {
        store.messages.upsertSummaries(inbox.id, [
          summary(1, subject: 'Quarterly report for München'),
          summary(2, subject: '會議通知：明天上午十點'),
          summary(
            3,
            subject: 'Lunch?',
            from: const MailAddress(
              displayName: 'Bob Example',
              localPart: 'bob',
              domain: 'fmail.test',
            ),
          ),
          summary(4, subject: '100% off; DROP TABLE messages; --'),
        ]);
        final id = store.messages.byUid(inbox.id, 3)!.id;
        store.messages.saveBody(
          id,
          Uint8List(0),
          searchableText: 'Shall we try the noodle place?',
        );
      });

      List<int> uids(String q) =>
          store.messages.search(q).map((m) => m.uid).toList();

      test('words in subject, sender and body', () {
        expect(uids('quarterly'), [1]);
        expect(uids('bob@fmail'), [3]);
        expect(uids('noodle'), [3]);
        expect(uids('lunch noodle'), [3], reason: 'all terms must match');
        expect(uids('lunch quarterly'), isEmpty);
      });

      test('accents are ignored', () {
        expect(uids('munchen'), [1]);
      });

      test(
        'Chinese: 3+ characters via the index, 2 characters via the fallback',
        () {
          expect(uids('會議通知'), [2]);
          expect(uids('會議'), [2]);
          expect(uids('十點'), [2]);
        },
      );

      test('typed syntax is literal: no errors, no wildcard matches', () {
        for (final hostile in [
          '"',
          'a"b',
          'NEAR(x y)',
          '*',
          'OR',
          'AND NOT',
          '%',
          '_',
          r'\',
          "'); DROP TABLE messages; --",
          'subject:x',
        ]) {
          expect(
            () => store.messages.search(hostile),
            returnsNormally,
            reason: hostile,
          );
        }
        expect(uids('%'), [
          4,
        ], reason: 'only the subject containing a literal %');
        expect(uids('_'), isEmpty);
        expect(uids('DROP TABLE'), [4]);
        expect(
          store.messages.uids(inbox.id),
          hasLength(4),
          reason: 'table still there',
        );
      });

      test('empty search finds nothing', () {
        expect(uids('   '), isEmpty);
      });
    });

    test('raw bodies are stored and returned exactly', () {
      store.messages.upsertSummaries(inbox.id, [summary(1)]);
      final id = store.messages.byUid(inbox.id, 1)!.id;
      final raw = Uint8List.fromList(List.generate(70000, (i) => i % 256));
      store.messages.saveBody(id, raw, searchableText: '');
      expect(store.messages.body(id), raw);
    });
  });

  group('outbox', () {
    late Account account;
    setUp(() => account = temp.addAccount());

    test('every action type round-trips through storage', () {
      final actions = <OutboxAction>[
        SetFlagsAction(
          mailboxId: 1,
          uidValidity: 9,
          uids: [1, 2],
          add: [r'\Seen'],
          remove: [r'\Flagged'],
        ),
        MoveAction(mailboxId: 1, uidValidity: 9, uids: [3], targetMailboxId: 2),
        DeleteAction(mailboxId: 1, uidValidity: 9, uids: [4]),
      ];
      for (final action in actions) {
        store.outbox.enqueue(account.id, action);
      }
      store.outbox.enqueue(
        account.id,
        AppendAction(mailboxId: 2, flags: [r'\Draft']),
        data: Uint8List.fromList([1, 2]),
      );
      store.outbox.enqueue(
        account.id,
        SendAction(
          from: 'alice@fmail.test',
          recipients: ['bob@fmail.test'],
          sentMailboxId: 3,
        ),
        data: Uint8List.fromList([3]),
      );
      final due = store.outbox.due(account.id);
      expect(due.map((e) => e.action.encode()), [
        ...actions.map((a) => a.encode()),
        AppendAction(mailboxId: 2, flags: [r'\Draft']).encode(),
        SendAction(
          from: 'alice@fmail.test',
          recipients: ['bob@fmail.test'],
          sentMailboxId: 3,
        ).encode(),
      ]);
      expect(due.last.data, [3]);
    });

    test('retry later, give up, retry by hand, complete', () {
      final entry = store.outbox.enqueue(
        account.id,
        DeleteAction(mailboxId: 1, uidValidity: 9, uids: [1]),
      );
      final now = DateTime.utc(2026, 10, 21, 12);
      store.outbox.retryLater(
        entry.id,
        'offline',
        now.add(const Duration(minutes: 5)),
      );
      expect(store.outbox.due(account.id, now: now), isEmpty);
      expect(
        store.outbox
            .due(account.id, now: now.add(const Duration(minutes: 6)))
            .single
            .attempts,
        1,
      );

      store.outbox.markFailed(entry.id, 'NO [NONEXISTENT] folder gone');
      expect(
        store.outbox.due(account.id, now: now.add(const Duration(days: 1))),
        isEmpty,
      );
      expect(store.outbox.all(account.id).single.state, OutboxState.failed);

      store.outbox.retryFailed(entry.id);
      expect(store.outbox.pendingCount(account.id), 1);
      store.outbox.complete(entry.id);
      expect(store.outbox.all(account.id), isEmpty);
    });

    test('a corrupted entry is marked failed and does not block the queue', () {
      store.database.execute(
        "INSERT INTO outbox (account_id, action, created_at) VALUES (?, '{\"type\":\"wipeEverything\"}', 0)",
        [account.id],
      );
      store.outbox.enqueue(
        account.id,
        DeleteAction(mailboxId: 1, uidValidity: 9, uids: [1]),
      );
      final due = store.outbox.due(account.id);
      expect(due.single.action, isA<DeleteAction>());
      expect(
        store.database
            .select("SELECT count(*) FROM outbox WHERE state = 'failed'")
            .first
            .columnAt(0),
        1,
      );
    });

    test('invalid actions are rejected', () {
      expect(
        () =>
            SetFlagsAction(mailboxId: 1, uidValidity: 9, uids: [], add: ['x']),
        throwsArgumentError,
      );
      expect(
        () =>
            SetFlagsAction(mailboxId: 1, uidValidity: 9, uids: [0], add: ['x']),
        throwsArgumentError,
      );
      expect(
        () => MoveAction(
          mailboxId: 1,
          uidValidity: 9,
          uids: [1],
          targetMailboxId: 1,
        ),
        throwsArgumentError,
      );
      expect(
        () => store.outbox.enqueue(
          account.id,
          SendAction(from: 'a@x', recipients: ['b@x']),
        ),
        throwsArgumentError,
        reason: 'send needs the message data',
      );
      for (final bad in [
        '[]',
        '{"type":"move","mailboxId":"1","uids":[1],"targetMailboxId":2}',
        '{"type":"setFlags","mailboxId":1,"uidValidity":9,"uids":[-1],"add":[],"remove":[]}',
        '{"type":"delete","mailboxId":1,"uids":[1]}',
        '{"type":"setFlags","mailboxId":1,"uidValidity":9,"uids":[1],"add":[],"remove":[]}',
      ]) {
        expect(
          () => OutboxAction.decode(bad),
          throwsFormatException,
          reason: bad,
        );
      }
    });
  });

  group('smart inbox', () {
    late Account alice;
    late StoredMailbox inbox;
    late StoredMailbox sent;
    late StoredMailbox important;

    MailAddress address(String a) =>
        MailAddress(localPart: a.split('@').first, domain: a.split('@').last);

    setUp(() {
      alice = temp.addAccount();
      final boxes = store.mailboxes.replaceAll(alice.id, [
        folder('INBOX'),
        folder('Sent', use: 'Sent'),
        folder('Important', use: 'Important'),
      ]);
      inbox = boxes.firstWhere((b) => b.isInbox);
      sent = boxes.firstWhere((b) => b.specialUse == SpecialUse.sent);
      important = boxes.firstWhere((b) => b.specialUse == SpecialUse.important);
    });

    Set<String?> section(SmartSection s, {List<int>? accounts}) => store
        .messages
        .list(MessageQuery.smart(s, accountIds: accounts, limit: 500))
        .map((m) => m.subject)
        .toSet();

    test('every inbox message is in exactly one section', () {
      // Alice wrote to Carol (as Cc) and sent message <q@x>.
      store.messages.upsertSummaries(sent.id, [
        MessageSummary(
          uid: 1,
          receivedAt: DateTime.utc(2026),
          messageId: 'q@x',
          from: address('alice@fmail.test'),
          to: [address('dave@x.example')],
          cc: [address('Carol@X.example')],
        ),
      ]);
      store.messages.upsertSummaries(inbox.id, [
        summary(1, subject: 'stranger'),
        summary(2, subject: 'from carol', from: address('carol@x.example')),
        MessageSummary(
          uid: 3,
          subject: 'reply to alice',
          receivedAt: DateTime.utc(2026, 2),
          inReplyTo: 'q@x',
          from: address('erin@x.example'),
        ),
        summary(
          4,
          subject: 'server says important',
          flags: MessageFlags.fromImap([r'$Important']),
        ),
        MessageSummary(
          uid: 5,
          subject: 'in gmail important folder',
          receivedAt: DateTime.utc(2026, 3),
          messageId: 'imp@x',
        ),
        summary(
          6,
          subject: 'newsletter from carol',
          from: address('carol@x.example'),
          category: MessageCategory.newsletters,
        ),
        summary(7, subject: 'alert', category: MessageCategory.notifications),
        summary(
          8,
          subject: 'pinned newsletter',
          category: MessageCategory.newsletters,
          flags: MessageFlags.fromImap([r'\Flagged', r'\Seen']),
        ),
      ]);
      store.messages.upsertSummaries(important.id, [
        MessageSummary(
          uid: 1,
          receivedAt: DateTime.utc(2026, 3),
          messageId: 'imp@x',
        ),
      ]);

      expect(section(SmartSection.pinned), {'pinned newsletter'});
      expect(section(SmartSection.important), {
        'from carol',
        'reply to alice',
        'server says important',
        'in gmail important folder',
      });
      expect(section(SmartSection.general), {'stranger'});
      expect(section(SmartSection.newsletters), {'newsletter from carol'});
      expect(section(SmartSection.notifications), {'alert'});

      final counts = store.messages.sectionCounts();
      expect(counts[SmartSection.important]!.total, 4);
      expect(counts[SmartSection.important]!.unread, 4);
      expect(counts[SmartSection.pinned]!.total, 1);
      expect(counts[SmartSection.pinned]!.unread, 0);
      expect(
        counts.values.fold<int>(0, (sum, c) => sum + c.total),
        8,
        reason: 'only inbox messages, each counted once',
      );
      expect(
        store.messages.list(const MessageQuery.inbox(limit: 500)),
        hasLength(8),
      );
    });

    test('sections can be limited to one account', () {
      final bob = temp.addAccount('bob@fmail.test');
      final bobInbox = store.mailboxes.replaceAll(bob.id, [
        folder('INBOX'),
      ]).single;
      store.messages.upsertSummaries(inbox.id, [summary(1, subject: 'a')]);
      store.messages.upsertSummaries(bobInbox.id, [summary(1, subject: 'b')]);
      expect(section(SmartSection.general), {'a', 'b'});
      expect(section(SmartSection.general, accounts: [bob.id]), {'b'});
      expect(
        store.messages
            .sectionCounts(accountIds: [alice.id])[SmartSection.general]!
            .total,
        1,
      );
    });

    test('pins across every folder', () {
      store.messages.upsertSummaries(sent.id, [
        summary(
          1,
          subject: 'pinned sent',
          flags: MessageFlags.fromImap([r'\Flagged']),
        ),
        summary(2, subject: 'plain sent'),
      ]);
      expect(
        store.messages
            .list(const MessageQuery(flaggedOnly: true))
            .map((m) => m.subject),
        ['pinned sent'],
      );
    });

    test('re-sorting reads stored mail and writes new decisions', () {
      store.messages.upsertSummaries(inbox.id, [
        MessageSummary(
          uid: 1,
          receivedAt: DateTime.utc(2026),
          from: address('news@shop.example'),
          headers: const {
            'List-Unsubscribe': ['<mailto:u@shop.example>'],
          },
        ),
      ]);
      final batch = store.messages.sortable();
      expect(batch.single.from?.address, 'news@shop.example');
      expect(batch.single.headers, {
        'list-unsubscribe': ['<mailto:u@shop.example>'],
      });
      expect(store.messages.sortable(afterId: batch.last.id), isEmpty);
      store.messages.updateCategories([
        CategoryDecision(
          messageId: batch.single.id,
          category: MessageCategory.newsletters,
          source: CategorySource.rule,
          listId: 'l.shop.example',
        ),
      ]);
      final m = store.messages.byUid(inbox.id, 1)!;
      expect(m.category, MessageCategory.newsletters);
      expect(m.listId, 'l.shop.example');
    });

    test('quoted local parts round-trip', () {
      const quoted = MailAddress(
        localPart: 'john "jd" doe',
        domain: 'x.example',
      );
      store.messages.upsertSummaries(inbox.id, [summary(1, from: quoted)]);
      final stored = store.messages.byUid(inbox.id, 1)!.from!;
      expect(stored.localPart, 'john "jd" doe');
      expect(stored.address, quoted.address);
    });

    test('categories are stored under their schema names', () {
      expect(MessageCategory.general.storageName, 'people');
      for (final c in MessageCategory.values) {
        expect(MessageCategory.fromStorage(c.storageName), c);
      }
      expect(() => MessageCategory.fromStorage('x'), throwsFormatException);
    });
  });

  group('settings', () {
    test('read, write, overwrite, delete, and persist', () {
      expect(store.settings.read('k'), isNull);
      store.settings
        ..write('k', 'one')
        ..write('k', 'two');
      temp.reopen();
      store = temp.store;
      expect(store.settings.read('k'), 'two');
      store.settings.delete('k');
      expect(store.settings.read('k'), isNull);
    });
  });
}
