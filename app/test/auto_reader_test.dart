// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Reading receipts, bills and booking emails ahead of time: a run
// downloads what the pages would read, at most a set number, one at a
// time, and carries on next time; failures are skipped and, after a few,
// no longer tried.

import 'dart:async';
import 'dart:convert';

import 'package:citusmail/src/services/auto_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  late StoredMailbox inbox;
  final now = DateTime.now().toUtc();
  var uid = 600;

  setUp(() async {
    app = await TestApp.create();
    inbox = app.store.mailboxes.inbox(app.store.accounts.all().single.id)!;
    // The sample inbox's "Your parcel" is on the device already: only
    // the bookings below are left to read.
    app.store.messages.saveBody(
      app.store.messages.byUid(inbox.id, 4)!.id,
      utf8.encode('Subject: Your parcel\r\n\r\nOn its way.\r\n'),
      searchableText: 'On its way.',
    );
  });
  tearDown(() => app.dispose());

  /// [count] booking emails from different hotels, newest first; their
  /// ids.
  List<int> bookings(int count) {
    final first = uid + 1;
    app.store.messages.upsertSummaries(inbox.id, [
      for (var i = 0; i < count; i++)
        MessageSummary(
          uid: ++uid,
          receivedAt: now.subtract(Duration(hours: i + 1)),
          subject: 'Your booking confirmation for Hotel $i',
          from: MailAddress(
            displayName: 'Stays',
            localPart: 'reservations',
            domain: 'stays$i.example',
          ),
          snippet: 'Thank you for booking with us.',
          size: 30000,
          category: MessageCategory.notifications,
        ),
    ]);
    return [
      for (var u = first; u <= uid; u++)
        app.store.messages.byUid(inbox.id, u)!.id,
    ];
  }

  /// Stores a small body, as a download from the server would.
  final loaded = <int>[];
  Future<void> download(int id) async {
    loaded.add(id);
    app.store.messages.saveBody(
      id,
      utf8.encode('Subject: Booking\r\n\r\nSee you soon.\r\n'),
      searchableText: 'See you soon.',
    );
  }

  setUp(loaded.clear);

  test('at most [cap] a run; the next run carries on', () async {
    final ids = bookings(30);
    final reader = AutoReader(app.store, download, cap: 12);
    addTearDown(reader.dispose);

    expect(await reader.run(), 12);
    expect(loaded, ids.take(12), reason: 'one at a time, newest first');
    expect(reader.downloaded, 12);

    expect(await reader.run(), 12);
    expect(loaded.skip(12), ids.skip(12).take(12));
    // The page itself reads at most 40 booking emails.
    expect(await reader.run(), 6);
    expect(await reader.run(), 0);
    expect(loaded.toSet(), ids.toSet());
  });

  test('off: nothing is read, nothing is planned', () async {
    bookings(3);
    app.services.settings.autoRead = false;
    final reader = AutoReader(app.store, download);
    addTearDown(reader.dispose);
    reader.start(const Stream.empty());
    expect(reader.active, isFalse);
    expect(await reader.run(), 0);
    expect(loaded, isEmpty);

    app.services.settings.autoRead = true;
    reader.request();
    expect(reader.active, isTrue);
  });

  test('a message that fails is skipped, and given up after 3 times', () async {
    final ids = bookings(3);
    final broken = ids[1];
    Future<void> load(int id) async {
      if (id == broken) throw const BodyUnavailableException(BodyProblem.gone);
      await download(id);
    }

    final reader = AutoReader(app.store, load);
    addTearDown(reader.dispose);
    expect(await reader.run(), 2);
    expect(ReadFailures(app.store).times(broken), 1);
    await reader.run();
    await reader.run();
    expect(ReadFailures(app.store).givenUp, {broken});
    expect(await AutoReader.wanted(app.store, now, cap: 50), isEmpty);
    expect(loaded, [ids[0], ids[2]]);
  });

  test(
    'offline: the account waits for the next run, nothing counted',
    () async {
      final ids = bookings(5);
      var calls = 0;
      var offline = true;
      Future<void> load(int id) async {
        calls++;
        if (offline) {
          throw const SyncWorkerException(
            SyncFailure(SyncFailureKind.network, 'offline'),
          );
        }
        await download(id);
      }

      final reader = AutoReader(app.store, load);
      addTearDown(reader.dispose);
      expect(await reader.run(), 0);
      expect(calls, 1, reason: 'the rest of the account is left for later');
      expect(ReadFailures(app.store).givenUp, isEmpty);
      expect(ReadFailures(app.store).times(ids.first), 0);

      offline = false;
      expect(await reader.run(), 5);
    },
  );

  test('runs a little after start and after syncs with new mail', () async {
    final ids = bookings(4);
    final events = StreamController<SyncEvent>.broadcast(sync: true);
    addTearDown(events.close);
    final reader = AutoReader(
      app.store,
      download,
      delay: const Duration(milliseconds: 50),
      firstDelay: const Duration(milliseconds: 50),
      minGap: Duration.zero,
    );
    addTearDown(reader.dispose);
    reader.start(events.stream);
    expect(reader.active, isTrue);
    await _until(() => !reader.active);
    expect(loaded, ids);

    // A sync without new mail: nothing to do.
    AccountSynced synced(int added) => AccountSynced(
      1,
      AccountSyncReport(
        replay: const ReplayResult(),
        mailboxes: {
          inbox.id: MailboxSyncResult(method: SyncMethod.qresync, added: added),
        },
      ),
    );
    events.add(synced(0));
    expect(reader.active, isFalse);

    // New mail, in several syncs close together: one run.
    final more = bookings(2);
    var runs = 0;
    reader.addListener(() => runs++);
    events
      ..add(synced(1))
      ..add(synced(1))
      ..add(synced(1));
    expect(reader.active, isTrue);
    await _until(() => !reader.active);
    expect(loaded.skip(4), more);
    // Waiting (once), running, done.
    expect(runs, 3);
  });

  test('stopping ends a run after the message it is on', () async {
    bookings(5);
    late AutoReader reader;
    Future<void> load(int id) async {
      await download(id);
      reader.stop();
    }

    reader = AutoReader(app.store, load);
    addTearDown(reader.dispose);
    expect(await reader.run(), 0);
    expect(loaded, hasLength(1));
  });
}

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(done(), isTrue);
}
