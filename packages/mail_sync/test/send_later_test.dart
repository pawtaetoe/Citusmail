// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// "Send later" through the real outbox replay, against small in-memory
// mail servers: a scheduled message never goes out early, goes out once
// when its time comes and is saved to Sent once, also when the app stops
// (and starts again) before or after the due time, or in the middle of
// sending.

import 'dart:io';

import 'package:mail_compose/mail_compose.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

import 'support/fake_mail_servers.dart';

void main() {
  final skip = fakeServersSkipReason;
  if (skip != null) {
    test('needs the test certificates', () {}, skip: skip);
    return;
  }

  late Directory directory;
  late DatabaseKey key;
  late MailStore store;
  late FakeMailServers servers;
  late MailConnector connector;
  late int accountId;

  // Wednesday morning; the message is due Thursday at 8.
  final now = DateTime(2026, 11, 4, 9, 10);
  final thursday = DateTime(2026, 11, 5, 8);

  setUp(() async {
    servers = await FakeMailServers.start();
    connector = servers.connector();
    directory = Directory.systemTemp.createTempSync('send_later_test');
    key = DatabaseKey.generate();
    store = MailStore.open('${directory.path}/mail.db', key);
    accountId = store.accounts
        .add(
          NewAccount(
            email: 'alice@citusmail.test',
            username: 'alice@citusmail.test',
            imap: ServerSettings(
              host: 'mail.citusmail.test',
              port: 993,
              security: ConnectionSecurity.implicitTls,
            ),
            smtp: ServerSettings(
              host: 'mail.citusmail.test',
              port: 465,
              security: ConnectionSecurity.implicitTls,
            ),
          ),
        )
        .id;
    for (final box in store.mailboxes.replaceAll(accountId, [
      ImapMailboxInfo(encodedName: 'INBOX', delimiter: '/', attributes: {}),
      ImapMailboxInfo(
        encodedName: 'Sent',
        delimiter: '/',
        attributes: {r'\Sent'},
      ),
      ImapMailboxInfo(
        encodedName: 'Drafts',
        delimiter: '/',
        attributes: {r'\Drafts'},
      ),
    ])) {
      store.mailboxes.saveSyncState(
        box.id,
        const MailboxSyncState(uidValidity: 1),
      );
    }
  });

  tearDown(() async {
    store.close();
    await servers.close();
    directory.deleteSync(recursive: true);
  });

  /// The app stops and starts again: a new connection to the same
  /// database, nothing kept in memory.
  void restart() {
    store.close();
    store = MailStore.open('${directory.path}/mail.db', key);
  }

  Account account() => store.accounts.byId(accountId)!;

  /// One replay of the queue as a sync does it, at [at].
  Future<ReplayResult> replayAt(DateTime at) async {
    final imap = await connector.imap(account());
    try {
      return await OutboxReplayer(
        store,
      ).replay(imap, account(), smtp: () => connector.smtp(account()), now: at);
    } finally {
      await imap.logout();
    }
  }

  /// Schedules a message for Thursday 8:00; returns its Message-ID.
  String schedule({String to = 'bob@x.example'}) {
    Sender(store).schedule(
      Draft(
        accountId: accountId,
        to: [MailAddress(localPart: to.split('@').first, domain: 'x.example')],
        subject: 'Quarterly numbers',
        body: 'Here they are, as promised.',
      ),
      thursday,
      now: now,
    );
    return const MimeParser()
        .parse(store.outbox.sends().single.data!)
        .messageId!;
  }

  /// What a replay does up to the moment the app dies: the SMTP server
  /// accepts the message and that is recorded.
  Future<void> sendAndRecordAcceptance(String messageId) async {
    final entry = store.outbox.sends().single;
    final action = entry.action as SendAction;
    final smtp = await connector.smtp(account());
    await smtp.send(
      BuiltMessage(
        bytes: entry.data!,
        messageId: messageId,
        recipients: [
          for (final r in action.recipients)
            const AddressParser().parse(r).mailboxes.single,
        ],
      ),
      from: const AddressParser().parse(action.from).mailboxes.single,
    );
    await smtp.quit();
    store.outbox.updateAction(entry.id, action.markAccepted());
  }

  test(
    'not sent early, also after a restart; sent once after its time',
    () async {
      final id = schedule();

      // The undo delay is over, an hour before its time, and again after a
      // restart: nothing goes.
      expect(
        (await replayAt(now.add(const Duration(minutes: 1)))).completed,
        0,
      );
      restart();
      final early = await replayAt(thursday.subtract(const Duration(hours: 1)));
      expect(early.completed, 0);
      expect(store.outbox.sends(), hasLength(1));
      expect(servers.delivered, isEmpty);

      // The app was not running at 8:00 and starts again at 17:00: the
      // message goes out then, once, and is saved to Sent once.
      restart();
      final late = await replayAt(thursday.add(const Duration(hours: 9)));
      expect(late.completed, 1);
      expect(store.outbox.sends(), isEmpty);
      expect(servers.deliveredCount(id), 1);
      expect(servers.countIn('Sent', id), 1);

      // Later syncs, after another restart, send nothing more.
      restart();
      expect(
        (await replayAt(thursday.add(const Duration(days: 1)))).completed,
        0,
      );
      expect(servers.deliveredCount(id), 1);
      expect(servers.countIn('Sent', id), 1);
    },
  );

  test('at its time exactly, and not a second earlier', () async {
    final id = schedule();
    await replayAt(thursday.subtract(const Duration(seconds: 1)));
    expect(servers.delivered, isEmpty);
    await replayAt(thursday);
    expect(servers.deliveredCount(id), 1);
  });

  test('a stop right after the server accepted it: not sent again', () async {
    final id = schedule();
    await sendAndRecordAcceptance(id);
    restart();

    expect((await replayAt(thursday)).completed, 1);
    expect(store.outbox.sends(), isEmpty);
    expect(servers.deliveredCount(id), 1, reason: 'sent once');
    expect(servers.countIn('Sent', id), 1, reason: 'saved once');
  });

  test('a stop after saving to Sent: neither sent nor saved again', () async {
    final id = schedule();
    await sendAndRecordAcceptance(id);
    final imap = await connector.imap(account());
    await imap.append('Sent', store.outbox.sends().single.data!);
    await imap.logout();
    restart();

    expect((await replayAt(thursday)).completed, 1);
    expect(servers.deliveredCount(id), 1);
    expect(servers.countIn('Sent', id), 1);
  });

  test('Send now goes out at once (after the undo delay), once', () async {
    schedule();
    final scheduled = ScheduledSends(store, Sender(store));
    final pending = scheduled.sendNow(scheduled.all().single, now: now)!;
    await replayAt(pending.undoUntil);
    expect(servers.delivered, hasLength(1));
    await replayAt(thursday);
    expect(servers.delivered, hasLength(1), reason: 'not again at 8:00');
  });

  test('Cancel and Edit: never sent', () async {
    schedule();
    final scheduled = ScheduledSends(store, Sender(store));
    expect(scheduled.cancel(scheduled.all().single, now: now), isNotNull);
    schedule();
    expect(scheduled.edit(scheduled.all().single, now: now), isNotNull);
    await replayAt(thursday.add(const Duration(days: 2)));
    expect(servers.delivered, isEmpty);
    expect(
      servers.folders['Drafts'],
      hasLength(1),
      reason: 'the cancelled one',
    );
  });

  test('refused by the server: failed, reported once, not retried', () async {
    servers.refuse.add('nobody@x.example');
    schedule(to: 'nobody@x.example');
    final result = await replayAt(thursday);
    expect(result.failed, 1);
    expect(store.outbox.sends().single.state, OutboxState.failed);
    await replayAt(thursday.add(const Duration(days: 1)));
    expect(servers.delivered, isEmpty);

    // Told once, also across a restart.
    restart();
    final scheduled = ScheduledSends(store, Sender(store));
    expect(scheduled.claimFailures(), hasLength(1));
    restart();
    expect(ScheduledSends(store, Sender(store)).claimFailures(), isEmpty);
  });
}
