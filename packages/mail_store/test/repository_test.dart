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

  group('sign-in method', () {
    test('password by default; OAuth when asked', () {
      final plain = temp.addAccount();
      expect(plain.usesOAuth, isFalse);
      final outlook = store.accounts.add(
        NewAccount(
          email: 'me@outlook.example',
          username: 'me@outlook.example',
          imap: ServerSettings(
            host: 'outlook.office365.com',
            port: 993,
            security: ConnectionSecurity.implicitTls,
          ),
          smtp: ServerSettings(
            host: 'smtp-mail.outlook.com',
            port: 587,
            security: ConnectionSecurity.startTls,
          ),
          oauthProvider: 'microsoft',
        ),
      );
      expect(outlook.oauthProvider, 'microsoft');
      expect(store.accounts.byId(outlook.id)!.usesOAuth, isTrue);
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

    test('the topmost value of a header in the newest messages', () {
      store.messages.upsertSummaries(inbox.id, [
        for (var uid = 1; uid <= 4; uid++)
          MessageSummary(
            uid: uid,
            receivedAt: DateTime.utc(2026, 1, uid),
            headers: {
              if (uid != 2)
                'Authentication-Results': ['top $uid', 'lower $uid'],
            },
          ),
      ]);
      expect(
        store.messages.firstHeaderValues(inbox.id, 'Authentication-Results'),
        ['top 4', 'top 3', null, 'top 1'],
      );
      expect(
        store.messages.firstHeaderValues(
          inbox.id,
          'authentication-results',
          limit: 2,
        ),
        ['top 4', 'top 3'],
      );
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
        RemoveDraftAction(mailboxId: 5, messageId: 'draft-1@fmail.test'),
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

    test('sections follow later changes: writing to someone, pinning', () {
      store.messages.upsertSummaries(inbox.id, [
        summary(1, subject: 'from dave', from: address('dave@x.example')),
        MessageSummary(
          uid: 2,
          subject: 'thread',
          receivedAt: DateTime.utc(2026, 4),
          inReplyTo: 'later@x',
          from: address('erin@x.example'),
        ),
      ]);
      expect(section(SmartSection.general), {'from dave', 'thread'});

      // Alice writes to Dave, in reply to nothing; and sends <later@x>.
      store.messages.upsertSummaries(sent.id, [
        MessageSummary(
          uid: 9,
          receivedAt: DateTime.utc(2026, 5),
          messageId: 'later@x',
          to: [address('DAVE@x.example')],
        ),
      ]);
      expect(section(SmartSection.important), {'from dave', 'thread'});

      final dave = store.messages
          .list(const MessageQuery.smart(SmartSection.important))
          .first;
      store.messages.updateFlags(inbox.id, [
        (
          uid: dave.uid,
          flags: MessageFlags.fromImap([r'\Flagged']),
          modSeq: null,
        ),
      ]);
      expect(section(SmartSection.pinned), {dave.subject});
      expect(section(SmartSection.important), hasLength(1));
    });

    test('lists read an index in date order, never the whole folder', () {
      for (final query in [
        const MessageQuery.smart(SmartSection.general),
        const MessageQuery.inbox(),
        const MessageQuery(unreadOnly: true),
      ]) {
        final plan = store.messages
            .debugQueryPlan(query, mailboxId: inbox.id)
            .join(' | ');
        expect(plan, contains('USING INDEX'), reason: plan);
        expect(
          plan,
          isNot(contains('TEMP B-TREE')),
          reason: 'no sorting: $plan',
        );
      }
      final pins = store.messages
          .debugQueryPlan(const MessageQuery(flaggedOnly: true))
          .join(' | ');
      expect(pins, contains('messages_pinned'), reason: pins);
      expect(pins, isNot(contains('TEMP B-TREE')), reason: pins);
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

  group('sending with undo', () {
    late Account account;
    setUp(() => account = temp.addAccount());

    OutboxEntry send({DateTime? notBefore}) => store.outbox.enqueue(
      account.id,
      SendAction(from: 'alice@fmail.test', recipients: ['bob@fmail.test']),
      data: Uint8List.fromList([1]),
      notBefore: notBefore,
    );

    test('a delayed entry is not due until its time', () {
      final now = DateTime.now();
      final entry = send(notBefore: now.add(const Duration(seconds: 5)));
      expect(store.outbox.due(account.id, now: now), isEmpty);
      expect(
        store.outbox
            .due(account.id, now: now.add(const Duration(seconds: 6)))
            .map((e) => e.id),
        [entry.id],
      );
      expect(store.outbox.sends().single.id, entry.id);
    });

    test('cancel is all or nothing, and never once an entry is due', () {
      final now = DateTime.now();
      final later = now.add(const Duration(seconds: 5));
      final a = send(notBefore: later);
      final b = store.outbox.enqueue(
        account.id,
        RemoveDraftAction(mailboxId: 1, messageId: 'd@x'),
        notBefore: later,
      );
      final immediate = send();
      expect(store.outbox.cancel([a.id, immediate.id], now: now), isFalse);
      expect(store.outbox.byId(a.id), isNotNull, reason: 'nothing cancelled');
      expect(
        store.outbox.cancel([
          a.id,
          b.id,
        ], now: later.subtract(const Duration(milliseconds: 500))),
        isFalse,
        reason: 'too close to its time',
      );
      expect(store.outbox.cancel([a.id, b.id], now: now), isTrue);
      expect(store.outbox.byId(a.id), isNull);
      expect(store.outbox.byId(b.id), isNull);
      expect(
        store.outbox.cancel([a.id], now: now),
        isFalse,
        reason: 'already gone',
      );
    });

    test('only failed entries can be discarded', () {
      final entry = send();
      expect(store.outbox.discardFailed(entry.id), isFalse);
      store.outbox.markFailed(entry.id, 'rejected');
      expect(store.outbox.discardFailed(entry.id), isTrue);
      expect(store.outbox.sends(), isEmpty);
    });

    test('remove-draft actions need a real Message-ID', () {
      for (final bad in ['', 'a b@x', '<a@x>', 'a\r\n@x']) {
        expect(
          () => RemoveDraftAction(mailboxId: 1, messageId: bad),
          throwsArgumentError,
          reason: bad,
        );
      }
    });
  });

  group('drafts', () {
    late Account account;
    setUp(() => account = temp.addAccount());

    test('save, update with attachments, delete', () {
      final id = store.drafts.save(
        accountId: account.id,
        content: '{"subject":"one"}',
        attachments: [
          StoredDraftAttachment(
            fileName: 'a.txt',
            mimeType: 'text/plain',
            data: Uint8List.fromList([1, 2]),
          ),
        ],
      );
      expect(store.drafts.byId(id)!.content, '{"subject":"one"}');
      expect(store.drafts.attachments(id).single.fileName, 'a.txt');

      store.drafts.save(
        id: id,
        accountId: account.id,
        content: '{"subject":"two"}',
        attachments: const [],
        savedMessageId: 'v1@fmail.test',
      );
      final draft = store.drafts.byId(id)!;
      expect(draft.content, '{"subject":"two"}');
      expect(draft.savedMessageId, 'v1@fmail.test');
      expect(store.drafts.attachments(id), isEmpty);
      expect(store.drafts.all(), hasLength(1));

      store.drafts.delete(id);
      expect(store.drafts.byId(id), isNull);
      expect(
        () => store.drafts.save(
          id: id,
          accountId: account.id,
          content: '{}',
          attachments: const [],
        ),
        throwsStateError,
      );
    });

    test('drafts go with their account', () {
      final id = store.drafts.save(
        accountId: account.id,
        content: '{}',
        attachments: const [],
      );
      store.accounts.remove(account.id);
      expect(store.drafts.byId(id), isNull);
    });
  });

  group('address suggestions', () {
    test('people written to rank first; typed text is literal', () {
      final account = temp.addAccount();
      final boxes = store.mailboxes.replaceAll(account.id, [
        folder('INBOX'),
        folder('Sent', use: 'Sent'),
      ]);
      final inbox = boxes.firstWhere((b) => b.isInbox);
      final sent = boxes.firstWhere((b) => !b.isInbox);
      MailAddress a(String s, [String? n]) => MailAddress(
        displayName: n,
        localPart: s.split('@').first,
        domain: s.split('@').last,
      );
      store.messages.upsertSummaries(sent.id, [
        MessageSummary(
          uid: 1,
          receivedAt: DateTime.utc(2026),
          to: [a('carol@x.example', 'Carol')],
        ),
      ]);
      store.messages.upsertSummaries(inbox.id, [
        summary(1, from: a('caroline@x.example', 'Caroline')),
        summary(2, from: a('caroline@x.example', 'Caroline')),
        summary(
          3,
          from: a('news@carousel.example'),
          category: MessageCategory.newsletters,
        ),
        summary(4, from: a('per_cent@x.example')),
      ]);
      expect(store.messages.suggestAddresses('car').map((m) => m.address), [
        'carol@x.example',
        'caroline@x.example',
      ]);
      expect(
        store.messages.suggestAddresses('Carol').first.displayName,
        'Carol',
      );
      expect(store.messages.suggestAddresses('%'), isEmpty);
      expect(store.messages.suggestAddresses('_').map((m) => m.address), [
        'per_cent@x.example',
      ]);
      expect(store.messages.suggestAddresses('  '), isEmpty);
    });
  });

  group('folder rules', () {
    late Account account;
    late StoredMailbox receipts;
    setUp(() {
      account = temp.addAccount();
      receipts = store.mailboxes
          .replaceAll(account.id, [folder('INBOX'), folder('Receipts')])
          .firstWhere((b) => !b.isInbox);
    });

    test('add, list, normalise and remove', () {
      final now = DateTime.utc(2026, 10, 22, 12);
      final rule = store.folderRules.add(
        accountId: account.id,
        mailboxId: receipts.id,
        field: RuleField.fromDomain,
        value: ' @Shop.Example ',
        now: now,
      );
      expect(rule.value, 'shop.example');
      expect(rule.appliesFrom, now);
      final existing = store.folderRules.add(
        accountId: account.id,
        mailboxId: receipts.id,
        field: RuleField.subject,
        value: 'Your Receipt',
        includeExisting: true,
      );
      expect(existing.value, 'your receipt');
      expect(
        existing.appliesFrom,
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
      expect(store.folderRules.forAccount(account.id).map((r) => r.id), [
        rule.id,
        existing.id,
      ]);
      expect(store.folderRules.forMailbox(receipts.id), hasLength(2));
      store.folderRules.remove(rule.id);
      expect(store.folderRules.forAccount(account.id).single.id, existing.id);
    });

    test('values are checked', () {
      void add(RuleField field, String value) => store.folderRules.add(
        accountId: account.id,
        mailboxId: receipts.id,
        field: field,
        value: value,
      );
      expect(() => add(RuleField.subject, '   '), throwsArgumentError);
      expect(
        () => add(RuleField.fromAddress, 'no-at-sign'),
        throwsArgumentError,
      );
      expect(
        () => add(RuleField.toAddress, 'a b@x.example'),
        throwsArgumentError,
      );
      expect(() => add(RuleField.fromDomain, 'localhost'), throwsArgumentError);
      expect(() => add(RuleField.subject, 'x' * 321), throwsArgumentError);
    });

    test('a rule must point at a folder of the same account', () {
      final other = temp.addAccount('bob@fmail.test');
      expect(
        () => store.folderRules.add(
          accountId: other.id,
          mailboxId: receipts.id,
          field: RuleField.subject,
          value: 'x',
        ),
        throwsArgumentError,
      );
    });

    test('a rule goes when its folder disappears from the server', () {
      store.folderRules.add(
        accountId: account.id,
        mailboxId: receipts.id,
        field: RuleField.subject,
        value: 'x',
      );
      store.mailboxes.replaceAll(account.id, [folder('INBOX')]);
      expect(store.folderRules.forAccount(account.id), isEmpty);
    });

    test('moves are remembered per account', () {
      store.folderRules.recordMoved(account.id, 'm1@x');
      store.folderRules.recordMoved(account.id, 'm1@x');
      expect(store.folderRules.wasMoved(account.id, 'm1@x'), isTrue);
      expect(store.folderRules.wasMoved(account.id, 'm2@x'), isFalse);
    });
  });

  group('unsubscriptions', () {
    late Account account;
    late StoredMailbox inbox;
    setUp(() {
      account = temp.addAccount();
      inbox = store.mailboxes.replaceAll(account.id, [folder('INBOX')]).single;
    });

    test('record, replace, find and remove', () {
      expect(
        Unsubscription.listKeyOf(listId: 'Weekly.Shop.Example'),
        'list:weekly.shop.example',
      );
      expect(
        Unsubscription.listKeyOf(fromAddress: 'News@Shop.example'),
        'from:news@shop.example',
      );
      expect(Unsubscription.listKeyOf(), isNull);

      store.unsubscriptions.record(
        accountId: account.id,
        listKey: 'list:weekly.shop.example',
        listName: 'Shop Weekly',
        kind: UnsubscribeKind.webPage,
        now: DateTime.utc(2026, 10, 1),
      );
      final later = store.unsubscriptions.record(
        accountId: account.id,
        listKey: 'list:weekly.shop.example',
        listName: 'Shop Weekly',
        kind: UnsubscribeKind.oneClick,
        now: DateTime.utc(2026, 10, 2),
      );
      expect(later.kind, UnsubscribeKind.oneClick);
      expect(later.at, DateTime.utc(2026, 10, 2));
      expect(store.unsubscriptions.forAccount(account.id), hasLength(1));
      expect(
        store.unsubscriptions.find(account.id, 'list:weekly.shop.example')?.id,
        later.id,
      );
      expect(store.unsubscriptions.find(account.id, 'list:other'), isNull);
      store.unsubscriptions.remove(later.id);
      expect(store.unsubscriptions.forAccount(account.id), isEmpty);
    });

    test('inbox mail from one list or one sender', () {
      MessageSummary from(int uid, String address, {String? listId}) =>
          MessageSummary(
            uid: uid,
            receivedAt: DateTime.utc(2026, 1, uid),
            from: MailAddress(
              localPart: address.split('@').first,
              domain: address.split('@').last,
            ),
            listId: listId,
          );
      store.messages.upsertSummaries(inbox.id, [
        from(1, 'news@shop.example', listId: 'weekly.shop.example'),
        from(2, 'deals@shop.example', listId: 'weekly.shop.example'),
        from(3, 'news@shop.example'),
        from(4, 'carol@x.example'),
      ]);
      expect(
        store.messages
            .inboxFromList(account.id, listId: 'Weekly.Shop.Example')
            .map((m) => m.uid),
        [2, 1],
      );
      expect(
        store.messages
            .inboxFromList(account.id, fromAddress: 'NEWS@shop.example')
            .map((m) => m.uid),
        [3, 1],
      );
      expect(store.messages.inboxFromList(account.id), isEmpty);
    });

    test('inbox mail from a domain and its subdomains', () {
      MessageSummary from(int uid, String address) => MessageSummary(
        uid: uid,
        receivedAt: DateTime.utc(2026, 1, uid),
        from: MailAddress(
          localPart: address.split('@').first,
          domain: address.split('@').last,
        ),
      );
      store.messages.upsertSummaries(inbox.id, [
        from(1, 'news@Shop.Example'),
        from(2, 'x@mail.shop.example'),
        from(3, 'x@evilshop.example'),
        from(4, 'x@shop.example.org'),
      ]);
      expect(
        store.messages
            .inboxFromDomain(account.id, 'shop.example')
            .map((m) => m.uid),
        [2, 1],
      );
      expect(store.messages.inboxFromDomain(account.id, '%'), isEmpty);
    });
  });

  group('blocked senders', () {
    test('block, match and unblock', () {
      final address = store.blocks.block(
        BlockKind.address,
        ' News@Shop.Example ',
        now: DateTime.utc(2026, 10, 1),
      );
      expect(address.value, 'news@shop.example');
      final again = store.blocks.block(BlockKind.address, 'news@shop.example');
      expect(again.id, address.id);
      expect(again.since, DateTime.utc(2026, 10, 1), reason: 'keeps the date');

      final domain = store.blocks.block(BlockKind.domain, 'spam.example');
      expect(store.blocks.all(), hasLength(2));

      expect(store.blocks.matching('NEWS@shop.example')?.id, address.id);
      expect(store.blocks.matching('other@shop.example'), isNull);
      expect(store.blocks.matching('x@spam.example')?.id, domain.id);
      expect(store.blocks.matching('x@mail.spam.example')?.id, domain.id);
      expect(store.blocks.matching('x@notspam.example'), isNull);
      expect(store.blocks.matching('x@spam.example.org'), isNull);
      expect(store.blocks.matching(null), isNull);
      expect(store.blocks.matching('no-at-sign'), isNull);

      expect(domain.matches('a@b.spam.example'), isTrue);
      expect(domain.matches('a@spam.example.org'), isFalse);
      expect(address.matches('News@Shop.example'), isTrue);

      store.blocks.unblock(address.id);
      expect(store.blocks.matching('news@shop.example'), isNull);
    });

    test('invalid values are refused', () {
      for (final (kind, value) in [
        (BlockKind.address, 'not an address'),
        (BlockKind.address, '@shop.example'),
        (BlockKind.domain, 'shop'),
        (BlockKind.domain, 'a@shop.example'),
        (BlockKind.domain, ''),
      ]) {
        expect(
          () => store.blocks.block(kind, value),
          throwsArgumentError,
          reason: value,
        );
      }
    });
  });

  group('image senders', () {
    test('allow, check and remove', () {
      final a = store.imageSenders.allow(' News@Shop.Example ');
      expect(a.address, 'news@shop.example');
      expect(store.imageSenders.allow('news@shop.example').id, a.id);
      expect(store.imageSenders.isAllowed('NEWS@shop.example'), isTrue);
      expect(store.imageSenders.isAllowed('other@shop.example'), isFalse);
      expect(store.imageSenders.isAllowed(null), isFalse);
      expect(store.imageSenders.all(), hasLength(1));
      expect(() => store.imageSenders.allow('nope'), throwsArgumentError);
      store.imageSenders.remove(a.id);
      expect(store.imageSenders.isAllowed('news@shop.example'), isFalse);
    });
  });

  group('read receipts', () {
    late Account account;
    late StoredMailbox inbox;
    setUp(() {
      account = temp.addAccount();
      inbox = store.mailboxes.replaceAll(account.id, [folder('INBOX')]).single;
    });

    test('only messages that asked get receipts; a later one replaces', () {
      expect(
        store.receipts.record(
          account.id,
          'x@a',
          recipient: 'bob@b.example',
          disposition: 'displayed',
        ),
        isFalse,
        reason: 'never asked',
      );
      store.receipts.requested(account.id, 'x@a');
      expect(store.receipts.wasRequested(account.id, 'x@a'), isTrue);
      store.receipts.record(
        account.id,
        'x@a',
        recipient: 'Bob@B.example',
        disposition: 'processed',
        at: DateTime.utc(2026, 10, 1),
      );
      store.receipts.record(
        account.id,
        'x@a',
        recipient: 'bob@b.example',
        disposition: 'displayed',
        at: DateTime.utc(2026, 10, 2),
      );
      store.receipts.record(
        account.id,
        'x@a',
        recipient: 'carol@c.example',
        disposition: 'displayed',
        at: DateTime.utc(2026, 10, 3),
      );
      final got = store.receipts.forMessage(account.id, 'x@a');
      expect(got.map((r) => (r.recipient, r.disposition)), [
        ('bob@b.example', 'displayed'),
        ('carol@c.example', 'displayed'),
      ]);
      expect(store.receipts.forMessage(account.id, 'other@a'), isEmpty);
    });

    test('incoming reports are found by Content-Type, once', () {
      store.messages.upsertSummaries(inbox.id, [
        MessageSummary(
          uid: 1,
          receivedAt: DateTime.utc(2026, 10, 1),
          headers: const {
            'content-type': [
              'multipart/report; report-type=disposition-notification; boundary="b"',
            ],
          },
        ),
        MessageSummary(
          uid: 2,
          receivedAt: DateTime.utc(2026, 10, 2),
          headers: const {
            'content-type': ['multipart/report; report-type=delivery-status'],
          },
        ),
        MessageSummary(uid: 3, receivedAt: DateTime.utc(2026, 10, 3)),
      ]);
      final reports = store.receipts.unreadReports(inbox.id);
      expect(reports, [store.messages.byUid(inbox.id, 1)!.id]);
      store.receipts.markReportRead(reports.single);
      expect(store.receipts.unreadReports(inbox.id), isEmpty);
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
