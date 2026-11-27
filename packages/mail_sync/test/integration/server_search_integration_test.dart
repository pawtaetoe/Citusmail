// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Search on the server, against a real one (not Gmail: TEXT in the inbox
// and Archive). Reads alice's seeded mail only; changes nothing there.

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

  test('mail the device does not keep is found on the server, stored once, '
      'and opens', () async {
    // One message per folder on the device: "Lunch on Friday?" (the
    // oldest in the inbox) is not.
    const settings = SyncSettings(initialWindow: 1, backfillBatch: 0);
    final device = TestDevice.create(servers, 'alice', settings: settings);
    addTearDown(device.dispose);
    final engine = SyncEngine(
      device.store,
      device.connector,
      settings: settings,
    );
    addTearDown(engine.dispose);
    await engine.syncAccount(device.account.id);
    final store = device.store;
    // (Sent has the reply.)
    List<String?> subjects() => [
      for (final m in store.messages.search('Lunch on Friday')) m.subject,
    ];
    expect(subjects(), isNot(contains('Lunch on Friday?')));

    // Words of its body.
    final found = await engine.searchServer(device.account.id, 'noodle place');
    expect(found, hasLength(1));
    final lunch = store.messages.byId(found.single)!;
    expect(lunch.subject, 'Lunch on Friday?');
    expect(lunch.mailboxId, store.mailboxes.inbox(device.account.id)!.id);
    expect(store.messages.body(lunch.id), isNull, reason: 'summary only');

    final body = String.fromCharCodes(await engine.loadBody(lunch.id));
    expect(body, contains('The new noodle place opened.'));

    // Again: the same message, not a second copy. And the next sync keeps
    // it.
    expect(await engine.searchServer(device.account.id, 'noodle place'), found);
    await engine.syncAccount(device.account.id);
    expect(store.messages.byId(lunch.id)?.subject, 'Lunch on Friday?');
    expect(subjects(), contains('Lunch on Friday?'));
  });
}
