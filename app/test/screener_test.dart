// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

MailAddress _address(String a, [String? name]) => MailAddress(
  displayName: name,
  localPart: a.split('@').first,
  domain: a.split('@').last,
);

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  MailStore store() => app.store;
  int accountId() => store().accounts.all().single.id;
  StoredMailbox inbox() => store().mailboxes.inbox(accountId())!;
  StoredMailbox archive() =>
      store().mailboxes.bySpecialUse(accountId(), SpecialUse.archive)!;
  SmartSection sectionOf(String subject) => store().messages
      .list(const MessageQuery.inbox(limit: 100))
      .firstWhere((m) => m.subject == subject)
      .section;

  /// The Screener on (everyone in the sample inbox counts as let in), and
  /// two first-time senders.
  void seedFirstTimers() {
    store().screener.enable(now: DateTime.utc(2026, 10, 21));
    store().messages.upsertSummaries(inbox().id, [
      MessageSummary(
        uid: 20,
        receivedAt: DateTime.utc(2026, 10, 22, 8),
        subject: 'Portfolio review?',
        from: _address('ana@studio.example', 'Ana Ruiz'),
        snippet:
            'Hi! I saw your talk last week and wondered if you could '
            'look at my portfolio.',
        messageId: 'ana1@studio.example',
      ),
      MessageSummary(
        uid: 21,
        receivedAt: DateTime.utc(2026, 10, 22, 10),
        subject: 'Exclusive offer, today only',
        from: _address('promo@deals.example', 'Deals Daily'),
        snippet: 'Save 70% on everything in store.',
        messageId: 'promo1@deals.example',
      ),
      MessageSummary(
        uid: 22,
        receivedAt: DateTime.utc(2026, 10, 22, 12),
        subject: 'Following up',
        from: _address('ana@studio.example', 'Ana Ruiz'),
        messageId: 'ana2@studio.example',
      ),
    ]);
  }

  Future<void> show(
    WidgetTester tester, {
    Size size = const Size(1400, 900),
  }) async {
    tester.view.physicalSize = size;
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
  }

  Future<void> openScreener(WidgetTester tester) async {
    await tester.tap(find.text('Screener'));
    await tester.pumpAndSettle();
  }

  testWidgets('no Screener entry while no one is waiting', (tester) async {
    store().screener.enable(now: DateTime.utc(2026, 10, 21));
    await show(tester);
    expect(find.text('Screener'), findsNothing);
    expect(find.text('Lunch?'), findsOneWidget, reason: 'known senders');
  });

  testWidgets('the entry counts waiting senders; their mail stays out', (
    tester,
  ) async {
    seedFirstTimers();
    await show(tester);
    expect(find.text('Screener'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('2 new senders are waiting for your OK'), findsOneWidget);
    expect(find.text('Portfolio review?'), findsNothing);
    expect(find.text('Hello there'), findsOneWidget);

    await openScreener(tester);
    expect(find.text('Ana Ruiz'), findsOneWidget);
    expect(find.text('Deals Daily'), findsOneWidget);
    // Her first email, with its preview; she wrote twice.
    expect(find.text('Portfolio review?'), findsOneWidget);
    expect(find.textContaining('I saw your talk'), findsOneWidget);
    expect(find.textContaining('2 emails'), findsOneWidget);
    expect(find.text('Following up'), findsNothing);
    // Each sender has their buttons on a wide screen.
    expect(find.widgetWithText(FilledButton, 'Let in'), findsNWidgets(2));
    expect(find.widgetWithText(OutlinedButton, 'Screen out'), findsNWidgets(2));
  });

  testWidgets('Let in, with Undo', (tester) async {
    seedFirstTimers();
    await show(tester);
    await openScreener(tester);
    // Ana wrote last, so she is listed first.
    await tester.tap(find.widgetWithText(FilledButton, 'Let in').first);
    await tester.pump();
    expect(find.text('Ana Ruiz can now reach your inbox'), findsOneWidget);
    expect(find.text('Ana Ruiz'), findsNothing, reason: 'no longer waiting');
    expect(sectionOf('Portfolio review?'), SmartSection.general);
    expect(sectionOf('Following up'), SmartSection.general);
    expect(
      store().screener.matching('ana@studio.example')!.decision,
      ScreenerDecision.letIn,
    );

    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(find.text('Ana Ruiz'), findsOneWidget);
    expect(sectionOf('Portfolio review?'), SmartSection.screener);
    expect(store().screener.all(), isEmpty);
  });

  testWidgets('Screen out sends their mail to Newsletters, with Undo', (
    tester,
  ) async {
    seedFirstTimers();
    await show(tester);
    await openScreener(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Screen out').last);
    await tester.pump();
    expect(
      find.text('Deals Daily screened out. Their mail goes to Newsletters.'),
      findsOneWidget,
    );
    expect(sectionOf('Exclusive offer, today only'), SmartSection.newsletters);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(sectionOf('Exclusive offer, today only'), SmartSection.screener);

    // Back in the inbox: the entry counts one sender less after a decision.
    await tester.tap(find.widgetWithText(OutlinedButton, 'Screen out').last);
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('1 new sender is waiting for your OK'), findsOneWidget);
  });

  testWidgets('Screen out to Archive moves their mail, with Undo', (
    tester,
  ) async {
    seedFirstTimers();
    store().screener.outPlace = ScreenOutPlace.archive;
    await show(tester);
    await openScreener(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Screen out').last);
    await tester.pump();
    expect(
      find.text('Deals Daily screened out. Moved to Archive.'),
      findsOneWidget,
    );
    // Gone from the inbox; the move to Archive waits in the outbox.
    expect(
      store().messages
          .list(const MessageQuery.inbox(limit: 100))
          .map((m) => m.subject),
      isNot(contains('Exclusive offer, today only')),
    );
    expect(
      store().outbox
          .all(accountId())
          .map((e) => e.action)
          .whereType<MoveAction>()
          .single
          .targetMailboxId,
      archive().id,
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(sectionOf('Exclusive offer, today only'), SmartSection.screener);
    expect(store().screener.all(), isEmpty);
  });

  testWidgets('Let in everyone at a company domain, from the menu', (
    tester,
  ) async {
    seedFirstTimers();
    await show(tester);
    await openScreener(tester);
    await tester.tap(find.byTooltip('More choices').first);
    await tester.pumpAndSettle();
    expect(find.text('Screen out everyone at studio.example'), findsOneWidget);
    await tester.tap(find.text('Let in everyone at studio.example'));
    await tester.pumpAndSettle();
    expect(
      find.text('Everyone at studio.example can now reach your inbox'),
      findsOneWidget,
    );
    final decision = store().screener.all().single;
    expect(
      (decision.kind, decision.value),
      (ScreenerKind.domain, 'studio.example'),
    );
  });

  testWidgets('phones: the buttons sit at the bottom, for the picked sender', (
    tester,
  ) async {
    seedFirstTimers();
    await show(tester, size: const Size(400, 860));
    await openScreener(tester);
    final letIn = find.widgetWithText(FilledButton, 'Let in');
    expect(letIn, findsOneWidget, reason: 'one bar, not one per sender');
    expect(
      tester.getBottomLeft(letIn).dy,
      greaterThan(860 - 100),
      reason: 'within reach of the thumb',
    );
    // The first sender (Ana) is picked; tapping another picks them.
    await tester.tap(find.text('Deals Daily'));
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Screen out'));
    await tester.pump();
    expect(sectionOf('Exclusive offer, today only'), SmartSection.newsletters);
    expect(sectionOf('Portfolio review?'), SmartSection.screener);
    // The next one is picked by itself.
    await tester.tap(letIn);
    await tester.pump();
    expect(sectionOf('Portfolio review?'), SmartSection.general);
    expect(
      find.text(
        'No one is waiting. New senders appear here before '
        'they reach your inbox.',
      ),
      findsOneWidget,
    );
  });

  group('settings', () {
    Future<void> showSettings(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsPage(services: app.services, isAndroid: false),
        ),
      );
    }

    testWidgets('the switch turns it on; existing senders are let in', (
      tester,
    ) async {
      await showSettings(tester);
      expect(store().screener.enabled, isFalse, reason: 'off by default');
      expect(find.text('Screened-out mail goes to'), findsNothing);
      await tester.tap(find.text('Screen first-time senders'));
      await tester.pump();
      expect(store().screener.enabled, isTrue);
      expect(store().screener.waitingCount(), 0);
      expect(sectionOf('Hello there'), SmartSection.general);

      await tester.tap(find.text('Newsletters'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Notifications').last);
      await tester.pumpAndSettle();
      expect(store().screener.outPlace, ScreenOutPlace.notifications);
    });

    testWidgets('Screened senders: change a decision, or ask again', (
      tester,
    ) async {
      seedFirstTimers();
      store().screener.decide(
        ScreenerKind.address,
        'promo@deals.example',
        ScreenerDecision.screenOut,
      );
      store().screener.decide(
        ScreenerKind.domain,
        'studio.example',
        ScreenerDecision.letIn,
      );
      await showSettings(tester);
      expect(find.text('2 senders you let in or screened out'), findsOneWidget);
      await tester.tap(find.text('Screened senders'));
      await tester.pumpAndSettle();
      expect(find.text('Everyone at studio.example'), findsOneWidget);
      expect(find.text('promo@deals.example'), findsOneWidget);
      expect(
        find.text('Screened out: their mail goes to the Newsletters section'),
        findsOneWidget,
      );

      // Let the screened-out sender in after all.
      await tester.tap(find.byTooltip('Change').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Let in').last);
      await tester.pumpAndSettle();
      expect(sectionOf('Exclusive offer, today only'), SmartSection.general);

      // Forget the domain: Ana waits again.
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Everyone at studio.example'),
          matching: find.byTooltip('Change'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ask again next time'));
      await tester.pumpAndSettle();
      expect(sectionOf('Portfolio review?'), SmartSection.screener);
      expect(store().screener.all(), hasLength(1));
    });
  });
}
