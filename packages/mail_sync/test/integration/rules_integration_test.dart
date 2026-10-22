// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Custom folders and their rules, against the local test servers (see
// sync_integration_test.dart). Uses carol, whose layout is cPanel's:
// every folder lives under "INBOX." with "." as the separator.

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

  test('a new folder follows the server layout; a rule files new mail into it, once', () async {
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
    await engine.syncAccount(device.account.id);
    final name = scratchFolder('Rules');
    // A sender domain of this run only, so leftovers never interfere.
    final domain = '${name.toLowerCase()}.example';

    final folderId = await engine.createFolder(device.account.id, name);
    final created = device.store.mailboxes.byId(folderId)!;
    expect(created.encodedName, 'INBOX.$name');

    device.store.folderRules.add(
      accountId: device.account.id,
      mailboxId: folderId,
      field: RuleField.fromDomain,
      value: domain,
    );

    // New mail arrives in the inbox.
    final messageId = '$name@$domain';
    final other = await servers.otherDevice('carol');
    await other.append(
      'INBOX',
      utf8.encode(
        'From: Orders <orders@$domain>\r\n'
        'To: carol@fmail.test\r\n'
        'Subject: Your order\r\n'
        'Message-ID: <$messageId>\r\n'
        'Date: Thu, 22 Oct 2026 10:00:00 +0000\r\n'
        '\r\n'
        'Thanks for your order.\r\n',
      ),
    );

    final report = await engine.syncAccount(device.account.id);
    expect(report!.movedByRules, 1);
    expect(
      device.store.outbox.all(device.account.id),
      isEmpty,
      reason: 'moved on the server now',
    );

    Future<int> count(String folder) async {
      await other.select(folder, readOnly: true);
      return (await other.uidSearch(
        SearchCriteria.header('Message-ID', messageId),
      )).matches.length;
    }

    expect(await count('INBOX'), 0);
    expect(await count('INBOX.$name'), 1);

    // The user moves it back: it stays in the inbox.
    await other.select('INBOX.$name');
    final uids = (await other.uidSearch(SearchCriteria.all())).matches;
    await other.uidMove(uids, 'INBOX');
    final again = await engine.syncAccount(device.account.id);
    expect(again!.movedByRules, 0);
    expect(await count('INBOX'), 1);

    // Leave carol's inbox as it was.
    await other.select('INBOX');
    final back = (await other.uidSearch(
      SearchCriteria.header('Message-ID', messageId),
    )).matches;
    await other.uidStore(back, FlagChange.add, {r'\Deleted'});
    await other.uidExpunge(back);
    await other.logout();
  });
}
