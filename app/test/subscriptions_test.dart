// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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

  testWidgets('receipts become a subscription with its price and dates', (
    tester,
  ) async {
    // Reading automatically off: the page offers it, as a card.
    app.services.settings.autoRead = false;
    final inbox = app.store.mailboxes.inbox(
      app.store.accounts.all().single.id,
    )!;
    final now = DateTime.now().toUtc();
    app.store.messages.upsertSummaries(inbox.id, [
      for (final (i, daysAgo) in [5, 35, 65].indexed)
        MessageSummary(
          uid: 300 + i,
          receivedAt: now.subtract(Duration(days: daysAgo)),
          subject: 'Your StreamFlix receipt',
          from: const MailAddress(
            displayName: 'StreamFlix',
            localPart: 'info',
            domain: 'mailer.streamflix.example',
          ),
          snippet: 'Your membership has been renewed. Total S\$17.98',
        ),
      // An ordinary message with a receipt word: not a subscription.
      MessageSummary(
        uid: 310,
        receivedAt: now.subtract(const Duration(days: 3)),
        subject: 'Receipt for lunch',
        from: const MailAddress(localPart: 'carol', domain: 'x.example'),
      ),
    ]);

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
    // In the sidebar's "Found in your mail" group, folded at first.
    await tester.tap(find.text('Found in your mail'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Subscriptions'));
    await tester.pump();
    await settle(tester);
    await tester.pumpAndSettle();

    // What it costs a year, a month and a day, and its share of the year.
    expect(find.text('S\$215.76'), findsOneWidget);
    expect(find.text('S\$17.98'), findsWidgets); // a month, and its price
    expect(find.text('S\$0.59'), findsOneWidget);
    expect(find.text('S\$215.76 a year'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(find.textContaining('1 active'), findsOneWidget);
    expect(find.text('StreamFlix'), findsNWidgets(2)); // split and list
    expect(find.textContaining('Monthly · Next charge about'), findsOneWidget);
    expect(find.text('Receipt for lunch'), findsNothing);
    // Every price is known; only the unrecognised receipt (it may be a
    // subscription whose preview says little) is offered for reading.
    expect(find.textContaining('found in 1 receipt not'), findsOneWidget);

    // Its own page: what was charged, every receipt.
    await tester.tap(find.text('StreamFlix').last);
    await tester.pumpAndSettle();
    expect(find.text('S\$17.98 · monthly'), findsOneWidget);
    expect(find.textContaining('3 times since'), findsOneWidget);
    expect(find.text('S\$53.94'), findsOneWidget, reason: 'in total');
    expect(find.text('S\$17.98'), findsNWidgets(3), reason: 'per receipt');

    // A receipt opens right here; Back returns to the subscription.
    await tester.tap(find.text('S\$17.98').first);
    await settle(tester);
    expect(find.text('Receipt'), findsOneWidget);
    expect(find.text('Your StreamFlix receipt'), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('S\$17.98 · monthly'), findsOneWidget);

    // "Not a subscription": back to the list, with Undo.
    await tester.tap(find.text('Not a subscription'));
    await settle(tester);
    expect(find.text('No subscriptions found'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect(find.text('StreamFlix'), findsNWidgets(2));
  });
}
