// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// How long a full sync of five accounts of 30 folders takes against
// servers that answer in 10 ms, with IDLE on each inbox: with as many
// connections as a sync wants (0.6.4), within the budget of 4 per
// account, and within a budget lowered to 2 after a refusal. Prints a
// table; asserts what the budget promises (accounts side by side, extra
// connections while there is room, never more than the budget), with
// generous time bounds only.

import 'dart:io';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

import 'support/fake_imap.dart';

const _accounts = 5;
const _folders = 30;
const _latency = Duration(milliseconds: 10);

/// Each account's own server.
final class _Servers implements MailConnector {
  _Servers(this.byEmail);

  final Map<String, FakeImap> byEmail;

  @override
  Future<ImapClient> imap(Account account) =>
      byEmail[account.email]!.connector().imap(account);

  @override
  Future<SmtpClient> smtp(Account account) =>
      byEmail[account.email]!.connector().smtp(account);

  @override
  Future<ManageSieveClient> sieve(Account account) =>
      byEmail[account.email]!.connector().sieve(account);
}

void main() {
  final skip = FakeImap.skipReason;
  if (skip != null) {
    test('needs the test certificates', () {}, skip: skip);
    return;
  }

  final table = <String>[];
  tearDownAll(() {
    // ignore: avoid_print
    print(
      'Full sync, $_accounts accounts x $_folders folders, '
      '${_latency.inMilliseconds} ms a reply, IDLE on:\n${table.join('\n')}',
    );
  });

  Future<void> measure(
    String name, {
    required int perAccount,
    required int connections,
    required int expectPeak,
    bool listStatus = false,
  }) async {
    final directory = Directory.systemTemp.createTempSync('sync_speed');
    final store = MailStore.open(
      '${directory.path}/mail.db',
      DatabaseKey.generate(),
    );
    final servers = <String, FakeImap>{};
    final accounts = <Account>[];
    for (var a = 0; a < _accounts; a++) {
      final server = await FakeImap.start(condstore: true, idle: true)
        ..listStatus = listStatus;
      for (var f = 0; f < _folders - 1; f++) {
        final folder = server.folders['Folder $f'] = FakeFolder();
        for (var i = 0; i < 10; i++) {
          folder.add(subject: 'folder $f message $i');
        }
      }
      for (var i = 0; i < 10; i++) {
        server.folders['INBOX']!.add(subject: 'inbox $i');
      }
      final email = 'user$a@citusmail.test';
      servers[email] = server;
      accounts.add(server.addAccount(store, email: email));
    }
    final engine = SyncEngine(
      store,
      _Servers(servers),
      classifier: const HeaderRuleClassifier(),
      settings: SyncSettings(connections: connections),
      connections: ConnectionBudget(_Servers(servers), perAccount: perAccount),
      // Only the syncs asked for here.
      changeDelay: const Duration(hours: 1),
    );
    try {
      engine.start();
      // The first sync of each account, then IDLE.
      final end = DateTime.now().add(const Duration(seconds: 60));
      while (servers.values.any((s) => s.inIdle == 0)) {
        if (DateTime.now().isAfter(end)) fail('IDLE did not start');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      for (final server in servers.values) {
        server.latency = _latency;
        // New mail in the inbox and in a few folders; the rest unchanged.
        server.folders['INBOX']!.add(subject: 'new in the inbox');
        for (final f in [3, 11, 20]) {
          server.folders['Folder $f']!.add(subject: 'new in $f');
        }
        server.peakLoggedIn = server.loggedIn;
      }
      final started = <AccountId, DateTime>{};
      final finished = <AccountId, DateTime>{};
      engine.events.listen((e) {
        if (e is AccountSyncStarted) started[e.accountId] = DateTime.now();
        if (e is AccountSynced) finished[e.accountId] = DateTime.now();
      });
      final watch = Stopwatch()..start();
      final reports = await Future.wait([
        for (final account in accounts) engine.syncAccount(account.id),
      ]);
      watch.stop();

      final added = reports.fold(
        0,
        (sum, r) => sum + r!.mailboxes.values.fold(0, (s, m) => s + m.added),
      );
      expect(added, _accounts * 4, reason: 'all the new mail');
      final skipped = reports.fold(
        0,
        (sum, r) =>
            sum +
            r!.mailboxes.values
                .where((m) => m.method == SyncMethod.unchanged)
                .length,
      );
      expect(
        skipped,
        listStatus ? _accounts * (_folders - 4) : 0,
        reason: 'unchanged folders not opened, with LIST-STATUS',
      );
      // Side by side: every account started before the first finished.
      final firstDone = finished.values.reduce((a, b) => a.isBefore(b) ? a : b);
      expect(started.values.every((s) => !s.isAfter(firstDone)), isTrue);
      for (final server in servers.values) {
        expect(server.refused, 0);
        expect(server.peakLoggedIn, lessThanOrEqualTo(perAccount));
        expect(server.peakLoggedIn, expectPeak, reason: 'IDLE and the sync');
      }
      expect(watch.elapsed, lessThan(const Duration(seconds: 30)));
      final ms = watch.elapsedMilliseconds;
      table.add(
        '  ${name.padRight(34)} ${'$ms ms'.padLeft(8)}  '
        '(${servers.values.first.peakLoggedIn} connections an account)',
      );
    } finally {
      await engine.dispose();
      store.close();
      for (final server in servers.values) {
        await server.close();
      }
      directory.deleteSync(recursive: true);
    }
  }

  test('0.6.4: 3 connections a sync, no budget', () async {
    await measure(
      '0.6.4 (3 a sync, no budget)',
      perAccount: 100,
      connections: 3,
      expectPeak: 4,
    );
  });

  test('a budget of 4', () async {
    await measure('budget 4', perAccount: 4, connections: 3, expectPeak: 4);
  });

  test('a budget of 2 (after a refusal)', () async {
    await measure('budget 2', perAccount: 2, connections: 3, expectPeak: 2);
  });

  test('a budget of 4, unchanged folders skipped (LIST-STATUS)', () async {
    await measure(
      'budget 4, LIST-STATUS',
      perAccount: 4,
      connections: 3,
      expectPeak: 4,
      listStatus: true,
    );
  });

  test('a budget of 2, unchanged folders skipped (LIST-STATUS)', () async {
    await measure(
      'budget 2, LIST-STATUS',
      perAccount: 2,
      connections: 3,
      expectPeak: 2,
      listStatus: true,
    );
  });
}
