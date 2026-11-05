// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// "Read receipts and bookings automatically": with it on (the default),
// the pages that find things in mail show no "Read …" card, only a quiet
// line while their emails are read; with it off, the card is offered as
// before.

import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  /// Lets isolates (text extraction) finish.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  /// One inbox email the page would read (not on the device), from
  /// [from].
  void add(String subject, String from, {MessageCategory? category}) {
    final inbox = app.store.mailboxes.inbox(
      app.store.accounts.all().single.id,
    )!;
    app.store.messages.upsertSummaries(inbox.id, [
      MessageSummary(
        uid: 700,
        receivedAt: DateTime.now().toUtc().subtract(const Duration(days: 2)),
        subject: subject,
        from: MailAddress(
          localPart: from.split('@').first,
          domain: from.split('@').last,
        ),
        snippet: 'Thank you.',
        size: 20000,
        category: category ?? MessageCategory.notifications,
      ),
    ]);
  }

  Future<void> open(WidgetTester tester, String page) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
    await tester.pump();
    await tester.tap(find.text(page));
    await tester.pump();
    await settle(tester);
  }

  for (final (page, setUpMail, button, offer, reading) in [
    (
      'Subscriptions',
      () => add('Your receipt from CloudBox', 'billing@cloudbox.example'),
      'Read receipts',
      'found in 1 receipt not',
      'Reading 1 receipt…',
    ),
    (
      'Trips',
      () => add(
        'Your booking confirmation for Hotel Sakura',
        'reservations@stays.example',
      ),
      'Read booking emails',
      'found in 1 booking email',
      'Reading 1 booking email…',
    ),
    (
      'Deliveries',
      // (With the sample inbox's "Your parcel".)
      () => add('Your order has shipped', 'orders@shop.example'),
      'Read shipping emails',
      'found in 2 shipping emails',
      'Reading 2 shipping emails…',
    ),
    (
      'Online accounts',
      () => add(
        'Welcome!',
        'hello@paperboard.example',
        category: MessageCategory.newsletters,
      ),
      'Read emails',
      '1 welcome or account email',
      'Reading 1 account email…',
    ),
  ]) {
    group(page, () {
      testWidgets('on: no card, a quiet line while reading', (tester) async {
        setUpMail();
        expect(app.services.settings.autoRead, isTrue, reason: 'default');
        await open(tester, page);

        expect(find.text(button), findsNothing);
        expect(find.textContaining(offer), findsNothing);
        expect(find.text(reading), findsOneWidget);

        // Offline here: the run ends, the line goes, no card comes.
        await tester.runAsync(app.services.autoRead.run);
        await tester.pump();
        expect(app.services.autoRead.active, isFalse);
        expect(find.text(reading), findsNothing);
        expect(find.text(button), findsNothing);
      });

      testWidgets('off: the card, as before', (tester) async {
        setUpMail();
        app.services.settings.autoRead = false;
        await open(tester, page);

        expect(find.textContaining(offer), findsOneWidget);
        expect(find.text(button), findsOneWidget);
        expect(find.text(reading), findsNothing);
      });
    });
  }
}
