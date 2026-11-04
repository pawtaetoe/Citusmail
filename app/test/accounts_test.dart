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

  void seed() {
    final inbox = app.store.mailboxes.inbox(
      app.store.accounts.all().single.id,
    )!;
    final now = DateTime.now().toUtc();
    const alice = MailAddress(localPart: 'alice', domain: 'citusmail.test');
    const shopeeAlice = MailAddress(
      localPart: 'alice+shopee',
      domain: 'citusmail.test',
    );
    MessageSummary mail(
      int uid,
      String subject,
      MailAddress from,
      int daysAgo, {
      String? snippet,
      MailAddress to = alice,
    }) => MessageSummary(
      uid: uid,
      receivedAt: now.subtract(Duration(days: daysAgo)),
      subject: subject,
      from: from,
      to: [to],
      snippet: snippet,
      flags: MessageFlags.fromImap([r'\Seen']),
    );
    const google = MailAddress(
      displayName: 'Google',
      localPart: 'no-reply',
      domain: 'accounts.google.com',
    );
    app.store.messages.upsertSummaries(inbox.id, [
      mail(
        500,
        'Security alert',
        google,
        10,
        snippet: 'A new sign-in on Windows. alice@citusmail.test',
      ),
      mail(501, 'Welcome to your new Google Account', google, 5 * 365),
      mail(
        502,
        'Please confirm your Shopee account',
        const MailAddress(
          displayName: 'Shopee',
          localPart: 'info',
          domain: 'mail.shopee.sg',
        ),
        3 * 365,
        to: shopeeAlice,
      ),
      // Someone else's discussion, a friend, a one-off shop: not accounts.
      mail(
        503,
        'Re: [octo/widgets] Password reset form crashes (#77)',
        const MailAddress(
          displayName: 'Bob',
          localPart: 'notifications',
          domain: 'github.com',
        ),
        2,
      ),
      mail(
        504,
        'Welcome to the neighbourhood!',
        const MailAddress(
          displayName: 'Carol',
          localPart: 'carol',
          domain: 'gmail.com',
        ),
        3,
      ),
      mail(
        505,
        'Your receipt from Flower Shop',
        const MailAddress(localPart: 'orders', domain: 'flowers.example'),
        4,
        snippet: 'Thank you for your order. Total S\$45.00',
      ),
    ]);
  }

  testWidgets('services with an account, their address, filters and Undo', (
    tester,
  ) async {
    seed();
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
    await tester.tap(find.text('Your accounts'));
    await tester.pump();
    await settle(tester);
    await tester.pumpAndSettle();

    expect(
      find.text('2 services have an account with your email'),
      findsOneWidget,
    );
    expect(find.text('Google'), findsOneWidget);
    expect(find.text('Shopee'), findsOneWidget);
    expect(find.text('Flower Shop'), findsNothing);
    expect(find.text('Carol'), findsNothing);
    expect(find.text('github.com'), findsNothing);
    // The address each uses, plus-address included.
    expect(find.text('alice@citusmail.test'), findsWidgets);
    expect(find.text('alice+shopee@citusmail.test'), findsWidgets);
    expect(
      find.textContaining(
        RegExp(r'^Signed up \w+ \d{4} · last security alert'),
      ),
      findsOneWidget,
    );
    expect(find.text('Security alerts'), findsOneWidget);
    // Most recent first.
    expect(
      tester.getTopLeft(find.text('Google')).dy,
      lessThan(tester.getTopLeft(find.text('Shopee')).dy),
    );

    // A–Z is the same here; search narrows.
    await tester.enterText(find.byType(TextField), 'shop');
    await tester.pump();
    expect(find.text('Google'), findsNothing);
    expect(find.text('Shopee'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();

    // Not heard from in two years: Shopee only.
    await tester.tap(find.text('Not heard from in 2+ years'));
    await tester.pump();
    expect(find.text('Google'), findsNothing);
    expect(find.text('Shopee'), findsOneWidget);
    await tester.tap(find.text('Not heard from in 2+ years'));
    await tester.pump();

    // By address (the chips scroll sideways).
    await tester.ensureVisible(
      find.widgetWithText(FilterChip, 'alice@citusmail.test'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'alice@citusmail.test'));
    await tester.pump();
    expect(find.text('Google'), findsOneWidget);
    expect(find.text('Shopee'), findsNothing);
    await tester.tap(find.widgetWithText(FilterChip, 'alice@citusmail.test'));
    await tester.pump();

    // Its own page: the address, what was seen, every email in place.
    await tester.tap(find.text('Google'));
    await tester.pumpAndSettle();
    expect(find.text('Search all mail from Google'), findsOneWidget);
    expect(find.text('Signed up'), findsWidgets);
    expect(find.text('Security alerts'), findsOneWidget);
    expect(find.textContaining('Delete account'), findsOneWidget);
    await tester.tap(find.text('Welcome to your new Google Account'));
    await settle(tester);
    expect(find.text('Email'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Search all mail from Google'), findsOneWidget);

    // "Not an account": back to the list, with Undo.
    await tester.scrollUntilVisible(find.text('Not an account'), 200);
    await tester.tap(find.text('Not an account'));
    await settle(tester);
    expect(find.text('Google'), findsNothing);
    expect(
      find.text('1 service has an account with your email'),
      findsOneWidget,
    );
    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect(find.text('Google'), findsOneWidget);

    // Search all its mail: back in the mail, with the search.
    await tester.tap(find.text('Google'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search all mail from Google'));
    await settle(tester);
    await tester.pumpAndSettle();
    expect(find.text('Your accounts'), findsOneWidget, reason: 'sidebar');
    expect(find.text('Security alert'), findsOneWidget);
    expect(find.text('Please confirm your Shopee account'), findsNothing);
  });
}
