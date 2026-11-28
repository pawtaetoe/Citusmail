// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Mail servers allow a handful of connections per account, shared by all
// the user's devices (Gmail about 15), and refuse the next login with "Too
// many simultaneous connections". Every connection the engine opens counts
// in one budget per account; the user's work goes first; a refusal lowers
// the budget and is retried; and every connection opened is closed again.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
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

  Future<void> start({bool idle = false, bool gmail = false}) async {
    server = await FakeImap.start(idle: idle, gmail: gmail, condstore: true);
    directory = Directory.systemTemp.createTempSync('connections_test');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
    account = server.addAccount(store);
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
    int perAccount = 4,
    Duration waitTimeout = const Duration(seconds: 10),
    SyncSettings settings = const SyncSettings(),
    Duration changeDelay = const Duration(milliseconds: 500),
  }) {
    final engine = SyncEngine(
      store,
      server.connector(),
      classifier: const HeaderRuleClassifier(),
      settings: settings,
      changeDelay: changeDelay,
      connections: ConnectionBudget(
        server.connector(),
        perAccount: perAccount,
        waitTimeout: waitTimeout,
      ),
      refusalRetryDelays: const [
        Duration(milliseconds: 20),
        Duration(milliseconds: 50),
      ],
    );
    engines.add(engine);
    return engine;
  }

  /// Waits until [done], at most a few seconds.
  Future<void> until(
    bool Function() done, {
    String? reason,
    Duration within = const Duration(seconds: 5),
  }) async {
    final end = DateTime.now().add(within);
    while (!done()) {
      if (DateTime.now().isAfter(end)) fail('timed out: ${reason ?? ''}');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  StoredMailbox inbox() => store.mailboxes.inbox(account.id)!;
  List<StoredMessage> inboxMessages() =>
      store.messages.list(MessageQuery(mailboxIds: [inbox().id]));
  bool idling() => server.commands.contains('IDLE');
  bool idlingNow() => server.inIdle > 0;

  void addFolders(int count, {int messages = 3}) {
    for (var i = 0; i < messages; i++) {
      server.folders['INBOX']!.add(subject: 'inbox $i');
    }
    for (var f = 0; f < count; f++) {
      final folder = server.folders['Folder $f'] = FakeFolder();
      for (var i = 0; i < messages; i++) {
        folder.add(subject: 'folder $f message $i');
      }
    }
  }

  group('the budget', () {
    test(
      'a full sync, an opened message and IDLE never open more than 4',
      () async {
        await start(idle: true);
        addFolders(8);
        // Like Gmail: one more login than that is refused.
        server
          ..maxLoggedIn = 4
          ..latency = const Duration(milliseconds: 3);
        final e = engine()..start();
        await until(idling, reason: 'IDLE');
        final message = inboxMessages().first;

        final sync = e.syncAccount(account.id);
        final body = e.loadBody(message.id);
        expect(await sync, isNotNull);
        expect(await body, isNotEmpty);
        expect(server.refused, 0, reason: 'no login refused');
        expect(server.peakLoggedIn, lessThanOrEqualTo(4));
        expect(e.connections.openFor(account.id), lessThanOrEqualTo(4));
      },
    );

    test(
      'a full sync syncs on one connection when the budget is full',
      () async {
        await start();
        addFolders(4);
        server.maxLoggedIn = 1;
        final e = engine(perAccount: 1);
        final report = await e.syncAccount(account.id);
        expect(report, isNotNull);
        expect(report!.mailboxes, hasLength(5), reason: 'every folder');
        expect(server.logins, 1);
        expect(server.refused, 0);
      },
    );

    test('a full sync uses extra connections while there is room, and '
        'keeps only one afterwards', () async {
      await start();
      addFolders(6);
      server.latency = const Duration(milliseconds: 3);
      final e = engine();
      expect(await e.syncAccount(account.id), isNotNull);
      expect(server.peakLoggedIn, 3, reason: 'SyncSettings.connections');
      await until(() => server.loggedIn == 1, reason: 'extras closed');
      expect(e.connections.openFor(account.id), 1);
      // The next sync reuses the kept one.
      expect(
        await e.syncAccount(account.id, mailboxIds: {inbox().id}),
        isNotNull,
      );
      expect(server.logins, 3);
    });

    test('waiting work goes on when a connection comes free', () async {
      await start();
      final budget = ConnectionBudget(server.connector(), perAccount: 1);
      addTearDown(budget.close);
      final sync = Object(), user = Object(), other = Object();
      final first = await budget.take(account, owner: sync);
      var waited = false;
      final waiting = budget
          .take(account, owner: user, priority: ConnectionPriority.user)
          .whenComplete(() => waited = true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(waited, isFalse, reason: 'the budget is full');
      expect(budget.openFor(account.id), 1);

      // Given back: handed over, still logged in.
      await budget.give(account, first, owner: sync);
      final second = await waiting;
      expect(second, same(first));
      expect(server.logins, 1);

      // Closed: the one waiting logs in on the freed slot.
      final third = budget.take(account, owner: other);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await budget.discard(account, second);
      final client = await third;
      expect(server.logins, 2);
      expect(budget.openFor(account.id), 1);
      await budget.discard(account, client);
      expect(budget.openFor(account.id), 0);
    });

    test('the user\'s work goes ahead of background work', () async {
      await start();
      final budget = ConnectionBudget(server.connector(), perAccount: 1);
      addTearDown(budget.close);
      final holder = Object();
      final held = await budget.take(account, owner: holder);
      final order = <String>[];
      Future<void> queue(String name, ConnectionPriority priority) async {
        final owner = Object();
        final client = await budget.take(
          account,
          owner: owner,
          priority: priority,
        );
        order.add(name);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await budget.give(account, client, owner: owner);
      }

      final waiting = [
        queue('sync', ConnectionPriority.background),
        queue('read ahead', ConnectionPriority.background),
        queue('open message', ConnectionPriority.user),
        queue('search', ConnectionPriority.user),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(budget.userWaiting(account.id), isTrue);
      await budget.give(account, held, owner: holder);
      await Future.wait(waiting);
      expect(order, ['open message', 'search', 'sync', 'read ahead']);
      expect(server.logins, 1, reason: 'handed from one to the next');
    });

    test('a wait that takes too long fails, and frees its place', () async {
      await start();
      final budget = ConnectionBudget(
        server.connector(),
        perAccount: 1,
        waitTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(budget.close);
      final owner = Object();
      final held = await budget.take(account, owner: owner);
      await expectLater(
        budget.take(account, owner: Object()),
        throwsA(isA<ConnectionBusyException>()),
      );
      expect(budget.contended(account.id), isFalse);
      await budget.give(account, held, owner: owner);
    });

    test('the user\'s work takes a sync connection kept idle', () async {
      await start();
      addFolders(0);
      final e = engine(perAccount: 1);
      expect(await e.syncAccount(account.id), isNotNull);
      expect(await e.loadBody(inboxMessages().first.id), isNotEmpty);
      expect(server.logins, 1, reason: 'the kept sync connection');
    });

    test('IDLE hands its connection to the user\'s work', () async {
      await start(idle: true);
      addFolders(0);
      final e = engine(perAccount: 1)..start();
      await until(idling, reason: 'IDLE');
      final body = await e
          .loadBody(inboxMessages().first.id)
          .timeout(const Duration(seconds: 5));
      expect(body, isNotEmpty);
      expect(server.logins, 1, reason: 'one connection all along');
    });

    test(
      'a full sync hands its connection to the user between folders',
      () async {
        await start();
        addFolders(6);
        server.latency = const Duration(milliseconds: 5);
        final e = engine(perAccount: 1);
        expect(await e.syncAccount(account.id), isNotNull);
        final message = inboxMessages().first;
        final mark = server.commands.length;
        final sync = e.syncAccount(account.id);
        // Once the sync is under way (a folder or two).
        await until(() => server.since(mark, 'SELECT').length >= 2);
        final opened = DateTime.now();
        expect(await e.loadBody(message.id), isNotEmpty);
        final waited = DateTime.now().difference(opened);
        final report = await sync;
        expect(report, isNotNull);
        expect(report!.mailboxes, hasLength(7));
        expect(server.logins, 1);
        // The message did not wait for the whole sync.
        expect(
          server.commands.lastIndexWhere((c) => c.contains('BODY.PEEK[]')),
          lessThan(
            server.commands.lastIndexWhere((c) => c.startsWith('SELECT')),
          ),
        );
        expect(waited, lessThan(const Duration(seconds: 2)));
      },
    );
  });

  group('waits that end', () {
    test('a wait for a removed account ends, and nothing logs in for it '
        'later', () async {
      await start();
      final budget = ConnectionBudget(
        server.connector(),
        perAccount: 1,
        waitTimeout: const Duration(seconds: 5),
      );
      addTearDown(budget.close);
      final owner = Object();
      final held = await budget.take(account, owner: owner);
      final waiting = expectLater(
        budget
            .take(account, owner: Object())
            .timeout(const Duration(seconds: 2)),
        throwsA(isA<ConnectionBusyException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await budget.forget(account.id);
      await waiting;
      await budget.give(account, held, owner: owner);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(server.logins, 1, reason: 'no login with what it was');
      expect(budget.openFor(account.id), 0);
    });

    test('background work that has waited long is not overtaken by the '
        'user\'s work any more', () async {
      await start();
      var now = DateTime.utc(2026, 11, 28, 9);
      final budget = ConnectionBudget(
        server.connector(),
        perAccount: 1,
        now: () => now,
      );
      addTearDown(budget.close);
      final holder = Object();
      final held = await budget.take(account, owner: holder);
      final order = <String>[];
      Future<void> queue(String name, ConnectionPriority priority) async {
        final owner = Object();
        final client = await budget.take(
          account,
          owner: owner,
          priority: priority,
        );
        order.add(name);
        await budget.give(account, client, owner: owner);
      }

      final sync = queue('sync', ConnectionPriority.background);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      now = now.add(budget.ageAfter);
      final open = queue('open message', ConnectionPriority.user);
      final readAhead = queue('read ahead', ConnectionPriority.background);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await budget.give(account, held, owner: holder);
      await Future.wait([sync, open, readAhead]);
      expect(order, ['sync', 'open message', 'read ahead']);
    });

    test('a full sync hands its connection to the user between the steps '
        'after the folders too', () async {
      await start(gmail: true);
      server.folders['[Gmail]/All Mail'] = FakeFolder(specialUse: 'All');
      addFolders(3);
      for (var i = 0; i < 4; i++) {
        server.folders['[Gmail]/All Mail']!.add(subject: 'archived $i');
      }
      final e = engine(perAccount: 1);
      expect(await e.syncAccount(account.id), isNotNull);
      final message = inboxMessages().first;
      server.latency = const Duration(milliseconds: 5);
      Future<Uint8List>? body;
      // Once the sync is at its last folder, the user opens a message.
      server.dropOn = (command) {
        if (command.contains('Folder 2')) {
          body ??= e.loadBody(message.id);
        }
        return false;
      };
      expect(await e.syncAccount(account.id), isNotNull);
      expect(await body, isNotEmpty);
      final opened = server.commands.indexWhere(
        (c) => c.contains('BODY.PEEK[]'),
      );
      final backfill = server.commands.lastIndexWhere(
        (c) => c.contains('[Gmail]/All Mail'),
      );
      expect(opened, greaterThan(0));
      expect(
        opened,
        lessThan(backfill),
        reason: 'the message did not wait for the archived mail',
      );
    });
  });

  group('no deadlock', () {
    for (final perAccount in [1, 2]) {
      test('a budget of $perAccount: a full sync, opening a message, a '
          'search on the server, older mail, a new folder, reading ahead '
          'and IDLE all finish', () async {
        await start(idle: true, gmail: true);
        server.folders['[Gmail]/All Mail'] = FakeFolder(specialUse: 'All');
        addFolders(6, messages: 6);
        for (var i = 0; i < 6; i++) {
          server.folders['[Gmail]/All Mail']!.add(subject: 'archived $i');
        }
        server
          ..maxLoggedIn = perAccount
          ..latency = const Duration(milliseconds: 2);
        final e = engine(
          perAccount: perAccount,
          waitTimeout: const Duration(seconds: 30),
          settings: const SyncSettings(initialWindow: 3, backfillBatch: 2),
          changeDelay: const Duration(hours: 1),
        )..start();
        await until(idling, reason: 'IDLE');
        final messages = inboxMessages();
        // A change for the server, replayed by the sync.
        MailActions(store).markRead([messages.last]);
        server.folders['INBOX']!.add(subject: 'new');

        final work = await Future.wait<Object?>([
          e.syncAccount(account.id),
          e.loadBody(messages.first.id),
          e.searchServer(account.id, 'archived'),
          e.fetchOlder(inbox().id),
          e.createFolder(account.id, 'Projects'),
          e.loadBody(messages[1].id, background: true),
          e.syncAccount(account.id, mailboxIds: {inbox().id}),
        ]).timeout(const Duration(seconds: 60));

        expect(work[0], isNotNull, reason: 'the full sync');
        expect(work[1], isNotEmpty, reason: 'the message');
        expect(work[2], isNotEmpty, reason: 'the search');
        expect(work[6], isNotNull, reason: 'the inbox check');
        expect(server.refused, 0);
        expect(server.peakLoggedIn, lessThanOrEqualTo(perAccount));
        // IDLE comes back once nothing waits.
        final mark = server.commands.length;
        await until(
          () => server.since(mark, 'IDLE').isNotEmpty || idlingNow(),
          reason: 'IDLE again',
          within: const Duration(seconds: 20),
        );
      });
    }
  });

  group('when the server refuses', () {
    test('"Too many simultaneous connections" lowers the budget, closes kept '
        'connections, and the message opens on a retry', () async {
      await start();
      addFolders(0);
      final e = engine();
      expect(await e.syncAccount(account.id), isNotNull);
      expect(e.connections.openFor(account.id), 1, reason: 'kept for later');
      // Another device takes the last connection the server allows.
      server.maxLoggedIn = 2;
      final otherDevice = await server.connector().imap(account);
      addTearDown(otherDevice.logout);
      expect(server.loggedIn, 2);

      final body = await e.loadBody(inboxMessages().first.id);
      expect(body, isNotEmpty, reason: 'no error reached the caller');
      expect(server.refused, 1);
      expect(e.connections.limitFor(account.id), 2);
      expect(
        e.connections.openFor(account.id),
        1,
        reason: 'the kept sync connection was closed',
      );
      expect(server.loggedIn, 2);
    });

    test('the error reaches the caller after the retries', () async {
      await start();
      addFolders(0);
      final e = engine();
      expect(await e.syncAccount(account.id), isNotNull);
      final message = inboxMessages().first;
      await e.accountChanged(account.id);
      server.maxLoggedIn = 0;
      await expectLater(
        e.loadBody(message.id),
        throwsA(
          isA<ImapAuthenticationException>().having(
            (e) => e.temporary,
            'temporary',
            isTrue,
          ),
        ),
      );
      expect(server.refused, 3, reason: 'tried, then twice again');
    });

    test('the lowered budget comes back over half an hour', () async {
      await start();
      var now = DateTime.utc(2026, 11, 28, 9);
      final budget = ConnectionBudget(server.connector(), now: () => now);
      addTearDown(budget.close);
      server.maxLoggedIn = 0;
      await expectLater(
        budget.take(account, owner: Object()),
        throwsA(isA<ImapAuthenticationException>()),
      );
      expect(budget.limitFor(account.id), 2);
      now = now.add(const Duration(minutes: 15));
      expect(budget.limitFor(account.id), 3);
      now = now.add(const Duration(minutes: 15));
      expect(budget.limitFor(account.id), 4);
      expect(budget.openFor(account.id), 0);
    });

    test('background checks back off after a refusal', () async {
      await start();
      store.mailboxes.replaceAll(account.id, [
        ImapMailboxInfo(encodedName: 'INBOX', delimiter: '/', attributes: {}),
      ]);
      server.maxLoggedIn = 0;
      final e = engine(changeDelay: Duration.zero);
      final failures = <SyncFailure>[];
      var started = 0;
      e.events.listen((event) {
        if (event is AccountSyncFailed) failures.add(event.failure);
        if (event is AccountSyncStarted) started++;
      });
      expect(await e.syncAccount(account.id), isNull);
      expect(failures.single.kind, SyncFailureKind.server, reason: '#109');
      e.checkInboxes();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(started, 1, reason: 'no new attempt in the backoff');
      // Asked for directly, it still runs.
      server.maxLoggedIn = null;
      expect(await e.syncAccount(account.id), isNotNull);
      e.checkInboxes();
      await until(() => started == 3, reason: 'checks again once it worked');
    });
  });

  group('no leaks', () {
    test('every connection opened is closed after syncs, failures and '
        'dispose', () async {
      await start(idle: true, gmail: true);
      server.folders
        ..['[Gmail]/All Mail'] = FakeFolder(specialUse: 'All')
        ..['[Gmail]/Trash'] = FakeFolder(specialUse: 'Trash');
      addFolders(4, messages: 6);
      for (var i = 0; i < 4; i++) {
        server.folders['[Gmail]/All Mail']!.add(subject: 'archived $i');
      }
      final e = engine(
        settings: const SyncSettings(initialWindow: 3, backfillBatch: 1),
        // No syncs of their own after a change: only those asked for here.
        changeDelay: const Duration(hours: 1),
      )..start();
      await until(idling, reason: 'IDLE');
      final messages = inboxMessages();
      expect(await e.loadBody(messages.first.id), isNotEmpty);
      await e.loadBody(messages.last.id, background: true);
      expect(await e.searchServer(account.id, 'archived'), isNotEmpty);
      expect(await e.fetchOlder(inbox().id), greaterThan(0));
      await e.createFolder(account.id, 'Projects');
      // A message deleted on the server meanwhile.
      server.folders['INBOX']!.remove(messages[1].uid);
      await expectLater(
        e.loadBody(messages[1].id),
        throwsA(isA<BodyUnavailableException>()),
      );
      // The network drops in the middle of a sync, then of opening one.
      var drops = 1;
      server.dropOn = (c) => c.startsWith('SELECT') && drops-- > 0;
      expect(await e.syncAccount(account.id), isNull);
      server.dropOn = (c) => c.startsWith('UID FETCH') && drops-- > 0;
      drops = 2;
      final notOpened = inboxMessages().firstWhere(
        (m) => store.messages.body(m.id) == null,
      );
      await expectLater(
        e.loadBody(notOpened.id),
        throwsA(isA<MailConnectionException>()),
      );
      server.dropOn = null;
      expect(await e.syncAccount(account.id), isNotNull);
      // Refused logins.
      await e.accountChanged(account.id);
      server.maxLoggedIn = 0;
      expect(await e.syncAccount(account.id), isNull);
      server.maxLoggedIn = null;
      expect(await e.syncAccount(account.id), isNotNull);

      expect(server.peakLoggedIn, lessThanOrEqualTo(4));
      await e.dispose();
      expect(e.connections.openFor(account.id), 0);
      await until(() => server.open == 0, reason: 'all closed');
      expect(server.loggedIn, 0);
    });

    test('stopping waits for IDLE to log out', () async {
      await start(idle: true);
      addFolders(0);
      final e = engine()..start();
      await until(idling, reason: 'IDLE');
      await e.stop();
      expect(e.connections.openFor(account.id), 0);
      await until(() => server.open == 0, reason: 'all closed');
    });

    test('stopping while a sync waits for a connection', () async {
      await start(idle: true);
      addFolders(0);
      final e = engine(perAccount: 1);
      // The budget is taken: the first sync waits in the queue.
      final held = await e.connections.take(account, owner: Object());
      e.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(e.connections.contended(account.id), isTrue);
      await e.dispose().timeout(const Duration(seconds: 2));
      expect(server.logins, 1, reason: 'no connection opened for it');
      await e.connections.discard(account, held);
      expect(e.connections.openFor(account.id), 0);
      await until(() => server.open == 0, reason: 'all closed');
    });
  });
}
