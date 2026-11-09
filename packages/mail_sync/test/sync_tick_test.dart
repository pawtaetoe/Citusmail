// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// How much one sync does: the 1-minute inbox check and the 5-minute full
// sync should cost next to nothing when nothing changed.

import 'dart:io';

import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

import 'support/fake_imap.dart';

void main() {
  final skip = FakeImap.skipReason;
  if (skip != null) {
    test('needs the test certificates', () {}, skip: skip);
    return;
  }

  late Directory directory;
  late MailStore store;
  late FakeImap server;
  late Account account;

  Future<void> setUpWith({bool condstore = false}) async {
    server = await FakeImap.start(condstore: condstore);
    directory = Directory.systemTemp.createTempSync('sync_tick_test');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
    account = server.addAccount(store);
  }

  tearDown(() async {
    store.close();
    await server.close();
    directory.deleteSync(recursive: true);
  });

  StoredMailbox inbox() => store.mailboxes.inbox(account.id)!;

  test('the fake server syncs', () async {
    await setUpWith();
    server.folders['INBOX']!
      ..add(subject: 'one')
      ..add(subject: 'two');
    final engine = SyncEngine(store, server.connector());
    final report = await engine.syncAccount(account.id);
    expect(report, isNotNull);
    expect(
      store.messages
          .list(MessageQuery(mailboxIds: [inbox().id]))
          .map((m) => m.subject),
      ['two', 'one'],
    );
    await engine.dispose();
  });

  test('syncs reuse one logged-in connection', () async {
    await setUpWith();
    server.folders['INBOX']!.add(subject: 'one');
    final engine = SyncEngine(store, server.connector());
    await engine.syncAccount(account.id);
    for (var i = 0; i < 3; i++) {
      server.folders['INBOX']!.add(subject: 'more $i');
      await engine.syncAccount(account.id, mailboxIds: {inbox().id});
    }
    expect(server.logins, 1, reason: 'no new login per inbox check');
    expect(
      store.messages.list(MessageQuery(mailboxIds: [inbox().id])),
      hasLength(4),
    );
    await engine.dispose();
    expect(server.logins, 1);
  });

  test('stopping closes kept connections; the next sync logs in', () async {
    await setUpWith();
    final engine = SyncEngine(store, server.connector());
    expect(await engine.syncAccount(account.id), isNotNull);
    await engine.stop();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(server.open, 0);
    expect(await engine.syncAccount(account.id), isNotNull);
    expect(server.logins, 2);
    await engine.dispose();
  });

  group('the folder list', () {
    late DateTime now;
    late AccountSynchronizer synchronizer;

    setUp(() async {
      await setUpWith();
      now = DateTime.utc(2026, 11, 9, 9);
      synchronizer = AccountSynchronizer(
        store,
        server.connector(),
        MailboxSynchronizer(store, const SummaryMapper(HeaderRuleClassifier())),
        OutboxReplayer(store),
        now: () => now,
      );
    });

    test('is read at most every 15 minutes', () async {
      server.folders['Projects'] = FakeFolder();
      await synchronizer.sync(account);
      now = now.add(const Duration(minutes: 1));
      await synchronizer.sync(account, mailboxIds: {inbox().id});
      now = now.add(const Duration(minutes: 5));
      await synchronizer.sync(account);
      expect(server.since(0, 'LIST'), hasLength(1));
      now = now.add(const Duration(minutes: 10));
      await synchronizer.sync(account);
      expect(server.since(0, 'LIST'), hasLength(2));
    });

    test('a folder deleted elsewhere in between is no failure', () async {
      server.folders['Projects'] = FakeFolder()..add(subject: 'plans');
      await synchronizer.sync(account);
      expect(
        store.mailboxes.forAccount(account.id).map((m) => m.name),
        contains('Projects'),
      );
      server.folders.remove('Projects');
      now = now.add(const Duration(minutes: 5));
      await synchronizer.sync(account);
      expect(
        store.mailboxes.forAccount(account.id).map((m) => m.name),
        isNot(contains('Projects')),
      );
    });
  });
}
