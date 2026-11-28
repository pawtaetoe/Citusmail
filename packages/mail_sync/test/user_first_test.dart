// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The user's work goes ahead of syncing: a sync hands its connection over
// inside its long steps, between two batches, and a message the user
// sends goes out without waiting for a sync. And nothing starves: a sync
// that handed its connection over gets it back after a bounded wait, the
// user's work moves up the tiers as it waits, and background work goes
// on alongside. See docs/architecture.md, "Connections" and
// "Concurrency".

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
  final engines = <SyncEngine>[];

  /// Each connection handed out by the budget, in order.
  final taken = <({DateTime at, ConnectionPriority priority, bool back})>[];

  Future<void> start({bool condstore = true}) async {
    server = await FakeImap.start(condstore: condstore);
    server.folders['Sent'] = FakeFolder(specialUse: 'Sent');
    directory = Directory.systemTemp.createTempSync('user_first_test');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
    account = server.addAccount(store);
    taken.clear();
  }

  tearDown(() async {
    for (final engine in engines) {
      await engine.dispose();
    }
    engines.clear();
    store.close();
    await server.close();
    directory.deleteSync(recursive: true);
  });

  SyncEngine engine({
    int perAccount = 1,
    SyncSettings settings = const SyncSettings(initialWindow: 5000),
    Duration fullSyncInterval = const Duration(hours: 1),
    Duration? inboxCheckInterval,
    Duration changeDelay = const Duration(hours: 1),
  }) {
    final engine = SyncEngine(
      store,
      server.connector(),
      classifier: const HeaderRuleClassifier(),
      settings: settings,
      fullSyncInterval: fullSyncInterval,
      inboxCheckInterval: inboxCheckInterval,
      changeDelay: changeDelay,
      connections: ConnectionBudget(
        server.connector(),
        perAccount: perAccount,
        waitTimeout: const Duration(seconds: 60),
        onTaken: (_, priority, {required afterHandOver}) => taken.add((
          at: DateTime.now(),
          priority: priority,
          back: afterHandOver,
        )),
      ),
    );
    engines.add(engine);
    return engine;
  }

  Future<void> until(
    bool Function() done, {
    String? reason,
    Duration within = const Duration(seconds: 10),
  }) async {
    final end = DateTime.now().add(within);
    while (!done()) {
      if (DateTime.now().isAfter(end)) fail('timed out: ${reason ?? ''}');
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  StoredMailbox inbox() => store.mailboxes.inbox(account.id)!;
  StoredMailbox folder(String name) => store.mailboxes
      .forAccount(account.id)
      .firstWhere((m) => m.encodedName == name);
  List<StoredMessage> messagesIn(String name) => store.messages.list(
    MessageQuery(mailboxIds: [folder(name).id], limit: 100000),
  );
  List<StoredMessage> inboxMessages() => store.messages.list(
    MessageQuery(mailboxIds: [inbox().id], limit: 100000),
  );

  bool isBatch(String c) => c.startsWith('UID FETCH') && c.contains('ENVELOPE');
  bool isBody(String c) => c.contains('BODY.PEEK[]');

  /// Indexes of the sync's FETCHes of summaries since [mark].
  List<int> batches(int mark) => [
    for (var i = mark; i < server.commands.length; i++)
      if (isBatch(server.commands[i])) i,
  ];

  /// Lists the folders and syncs the inbox, then gives the server [count]
  /// messages in "Big" for the next full sync to fetch: its first sync.
  Future<void> bigFolder(SyncEngine e, int count, {int inboxSize = 5}) async {
    for (var i = 0; i < inboxSize; i++) {
      server.folders['INBOX']!.add(subject: 'inbox $i');
    }
    final big = server.folders['Big'] = FakeFolder();
    expect(await e.syncAccount(account.id, mailboxIds: {}), isNotNull);
    expect(
      await e.syncAccount(account.id, mailboxIds: {inbox().id}),
      isNotNull,
    );
    for (var i = 0; i < count; i++) {
      big.add(subject: 'big $i');
    }
  }

  Uint8List raw(String id) => Uint8List.fromList(
    utf8.encode(
      'From: alice@citusmail.test\r\nTo: bob@x.example\r\n'
      'Subject: sent $id\r\nMessage-ID: <$id>\r\n\r\nHi.\r\n',
    ),
  );

  /// Queues a message to send now (its undo delay is over).
  void queueSend(String id) => store.outbox.enqueue(
    account.id,
    SendAction(
      from: account.email,
      recipients: const ['bob@x.example'],
      sentMailboxId: folder('Sent').id,
    ),
    data: raw(id),
    notBefore: DateTime.now().subtract(const Duration(seconds: 1)),
  );

  int inSent(String id) => server.folders['Sent']!.messages
      .where((m) => latin1.decode(m.raw).contains('<$id>'))
      .length;

  /// The longest run of the user's connections between two of the
  /// sync's (taken back after a hand-over) in [log].
  int longestUserRun(
    List<({DateTime at, ConnectionPriority priority, bool back})> log,
  ) {
    var longest = 0, run = 0;
    for (final t in log) {
      if (t.priority.isUser) {
        run++;
        if (run > longest) longest = run;
      } else {
        run = 0;
      }
    }
    return longest;
  }

  /// The longest time between two FETCHes of summaries since [mark].
  Duration longestStall(int mark) {
    final at = [for (final i in batches(mark)) server.commandTimes[i]];
    var longest = Duration.zero;
    for (var i = 1; i < at.length; i++) {
      final gap = at[i].difference(at[i - 1]);
      if (gap > longest) longest = gap;
    }
    return longest;
  }

  group('inside long steps', () {
    test('at a budget of 1, a message opened during a big first sync waits '
        'for one batch, and the sync stores everything once', () async {
      await start();
      final e = engine();
      await bigFolder(e, 3000);
      final message = inboxMessages().first;
      server.latency = const Duration(milliseconds: 10);
      final mark = server.commands.length;
      final sync = e.syncAccount(account.id);
      await until(() => batches(mark).length >= 3, reason: 'under way');
      final asked = server.commands.length;
      final opened = DateTime.now();
      expect(await e.loadBody(message.id), isNotEmpty);
      final waited = DateTime.now().difference(opened);
      final body = server.commands.indexWhere(isBody, asked);
      final report = await sync;

      final ahead = batches(asked).where((i) => i < body).length;
      printOnFailure('waited $waited, $ahead batches ahead');
      show('body load during a big first sync: waited $waited');
      expect(ahead, lessThanOrEqualTo(1), reason: 'within one batch');
      expect(waited, lessThan(const Duration(milliseconds: 500)));
      expect(report, isNotNull);
      expect(report!.mailboxes[folder('Big').id]!.added, 3000);
      final stored = store.messages.uids(folder('Big').id);
      expect(stored, hasLength(3000));
      expect(stored.toSet(), hasLength(3000));
      expect(
        batches(mark),
        hasLength(30),
        reason: 'nothing fetched again after the hand-over',
      );
      expect(server.logins, 1, reason: 'one connection all along');
    });

    test('the folder is selected again after the hand-over, and a reset '
        'meanwhile (UIDVALIDITY) starts it afresh', () async {
      await start();
      final e = engine();
      await bigFolder(e, 2000);
      final message = inboxMessages().first;
      server.latency = const Duration(milliseconds: 5);
      final mark = server.commands.length;
      final sync = e.syncAccount(account.id);
      await until(() => batches(mark).length >= 3, reason: 'under way');
      // While the message is fetched, the folder is recreated on the
      // server: another UIDVALIDITY, other messages.
      server.dropOn = (command) {
        if (isBody(command) && server.folders['Big']!.uidValidity == 1) {
          final fresh = server.folders['Big'] = FakeFolder()..uidValidity = 7;
          for (var i = 0; i < 40; i++) {
            fresh.add(subject: 'fresh $i');
          }
        }
        return false;
      };
      expect(await e.loadBody(message.id), isNotEmpty);
      final report = await sync;
      expect(report, isNotNull);
      final result = report!.mailboxes[folder('Big').id]!;
      expect(result.wasReset, isTrue);
      expect(folder('Big').syncState.uidValidity, 7);
      final stored = messagesIn('Big');
      expect(stored, hasLength(40), reason: 'nothing of the old folder');
      expect(
        stored.every((m) => (m.subject ?? '').startsWith('fresh')),
        isTrue,
      );
      final after = server.commands.indexWhere(isBody, mark);
      expect(
        server.commands
            .skip(after)
            .any((c) => c.startsWith('EXAMINE') && c.contains('Big')),
        isTrue,
        reason: 'selected again on the connection that came back',
      );
    });

    for (final condstore in [false, true]) {
      test('flags and removals are compared in parts, the user going first '
          'between two (${condstore ? 'CONDSTORE' : 'plain'})', () async {
        await start(condstore: condstore);
        for (var i = 0; i < 10; i++) {
          server.folders['INBOX']!.add(subject: 'm $i');
        }
        final e = engine(
          settings: const SyncSettings(initialWindow: 100, checkBatch: 3),
        );
        expect(await e.syncAccount(account.id), isNotNull);
        server.folders['INBOX']!
          ..setFlags(2, {r'\Seen'})
          ..setFlags(9, {r'\Flagged'})
          ..remove(5);
        final mark = server.commands.length;
        expect(await e.syncAccount(account.id), isNotNull);
        final byUid = {for (final m in inboxMessages()) m.uid: m};
        expect(byUid.keys, isNot(contains(5)), reason: 'removed');
        expect(byUid, hasLength(9));
        expect(byUid[2]!.flags.seen, isTrue);
        expect(byUid[9]!.flags.flagged, isTrue);
        if (condstore) {
          expect(server.since(mark, 'UID SEARCH'), [
            'UID SEARCH UID 1:3',
            'UID SEARCH UID 4:6',
            'UID SEARCH UID 7:9',
            'UID SEARCH UID 10:*',
          ], reason: 'removals looked for in parts');
        } else {
          expect(server.since(mark, 'UID FETCH'), [
            'UID FETCH 1:3 (UID FLAGS)',
            'UID FETCH 4:6 (UID FLAGS)',
            'UID FETCH 7:9 (UID FLAGS)',
            'UID FETCH 10:* (UID FLAGS)',
          ]);
        }
      });
    }
  });

  group('sending', () {
    test(
      'at a budget of 1, a message sent during a long sync goes out at '
      'once, is saved to Sent before the next batch, and only once',
      () async {
        await start();
        final e = engine();
        await bigFolder(e, 3000);
        server.latency = const Duration(milliseconds: 10);
        final begun = server.commands.length;
        e.start(); // its first sync is the long one
        await until(() => batches(begun).length >= 3, reason: 'under way');
        queueSend('s1@citusmail.test');
        final mark = server.commands.length;
        final sent = DateTime.now();
        // Undo delay over: what the screen asks for.
        e.syncAt(account.id, DateTime.now());
        // A second sync waits meanwhile, with its own replay to come.
        final next = e.syncAccount(account.id);
        await until(() => server.delivered.isNotEmpty, reason: 'SMTP');
        final smtp = server.delivered.first.at.difference(sent);
        await until(
          () => server.since(mark, 'APPEND').isNotEmpty,
          reason: 'saved to Sent',
        );
        final append = server.commands.indexWhere(
          (c) => c.startsWith('APPEND'),
          mark,
        );
        final saved = server.commandTimes[append].difference(sent);
        expect(
          store.messages.uids(folder('Big').id).length,
          lessThan(3000),
          reason: 'the sync was still going',
        );
        show('send during a long sync: SMTP after $smtp, Sent after $saved');
        final delivered = server.delivered.first.at;
        final batchesBetween = [
          for (final i in batches(mark))
            if (i < append && server.commandTimes[i].isAfter(delivered)) i,
        ];
        expect(
          batchesBetween.length,
          lessThanOrEqualTo(2),
          reason: 'ahead of the sync\'s next batch (one may be under way)',
        );
        expect(smtp, lessThan(const Duration(milliseconds: 500)));
        expect(saved, lessThan(const Duration(seconds: 1)));
        expect(await next, isNotNull);
        expect(server.deliveredCount('s1@citusmail.test'), 1);
        expect(inSent('s1@citusmail.test'), 1);
        expect(store.outbox.all(account.id), isEmpty);
        expect(store.messages.uids(folder('Big').id), hasLength(3000));
      },
    );

    test(
      'the sync\'s replay stops for the user\'s, which goes on where it '
      'stopped: each change is replayed once, the message sent once',
      () async {
        await start();
        for (var i = 0; i < 12; i++) {
          server.folders['INBOX']!.add(subject: 'inbox $i');
        }
        final e = engine();
        expect(await e.syncAccount(account.id), isNotNull);
        final messages = inboxMessages();
        for (final m in messages) {
          MailActions(store).markRead([m]);
        }
        server.latency = const Duration(milliseconds: 10);
        final mark = server.commands.length;
        final sync = e.syncAccount(account.id);
        await until(
          () => server.since(mark, 'UID STORE').length >= 2,
          reason: 'the sync replays',
        );
        queueSend('s2@citusmail.test');
        await e.replayNow(account.id);
        expect(await sync, isNotNull);
        expect(server.deliveredCount('s2@citusmail.test'), 1);
        expect(inSent('s2@citusmail.test'), 1);
        expect(
          server.since(mark, 'UID STORE'),
          hasLength(messages.length),
          reason: 'each change once',
        );
        expect(store.outbox.all(account.id), isEmpty);
      },
    );

    test('a sync\'s replay and the user\'s at the same moment send each '
        'message once', () async {
      await start();
      server.folders['INBOX']!.add(subject: 'hello');
      final e = engine(perAccount: 2);
      expect(await e.syncAccount(account.id), isNotNull);
      server.latency = const Duration(milliseconds: 5);
      for (var round = 0; round < 6; round++) {
        final ids = [for (var i = 0; i < 4; i++) 'r$round-$i@citusmail.test'];
        ids.forEach(queueSend);
        // Both at once, in either order.
        await Future.wait([
          if (round.isEven) e.syncAccount(account.id),
          e.replayNow(account.id),
          if (round.isOdd) e.syncAccount(account.id),
        ]);
        for (final id in ids) {
          expect(server.deliveredCount(id), 1, reason: id);
          expect(inSent(id), 1, reason: id);
        }
      }
      expect(store.outbox.all(account.id), isEmpty);
    });

    test('offline, the user\'s replay leaves the message as it was, for the '
        'sync that follows', () async {
      await start();
      final e = engine();
      expect(await e.syncAccount(account.id), isNotNull);
      queueSend('offline@citusmail.test');
      final before = store.outbox.all(account.id).single;
      await server.close(); // the network is gone
      await e.replayNow(account.id);
      final after = store.outbox.all(account.id).single;
      expect(after.attempts, 0, reason: 'not counted as a try');
      expect(after.notBefore, before.notBefore, reason: 'no back-off');
      expect(after.state, OutboxState.pending);
    });
  });

  group('priorities', () {
    test('with a send, an opened message, a search and background work '
        'waiting, they go in that order', () async {
      await start();
      for (var i = 0; i < 5; i++) {
        server.folders['INBOX']!.add(subject: 'inbox $i');
      }
      server.folders['INBOX']!.add(subject: 'needle');
      final e = engine();
      expect(await e.syncAccount(account.id), isNotNull);
      final [first, second, ...] = inboxMessages();
      // Something else holds the only connection.
      final holder = Object();
      final held = await e.connections.take(account, owner: holder);
      server.latency = const Duration(milliseconds: 5);
      final work = <Future<Object?>>[
        e.syncAccount(account.id),
        e.loadBody(second.id, background: true),
        e.searchServer(account.id, 'needle'),
        e.loadBody(first.id),
      ];
      queueSend('s3@citusmail.test');
      work.add(e.replayNow(account.id));
      await until(
        () => e.connections.waitingFor(account.id).length == 5,
        reason: 'all waiting',
      );
      final mark = server.commands.length;
      await e.connections.give(account, held, owner: holder);
      await Future.wait(work);
      int at(bool Function(String c) test) =>
          server.commands.indexWhere(test, mark);
      final send = at((c) => c.startsWith('APPEND'));
      final body = at((c) => c.startsWith('UID FETCH ${first.uid} '));
      final search = at((c) => c.contains('needle'));
      final background = [
        at((c) => c.startsWith('UID FETCH ${second.uid} ')),
        at((c) => c.startsWith('LIST')),
        at((c) => c.startsWith('SELECT')),
      ].where((i) => i >= 0).reduce((a, b) => a < b ? a : b);
      expect([send, body, search, background], everyElement(greaterThan(0)));
      expect(send, lessThan(body), reason: 'send first');
      expect(body, lessThan(search), reason: 'then the opened message');
      expect(search, lessThan(background), reason: 'then the search');
      expect(server.deliveredCount('s3@citusmail.test'), 1);
    });

    test('a search waiting behind a stream of opened messages gets its turn '
        'within the bound', () async {
      await start();
      for (var i = 0; i < 300; i++) {
        server.folders['INBOX']!.add(subject: 'inbox $i');
      }
      server.folders['INBOX']!.add(subject: 'needle');
      final e = engine();
      expect(await e.syncAccount(account.id), isNotNull);
      final messages = inboxMessages();
      server.latency = const Duration(milliseconds: 10);
      // Two readers: one open always waits for the connection.
      var next = 0, stop = false;
      Future<void> reader() async {
        while (!stop && next < messages.length) {
          await e.loadBody(messages[next++].id);
        }
      }

      final readers = [reader(), reader()];
      await until(() => next > 10, reason: 'reading');
      final asked = DateTime.now();
      final opensBefore = next;
      final found = await e.searchServer(account.id, 'needle');
      final waited = DateTime.now().difference(asked);
      final overtook = next - opensBefore;
      stop = true;
      await Future.wait(readers);
      show('search behind opens: waited $waited, $overtook opens meanwhile');
      expect(found, hasLength(1));
      final budget = e.connections;
      expect(
        waited,
        lessThan(budget.promoteAfter * 2 + const Duration(milliseconds: 500)),
      );
    });
  });

  group('no starvation', () {
    test('at a budget of 1, a big first sync completes under a stream of '
        'opened messages, moving on between every few', () async {
      await start();
      final e = engine();
      await bigFolder(e, 3000, inboxSize: 250);
      final messages = inboxMessages();
      server.latency = const Duration(milliseconds: 20);
      final mark = server.commands.length;
      taken.clear();
      final sync = e.syncAccount(account.id);
      final loads = <Future<Uint8List>>[];
      var syncDone = false;
      unawaited(sync.whenComplete(() => syncDone = true));
      final end = DateTime.now().add(const Duration(seconds: 10));
      for (var i = 0; DateTime.now().isBefore(end); i++) {
        loads.add(e.loadBody(messages[i % messages.length].id));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (syncDone && i > 20) break;
      }
      final report = await sync;
      final syncEnd = taken.length;
      expect(await Future.wait(loads), everyElement(isNotEmpty));
      expect(report, isNotNull, reason: 'the sync completed');
      expect(store.messages.uids(folder('Big').id), hasLength(3000));
      final run = longestUserRun(taken.sublist(0, syncEnd));
      final stall = longestStall(mark);
      final handOvers = taken.where((t) => t.back).length;
      show(
        'stream of opens at a budget of 1: ${loads.length} opened, '
        '$handOvers hand-overs, at most $run in a row, longest stall $stall',
      );
      expect(handOvers, greaterThan(5), reason: 'the user went first');
      expect(run, lessThanOrEqualTo(e.connections.handBackAfter));
      expect(stall, lessThan(e.connections.handBackWithin));
    });

    test('at a budget of 1, a big first sync completes under a stream of '
        'sends, each sent once', () async {
      await start();
      final e = engine();
      await bigFolder(e, 3000);
      server.latency = const Duration(milliseconds: 20);
      final mark = server.commands.length;
      taken.clear();
      final sync = e.syncAccount(account.id);
      var syncDone = false;
      unawaited(sync.whenComplete(() => syncDone = true));
      final sends = <Future<void>>[];
      final ids = <String>[];
      final end = DateTime.now().add(const Duration(seconds: 6));
      for (var i = 0; DateTime.now().isBefore(end); i++) {
        final id = 'stream$i@citusmail.test';
        ids.add(id);
        queueSend(id);
        sends.add(e.replayNow(account.id));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (syncDone && i > 10) break;
      }
      final report = await sync;
      final syncEnd = taken.length;
      await Future.wait(sends);
      await e.replayNow(account.id);
      expect(report, isNotNull, reason: 'the sync completed');
      expect(store.messages.uids(folder('Big').id), hasLength(3000));
      for (final id in ids) {
        expect(server.deliveredCount(id), 1, reason: id);
        expect(inSent(id), 1, reason: id);
      }
      final run = longestUserRun(taken.sublist(0, syncEnd));
      final stall = longestStall(mark);
      show(
        'stream of sends at a budget of 1: ${ids.length} sent, at most $run '
        'in a row, longest stall $stall',
      );
      expect(run, lessThanOrEqualTo(e.connections.handBackAfter));
      expect(stall, lessThan(e.connections.handBackWithin));
    });

    for (final perAccount in [1, 2, 4]) {
      test('a budget of $perAccount: opened messages, sends and a big sync '
          'together stay within the bounds and the budget', () async {
        await start();
        final e = engine(perAccount: perAccount);
        await bigFolder(e, 2000, inboxSize: 100);
        final messages = inboxMessages();
        server
          ..maxLoggedIn = perAccount
          ..latency = const Duration(milliseconds: 10);
        final mark = server.commands.length;
        taken.clear();
        final sync = e.syncAccount(account.id);
        var syncDone = false;
        unawaited(sync.whenComplete(() => syncDone = true));
        final work = <Future<Object?>>[];
        final ids = <String>[];
        final end = DateTime.now().add(const Duration(seconds: 3));
        for (var i = 0; DateTime.now().isBefore(end); i++) {
          work.add(e.loadBody(messages[i % messages.length].id));
          if (i % 5 == 0) {
            final id = 'b$perAccount-$i@citusmail.test';
            ids.add(id);
            queueSend(id);
            work.add(e.replayNow(account.id));
          }
          await Future<void>.delayed(const Duration(milliseconds: 40));
          if (syncDone && i > 10) break;
        }
        final report = await sync;
        final syncEnd = taken.length;
        await Future.wait(work);
        await e.replayNow(account.id);
        expect(report, isNotNull);
        expect(store.messages.uids(folder('Big').id), hasLength(2000));
        for (final id in ids) {
          expect(server.deliveredCount(id), 1, reason: id);
        }
        expect(server.refused, 0);
        expect(server.peakLoggedIn, lessThanOrEqualTo(perAccount));
        final stall = longestStall(mark);
        final run = longestUserRun(taken.sublist(0, syncEnd));
        show('budget $perAccount: longest stall $stall, user run $run');
        expect(stall, lessThan(e.connections.handBackWithin));
        if (perAccount == 1) {
          expect(run, lessThanOrEqualTo(e.connections.handBackAfter));
        }
      });
    }

    test('older mail keeps coming in while inbox checks repeat and messages '
        'are read ahead', () async {
      await start();
      final old = server.folders['Old'] = FakeFolder();
      for (var i = 0; i < 600; i++) {
        old.add(subject: 'old $i');
      }
      for (var i = 0; i < 60; i++) {
        server.folders['INBOX']!.add(subject: 'inbox $i');
      }
      final e = engine(
        settings: const SyncSettings(initialWindow: 100, backfillBatch: 100),
        fullSyncInterval: const Duration(milliseconds: 300),
        inboxCheckInterval: const Duration(milliseconds: 50),
        changeDelay: const Duration(milliseconds: 10),
      );
      server.latency = const Duration(milliseconds: 5);
      e.start();
      await until(
        () =>
            store.mailboxes.inbox(account.id) != null &&
            inboxMessages().length == 60,
        reason: 'first sync',
      );
      final messages = inboxMessages();
      final readAhead = <Future<Uint8List>>[];
      final end = DateTime.now().add(const Duration(seconds: 15));
      var i = 0;
      while (store.messages.uids(folder('Old').id).length < 600 &&
          DateTime.now().isBefore(end)) {
        if (i < messages.length) {
          readAhead.add(e.loadBody(messages[i++].id, background: true));
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(
        store.messages.uids(folder('Old').id),
        hasLength(600),
        reason: 'all back-filled',
      );
      expect(await Future.wait(readAhead), everyElement(isNotEmpty));
      expect(
        server.since(0, 'SELECT INBOX').length +
            server.since(0, 'SELECT "INBOX"').length,
        greaterThan(10),
        reason: 'the inbox was checked again and again meanwhile',
      );
    });
  });
}

/// Shows a measurement in the test output.
void show(String text) {
  // ignore: avoid_print
  print(text);
}
