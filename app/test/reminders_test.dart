// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/mail/mail_controller.dart';
import 'package:citusmail/src/services/reminders.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/subscriptions_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  /// Bills, a trial, a yearly renewal, and mail that must not remind.
  void seed() {
    final inbox = app.store.mailboxes.inbox(
      app.store.accounts.all().single.id,
    )!;
    var uid = 500;
    MessageSummary m(
      DateTime at,
      String subject,
      String name,
      String domain,
      String snippet,
    ) => MessageSummary(
      uid: uid++,
      receivedAt: at.toUtc(),
      subject: subject,
      from: MailAddress(displayName: name, localPart: 'hello', domain: domain),
      snippet: snippet,
    );
    app.store.messages.upsertSummaries(inbox.id, [
      m(
        DateTime(2026, 11, 1, 12),
        'Your MyRepublic e-Bill is ready!',
        'MyRepublic',
        'myrepublic.com.sg',
        'Your e-bill is ready! The outstanding amount for your account '
            'RA2328693 is: \$32.99. Please pay your bill within 7 days of '
            'receiving this email.',
      ),
      m(
        DateTime(2026, 10, 29, 12),
        'Your pandapro free trial has started.',
        'foodpanda',
        'foodpanda.sg',
        'Your 14-day free trial starts today. Then S\$59.88/year, cancel '
            'anytime.',
      ),
      m(
        DateTime(2025, 11, 8, 9),
        'Your Netflix membership has been renewed',
        'Netflix',
        'netflix.com',
        'Annual plan. Amount charged S\$203.88.',
      ),
      // Paid already.
      m(
        DateTime(2026, 11, 1, 9),
        'Your Singtel bill is ready',
        'Singtel',
        'singtel.com',
        'Amount due S\$45.00. Due date: 15 Nov 2026',
      ),
      m(
        DateTime(2026, 11, 2, 9),
        'Payment received - thank you',
        'Singtel',
        'singtel.com',
        'We have received your payment of S\$45.00.',
      ),
      // A bank statement.
      m(
        DateTime(2026, 11, 1, 9),
        'Your DBS Credit Card e-Statement is ready',
        'DBS',
        'dbs.com',
        'Minimum payment S\$50.00. Payment due date: 20 Nov 2026',
      ),
    ]);
  }

  /// Lets isolates (text extraction) finish.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('Coming up: bills, trials and renewals; dismissed with Undo', (
    tester,
  ) async {
    seed();
    final now = DateTime(2026, 11, 4, 10);
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: SubscriptionsPage(
          controller: MailController(app.services),
          now: () => now,
        ),
      ),
    );
    await settle(tester);
    await tester.pumpAndSettle();

    const billKey = ValueKey('reminder-billDue:myrepublic.com.sg:2026-11-08');
    expect(find.text('Coming up'), findsOneWidget);
    expect(find.byKey(billKey), findsOneWidget);
    expect(find.textContaining('Due Sun, 8 Nov'), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(billKey), matching: find.text(r'$32.99')),
      findsOneWidget,
    );
    expect(find.text('in 4 days'), findsWidgets);
    expect(find.text('pandapro'), findsOneWidget);
    expect(
      find.textContaining(r'Free trial ends Thu, 12 Nov, then S$59.88 a year'),
      findsOneWidget,
    );
    expect(find.textContaining('Renews Sun, 8 Nov'), findsOneWidget);
    // Paid bills and statements are not listed; the trial is not a
    // subscription (Netflix and the MyRepublic bill are).
    expect(find.text('Singtel'), findsNothing);
    expect(find.text('DBS'), findsNothing);
    expect(find.text('pandapro'), findsOneWidget);
    expect(find.textContaining('2 active'), findsOneWidget);

    // Done: gone, and remembered; Undo brings it back.
    await tester.tap(
      find.descendant(
        of: find.byKey(billKey),
        matching: find.byIcon(Icons.more_vert),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done, it\'s paid'));
    await tester.pumpAndSettle();
    expect(find.byKey(billKey), findsNothing);
    expect(
      ReminderState(app.store).dismissed,
      contains('billDue:myrepublic.com.sg:2026-11-08'),
    );
    await tester.tap(find.text('Undo'));
    await settle(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(billKey), findsOneWidget);
    expect(ReminderState(app.store).dismissed, isEmpty);

    // Tapping one opens its email in place.
    await tester.tap(find.byKey(billKey));
    await settle(tester);
    expect(find.text('Bill'), findsOneWidget);
    expect(find.text('Your MyRepublic e-Bill is ready!'), findsWidgets);
  });

  group('notifications', () {
    Future<List<String>> check(DateTime now) async {
      final posted = <String>[];
      await ReminderCheck.run(app.store, (notices) async {
        posted.addAll([for (final n in notices) n.text]);
      }, now: now);
      return posted;
    }

    test('once per stage, in the daytime, at most twice a day', () async {
      seed();
      expect(await check(DateTime(2026, 11, 5, 10)), [
        r'MyRepublic bill of $32.99 is due in 3 days',
        r'Netflix renews in 3 days (S$203.88)',
      ]);
      // Not again so soon, nor at night.
      expect(await check(DateTime(2026, 11, 5, 15)), isEmpty);
      expect(await check(DateTime(2026, 11, 5, 23)), isEmpty);
      // The next day: nothing new.
      expect(await check(DateTime(2026, 11, 6, 9)), isEmpty);
      // The trial three days before it ends; the bill on its day.
      expect(await check(DateTime(2026, 11, 8, 9)), [
        r'MyRepublic bill of $32.99 is due today',
      ]);
      expect(await check(DateTime(2026, 11, 9, 9)), [
        r'Your pandapro free trial ends in 3 days, then S$59.88 a year',
      ]);
    });

    test('never for dismissed ones, nor with the settings off', () async {
      seed();
      ReminderState(app.store).dismiss('billDue:myrepublic.com.sg:2026-11-08');
      app.services.settings.reminders = false;
      expect(await check(DateTime(2026, 11, 5, 10)), isEmpty);
      app.services.settings.reminders = true;
      app.services.settings.notifications = false;
      expect(await check(DateTime(2026, 11, 5, 10)), isEmpty);
      app.services.settings.notifications = true;
      expect(await check(DateTime(2026, 11, 5, 10)), [
        r'Netflix renews in 3 days (S$203.88)',
      ]);
    });

    test('words', () {
      final bill = Reminder(
        kind: ReminderKind.billDue,
        company: 'myrepublic.com.sg',
        name: 'MyRepublic',
        date: DateTime.utc(2026, 11, 15),
        messageId: 1,
      );
      final now = DateTime(2026, 11, 14, 9);
      expect(
        ReminderWords.notification(bill, now),
        'MyRepublic bill is due tomorrow',
      );
      expect(ReminderWords.detail(bill, now), 'Due Sun, 15 Nov');
      expect(
        ReminderWords.detail(bill, DateTime(2026, 11, 17, 9)),
        'Was due Sun, 15 Nov',
      );
      final spotify = Reminder(
        kind: ReminderKind.renewal,
        company: 'spotify.com',
        name: 'Spotify',
        date: DateTime.utc(2026, 11, 17),
        messageId: 2,
        amount: const Money(1198, 'SGD'),
        cadence: Cadence.monthly,
      );
      expect(
        ReminderWords.notification(spotify, now),
        r'Spotify renews in 3 days (S$11.98)',
      );
      // Its own notification id, apart from new mail's.
      final id = ReminderNotice(spotify, '', '').id;
      expect(id & 0xF0000000, 0x20000000);
      expect(ReminderNotice(spotify, '', '').id, id);
    });
  });
}
