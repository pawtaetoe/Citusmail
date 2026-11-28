// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Syncs of one account never overlap, and however many are asked for at
// once (the inbox check, IDLE, the user's actions, "Send later" timers),
// an account has at most one running and one waiting. Different accounts
// sync side by side.

import 'dart:async';
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
  final engines = <SyncEngine>[];

  setUp(() async {
    server = await FakeImap.start(condstore: true)
      ..latency = const Duration(milliseconds: 5);
    for (var i = 0; i < 3; i++) {
      server.folders['INBOX']!.add(subject: 'inbox $i');
    }
    for (var f = 0; f < 4; f++) {
      final folder = server.folders['Folder $f'] = FakeFolder();
      folder.add(subject: 'folder $f');
    }
    server.folders['[Gmail]/Starred'] = FakeFolder(specialUse: 'Flagged')
      ..add(subject: 'starred');
    directory = Directory.systemTemp.createTempSync('scheduling_test');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
  });

  tearDown(() async {
    for (final engine in engines) {
      await engine.dispose();
    }
    engines.clear();
    store.close();
    await server.close();
    directory.deleteSync(recursive: true);
  });

  SyncEngine engine({Duration changeDelay = Duration.zero}) {
    final engine = SyncEngine(
      store,
      server.connector(),
      classifier: const HeaderRuleClassifier(),
      changeDelay: changeDelay,
    );
    engines.add(engine);
    return engine;
  }

  /// Counts, per account, the syncs started and the most running at once.
  ({Map<AccountId, int> started, Map<AccountId, int> peak}) watch(
    SyncEngine e,
  ) {
    final started = <AccountId, int>{};
    final running = <AccountId, int>{};
    final peak = <AccountId, int>{};
    e.events.listen((event) {
      final id = event.accountId;
      switch (event) {
        case AccountSyncStarted():
          started[id] = (started[id] ?? 0) + 1;
          running[id] = (running[id] ?? 0) + 1;
          if (running[id]! > (peak[id] ?? 0)) peak[id] = running[id]!;
        case AccountSynced() || AccountSyncFailed():
          running[id] = (running[id] ?? 1) - 1;
      }
    });
    return (started: started, peak: peak);
  }

  test('a burst of 20 requests: one sync running and one waiting', () async {
    final account = server.addAccount(store);
    final e = engine();
    expect(await e.syncAccount(account.id), isNotNull);
    final inbox = store.mailboxes.inbox(account.id)!;
    final counts = watch(e);

    final reports = <Future<AccountSyncReport?>>[];
    for (var i = 0; i < 20; i++) {
      switch (i % 4) {
        case 0:
          reports.add(e.syncAccount(account.id));
        case 1:
          reports.add(e.syncAccount(account.id, mailboxIds: {inbox.id}));
        case 2:
          e.requestSync(account.id);
        default:
          e
            ..requestSync(account.id, mailboxIds: {inbox.id})
            ..checkInboxes();
      }
    }
    final done = await Future.wait(reports);
    // The requests' own delay has passed: they joined the waiting sync, or
    // ran after it.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await e.syncAccount(account.id);

    expect(done, everyElement(isNotNull), reason: 'every caller has a report');
    expect(counts.peak[account.id], 1, reason: 'never two at once');
    expect(
      counts.started[account.id],
      lessThanOrEqualTo(4),
      reason:
          'the burst: one running, one waiting; the delayed requests and '
          'the last call: at most one more each',
    );
  });

  test('accounts sync side by side', () async {
    final first = server.addAccount(store);
    final second = server.addAccount(store, email: 'bob@citusmail.test');
    final e = engine();
    final order = <String>[];
    e.events.listen((event) {
      final who = event.accountId == first.id ? 'first' : 'second';
      switch (event) {
        case AccountSyncStarted():
          order.add('$who started');
        case AccountSynced():
          order.add('$who synced');
        case AccountSyncFailed(:final failure):
          order.add('$who failed: ${failure.message}');
      }
    });
    await Future.wait([e.syncAccount(first.id), e.syncAccount(second.id)]);
    expect(order.take(2), ['first started', 'second started']);
    expect(order.skip(2), unorderedEquals(['first synced', 'second synced']));
  });

  test('requests merged within the delay keep the widest', () async {
    final account = server.addAccount(store);
    final e = engine(changeDelay: const Duration(milliseconds: 50));
    expect(await e.syncAccount(account.id), isNotNull);
    final inbox = store.mailboxes.inbox(account.id)!;
    final starred = store.mailboxes
        .forAccount(account.id)
        .firstWhere((m) => m.isView);
    final synced = <AccountSyncReport>[];
    e.events.listen((event) {
      if (event case AccountSynced(:final report)) synced.add(report);
    });

    // The user acted on mail (every folder), then IDLE saw the inbox
    // change, then the user opened Starred.
    e
      ..requestSync(account.id)
      ..requestSync(account.id, mailboxIds: {inbox.id})
      ..requestSync(account.id, mailboxIds: {starred.id});
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(synced, hasLength(1), reason: 'one sync for all three');
    final folders = synced.single.mailboxes.keys.toSet();
    expect(folders, contains(starred.id), reason: 'the view asked for');
    expect(
      folders,
      containsAll([
        for (final m in store.mailboxes.forAccount(account.id))
          if (!m.isView) m.id,
      ]),
      reason: 'the full sync was not lost',
    );
  });

  test('a waiting sync is dropped when the engine stops', () async {
    final account = server.addAccount(store);
    final e = engine();
    final counts = watch(e);
    final running = e.syncAccount(account.id);
    final waiting = e.syncAccount(account.id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await e.stop();
    expect(await running, isNotNull);
    expect(await waiting, isNull, reason: 'not started after stop');
    expect(counts.started[account.id], 1);
    // Asked for once stopped, it runs again.
    expect(await e.syncAccount(account.id), isNotNull);
  });

  test('nothing is thrown where nobody waits for it: after dispose, and '
      'when the store cannot be read', () async {
    final account = server.addAccount(store);
    final errors = <Object>[];
    await runZonedGuarded(() async {
      final e = engine();
      expect(await e.syncAccount(account.id), isNotNull);
      await e.dispose();
      expect(await e.syncAccount(account.id), isNull);
      e.requestSync(account.id);

      final other = engine();
      store.close();
      expect(await other.syncAccount(account.id), isNull);
      other
        ..checkInboxes()
        ..requestSync(account.id);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }, (error, _) => errors.add(error));
    // tearDown closes it again (a no-op) and disposes the engines.
    expect(errors, isEmpty);
  });
}
