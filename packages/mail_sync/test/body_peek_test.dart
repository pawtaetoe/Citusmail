// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Downloading a message's body (opening it, or the app reading receipts
// and booking emails ahead of time) leaves it unread: the folder is
// opened read-only, the message fetched with BODY.PEEK[], and no flag is
// set, on the server or on the device.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
  late MailStore store;
  late FakeMailServers servers;

  setUp(() async {
    servers = await FakeMailServers.start();
    directory = Directory.systemTemp.createTempSync('body_peek_test');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
  });

  tearDown(() async {
    store.close();
    await servers.close();
    directory.deleteSync(recursive: true);
  });

  test('loadBody keeps the message unread', () async {
    final account = store.accounts.add(
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
    );
    final inbox = store.mailboxes.replaceAll(account.id, [
      ImapMailboxInfo(encodedName: 'INBOX', delimiter: '/', attributes: {}),
    ]).single;
    store.mailboxes.saveSyncState(
      inbox.id,
      const MailboxSyncState(uidValidity: 1, uidNext: 2),
    );
    servers.folders['INBOX']!.add(
      Uint8List.fromList(
        utf8.encode(
          'From: StreamFlix <info@streamflix.example>\r\n'
          'To: alice@citusmail.test\r\n'
          'Subject: Your StreamFlix receipt\r\n'
          'Date: Sun, 25 Oct 2026 10:00:00 +0000\r\n'
          'Content-Type: text/plain; charset=utf-8\r\n'
          '\r\n'
          'Your membership has been renewed. Total: S\$17.98.\r\n',
        ),
      ),
    );
    store.messages.upsertSummaries(inbox.id, [
      MessageSummary(
        uid: 1,
        receivedAt: DateTime.utc(2026, 10, 25, 10),
        subject: 'Your StreamFlix receipt',
        from: const MailAddress(
          displayName: 'StreamFlix',
          localPart: 'info',
          domain: 'streamflix.example',
        ),
        size: 300,
      ),
    ]);
    final receipt = store.messages.byUid(inbox.id, 1)!;
    expect(receipt.flags.seen, isFalse);

    final engine = SyncEngine(store, servers.connector());
    addTearDown(engine.dispose);
    final raw = await engine.loadBody(receipt.id);

    expect(utf8.decode(raw), contains('S\$17.98'));
    expect(store.messages.body(receipt.id), isNotNull);
    expect(store.messages.byId(receipt.id)!.flags.seen, isFalse);
    expect(servers.seen, isEmpty);
    final commands = servers.imapCommands;
    expect(commands, contains(startsWith('EXAMINE')), reason: 'read-only');
    expect(commands, isNot(contains(startsWith('SELECT'))));
    expect(
      commands,
      contains(allOf(startsWith('UID FETCH 1'), contains('BODY.PEEK[]'))),
    );
    expect(commands, isNot(contains(contains(' BODY['))));
    expect(commands, isNot(contains(startsWith('UID STORE'))));
  });

  test(
    'reading ahead has its own connection: opened mail never waits',
    () async {
      final account = store.accounts.add(
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
      );
      final inbox = store.mailboxes.replaceAll(account.id, [
        ImapMailboxInfo(encodedName: 'INBOX', delimiter: '/', attributes: {}),
      ]).single;
      store.mailboxes.saveSyncState(
        inbox.id,
        const MailboxSyncState(uidValidity: 1, uidNext: 4),
      );
      for (var uid = 1; uid <= 3; uid++) {
        servers.folders['INBOX']!.add(
          Uint8List.fromList(
            utf8.encode(
              'From: Shop <orders@shop.example>\r\n'
              'Subject: Order $uid\r\n'
              'Date: Sun, 25 Oct 2026 10:00:00 +0000\r\n'
              '\r\n'
              'Order $uid shipped.\r\n',
            ),
          ),
        );
      }
      store.messages.upsertSummaries(inbox.id, [
        for (var uid = 1; uid <= 3; uid++)
          MessageSummary(
            uid: uid,
            receivedAt: DateTime.utc(2026, 10, 25, 10, uid),
            subject: 'Order $uid',
            size: 120,
          ),
      ]);
      final counting = _CountingConnector(servers.connector());
      final engine = SyncEngine(store, counting);
      addTearDown(engine.dispose);
      int id(int uid) => store.messages.byUid(inbox.id, uid)!.id;

      await engine.loadBody(id(1), background: true);
      expect(counting.imapLogins, 1);
      // Opened by the user: not on the reading-ahead connection.
      await engine.loadBody(id(2));
      expect(counting.imapLogins, 2);
      // Each kind keeps its connection.
      await engine.loadBody(id(3));
      expect(counting.imapLogins, 2);
      for (var uid = 1; uid <= 3; uid++) {
        expect(store.messages.body(id(uid)), isNotNull);
      }
    },
  );
}

/// Counts IMAP logins (one per connection opened).
final class _CountingConnector implements MailConnector {
  _CountingConnector(this._inner);

  final MailConnector _inner;
  int imapLogins = 0;

  @override
  Future<ImapClient> imap(Account account) {
    imapLogins++;
    return _inner.imap(account);
  }

  @override
  Future<SmtpClient> smtp(Account account) => _inner.smtp(account);

  @override
  Future<ManageSieveClient> sieve(Account account) => _inner.sieve(account);
}
