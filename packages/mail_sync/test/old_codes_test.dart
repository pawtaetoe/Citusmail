// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Verification mail older than a day still gets its code shown: the code
// reader fills spare places with it, and opening one reads it at once.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

import 'support/fake_imap.dart';

Uint8List google(DateTime date) => Uint8List.fromList(
  utf8.encode(
    'From: Google <noreply@google.com>\r\n'
    'To: alice@citusmail.test\r\n'
    'Subject: Google Verification Code\r\n'
    'Message-ID: <code-1@google.com>\r\n'
    'Date: ${HttpDate.format(date)}\r\n'
    'Content-Type: text/plain; charset=utf-8\r\n'
    '\r\n'
    'Hi Tommy,\r\n'
    'We received a request to access your Google Account through your '
    'email address. Your Google verification code is:\r\n'
    '\r\n'
    '155031\r\n'
    '\r\n'
    'If you did not request this code, someone else may be trying to '
    'access your account.\r\n',
  ),
);

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

  setUp(() async {
    server = await FakeImap.start();
    directory = Directory.systemTemp.createTempSync('old_codes_test');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
    account = server.addAccount(store);
  });

  tearDown(() async {
    store.close();
    await server.close();
    directory.deleteSync(recursive: true);
  });

  StoredMessage onlyMessage() => store.messages
      .list(MessageQuery(mailboxIds: [store.mailboxes.inbox(account.id)!.id]))
      .single;

  test('a code email from months ago gets its code', () async {
    final date = DateTime.utc(2025, 4, 24, 19, 46);
    server.folders['INBOX']!.add(raw: google(date), date: date);
    final engine = SyncEngine(store, server.connector());
    await engine.syncAccount(account.id);
    final message = onlyMessage();
    expect(message.category, MessageCategory.codes);
    expect(message.code, '155031');
    await engine.dispose();
  });

  test('opening one reads its code when none was found yet', () async {
    final date = DateTime.utc(2025, 4, 24, 19, 46);
    server.folders['INBOX']!.add(raw: google(date), date: date);
    final engine = SyncEngine(store, server.connector());
    await engine.syncAccount(account.id);
    final id = onlyMessage().id;
    store.messages.setCode(id, ''); // as if never found
    await engine.loadBody(id);
    expect(onlyMessage().code, '155031');
    await engine.dispose();
  });
}
