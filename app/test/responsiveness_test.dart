// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// How long the mail screen keeps the UI isolate busy on a large store:
// five accounts and about 32,000 emails. Each interaction is timed slice
// by slice (UiWork); the table is printed for the record.

// Timings are printed for the record.
// ignore_for_file: avoid_print

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
  Future<UiWork> measure(
    String name,
    Future<void> Function() action, {
    int runs = 1,
    void Function()? before,
  }) async {
    final all = <UiWork>[];
    for (var i = 0; i < runs; i++) {
      before?.call();
      all.add(await UiWork.measure(name, store(), action));
    }
    all.sort((a, b) => a.longest.compareTo(b.longest));
    final work = all[all.length ~/ 2];
    results.add(work);
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
    await measure('open the mail screen (controller)', () async {
      controller = MailController(app.services);
    });
  });

  test('after a sync event', () async {
    var account = 0;
    await measure(
      'refresh after new mail',
      () async => controller.refresh(),
      runs: 5,
      before: () => arrive(account++ % 5),
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

    await measure('Deliveries', () => page(DeliveriesModel(services)));
    await measure('Subscriptions', () => page(SubscriptionsModel(services)));
    await measure('Trips', () => page(TripsModel(services)));
    await measure('Appointments', () => page(AppointmentsModel(services)));
    await measure('Online accounts', () => page(AccountsModel(services)));
    await measure('Deliveries again', () => page(DeliveriesModel(services)));
    await measure('Clean up', () => page(SenderCleanupModel(controller)));
    await measure('Privacy report', () => page(PrivacyReportModel(services)));
    await measure('Files', () async {
      final files = AttachmentsModel(services);
      await files.load();
      files.dispose();
    });
    final summary = controller.summary..watch();
    await measure('summary line: today', () async {
      await summary.debugRead();
    });
    summary.unwatch();
    await measure('reading ahead: what to read', () async {
      await services.autoRead.debugWanted();
    });
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
