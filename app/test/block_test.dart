// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/mail/mail_controller.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  MailStore store() => app.store;
  int accountId() => store().accounts.all().single.id;
  StoredMailbox inbox() => store().mailboxes.inbox(accountId())!;
  StoredMailbox junk() =>
      store().mailboxes.bySpecialUse(accountId(), SpecialUse.junk)!;
  StoredMessage message(String subject) => store().messages
      .list(const MessageQuery.inbox())
      .firstWhere((m) => m.subject == subject);

  Future<void> show(WidgetTester tester) async {
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
  }

  Future<void> open(WidgetTester tester, String subject) async {
    await tester.tap(find.text(subject).first);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }

  /// Taps a reader action, from the "More" menu if it didn't fit.
  Future<void> action(WidgetTester tester, String label) async {
    final button = find.byTooltip(label);
    if (button.evaluate().isEmpty) {
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
    } else {
      await tester.tap(button);
    }
    await tester.pumpAndSettle();
  }

  testWidgets('block a sender from the reader; Undo brings it all back', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.text('Classic'));
    await tester.pump();
    await open(tester, 'Weekly deals');
    await action(tester, 'Block sender');

    expect(find.text('Block this sender?'), findsOneWidget);
    expect(find.text('Only news@shop.example'), findsOneWidget);
    expect(find.text('Everyone at shop.example'), findsOneWidget);
    expect(
      find.text('Also move the message from them in your inbox to Junk'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Block'));
    await tester.pump();

    expect(
      find.text('Blocked news@shop.example. Moved 1 to Junk.'),
      findsOneWidget,
    );
    expect(store().blocks.matching('news@shop.example'), isNotNull);
    expect(store().messages.uids(inbox().id), isNot(contains(3)));
    final move = store().outbox
        .all(accountId())
        .map((e) => e.action)
        .whereType<MoveAction>()
        .single;
    expect(move.targetMailboxId, junk().id);
    expect(find.text('Weekly deals'), findsNothing);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(store().blocks.all(), isEmpty);
    expect(find.text('Weekly deals'), findsOneWidget);
  });

  testWidgets('blocking a whole domain', (tester) async {
    await show(tester);
    await tester.tap(find.text('Classic'));
    await tester.pump();
    await open(tester, 'Weekly deals');
    await action(tester, 'Block sender');
    await tester.tap(find.text('Everyone at shop.example'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Block'));
    await tester.pump();
    expect(
      find.text('Blocked everyone at shop.example. Moved 1 to Junk.'),
      findsOneWidget,
    );
    final block = store().blocks.all().single;
    expect(block.kind, BlockKind.domain);
    expect(block.value, 'shop.example');
  });

  testWidgets('mail from a blocked sender says so and can be unblocked', (
    tester,
  ) async {
    store().blocks.block(BlockKind.address, 'carol@x.example');
    await show(tester);
    await open(tester, 'Lunch?');
    expect(find.text('You blocked carol@x.example.'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Unblock'));
    await tester.pump();
    expect(store().blocks.all(), isEmpty);
    expect(find.text('You blocked carol@x.example.'), findsNothing);
    expect(find.text('Unblocked carol@x.example'), findsOneWidget);
  });

  testWidgets('Settings lists blocked senders and unblocks them', (
    tester,
  ) async {
    store().blocks.block(BlockKind.domain, 'spam.example');
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(services: app.services, isAndroid: false)),
    );
    await tester.scrollUntilVisible(find.text('Blocked senders'), 100);
    await tester.tap(find.text('Blocked senders'));
    await tester.pumpAndSettle();
    expect(find.text('Everyone at spam.example'), findsOneWidget);
    await tester.tap(find.text('Unblock'));
    await tester.pump();
    expect(store().blocks.all(), isEmpty);
    expect(find.textContaining('No one is blocked'), findsOneWidget);
  });

  test('own addresses and free mail domains are handled with care', () {
    final controller = MailController(app.services);
    addTearDown(controller.dispose);
    final ownSent = store().messages
        .list(
          MessageQuery(
            mailboxIds: [
              store().mailboxes.bySpecialUse(accountId(), SpecialUse.sent)!.id,
            ],
          ),
        )
        .single;
    expect(controller.canBlock(ownSent), isFalse);
    expect(controller.blockChoice(ownSent), isNull);

    final stranger = controller.blockChoice(message('Hello there'))!;
    expect(stranger.address, 'stranger@x.example');
    expect(stranger.domain, 'x.example');
    expect(stranger.fromAddress, 1);
    expect(stranger.fromDomain, 3, reason: 'stranger, carol and dave');

    store().messages.upsertSummaries(inbox().id, [
      MessageSummary(
        uid: 40,
        receivedAt: DateTime.utc(2026, 10, 22),
        subject: 'From Gmail',
        from: const MailAddress(localPart: 'someone', domain: 'gmail.com'),
      ),
      MessageSummary(
        uid: 41,
        receivedAt: DateTime.utc(2026, 10, 22),
        subject: 'Colleague',
        from: const MailAddress(localPart: 'bob', domain: 'citusmail.test'),
      ),
    ]);
    expect(controller.blockChoice(message('From Gmail'))!.domain, isNull);
    expect(
      controller.blockChoice(message('Colleague'))!.domain,
      isNull,
      reason: 'the user\'s own domain',
    );
  });
}
