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
}
