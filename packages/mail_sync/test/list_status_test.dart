// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// On a server with LIST-STATUS, a full sync reads every folder's counters
// with the folder list, in one command, and opens only the folders whose
// counters changed: on one connection (a budget of 2 with IDLE), 30
// unchanged folders cost one round trip instead of 30.

import 'dart:io';

import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

import 'support/fake_imap.dart';

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
  late SyncEngine engine;

  setUp(() async {
    server = await FakeImap.start(condstore: true)
      ..listStatus = true;
    for (var f = 0; f < 4; f++) {
      final folder = server.folders['Folder $f'] = FakeFolder();
      for (var i = 0; i < 3; i++) {
        folder.add(subject: 'folder $f message $i');
      }
    }
    server.folders['INBOX']!.add(subject: 'hello');
    directory = Directory.systemTemp.createTempSync('list_status_test');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
    account = server.addAccount(store);
    engine = SyncEngine(
      store,
      server.connector(),
      classifier: const HeaderRuleClassifier(),
    );
  });

  tearDown(() async {
    await engine.dispose();
    store.close();
    await server.close();
    directory.deleteSync(recursive: true);
  });

  /// The folders a full sync opened.
  Future<Set<String>> opened() async {
    final mark = server.commands.length;
    final report = await engine.syncAccount(account.id);
    expect(report, isNotNull);
    expect(report!.mailboxes, hasLength(5), reason: 'every folder reported');
    return {
      for (final c in server.since(mark, 'SELECT'))
        RegExp('"([^"]+)"').firstMatch(c)!.group(1)!,
    };
  }

  test('only the folders whose counters changed are opened', () async {
    expect(await opened(), hasLength(5), reason: 'the first sync');
    expect(await opened(), isEmpty, reason: 'nothing changed');

    server.folders['Folder 1']!.add(subject: 'new');
    final folder2 = server.folders['Folder 2']!;
    folder2.setFlags(folder2.messages.first.uid, {r'\Seen'});
    final folder3 = server.folders['Folder 3']!;
    folder3.remove(folder3.messages.first.uid);
    expect(await opened(), {'Folder 1', 'Folder 2', 'Folder 3'});

    final stored = {
      for (final m in store.mailboxes.forAccount(account.id)) m.encodedName: m,
    };
    List<StoredMessage> messages(String name) =>
        store.messages.list(MessageQuery(mailboxIds: [stored[name]!.id]));
    expect(messages('Folder 1'), hasLength(4), reason: 'the new message');
    expect(
      messages('Folder 2').where((m) => m.flags.seen),
      hasLength(1),
      reason: 'the flag change',
    );
    expect(messages('Folder 3'), hasLength(2), reason: 'the removal');
    expect(await opened(), isEmpty);
  });

  test('without CONDSTORE every folder is still opened', () async {
    await server.close();
    server = await FakeImap.start()
      ..listStatus = true;
    server.folders['INBOX']!.add(subject: 'hello');
    await engine.dispose();
    store.close();
    directory.deleteSync(recursive: true);
    directory = Directory.systemTemp.createTempSync('list_status_test');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
    account = server.addAccount(store);
    engine = SyncEngine(
      store,
      server.connector(),
      classifier: const HeaderRuleClassifier(),
    );
    expect(await engine.syncAccount(account.id), isNotNull);
    final mark = server.commands.length;
    expect(await engine.syncAccount(account.id), isNotNull);
    expect(
      server.since(mark, 'SELECT'),
      hasLength(1),
      reason: 'a flag change shows in no counter',
    );
  });
}
