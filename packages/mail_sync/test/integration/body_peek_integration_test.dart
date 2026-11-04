// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Downloading a message's body (opening it, or the app reading receipts
// and booking emails ahead of time) leaves it unread on the server and on
// the device. (carol: other tests do not count her inbox.)

import 'dart:convert';

import 'package:mail_protocol/mail_protocol.dart';
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

  test('loadBody keeps the message unread', () async {
    final device = TestDevice.create(servers, 'carol');
    addTearDown(device.dispose);
    final engine = SyncEngine(
      device.store,
      DefaultMailConnector(
        const TestCredentials(),
        tls: servers.tls,
        endpointFor: servers.endpointFor,
      ),
    );
    addTearDown(engine.dispose);

    final tag = scratchFolder('peek').toLowerCase();
    final other = await servers.otherDevice('carol');
    addTearDown(() async {
      await other.select('INBOX');
      final found = (await other.uidSearch(
        SearchCriteria.header('Subject', tag),
      )).matches;
      if (!found.isEmpty) {
        await other.uidStore(found, FlagChange.add, {r'\Deleted'});
        await other.uidExpunge(found);
      }
      await other.logout();
    });
    await other.append(
      'INBOX',
      utf8.encode(
        'From: StreamFlix <info@streamflix.example>\r\n'
        'To: carol@citusmail.test\r\n'
        'Subject: Your StreamFlix receipt $tag\r\n'
        'Date: Sun, 25 Oct 2026 10:00:00 +0000\r\n'
        'MIME-Version: 1.0\r\n'
        'Content-Type: text/plain; charset=utf-8\r\n'
        '\r\n'
        'Your membership has been renewed.\r\n'
        'Total: S\$17.98, billed monthly.\r\n',
      ),
    );
    await engine.syncAccount(device.account.id);

    final inbox = device.store.mailboxes.inbox(device.account.id)!;
    final receipt = device.store.messages
        .list(MessageQuery(mailboxIds: [inbox.id], limit: 500))
        .singleWhere((m) => m.subject?.contains(tag) ?? false);
    expect(receipt.flags.seen, isFalse);
    expect(device.store.messages.body(receipt.id), isNull);

    await engine.loadBody(receipt.id);
    expect(device.store.messages.body(receipt.id), isNotNull);
    expect(device.store.messages.byId(receipt.id)!.flags.seen, isFalse);

    // Still unread on the server, also after the next sync.
    await other.select('INBOX', readOnly: true);
    final tagged = (await other.uidSearch(
      SearchCriteria.header('Subject', tag),
    )).matches.toList();
    final unseen = (await other.uidSearch(SearchCriteria.unseen())).matches
        .toList();
    expect(tagged, hasLength(1));
    expect(unseen, containsAll(tagged));
    await engine.syncAccount(device.account.id);
    expect(device.store.messages.byId(receipt.id)!.flags.seen, isFalse);
  });
}
