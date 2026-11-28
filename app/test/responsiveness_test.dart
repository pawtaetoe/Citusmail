// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// How long the mail screen keeps the UI isolate busy on a large store:
// five accounts and about 32,000 emails. Each interaction is timed slice
// by slice (UiWork); the table is printed for the record.

// Timings are printed for the record.
// ignore_for_file: avoid_print

import 'dart:isolate';

import 'package:citusmail/src/core/state/load_state.dart';
import 'package:citusmail/src/core/state/page_model.dart';
import 'package:citusmail/src/core/theme/citusmail_theme.dart';
import 'package:citusmail/src/features/accounts/state/accounts_model.dart';
import 'package:citusmail/src/features/found/state/appointments_model.dart';
import 'package:citusmail/src/features/found/state/attachments_model.dart';
import 'package:citusmail/src/features/found/state/deliveries_model.dart';
import 'package:citusmail/src/features/found/state/subscriptions_model.dart';
import 'package:citusmail/src/features/found/state/trips_model.dart';
import 'package:citusmail/src/features/inbox/state/mail_controller.dart';
import 'package:citusmail/src/features/inbox/state/mail_location.dart';
import 'package:citusmail/src/features/inbox/ui/mail_shell.dart';
import 'package:citusmail/src/features/inbox/ui/message_tile.dart';
import 'package:citusmail/src/features/organise/state/privacy_report_model.dart';
import 'package:citusmail/src/features/organise/state/sender_cleanup_model.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import 'support/big_mailbox.dart';
import 'support/test_app.dart';
import 'support/ui_work.dart';

void main() {
  late TestApp app;
  late BigMailbox big;
  late MailController controller;
  final now = DateTime.now();
  final results = <UiWork>[];

  setUpAll(() async {
    app = await TestApp.create(readsInIsolate: true);
    final watch = Stopwatch()..start();
    big = BigMailbox.seed(app, now: now);
    print(
      'stored ${big.stored} messages in ${big.accounts.length} accounts, '
      '${big.bodies} bodies: ${watch.elapsedMilliseconds} ms',
    );
  });
  tearDownAll(() async {
    print('');
    for (final r in results) {
      print(r);
    }
    controller.dispose();
    await app.dispose();
  });

  MailStore store() => app.store;

  /// Times [action] [runs] times ([before] each, untimed) and keeps the
  /// run with the median longest slice: single runs on a test machine
  /// vary with garbage collection and compilation.
  ///
  /// The checks are loose: a slow machine must not fail them, a return
  /// of what was fixed must. [statements] bounds the work done on the
  /// UI's connection; every slice stays under [ms] (a quarter of a
  /// second by default, where it took up to 850 ms before).
  Future<UiWork> measure(
    String name,
    Future<void> Function() action, {
    int runs = 1,
    void Function()? before,
    int? statements,
    int ms = 250,
  }) async {
    final all = <UiWork>[];
    for (var i = 0; i < runs; i++) {
      before?.call();
      all.add(await UiWork.measure(name, store(), action));
    }
    all.sort((a, b) => a.longest.compareTo(b.longest));
    final work = all[all.length ~/ 2];
    results.add(work);
    expect(work.longest.inMilliseconds, lessThan(ms), reason: name);
    if (statements != null) {
      expect(work.statements, lessThanOrEqualTo(statements), reason: name);
    }
    return work;
  }

  /// A new message arrives in [account]'s inbox (as the sync worker
  /// stores it).
  var uid = 200000;
  void arrive(int account) {
    final inbox = store().mailboxes.inbox(big.accounts[account].id)!;
    store().messages.upsertSummaries(inbox.id, [
      MessageSummary(
        uid: uid++,
        receivedAt: DateTime.now(),
        messageId: 'new$uid@gen.example',
        subject: 'Just arrived $uid',
        from: const MailAddress(
          displayName: 'Carol',
          localPart: 'carol',
          domain: 'x.example',
        ),
        snippet: 'Hello',
      ),
    ]);
  }

  test('opening the mail screen', () async {
    // Once, at start-up, with the code compiling as it runs: timed, but
    // only checked for the worst.
    await measure('open the mail screen (controller)', () async {
      controller = MailController(app.services);
    }, ms: 2000);
  });

  test('after a sync event', () async {
    var account = 0;
    await measure(
      'refresh after new mail',
      () async => controller.refresh(),
      runs: 5,
      before: () => arrive(account++ % 5),
      statements: 120,
    );
    await measure(
      'refresh, nothing changed',
      () async => controller.refresh(),
      runs: 5,
    );
    await measure(
      'counts after new mail',
      () async => controller.countsController.refresh(),
      runs: 5,
      before: () => arrive(account++ % 5),
    );
  });

  test('an idle app while the accounts are checked for mail', () async {
    // Every minute each account's inbox is checked: a sync starts and
    // ends for each, and the worker writes (the folders' sync state)
    // without changing anything on screen.
    final summary = controller.summary..watch();
    // What the earlier tests stored is on screen.
    controller.refresh();
    var list = 0, counts = 0, reader = 0, status = 0, line = 0;
    controller.list.addListener(() => list++);
    controller.counts.addListener(() => counts++);
    controller.reader.addListener(() => reader++);
    controller.status.addListener(() => status++);
    summary.addListener(() => line++);
    final refreshes = controller.refreshes;
    final statements = store().database.statementCount;
    const minutes = 3;
    for (var minute = 0; minute < minutes; minute++) {
      for (final a in big.accounts) {
        controller.syncStatusController.debugEvent(AccountSyncStarted(a.id));
      }
      for (final a in big.accounts) {
        final inbox = store().mailboxes.inbox(a.id)!;
        store().mailboxes.saveSyncState(
          inbox.id,
          MailboxSyncState(uidValidity: 1, uidNext: 100000 + minute),
        );
        controller.syncStatusController.debugEvent(
          AccountSynced(
            a.id,
            AccountSyncReport(
              replay: const ReplayResult(),
              mailboxes: {
                inbox.id: MailboxSyncResult(method: SyncMethod.qresync),
              },
            ),
          ),
        );
      }
      await Future<void>.delayed(
        MailController.refreshDelay + const Duration(milliseconds: 100),
      );
    }
    summary.unwatch();
    print(
      '$minutes idle minutes: ${controller.refreshes - refreshes} refreshes, '
      '${store().database.statementCount - statements} statements; the '
      'list told $list times, counts $counts, the reader $reader, the '
      'status line $status, the summary line $line',
    );
    // One refresh per check of all accounts, and nothing built again:
    // only the status line says "Updating…" and "Updated".
    expect(controller.refreshes - refreshes, lessThanOrEqualTo(minutes));
    expect((list, counts, reader, line), (0, 0, 0, 0));
    expect(status, lessThanOrEqualTo(2 * minutes));
  });

  test('opening a message', () async {
    void unread(StoredMessage m) =>
        app.services.actions.markRead([m], read: false);
    await measure(
      'open a 1.5 MB HTML newsletter (unread)',
      () => controller.open(big.largeHtml),
      runs: 3,
      before: () => unread(big.largeHtml),
    );
    final small = controller.list.sections
        .firstWhere((s) => s.section == SmartSection.general)
        .messages
        .first;
    await measure(
      'open a small message (unread)',
      () => controller.open(small),
      runs: 3,
      before: () => unread(small),
    );
    controller.closeMessage();
  });

  test('scrolling to page 10', () async {
    controller.goTo(const SectionLocation(SmartSection.general));
    for (var page = 2; page <= 10; page++) {
      await measure('General, page $page', () => controller.loadMore());
    }
    await measure(
      'refresh at page 10 after new mail',
      () async => controller.refresh(),
      runs: 3,
      before: () => arrive(0),
    );
    controller.goTo(const InboxLocation());
    for (var i = 0; i < 9; i++) {
      await measure('inbox section, show more ${i + 1}', () async {
        controller.list.showMoreInSection(SmartSection.notifications);
      });
    }
  });

  test('switching account or folder', () async {
    for (final a in big.accounts) {
      await measure('switch to account ${a.email}', () async {
        controller.goTo(InboxLocation(accountId: a.id));
      });
    }
    final archive = store().mailboxes.bySpecialUse(
      big.accounts[1].id,
      SpecialUse.archive,
    )!;
    await measure('switch to a folder (Archive)', () async {
      controller.goTo(FolderLocation(archive.id, big.accounts[1].id));
    });
    await measure('switch to Pins', () async {
      controller.goTo(const PinsLocation());
    });
    await measure('back to the unified inbox', () async {
      controller.goTo(const InboxLocation());
    });
  });

  test('searching', () async {
    for (final text in ['in', 'inv', 'invoice', 'invoise', 'recieve']) {
      await measure('search "$text"', () async => controller.search(text));
    }
    for (final text in ['i', 'in', 'inv', 'invo']) {
      await measure('command bar emails "$text"', () async {
        store().messages.search(text, limit: 5);
      });
    }
    controller.goTo(const InboxLocation());
  });

  test('found pages, the summary line and reading ahead', () async {
    final services = app.services;
    Future<void> page(PageModel<Object?> model) async {
      await model.load();
      expect(model.state, isA<Loaded<Object?>>());
      model.dispose();
    }

    await measure(
      'Deliveries',
      () => page(DeliveriesModel(services)),
      statements: 100,
    );
    await measure(
      'Subscriptions',
      () => page(SubscriptionsModel(services)),
      statements: 40,
    );
    await measure('Trips', () => page(TripsModel(services)), statements: 40);
    await measure(
      'Appointments',
      () => page(AppointmentsModel(services)),
      statements: 40,
    );
    await measure(
      'Online accounts',
      () => page(AccountsModel(services)),
      statements: 40,
    );
    await measure(
      'Deliveries again',
      () => page(DeliveriesModel(services)),
      statements: 40,
    );
    await measure(
      'Clean up',
      () => page(SenderCleanupModel(controller)),
      statements: 20,
    );
    await measure(
      'Privacy report',
      () => page(PrivacyReportModel(services)),
      statements: 40,
    );
    await measure('Files', () async {
      final files = AttachmentsModel(services);
      await files.load();
      files.dispose();
    }, statements: 40);
    final summary = controller.summary..watch();
    await measure('summary line: today', () async {
      await summary.debugRead();
    }, statements: 40);
    summary.unwatch();
    await measure('reading ahead: what to read', () async {
      await services.autoRead.debugWanted();
    }, statements: 40);
  });

  test('during a long sync: scrolling, opening and marking read', () async {
    // The sync worker, in its own isolate with its own connection, stores
    // 3,000 summaries in one account's inbox as a full sync does: a FETCH
    // of 100 at a time, stored 25 to a transaction.
    final account = big.accounts[3];
    final inbox = store().mailboxes.inbox(account.id)!;
    var written = false;
    final writing = Isolate.run(
      _syncWriting(_SyncWrites(app.path, app.key.bytes, inbox.id.value, 3000)),
    ).whenComplete(() => written = true);
    controller.syncStatusController.debugEvent(AccountSyncStarted(account.id));
    controller.goTo(const SectionLocation(SmartSection.general));
    final general = controller.list.visible.take(20).toList();
    final during = <String, List<UiWork>>{};
    Future<void> time(String name, Future<void> Function() action) async {
      final work = await UiWork.measure(name, store(), action);
      (during[name] ??= []).add(work);
    }

    var round = 0;
    while (!written || round < 3) {
      final message = general[round % general.length];
      await time('during a sync: scroll a page', () => controller.loadMore());
      await time('during a sync: open a message', () async {
        await controller.open(message);
      });
      await time('during a sync: mark unread (a write)', () async {
        controller.toggleRead([message]);
      });
      // Another account's inbox check ends meanwhile.
      await time('during a sync: refresh after another account', () async {
        controller.refresh();
      });
      round++;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final longestBatch = await writing;
    controller.syncStatusController.debugEvent(
      AccountSynced(
        account.id,
        AccountSyncReport(
          replay: const ReplayResult(),
          mailboxes: {
            inbox.id: const MailboxSyncResult(
              method: SyncMethod.condstore,
              added: 3000,
            ),
          },
        ),
      ),
    );
    await measure(
      'refresh after a sync stored 3,000',
      () async => controller.refresh(),
    );
    controller
      ..closeMessage()
      ..goTo(const InboxLocation());

    print(
      'during a sync of 3,000 summaries ($round rounds; the longest '
      'transaction in the worker ${longestBatch ~/ 1000} ms):',
    );
    for (final MapEntry(key: name, value: all) in during.entries) {
      all.sort((a, b) => a.longest.compareTo(b.longest));
      final worst = all.last;
      results.add(
        UiWork.frame(
          '$name (worst of ${all.length})',
          worst.longest,
          worst.statements,
        ),
      );
      // The guarantee: a write waits for one of the worker's
      // transactions at most, a read for none. So the screen's own
      // bound, plus the longest transaction this run measured: on a
      // loaded machine (CI runs two test files on two cores) the worker
      // can be paused while it holds the lock, and no size of batch
      // prevents that. Waiting behind several (SQLite's own busy wait,
      // or long transactions) still fails.
      expect(
        worst.longest.inMilliseconds,
        lessThan(250 + longestBatch ~/ 1000),
        reason:
            '$name: its own work plus one transaction of the worker '
            '(${longestBatch ~/ 1000} ms) at most',
      );
    }
    expect(round, greaterThanOrEqualTo(3));
  });

  testWidgets('the mail screen on a phone: scrolling and opening', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final frames = <String, List<UiWork>>{};

    /// [action] and the frame after it, timed (the harness's own work
    /// included), with the statements it ran.
    Future<UiWork> frame(String name, Future<void> Function() action) async {
      final before = store().database.statementCount;
      final watch = Stopwatch()..start();
      await action();
      await tester.pump(const Duration(milliseconds: 16));
      final work = UiWork.frame(
        name,
        watch.elapsed,
        store().database.statementCount - before,
      );
      (frames[name] ??= []).add(work);
      return work;
    }

    await frame('phone: the mail screen, first frame', () async {
      await tester.pumpWidget(
        MaterialApp(
          theme: CitusmailTheme.light(),
          home: MailShell(
            notifications: false,
            services: app.services,
            onAddAccount: () {},
            onAccountsChanged: () {},
          ),
        ),
      );
    });
    final list = find.byType(CustomScrollView).first;
    MessageId top() =>
        tester.widget<MessageTile>(find.byType(MessageTile).first).message.id;
    final first = top();
    for (var i = 0; i < 20; i++) {
      await frame('phone: a frame of scrolling the inbox', () async {
        await tester.drag(list, const Offset(0, -120));
      });
    }
    // The list did scroll, building new rows on the way.
    expect(top(), isNot(first));
    final row = find.byType(MessageTile).first;
    await frame('phone: tap a row, the frame after', () async {
      await tester.tap(row);
    });
    for (final MapEntry(key: name, value: all) in frames.entries) {
      all.sort((a, b) => a.longest.compareTo(b.longest));
      final median = all[all.length ~/ 2];
      results.add(
        UiWork.frame(
          all.length == 1 ? name : '$name (median of ${all.length})',
          median.longest,
          median.statements,
        ),
      );
    }
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
}

/// What the sync worker stores in a full sync: [_SyncWrites.count] new
/// summaries in a folder, fetched 100 at a time (a few ms each from the
/// server) and stored as the sync stores them ([WriteSteps]: short
/// transactions sized by time), on its own connection.
/// Returns the longest transaction (µs).
Future<int> _syncWrites(_SyncWrites job) async {
  final store = MailStore.open(job.path, DatabaseKey.fromBytes(job.key));
  final mailbox = MailboxId(job.mailbox);
  final writes = WriteSteps(
    initial: const SyncSettings().writeBatch,
    pause: MailboxSynchronizer.writePause,
  );
  final watch = Stopwatch();
  var longest = 0;
  try {
    for (var fetched = 0; fetched < job.count; fetched += 100) {
      // The next FETCH from the server.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await writes.run(
        [
          for (var n = fetched; n < fetched + 100; n++)
            MessageSummary(
              uid: 500000 + n,
              receivedAt: DateTime.utc(2024).add(Duration(minutes: n)),
              messageId: 'synced$n@gen.example',
              subject: 'Synced message $n about the quarterly report',
              from: const MailAddress(
                displayName: 'Dana',
                localPart: 'dana',
                domain: 'x.example',
              ),
              snippet: 'Hello, here is message $n, with a few words in it.',
            ),
        ],
        (part) {
          watch
            ..reset()
            ..start();
          store.messages.upsertSummaries(mailbox, part);
          if (watch.elapsedMicroseconds > longest) {
            longest = watch.elapsedMicroseconds;
          }
        },
      );
    }
  } finally {
    store.close();
  }
  return longest;
}

/// [_syncWrites] of [job], capturing nothing else.
Future<int> Function() _syncWriting(_SyncWrites job) =>
    () => _syncWrites(job);

final class _SyncWrites {
  const _SyncWrites(this.path, this.key, this.mailbox, this.count);

  final String path;
  final List<int> key;
  final int mailbox;
  final int count;
}
