// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Thousands of emails at once (a sender's whole history on the Clean up
// page, a big folder selected): done in steps, so the app never stops
// drawing, with one queued server change per folder and one Undo.

// Timings are printed for the record.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

import 'support/fake_imap.dart';

/// Counts turns of the event loop: a zero timer that sets itself again
/// until stopped, as a frame would be scheduled between steps.
final class LoopTurns {
  LoopTurns() {
    _next();
  }

  int count = 0;
  bool _stopped = false;

  void _next() => Timer(Duration.zero, () {
    if (_stopped) return;
    count++;
    _next();
  });

  void stop() => _stopped = true;
}

void main() {
  late Directory directory;
  late MailStore store;
  late StoredMailbox inbox;
  late StoredMailbox archive;
  late StoredMailbox allMail;

  const from = MailAddress(
    displayName: 'IB Trading Assistant',
    localPart: 'assistant',
    domain: 'broker.example',
  );

  setUp(() {
    directory = Directory.systemTemp.createTempSync('bulk_actions_test');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
    final account = store.accounts.add(
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
    ImapMailboxInfo folder(String name, [String? use]) => ImapMailboxInfo(
      encodedName: name,
      delimiter: '/',
      attributes: {if (use != null) '\\$use'},
    );
    final boxes = store.mailboxes.replaceAll(account.id, [
      folder('INBOX'),
      folder('Archive', 'Archive'),
      folder('All Mail', 'All'),
      folder('Trash', 'Trash'),
    ]);
    for (final b in boxes) {
      store.mailboxes.saveSyncState(
        b.id,
        const MailboxSyncState(uidValidity: 1),
      );
    }
    StoredMailbox named(String name) =>
        boxes.firstWhere((b) => b.encodedName == name);
    inbox = named('INBOX');
    archive = named('Archive');
    allMail = named('All Mail');
  });

  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  MessageSummary trade(int uid, int i) => MessageSummary(
    uid: uid,
    messageId: 'trade$i@broker.example',
    subject: 'Trade confirmation $i',
    receivedAt: DateTime.utc(2024).add(Duration(hours: i)),
    from: from,
    to: const [MailAddress(localPart: 'alice', domain: 'citusmail.test')],
    headers: const {
      'list-unsubscribe': ['<mailto:stop@broker.example>'],
    },
  );

  /// 7,000 emails in the inbox (every other UID) and 1,000 in Archive,
  /// all from one sender; All Mail holds copies of the first 500.
  void seed() {
    for (var start = 0; start < 7000; start += 250) {
      store.messages.upsertSummaries(inbox.id, [
        for (var i = start; i < start + 250; i++) trade(2 * i + 1, i),
      ]);
    }
    for (var start = 7000; start < 8000; start += 250) {
      store.messages.upsertSummaries(archive.id, [
        for (var i = start; i < start + 250; i++) trade(i, i),
      ]);
    }
    store.messages.upsertSummaries(allMail.id, [
      for (var i = 0; i < 500; i++) trade(10000 + i, i),
    ]);
    final first = store.messages.byUid(inbox.id, 1)!;
    store.messages.saveBody(
      first.id,
      Uint8List.fromList([1, 2, 3]),
      searchableText: 'uniquebodyword',
    );
  }

  List<StoredMessage> everything() =>
      store.messages.receivedFrom([from.address]);

  int count(StoredMailbox m) => store.messages.uids(m.id).length;

  test(
    'deleting 8,000 emails goes in steps with the event loop free in '
    'between, one queued delete per folder; Undo brings back every one',
    () async {
      seed();
      final mail = everything();
      expect(mail, hasLength(8000));
      final actions = MailActions(
        store,
        undoWindow: const Duration(seconds: 5),
        stepSize: 500,
      );
      final turns = LoopTurns();
      addTearDown(turns.stop);
      final progress = <(int, int)>[];
      final turnsAtStep = <int>[];
      DateTime? heldUntil;
      final watch = Stopwatch()..start();
      final receipt = await actions.deleteInSteps(
        mail,
        progress: (done, total) {
          progress.add((done, total));
          turnsAtStep.add(turns.count);
          // While steps remain, the queued deletes are held back.
          if (done == 500) {
            heldUntil = store.outbox.all(inbox.accountId).single.notBefore;
          }
        },
      );
      watch.stop();
      print('deleting 8,000 in steps of 500: ${watch.elapsedMilliseconds} ms');

      expect(progress, [for (var n = 500; n <= 8000; n += 500) (n, 8000)]);
      for (var i = 1; i < turnsAtStep.length; i++) {
        expect(
          turnsAtStep[i],
          greaterThan(turnsAtStep[i - 1]),
          reason: 'a timer ran between steps ${i - 1} and $i',
        );
      }
      expect(
        heldUntil!.isAfter(
          DateTime.now().add(
            const Duration(seconds: 5) + const Duration(seconds: 30),
          ),
        ),
        isTrue,
        reason: 'not replayed while the queue entry still grows',
      );
      expect(count(inbox), 0);
      expect(count(archive), 0);
      expect(count(allMail), 0, reason: 'Gmail-style copies leave too');

      // One delete per folder, with every UID, due when Undo ends.
      final queued = store.outbox.all(inbox.accountId);
      expect(queued, hasLength(2));
      final byFolder = {
        for (final e in queued) (e.action as DeleteAction).mailboxId: e,
      };
      expect(
        (byFolder[inbox.id]!.action as DeleteAction).uids,
        hasLength(7000),
      );
      expect(
        (byFolder[archive.id]!.action as DeleteAction).uids,
        hasLength(1000),
      );
      for (final e in queued) {
        expect(
          e.notBefore.millisecondsSinceEpoch,
          receipt.undoUntil.toUtc().millisecondsSinceEpoch,
        );
      }
      expect(receipt.entryIds, unorderedEquals([for (final e in queued) e.id]));
      expect(receipt.snapshot.messages, hasLength(8500));

      final undoProgress = <int>[];
      final undoTurns = <int>[];
      watch
        ..reset()
        ..start();
      final undone = await actions.undoInSteps(
        receipt,
        progress: (done, _) {
          undoProgress.add(done);
          undoTurns.add(turns.count);
        },
      );
      watch.stop();
      print(
        'putting 8,500 back in steps of 500: ${watch.elapsedMilliseconds} ms',
      );
      expect(undone, isTrue);
      expect(undoProgress, hasLength(17));
      expect(undoProgress.last, 8500);
      for (var i = 1; i < undoTurns.length; i++) {
        expect(undoTurns[i], greaterThan(undoTurns[i - 1]));
      }
      expect(count(inbox), 7000);
      expect(count(archive), 1000);
      expect(count(allMail), 500);
      expect(everything(), hasLength(8000));
      expect(store.outbox.all(inbox.accountId), isEmpty);
      final first = store.messages.byUid(inbox.id, 1)!;
      expect(store.messages.body(first.id), [1, 2, 3]);
      expect(store.messages.search('uniquebodyword').single.id, first.id);
    },
  );

  test('steps are sized by time, never above the largest step', () async {
    seed();
    final mail = everything();
    final actions = MailActions(store, undoWindow: const Duration(seconds: 5));
    final sizes = <int>[];
    final times = <int>[];
    var last = 0;
    final watch = Stopwatch()..start();
    final receipt = await actions.moveInSteps(
      [
        for (final m in mail)
          if (m.mailboxId == inbox.id) m,
      ],
      archive,
      progress: (done, _) {
        sizes.add(done - last);
        times.add(watch.elapsedMicroseconds);
        last = done;
        watch.reset();
      },
    );
    print(
      'archiving 7,000 in ${sizes.length} steps of '
      '${sizes.reduce((a, b) => a < b ? a : b)} to '
      '${sizes.reduce((a, b) => a > b ? a : b)}; longest step '
      '${times.reduce((a, b) => a > b ? a : b) ~/ 1000} ms',
    );
    expect(sizes.first, 50);
    expect(sizes.length, greaterThan(1));
    expect(sizes.every((s) => s <= MailActions.largestStep), isTrue);
    expect(sizes.fold(0, (a, b) => a + b), 7000);
    expect(count(inbox), 0);
    final queued = store.outbox.all(inbox.accountId).single;
    expect((queued.action as MoveAction).uids, hasLength(7000));
    expect((queued.action as MoveAction).targetMailboxId, archive.id);
    expect(count(allMail), 500, reason: 'archiving keeps Gmail copies');
    expect(await actions.undoInSteps(receipt), isTrue);
    expect(count(inbox), 7000);
  });

  test('several removals in steps are one action: held until the last '
      'step, then one undo window for all', () async {
    seed();
    final mail = everything();
    final actions = MailActions(
      store,
      undoWindow: const Duration(seconds: 5),
      stepSize: 400,
    );
    final progress = <(int, int)>[];
    final receipts = await actions.removeInSteps([
      (
        messages: [
          for (final m in mail)
            if (m.mailboxId == inbox.id) m,
        ],
        target: archive,
      ),
      (
        messages: [
          for (final m in mail)
            if (m.mailboxId == archive.id) m,
        ],
        target: null,
      ),
    ], progress: (done, total) => progress.add((done, total)));
    expect(receipts, hasLength(2));
    expect(progress.first, (400, 8000));
    expect(progress.last, (8000, 8000));
    final queued = store.outbox.all(inbox.accountId);
    expect(queued.map((e) => e.action.runtimeType), [MoveAction, DeleteAction]);
    expect(
      {for (final e in queued) e.notBefore.millisecondsSinceEpoch},
      {receipts.first.undoUntil.toUtc().millisecondsSinceEpoch},
    );
    expect(count(inbox), 0);
    expect(count(archive), 0, reason: 'the moved mail arrives with a sync');

    for (final r in receipts.reversed) {
      expect(await actions.undoInSteps(r), isTrue);
    }
    expect(count(inbox), 7000);
    expect(count(archive), 1000);
  });

  test('too late to undo once the change may be on its way', () async {
    seed();
    final actions = MailActions(store, stepSize: 1000); // no undo window
    final receipt = await actions.deleteInSteps(everything());
    expect(
      store.outbox.all(inbox.accountId).map((e) => e.notBefore.year),
      everyElement(1970),
      reason: 'due at the next sync',
    );
    expect(await actions.undoInSteps(receipt), isFalse);
    expect(everything(), isEmpty);
  });

  test('marking 8,000 read in steps: one flag change per folder, and '
      'Undo marks them unread again', () async {
    seed();
    final actions = MailActions(store, stepSize: 1000);
    final turns = LoopTurns();
    addTearDown(turns.stop);
    final at = <int>[];
    final watch = Stopwatch()..start();
    final receipt = await actions.markReadInSteps(
      everything(),
      progress: (_, _) => at.add(turns.count),
    );
    print('marking 8,000 read in steps: ${watch.elapsedMilliseconds} ms');
    expect(at, hasLength(8));
    for (var i = 1; i < at.length; i++) {
      expect(at[i], greaterThan(at[i - 1]));
    }
    expect(everything().every((m) => m.flags.seen), isTrue);
    final queued = store.outbox.all(inbox.accountId);
    expect(queued, hasLength(2));
    for (final e in queued) {
      expect((e.action as SetFlagsAction).add, [r'\Seen']);
      expect(e.notBefore.year, 1970, reason: 'due now that it is done');
    }
    expect(
      {for (final e in queued) (e.action as SetFlagsAction).uids.length},
      {7000, 1000},
    );

    expect(await actions.undoInSteps(receipt), isTrue);
    expect(everything().any((m) => m.flags.seen), isFalse);
  });

  group('UID sets for the server', () {
    test('runs of UIDs become ranges: one command', () {
      final sets = OutboxReplayer.uidSets([
        for (var uid = 1; uid <= 8000; uid++) uid,
      ]);
      expect(sets.map((s) => '$s'), ['1:8000']);
      expect(
        OutboxReplayer.uidSets([1, 2, 3, 500, 502, 510, 511, 512]).single
            .toString(),
        '1:3,500,502,510:512',
      );
    });

    test('thousands of scattered UIDs: a few commands of bounded length', () {
      final uids = [for (var i = 0; i < 7080; i++) 100000 + 2 * i];
      final sets = OutboxReplayer.uidSets(uids);
      expect(sets.length, inInclusiveRange(10, 15));
      for (final s in sets) {
        expect(s.toString().length, lessThanOrEqualTo(4000));
      }
      expect([for (final s in sets) ...s.toList()], uids);
    });
  });

  group('against a server', () {
    final skip = FakeImap.skipReason;
    if (skip != null) {
      test('needs the test certificates', () {}, skip: skip);
      return;
    }

    test('a stepped delete of scattered UIDs reaches the server as a few '
        'UID MOVE commands', () async {
      final server = await FakeImap.start();
      addTearDown(server.close);
      final dir = Directory.systemTemp.createTempSync('bulk_server_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final local = MailStore.open(
        '${dir.path}/mail.db',
        DatabaseKey.generate(),
      );
      addTearDown(local.close);
      server.folders['Trash'] = FakeFolder(specialUse: 'Trash');
      for (var i = 0; i < 2400; i++) {
        server.folders['INBOX']!.add(
          from: i.isEven ? 'assistant@broker.example' : 'ana@x.example',
          subject: 'Message $i',
        );
      }
      final account = server.addAccount(local);
      final engine = SyncEngine(
        local,
        server.connector(),
        settings: const SyncSettings(initialWindow: 3000),
      );
      addTearDown(engine.dispose);
      await engine.syncAccount(account.id);
      final mail = local.messages.receivedFrom(['assistant@broker.example']);
      expect(mail, hasLength(1200));

      await MailActions(local, stepSize: 100).deleteInSteps(mail);
      final mark = server.commands.length;
      await engine.syncAccount(account.id);
      final moves = server.since(mark, 'UID MOVE');
      expect(moves.length, inInclusiveRange(1, 3));
      for (final m in moves) {
        expect(m.length, lessThan(4100));
      }
      expect(server.folders['INBOX']!.messages, hasLength(1200));
      expect(server.folders['Trash']!.messages, hasLength(1200));
      expect(local.outbox.all(account.id), isEmpty);
    });
  });
}
