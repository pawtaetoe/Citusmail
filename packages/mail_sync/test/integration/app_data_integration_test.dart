// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// App data sync between two devices through the local test server. Uses
// carol (cPanel layout: folders under "INBOX.", "." as separator).

import 'dart:convert';

import 'package:mail_appsync/mail_appsync.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

import '../support/test_env.dart';

final class _Code implements SyncCodeProvider {
  _Code(this.code);

  String? code;

  @override
  Future<String?> syncCode() async => code;
}

void main() {
  final skip = integrationSkipReason;
  if (skip != null) {
    test('needs the local test servers', () {}, skip: skip);
    return;
  }
  final servers = TestServers.load();
  const folder = 'INBOX.Citusmail Sync';

  Future<void> cleanUp() async {
    final imap = await servers.otherDevice('carol');
    final boxes = await imap.listMailboxes();
    if (boxes.any((b) => b.encodedName == folder)) {
      await imap.select(folder);
      final all = (await imap.uidSearch(SearchCriteria.all())).matches;
      if (all.toList().isNotEmpty) {
        await imap.uidStore(all, FlagChange.add, {r'\Deleted'});
        await imap.uidExpunge(all);
      }
    }
    await imap.logout();
  }

  test('two devices share blocks, rules and removals; the server sees only sealed data', () async {
    await cleanUp();
    addTearDown(cleanUp);
    final code = _Code(SyncCode.generate().toString());

    TestDevice device() {
      final d = TestDevice.create(servers, 'carol');
      addTearDown(d.dispose);
      return d;
    }

    SyncEngine engine(TestDevice d) {
      final e = SyncEngine(
        d.store,
        DefaultMailConnector(
          const TestCredentials(),
          tls: servers.tls,
          endpointFor: servers.endpointFor,
        ),
        syncCodes: code,
      );
      addTearDown(e.dispose);
      return e;
    }

    final phone = device(), laptop = device();
    final phoneSync = engine(phone), laptopSync = engine(laptop);

    final first = await phoneSync.syncAccount(phone.account.id);
    expect(first!.appDataFailure, isNull);
    expect(first.appData!.published, isTrue);
    await laptopSync.syncAccount(laptop.account.id);

    // The phone blocks a domain and makes a rule for an existing folder.
    final domain = '${scratchFolder('blk').toLowerCase()}.example';
    phone.store.blocks.block(BlockKind.domain, domain);
    final archive = phone.store.mailboxes
        .forAccount(phone.account.id)
        .firstWhere((m) => m.specialUse == SpecialUse.archive);
    phone.store.folderRules.add(
      accountId: phone.account.id,
      mailboxId: archive.id,
      field: RuleField.fromAddress,
      value: 'receipts@$domain',
    );
    final sent = await phoneSync.syncAccount(phone.account.id);
    expect(sent!.appData!.published, isTrue);

    final got = await laptopSync.syncAccount(laptop.account.id);
    expect(got!.appData!.devices, 2);
    expect(got.appData!.changes.added, 2);
    expect(laptop.store.blocks.matching('x@mail.$domain'), isNotNull);
    expect(
      laptop.store.folderRules.forAccount(laptop.account.id).single.value,
      'receipts@$domain',
    );

    // The laptop unblocks; the phone follows.
    laptop.store.blocks.unblock(laptop.store.blocks.all().single.id);
    await laptopSync.syncAccount(laptop.account.id);
    final back = await phoneSync.syncAccount(phone.account.id);
    expect(back!.appData!.changes.removed, 1);
    expect(phone.store.blocks.all(), isEmpty);

    // On the server: one message per device, nothing readable, and the
    // folder never shows up as mail.
    final imap = await servers.otherDevice('carol');
    addTearDown(imap.logout);
    await imap.select(folder, readOnly: true);
    final uids = (await imap.uidSearch(SearchCriteria.all())).matches.toList();
    expect(uids, hasLength(2));
    final fetched = await imap.uidFetch(
      SequenceSet.of(uids),
      FetchItems(fullMessage: true),
    );
    for (final m in fetched.messages) {
      final text = latin1.decode(m.sections['']!);
      expect(
        text,
        contains(
          'X-Citusmail-Sync: ${SyncCode.parse(code.code!)!.keys.syncId}',
        ),
      );
      expect(text, isNot(contains(domain)));
      expect(text, isNot(contains('receipts@')));
    }
    final syncFolder = phone.store.mailboxes
        .forAccount(phone.account.id)
        .firstWhere((m) => m.isAppData);
    expect(phone.store.messages.uids(syncFolder.id), isEmpty);
  });

  test(
    'a device with another code can\'t read the data, and changes nothing',
    () async {
      await cleanUp();
      addTearDown(cleanUp);
      final mine = _Code(SyncCode.generate().toString());
      final stranger = _Code(SyncCode.generate().toString());
      final a = TestDevice.create(servers, 'carol');
      final b = TestDevice.create(servers, 'carol');
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      SyncEngine engine(TestDevice d, _Code c) => SyncEngine(
        d.store,
        DefaultMailConnector(
          const TestCredentials(),
          tls: servers.tls,
          endpointFor: servers.endpointFor,
        ),
        syncCodes: c,
      );
      a.store.blocks.block(BlockKind.address, 'secret@x.example');
      final ea = engine(a, mine), eb = engine(b, stranger);
      addTearDown(ea.dispose);
      addTearDown(eb.dispose);
      await ea.syncAccount(a.account.id);
      final report = await eb.syncAccount(b.account.id);
      expect(report!.appData!.devices, 1, reason: 'only itself');
      expect(b.store.blocks.all(), isEmpty);

      // Turning sync off removes this device's message only.
      await eb.forgetAppData();
      final imap = await servers.otherDevice('carol');
      addTearDown(imap.logout);
      await imap.select(folder, readOnly: true);
      expect(
        (await imap.uidSearch(SearchCriteria.all())).matches.toList(),
        hasLength(1),
      );
    },
  );
}
