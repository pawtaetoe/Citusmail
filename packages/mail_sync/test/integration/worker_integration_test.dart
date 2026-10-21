// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The background sync worker, opening messages and loading older mail,
// against the local test servers (see sync_integration_test.dart).

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:mail_view/mail_view.dart';
import 'package:test/test.dart';

import '../support/test_env.dart';

final class _WrongPassword implements CredentialProvider {
  const _WrongPassword();

  @override
  Future<String> passwordFor(Account account) async => 'wrong';
}

void main() {
  final skip = integrationSkipReason;
  if (skip != null) {
    test('needs the local test servers', () {}, skip: skip);
    return;
  }
  final servers = TestServers.load();
  late TestDevice device;
  setUp(() => device = TestDevice.create(servers, 'alice'));
  tearDown(() => device.dispose());

  SyncWorkerConfig config() => SyncWorkerConfig(
    databasePath: device.databasePath,
    key: device.key,
    connector: testConnector(servers),
  );

  test('the worker syncs in the background; the UI store sees it', () async {
    final worker = await SyncWorker.spawn(
      config(),
      credentials: const TestCredentials(),
    );
    addTearDown(worker.close);
    final events = <SyncEvent>[];
    worker.events.listen(events.add);

    await worker.syncNow(device.account.id);
    expect(events.whereType<AccountSynced>(), isNotEmpty);
    expect(
      device.store.messages.list(const MessageQuery.inbox(limit: 500)),
      hasLength(22),
    );

    // Open a message: downloaded by the worker, read from the UI store.
    final lunch = device.store.messages
        .list(const MessageQuery.inbox(limit: 500))
        .firstWhere((m) => m.subject == 'Lunch on Friday?');
    expect(device.store.messages.body(lunch.id), isNull);
    await worker.loadBody(lunch.id);
    final raw = device.store.messages.body(lunch.id)!;
    final view = MessageView.parse(raw);
    expect(view.body.plainText, contains('Hi Alice'));
    // The body text is now searchable.
    expect(
      device.store.messages.search('noodle').map((m) => m.id),
      contains(lunch.id),
    );
    // Opening never marks a message read on the server (BODY.PEEK).
    final unread = device.store.messages
        .list(const MessageQuery.inbox(limit: 500))
        .firstWhere((m) => !m.flags.seen);
    await worker.loadBody(unread.id);
    await worker.syncNow(device.account.id);
    expect(device.store.messages.byId(unread.id)!.flags.seen, isFalse);
  });

  test('a wrong password is reported, not hidden', () async {
    final worker = await SyncWorker.spawn(
      config(),
      credentials: const _WrongPassword(),
    );
    addTearDown(worker.close);
    final failures = <AccountSyncFailed>[];
    worker.events.listen((e) {
      if (e is AccountSyncFailed) failures.add(e);
    });
    await worker.syncNow(device.account.id);
    expect(failures.single.failure.kind, SyncFailureKind.authentication);
  });

  test('closing twice is harmless; requests after closing fail', () async {
    final worker = await SyncWorker.spawn(
      config(),
      credentials: const TestCredentials(),
    );
    await worker.close();
    await worker.close();
    expect(worker.syncNow(), throwsA(isA<SyncWorkerException>()));
  });

  group('on demand', () {
    late SyncEngine engine;
    setUp(() {
      engine = SyncEngine(
        device.store,
        DefaultMailConnector(
          const TestCredentials(),
          tls: servers.tls,
          endpointFor: servers.endpointFor,
        ),
        settings: const SyncSettings(initialWindow: 5),
      );
    });
    tearDown(() => engine.dispose());

    test('older mail loads page by page until none is left', () async {
      await engine.syncAccount(device.account.id);
      final inbox = device.mailbox('INBOX');
      expect(device.messages('INBOX'), hasLength(5));
      expect(await engine.fetchOlder(inbox.id, count: 10), 10);
      expect(await engine.fetchOlder(inbox.id, count: 10), 7);
      expect(await engine.fetchOlder(inbox.id, count: 10), 0);
      expect(device.messages('INBOX'), hasLength(22));
    });

    test('several messages open over one reused connection', () async {
      await engine.syncAccount(device.account.id);
      for (final m in device.messages('INBOX')) {
        await engine.loadBody(m.id);
        expect(device.store.messages.body(m.id), isNotNull);
      }
    });

    test('a message deleted elsewhere is reported as gone', () async {
      final folder = scratchFolder();
      final other = await servers.otherDevice('alice');
      await other.create(folder);
      await other.append(folder, testMessage('vanishing'));
      await engine.syncAccount(device.account.id);
      final message = device.messages(folder).single;

      await other.select(folder);
      final uids = (await other.uidSearch(SearchCriteria.all())).matches;
      await other.uidStore(uids, FlagChange.add, {r'\Deleted'});
      await other.uidExpunge(uids);
      await other.logout();

      await expectLater(
        engine.loadBody(message.id),
        throwsA(
          isA<BodyUnavailableException>().having(
            (e) => e.problem,
            'problem',
            BodyProblem.gone,
          ),
        ),
      );
    });
  });
}
