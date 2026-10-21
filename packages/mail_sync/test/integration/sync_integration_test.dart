// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Sync against the local test servers:
//   test-server/fmailtest up
//   FMAIL_INTEGRATION=1 dart test test/integration
//
// Tests that change mail use folders with random names.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

import '../support/test_env.dart';

void main() {
  final skip = integrationSkipReason;
  if (skip != null) {
    test('needs the local test servers', () {}, skip: skip);
    return;
  }
  final servers = TestServers.load();
  final devices = <TestDevice>[];
  TestDevice device(
    String user, {
    String imapPort = 'SECURE_IMAPS_PORT',
    bool useQresync = true,
  }) {
    final d = TestDevice.create(
      servers,
      user,
      imapPort: imapPort,
      useQresync: useQresync,
    );
    devices.add(d);
    return d;
  }

  tearDown(() {
    for (final d in devices) {
      d.dispose();
    }
    devices.clear();
  });

  test(
    'first sync of a real inbox: summaries, headers, previews, attachments',
    () async {
      final alice = device('alice');
      final report = await alice.sync(['INBOX']);
      final result = report.mailboxes.values.single;
      expect(result.method, SyncMethod.full);
      expect(result.added, 22);

      final messages = alice.messages('INBOX');
      expect(messages, hasLength(22));
      final lunch = messages.firstWhere(
        (m) => m.messageId == 'lunch-1@fmail.test',
      );
      expect(lunch.subject, 'Lunch on Friday?');
      expect(lunch.flags.seen && lunch.flags.answered, isTrue);
      expect(lunch.snippet, startsWith('Hi Alice'));

      final newsletter = messages.firstWhere(
        (m) => m.messageId == 'weekly-42@shop.example',
      );
      expect(
        alice.store.messages.headers(newsletter.id)['list-unsubscribe-post'],
        ['List-Unsubscribe=One-Click'],
      );
      expect(
        messages
            .firstWhere((m) => m.messageId == 'overdue@invoices.example')
            .hasAttachments,
        isTrue,
      );
      expect(lunch.hasAttachments, isFalse);

      final sent = alice.store.mailboxes.bySpecialUse(
        alice.account.id,
        SpecialUse.sent,
      );
      expect(sent?.name, 'Sent');

      final again = await alice.sync(['INBOX']);
      expect(again.mailboxes.values.single.method, SyncMethod.qresync);
      expect(again.mailboxes.values.single.hasChanges, isFalse);
    },
  );

  for (final (label, imapPort, qresync, method) in [
    ('QRESYNC', 'SECURE_IMAPS_PORT', true, SyncMethod.qresync),
    ('CONDSTORE', 'SECURE_IMAPS_PORT', false, SyncMethod.condstore),
    (
      'plain IMAP (limited server)',
      'LIMITED_IMAPS_PORT',
      true,
      SyncMethod.plain,
    ),
  ]) {
    test(
      'incremental sync with $label: new, changed and removed messages',
      () async {
        final folder = scratchFolder();
        final other = await servers.otherDevice('alice', imapPort: imapPort);
        await other.create(folder);
        final uids = [
          for (var i = 0; i < 3; i++)
            (await other.append(
              folder,
              testMessage('m$i'),
            ))!.destinationUids.toList().single,
        ];

        final me = device('alice', imapPort: imapPort, useQresync: qresync);
        await me.sync([folder]);
        expect(me.messages(folder), hasLength(3));

        await other.select(folder);
        await other.uidStore(SequenceSet.of([uids[0]]), FlagChange.add, {
          r'\Flagged',
        });
        await other.uidStore(SequenceSet.of([uids[1]]), FlagChange.add, {
          r'\Deleted',
        });
        await other.uidExpunge(SequenceSet.of([uids[1]]));
        await other.append(folder, testMessage('m3'));
        await other.logout();

        final result = (await me.sync([folder])).mailboxes.values.single;
        expect(result.method, method);
        expect([result.added, result.updated, result.removed], [1, 1, 1]);
        final subjects = me.messages(folder).map((m) => m.subject).toSet();
        expect(subjects, {'m0', 'm2', 'm3'});
        expect(
          me
              .messages(folder)
              .firstWhere((m) => m.subject == 'm0')
              .flags
              .flagged,
          isTrue,
        );
      },
    );
  }

  test('a new UIDVALIDITY rebuilds the folder cache', () async {
    final folder = scratchFolder();
    final other = await servers.otherDevice('alice');
    await other.create(folder);
    await other.append(folder, testMessage('before'));
    final me = device('alice');
    await me.sync([folder]);
    final before = me.mailbox(folder).syncState.uidValidity;

    // Deleting and recreating a folder gives it a new UIDVALIDITY.
    await other.select('INBOX');
    await other.deleteMailbox(folder);
    await other.create(folder);
    await other.append(folder, testMessage('after'));
    await other.logout();

    final result = (await me.sync([folder])).mailboxes.values.single;
    expect(result.wasReset, isTrue);
    expect(me.mailbox(folder).syncState.uidValidity, isNot(before));
    expect(me.messages(folder).map((m) => m.subject), ['after']);
  });

  group('sorting', () {
    test('the seeded inbox is sorted by header rules', () async {
      final alice = device('alice');
      await alice.sync(['INBOX']);
      Set<String?> subjects(MessageCategory category) => alice.store.messages
          .list(MessageQuery.unified(category, limit: 500))
          .map((m) => m.subject)
          .toSet();

      expect(subjects(MessageCategory.newsletters), {
        '50% off everything this week',
        "Today's deals",
        '[project-dev] Proposal: drop Python 3.9',
      });
      expect(subjects(MessageCategory.notifications), {
        'Re: [owner/repo] Fix crash on startup (PR #12)',
        'Reset your password',
      });
      expect(
        alice.store.messages.list(
          const MessageQuery.unified(MessageCategory.people, limit: 500),
        ),
        hasLength(17),
      );
      final list = alice
          .messages('INBOX')
          .firstWhere((m) => m.subject!.startsWith('[project-dev]'));
      expect(list.listId, 'dev.lists.project.example');
    });

    test('a correction covers earlier and later mail across syncs', () async {
      final folder = scratchFolder();
      Uint8List newsletter(int n) => utf8.encode(
        'From: Shop Weekly <news@shop.example>\r\n'
        'To: alice@fmail.test\r\n'
        'Subject: Offer $n\r\n'
        'Message-ID: <offer-$n-$folder@shop.example>\r\n'
        'Date: Thu, 22 Oct 2026 10:0$n:00 +0000\r\n'
        'List-Unsubscribe: <mailto:leave@shop.example>\r\n'
        '\r\n'
        'Offer $n\r\n',
      );
      final other = await servers.otherDevice('alice');
      await other.create(folder);
      await other.append(folder, newsletter(1));

      final me = device('alice');
      await me.sync([folder]);
      final first = me.messages(folder).single;
      expect(first.category, MessageCategory.newsletters);

      final move = CategoryCorrections(me.store)
          .move(first, MessageCategory.people);
      expect(move!.choice.scope, ChoiceScope.sender);
      await other.append(folder, newsletter(2));
      await other.logout();
      await me.sync([folder]);
      await me.sync([folder]);

      final messages = me.messages(folder);
      expect(messages, hasLength(2));
      for (final m in messages) {
        expect(m.category, MessageCategory.people, reason: m.subject);
        expect(m.categorySource, CategorySource.manual);
      }
    });
  });

  group('offline actions', () {
    late String folder;
    late TestDevice me;
    setUp(() async {
      folder = scratchFolder();
      final other = await servers.otherDevice('alice');
      await other.create(folder);
      for (var i = 0; i < 3; i++) {
        await other.append(folder, testMessage('a$i'));
      }
      await other.logout();
      me = device('alice');
      await me.sync([folder]);
    });

    Future<Set<String>> serverFlags(String subject) async {
      final other = await servers.otherDevice('alice');
      await other.select(folder, readOnly: true);
      final found = await other.uidSearch(
        SearchCriteria.header('Subject', subject),
      );
      final fetched = await other.uidFetch(
        found.matches,
        FetchItems.flagsOnly(),
      );
      await other.logout();
      return fetched.messages.single.flags!;
    }

    test(
      'mark read: local at once, server after sync, queue emptied',
      () async {
        final message = me
            .messages(folder)
            .firstWhere((m) => m.subject == 'a0');
        me.actions.markRead([message]);
        expect(
          me.store.messages.byId(message.id)!.flags.seen,
          isTrue,
          reason: 'local change is immediate',
        );
        expect(
          await serverFlags('a0'),
          isNot(contains(r'\Seen')),
          reason: 'not yet on the server',
        );

        final report = await me.sync([folder]);
        expect(report.replay.completed, 1);
        expect(await serverFlags('a0'), contains(r'\Seen'));
        expect(me.store.outbox.all(me.account.id), isEmpty);
        expect(me.store.messages.byId(message.id)!.flags.seen, isTrue);
      },
    );

    test('a local change waiting for retry is not undone by sync', () async {
      final message = me.messages(folder).firstWhere((m) => m.subject == 'a2');
      me.actions.markRead([message]);
      final entry = me.store.outbox.all(me.account.id).single;
      // The server was unreachable for this action: retry only later.
      me.store.outbox.retryLater(
        entry.id,
        'offline',
        DateTime.now().add(const Duration(hours: 1)),
      );

      final report = await me.sync([folder]);
      expect(report.replay.completed, 0, reason: 'not due yet');
      expect(await serverFlags('a2'), isNot(contains(r'\Seen')));
      expect(
        me.store.messages.byId(message.id)!.flags.seen,
        isTrue,
        reason: 'local change kept',
      );

      me.store.outbox.retryLater(
        entry.id,
        'offline',
        DateTime.now().subtract(const Duration(seconds: 1)),
      );
      await me.sync([folder]);
      expect(await serverFlags('a2'), contains(r'\Seen'));
    });

    test('move and delete reach the server; the cache follows', () async {
      final target = scratchFolder('Target');
      final other = await servers.otherDevice('alice');
      await other.create(target);
      await other.logout();
      await me.sync([folder, target]);

      final messages = me.messages(folder);
      me.actions.move([
        messages.firstWhere((m) => m.subject == 'a0'),
      ], me.mailbox(target));
      me.actions.delete([messages.firstWhere((m) => m.subject == 'a1')]);
      expect(me.messages(folder).map((m) => m.subject), ['a2']);

      await me.sync([folder, target, 'Trash']);
      expect(me.messages(folder).map((m) => m.subject), ['a2']);
      expect(me.messages(target).map((m) => m.subject), ['a0']);
      expect(me.messages('Trash').map((m) => m.subject), contains('a1'));
    });

    test(
      'acting on a message another device already removed is harmless',
      () async {
        final message = me
            .messages(folder)
            .firstWhere((m) => m.subject == 'a0');
        final other = await servers.otherDevice('alice');
        await other.select(folder);
        await other.uidStore(SequenceSet.of([message.uid]), FlagChange.add, {
          r'\Deleted',
        });
        await other.uidExpunge(SequenceSet.of([message.uid]));
        await other.logout();

        me.actions.markFlagged([message]);
        me.actions.delete([message]);
        final report = await me.sync([folder]);
        expect(report.replay.completed, 2);
        expect(report.replay.failed, 0);
      },
    );

    test('an action from before a folder reset is never applied', () async {
      final message = me.messages(folder).first;
      final mailbox = me.mailbox(folder);
      me.store.outbox.enqueue(
        me.account.id,
        SetFlagsAction(
          mailboxId: mailbox.id,
          uidValidity: mailbox.syncState.uidValidity! + 1,
          uids: [message.uid],
          add: [r'\Flagged'],
        ),
      );
      final report = await me.sync([folder]);
      expect(report.replay.failed, 1);
      expect(
        me.store.outbox.all(me.account.id).single.lastError,
        contains('reset'),
      );
    });

    test('appending the same message twice stores it once', () async {
      final data = testMessage('appended once');
      final mailbox = me.mailbox(folder);
      me.store.outbox.enqueue(
        me.account.id,
        AppendAction(mailboxId: mailbox.id),
        data: data,
      );
      me.store.outbox.enqueue(
        me.account.id,
        AppendAction(mailboxId: mailbox.id),
        data: data,
      );
      await me.sync([folder]);
      expect(
        me.messages(folder).where((m) => m.subject == 'appended once'),
        hasLength(1),
      );
    });
  });

  group('sending', () {
    test('send: delivered once, saved to Sent once, even when replayed after a crash', () async {
      final inboxFolder = scratchFolder('smtp');
      final me = device('alice');
      await me.sync([]);
      final built = MessageBuilder().build(
        OutgoingMessage(
          from: const MailAddress(localPart: 'alice', domain: 'fmail.test'),
          to: [
            MailAddress(localPart: 'alice+$inboxFolder', domain: 'fmail.test'),
          ],
          subject: 'sync engine send $inboxFolder',
          textBody: 'hello',
        ),
      );
      me.actions.send(me.account, built);
      final report = await me.sync([]);
      expect(report.replay.completed, 1);

      // Simulate a crash after SMTP accepted but before the entry was
      // removed: the same entry, marked accepted, is replayed.
      final sent = me.store.mailboxes.bySpecialUse(
        me.account.id,
        SpecialUse.sent,
      )!;
      me.store.outbox.enqueue(
        me.account.id,
        SendAction(
          from: 'alice@fmail.test',
          recipients: built.recipients.map((r) => r.address).toList(),
          sentMailboxId: sent.id,
          smtpAccepted: true,
        ),
        data: built.bytes,
      );
      await me.sync([]);

      final other = await servers.otherDevice('alice');
      Future<int> count(String folder) async {
        for (var i = 0; i < 25; i++) {
          final names = (await other.listMailboxes()).map((f) => f.encodedName);
          if (names.contains(folder)) {
            await other.select(folder, readOnly: true);
            final found = await other.uidSearch(
              SearchCriteria.header('Message-ID', built.messageId),
            );
            if (!found.matches.isEmpty) return found.matches.length;
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        return 0;
      }

      expect(await count(inboxFolder), 1, reason: 'delivered exactly once');
      expect(await count('Sent'), 1, reason: 'saved to Sent exactly once');
      await other.logout();
    });
  });

  test(
    'IDLE watcher reports another device\'s change within seconds',
    () async {
      final folder = scratchFolder();
      final other = await servers.otherDevice('alice');
      await other.create(folder);
      final me = device('alice');
      await me.sync([folder]);

      final changed = Completer<void>();
      final stop = Completer<void>();
      final watching = IdleWatcher(me.connector).watch(
        me.account,
        me.mailbox(folder),
        stop: stop.future,
        onChange: () {
          if (!changed.isCompleted) changed.complete();
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await other.append(folder, testMessage('wake up'));
      await changed.future.timeout(const Duration(seconds: 10));
      stop.complete();
      await watching;
      await other.logout();
    },
  );

  test('wrong password is reported as an authentication failure', () async {
    final me = device('alice');
    final engine = SyncEngine(
      me.store,
      DefaultMailConnector(
        _WrongPassword(),
        tls: servers.tls,
        endpointFor: servers.endpointFor,
      ),
    );
    final failure = engine.events.firstWhere((e) => e is AccountSyncFailed);
    await engine.syncAccount(me.account.id);
    expect(
      ((await failure) as AccountSyncFailed).failure.kind,
      SyncFailureKind.authentication,
    );
    await engine.dispose();
  });

  test('three devices with conflicting offline changes converge to the server', () async {
    final f1 = scratchFolder('Conv'), f2 = scratchFolder('Conv');
    final setup = await servers.otherDevice('bob');
    await setup.create(f1);
    await setup.create(f2);
    for (var i = 0; i < 12; i++) {
      await setup.append(f1, testMessage('c$i', to: 'bob@fmail.test'));
    }
    await setup.logout();

    final phones = [device('bob'), device('bob'), device('bob')];
    for (final p in phones) {
      await p.sync([f1, f2]);
    }

    // FMAIL_CONVERGENCE_SEED runs other random scenarios.
    final random = _SeededRandom(
      int.tryParse(Platform.environment['FMAIL_CONVERGENCE_SEED'] ?? '') ??
          2026,
    );
    for (var round = 0; round < 6; round++) {
      // Each device acts offline on its own (possibly stale) view.
      for (final p in phones) {
        for (var n = 0; n < 4; n++) {
          final folder = random.pick([f1, f2]);
          final messages = p.messages(folder);
          if (messages.isEmpty) continue;
          final m = random.pick(messages);
          switch (random.nextInt(6)) {
            case 0:
              p.actions.markRead([m]);
            case 1:
              p.actions.markRead([m], read: false);
            case 2:
              p.actions.markFlagged([m]);
            case 3:
              p.actions.markFlagged([m], flagged: false);
            case 4:
              p.actions.move([m], p.mailbox(folder == f1 ? f2 : f1));
            case 5:
              if (random.nextInt(3) == 0) p.actions.delete([m]);
          }
        }
      }
      // Devices come online in a random order.
      for (final p in random.shuffled(phones)) {
        await p.sync([f1, f2]);
      }
    }
    // Final round: everyone catches up.
    for (final p in phones) {
      await p.sync([f1, f2]);
    }

    final server = await servers.otherDevice('bob');
    for (final folder in [f1, f2]) {
      await server.select(folder, readOnly: true);
      final fetched = await server.uidFetch(
        SequenceSet.all(),
        FetchItems(flags: true, envelope: true),
      );
      final expected = {
        for (final m in fetched.messages)
          '${m.envelope!.subject} seen=${m.hasFlag(r'\Seen')} flagged=${m.hasFlag(r'\Flagged')}',
      };
      for (final p in phones) {
        final actual = {
          for (final m in p.messages(folder))
            '${m.subject} seen=${m.flags.seen} flagged=${m.flags.flagged}',
        };
        expect(
          actual,
          expected,
          reason: '$folder on device ${phones.indexOf(p)}',
        );
        expect(
          p.store.outbox.all(p.account.id),
          isEmpty,
          reason: 'every action applied, none failed',
        );
      }
    }
    await server.logout();
  }, timeout: const Timeout(Duration(minutes: 3)));
}

final class _WrongPassword implements CredentialProvider {
  @override
  Future<String> passwordFor(Account account) async => 'not-the-password';
}

/// A tiny seeded random helper so the convergence test is repeatable.
final class _SeededRandom {
  _SeededRandom(int seed) : _state = seed;

  int _state;

  int nextInt(int max) {
    _state = (_state * 1103515245 + 12345) & 0x7fffffff;
    return _state % max;
  }

  T pick<T>(List<T> items) => items[nextInt(items.length)];

  List<T> shuffled<T>(List<T> items) {
    final copy = [...items];
    for (var i = copy.length - 1; i > 0; i--) {
      final j = nextInt(i + 1);
      final t = copy[i];
      copy[i] = copy[j];
      copy[j] = t;
    }
    return copy;
  }
}
