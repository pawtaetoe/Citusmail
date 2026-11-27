// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// How long the mail screen keeps the UI isolate busy on a large store:
// five accounts and about 32,000 emails. Each interaction is timed slice
// by slice (UiWork); the table is printed for the record.

// Timings are printed for the record.
// ignore_for_file: avoid_print

import 'package:citusmail/src/features/found/state/appointments_model.dart';
import 'package:citusmail/src/features/found/state/deliveries_model.dart';
import 'package:citusmail/src/features/found/state/subscriptions_model.dart';
import 'package:citusmail/src/features/found/state/trips_model.dart';
import 'package:citusmail/src/features/inbox/state/inbox_summary.dart';
import 'package:citusmail/src/features/inbox/state/mail_controller.dart';
import 'package:citusmail/src/features/inbox/state/mail_location.dart';
import 'package:citusmail/src/features/organise/state/sender_cleanup_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

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
    app = await TestApp.create();
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

  test('found pages and the summary line', () async {
    await measure('Deliveries', () async {
      await findDeliveries(store(), now);
    });
    await measure('Subscriptions', () async {
      await findSubscriptions(store(), now, monthlyRenewals: true);
    });
    await measure('Trips', () async => findTrips(store(), now));
    await measure('Appointments', () async => findAppointments(store(), now));
    await measure('summary line: today', () async {
      await findToday(store(), now, monthlyRenewals: true);
    });
    await measure('Deliveries again (cached reads)', () async {
      await findDeliveries(store(), now);
    });
    await measure('Clean up', () async {
      await SenderCleanupModel(controller).fetch();
    });
  });
}
