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
    await tester.tap(find.text('Subscriptions'));
    await tester.pump();
    await settle(tester);
    await tester.pumpAndSettle();

    expect(find.text('About S\$17.98 a month'), findsOneWidget);
    expect(find.textContaining('1 active'), findsOneWidget);
    expect(find.text('StreamFlix'), findsOneWidget);
    expect(find.textContaining('Monthly · Next charge about'), findsOneWidget);
    expect(find.text('Receipt for lunch'), findsNothing);
    // Every price is known: nothing to download.
    expect(find.text('Read receipts'), findsNothing);

    // Its receipts, and "Not a subscription" with Undo.
    await tester.tap(find.text('StreamFlix'));
    await tester.pumpAndSettle();
    expect(find.text('Your StreamFlix receipt'), findsNWidgets(3));
    await tester.tap(find.text('Not a subscription'));
    await settle(tester);
    expect(find.text('No subscriptions found'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect(find.text('StreamFlix'), findsOneWidget);
  });
}
