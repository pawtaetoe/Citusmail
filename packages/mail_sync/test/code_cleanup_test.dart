// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late MailStore store;
  late Account account;
  late Map<String, StoredMailbox> boxes;
  late CodeCleaner cleaner;

  // "Now" for every test; the codes below are this many hours old.
  final now = DateTime.utc(2026, 11, 4, 12);
  DateTime hoursAgo(int hours) => now.subtract(Duration(hours: hours));

  List<StoredMailbox> folders(List<(String, Set<String>)> names) =>
      store.mailboxes.replaceAll(account.id, [
        for (final (name, attributes) in names)
          ImapMailboxInfo(
            encodedName: name,
            delimiter: '/',
            attributes: attributes,
          ),
      ]);

  setUp(() {
    directory = Directory.systemTemp.createTempSync('code_cleanup_test');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
    account = store.accounts.add(
      NewAccount(
        email: 'alice@citusmail.test',
        username: 'alice',
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
    boxes = {
      for (final b in folders([
        ('INBOX', {}),
        ('Archive', {r'\Archive'}),
        ('Trash', {r'\Trash'}),
        ('Sent', {r'\Sent'}),
        ('Receipts', {}),
      ]))
        b.encodedName: b,
    };
    for (final b in boxes.values) {
      store.mailboxes.saveSyncState(
        b.id,
        const MailboxSyncState(uidValidity: 1),
      );
    }
    // As in the app: moves wait a few seconds, so they can be undone.
    cleaner = CodeCleaner(
      store,
      MailActions(store, undoWindow: const Duration(seconds: 5)),
    );
  });

  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  void arrive(
    int uid,
    String subject, {
    required int hoursOld,
    String folder = 'INBOX',
    MessageCategory category = MessageCategory.codes,
    List<String> flags = const [],
    String from = 'no-reply@accounts.shop.example',
  }) => store.messages.upsertSummaries(boxes[folder]!.id, [
    MessageSummary(
      uid: uid,
      messageId: '<m$uid@shop.example>',
      receivedAt: hoursAgo(hoursOld),
      subject: subject,
      from: MailAddress(
        localPart: from.split('@').first,
        domain: from.split('@').last,
      ),
      category: category,
      flags: MessageFlags.fromImap(flags),
      code: category == MessageCategory.codes ? '482913' : null,
    ),
  ]);

  List<String?> subjects(Iterable<StoredMessage> messages) => [
    for (final m in messages) m.subject,
  ];

  List<String?> inFolder(String name) => subjects(
    store.messages.list(MessageQuery(mailboxIds: [boxes[name]!.id])),
  );

  void sampleInbox() {
    arrive(1, 'Your verification code is 482913', hoursOld: 3);
    arrive(2, 'Sign in to Shop: your magic link', hoursOld: 30);
    arrive(3, 'Reset your password', hoursOld: 24 * 8);
    arrive(4, 'Your login code (pinned)', hoursOld: 48, flags: [r'\Flagged']);
    arrive(5, 'Your code, replied to', hoursOld: 48, flags: [r'\Answered']);
    arrive(6, 'Draft code', hoursOld: 48, flags: [r'\Draft']);
    arrive(
      7,
      'Lunch on Friday?',
      hoursOld: 48,
      category: MessageCategory.general,
      from: 'carol@x.example',
    );
    arrive(
      8,
      'Weekly deals',
      hoursOld: 48,
      category: MessageCategory.newsletters,
    );
    arrive(9, 'Old code kept in a folder', hoursOld: 72, folder: 'Receipts');
    arrive(10, 'Code already archived', hoursOld: 72, folder: 'Archive');
  }

  group('which messages', () {
    setUp(sampleInbox);

    test('after a day: only old, untouched codes in the inbox', () {
      expect(subjects(cleaner.candidates(now)), [
        'Reset your password',
        'Sign in to Shop: your magic link',
      ]);
    });

    test('after a week: only codes older than seven days', () {
      cleaner.settings.age = CodeCleanupAge.week;
      expect(subjects(cleaner.candidates(now)), ['Reset your password']);
    });

    test('off: nothing', () {
      cleaner.settings.age = CodeCleanupAge.off;
      expect(cleaner.candidates(now), isEmpty);
      cleaner.settings.agree();
      expect(cleaner.run(now), isNull);
    });

    test('the cut-off is exact: just under a day stays', () {
      arrive(20, 'Code from 23 hours ago', hoursOld: 23);
      arrive(21, 'Code from 25 hours ago', hoursOld: 25);
      final picked = subjects(cleaner.candidates(now));
      expect(picked, contains('Code from 25 hours ago'));
      expect(picked, isNot(contains('Code from 23 hours ago')));
    });

    test('an account without an Archive (or Trash) keeps its codes', () {
      folders([('INBOX', {})]);
      expect(cleaner.candidates(now), isEmpty);
    });
  });

  group('running', () {
    setUp(sampleInbox);

    test('nothing moves before the user agrees', () {
      expect(cleaner.settings.consent, isA<ConsentUnasked>());
      expect(cleaner.run(now), isNull);
      expect(inFolder('INBOX'), hasLength(8));
      expect(store.outbox.all(account.id), isEmpty);
    });

    test('archives through the queued actions, once an hour', () {
      cleaner.settings.agree();
      final done = cleaner.run(now)!;
      expect(done.count, 2);
      expect(done.action, CodeCleanupAction.archive);
      expect(done.accountIds, {account.id});
      expect(inFolder('INBOX'), isNot(contains('Reset your password')));
      expect(inFolder('INBOX'), contains('Your login code (pinned)'));
      final moves = store.outbox.all(account.id).map((e) => e.action).toList();
      expect(moves, hasLength(1));
      final move = moves.single as MoveAction;
      expect(move.targetMailboxId, boxes['Archive']!.id);
      expect(move.uids.toSet(), {2, 3});

      // More old codes arrive, but the hour isn't over.
      arrive(30, 'Another code', hoursOld: 50);
      expect(cleaner.run(now.add(const Duration(minutes: 59))), isNull);
      // Another process (the background job) waits too.
      expect(
        CodeCleaner(
          store,
          MailActions(store),
        ).run(now.add(const Duration(minutes: 30))),
        isNull,
      );
      final later = cleaner.run(now.add(const Duration(minutes: 61)))!;
      expect(subjects(later.messages), ['Another code']);
    });

    test('Move to Trash moves to the Trash folder', () {
      cleaner.settings
        ..agree()
        ..action = CodeCleanupAction.trash;
      cleaner.run(now);
      final move = store.outbox.all(account.id).single.action as MoveAction;
      expect(move.targetMailboxId, boxes['Trash']!.id);
    });

    test('Gmail: archiving leaves the inbox for All Mail', () {
      final gmail = {
        for (final b in folders([
          ('INBOX', {}),
          ('[Gmail]/All Mail', {r'\All'}),
          ('[Gmail]/Trash', {r'\Trash'}),
        ]))
          b.encodedName: b,
      };
      cleaner.settings.agree();
      final done = cleaner.run(now)!;
      expect(done.count, 2);
      final move = store.outbox.all(account.id).single.action as MoveAction;
      expect(move.targetMailboxId, gmail['[Gmail]/All Mail']!.id);
    });

    test('in batches', () {
      for (var uid = 100; uid < 100 + CodeCleaner.batchSize + 20; uid++) {
        arrive(uid, 'Code $uid', hoursOld: 40);
      }
      cleaner.settings.agree();
      expect(cleaner.run(now)!.count, CodeCleaner.batchSize);
      final next = cleaner.run(now.add(CodeCleaner.interval))!;
      expect(next.count, 22);
    });

    test('Undo puts them back and the next run leaves them alone', () {
      cleaner.settings.agree();
      final done = cleaner.run(now)!;
      expect(cleaner.undo(done), isTrue);
      expect(inFolder('INBOX'), contains('Reset your password'));
      expect(store.outbox.all(account.id), isEmpty);

      arrive(40, 'A newer old code', hoursOld: 26);
      final next = cleaner.run(now.add(const Duration(hours: 2)))!;
      expect(subjects(next.messages), ['A newer old code']);
    });

    test('Undo after the move reached the server says so', () {
      final actions = MailActions(store, undoWindow: Duration.zero);
      final cleaner = CodeCleaner(store, actions)..settings.agree();
      // No undo window: the move is due at once.
      final done = cleaner.run(now)!;
      expect(cleaner.undo(done), isFalse);
      // Still remembered: not taken again if it comes back.
      expect(cleaner.settings.undone, contains('<m3@shop.example>'));
    });
  });

  group('asking first', () {
    setUp(sampleInbox);

    test('asks when there is something to tidy, until answered', () {
      expect(cleaner.shouldAsk(now), isTrue);
      cleaner.settings.agree();
      expect(cleaner.shouldAsk(now), isFalse);
    });

    test('"Not now" asks again only after 30 days', () {
      cleaner.settings.decline(now);
      expect(cleaner.shouldAsk(now.add(const Duration(days: 29))), isFalse);
      expect(cleaner.run(now.add(const Duration(days: 29))), isNull);
      expect(cleaner.shouldAsk(now.add(const Duration(days: 30))), isTrue);
    });

    test('never asks when off, or when nothing is old enough', () {
      cleaner.settings.age = CodeCleanupAge.off;
      expect(cleaner.shouldAsk(now), isFalse);
      cleaner.settings.age = CodeCleanupAge.week;
      expect(cleaner.shouldAsk(hoursAgo(24 * 7)), isFalse);
    });

    test('agreeing lifts the hourly wait', () {
      cleaner.settings.agree();
      cleaner.run(now);
      arrive(50, 'One more code', hoursOld: 30);
      cleaner.settings.agree();
      expect(cleaner.run(now.add(const Duration(minutes: 1)))?.count, 1);
    });
  });
}
