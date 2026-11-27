// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The sync status line on its own, without the mail screen.

import 'package:citusmail/src/features/inbox/state/sync_status.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  late SyncStatusController sync;
  setUp(() async {
    app = await TestApp.create();
    sync = SyncStatusController(app.store, app.services.worker);
  });
  tearDown(() {
    sync.dispose();
    return app.dispose();
  });

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test('idle with no sync yet', () {
    expect(sync.status.value, isA<SyncIdle>());
    expect((sync.status.value as SyncIdle).lastSynced, isNull);
    final account = app.store.accounts.all().single;
    expect(sync.lastEvent(account.id), isNull);
  });

  test(
    'a failed sync is a problem with the account, after the event',
    () async {
      final account = app.store.accounts.all().single;
      final seen = <(SyncEvent, SyncStatus)>[];
      sync.onEvent = (event) => seen.add((event, sync.status.value));
      await sync.syncNow();
      await until(() => sync.status.value is SyncProblem);

      final problem = sync.status.value as SyncProblem;
      expect(problem.kind, SyncFailureKind.network);
      expect(problem.account, account.email);
      expect(problem.accountId, account.id);
      expect(problem.oauth, isFalse);
      expect(sync.lastEvent(account.id), isA<AccountSyncFailed>());
      expect(seen, isNotEmpty);
      expect(
        seen.last.$2,
        same(sync.status.value),
        reason: 'the status is updated before onEvent runs',
      );

      final asked = <Account>[];
      sync.onReconnect = asked.add;
      sync.reconnect(problem);
      expect(asked.single.id, account.id);
    },
  );

  test('reconnecting an unknown account asks nothing', () {
    final asked = <Account>[];
    sync.onReconnect = asked.add;
    sync.reconnect(const SyncProblem(SyncFailureKind.authentication, 'x'));
    sync.reconnect(
      const SyncProblem(
        SyncFailureKind.authentication,
        'x',
        accountId: AccountId(999),
      ),
    );
    expect(asked, isEmpty);
  });
}
