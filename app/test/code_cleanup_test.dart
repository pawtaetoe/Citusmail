// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/mail/mail_controller.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/message_list_pane.dart';
import 'package:citusmail/src/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  late MailStore store;
  late StoredMailbox inbox;

  setUp(() async {
    app = await TestApp.create();
    store = app.store;
    inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
  });

  tearDown(() => app.dispose());

  void code(int uid, String subject, Duration age, {bool pinned = false}) =>
      store.messages.upsertSummaries(inbox.id, [
        MessageSummary(
          uid: uid,
          messageId: '<code$uid@accounts.shop.example>',
          receivedAt: DateTime.now().toUtc().subtract(age),
          subject: subject,
          from: const MailAddress(
            displayName: 'Shop',
            localPart: 'no-reply',
            domain: 'accounts.shop.example',
          ),
          category: MessageCategory.codes,
          code: '482913',
          flags: pinned
              ? MessageFlags.fromImap([r'\Flagged'])
              : MessageFlags.none,
        ),
      ]);

  void seedCodes() {
    code(20, 'Your verification code is 482913', const Duration(days: 3));
    code(21, 'Reset your password', const Duration(days: 2));
    code(22, 'Your sign-in code', const Duration(hours: 2));
  }

  Iterable<OutboxEntry> moves() =>
      store.outbox.all(inbox.accountId).where((e) => e.action is MoveAction);

  Future<MailController> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
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
    return tester
        .widget<MessageListPane>(find.byType(MessageListPane))
        .controller;
  }

  testWidgets('asks first; "Not now" moves nothing and stops asking', (
    tester,
  ) async {
    seedCodes();
    final controller = await show(tester);
    expect(find.text('Verification'), findsOneWidget);
    expect(find.text('Tidy up old codes automatically?'), findsOneWidget);

    // A sync before the answer moves nothing.
    controller.tidyCodes();
    await tester.pump();
    expect(find.text('Reset your password'), findsOneWidget);
    expect(moves(), isEmpty);

    await tester.tap(find.text('Not now'));
    await tester.pump();
    expect(find.text('Tidy up old codes automatically?'), findsNothing);
    expect(controller.codeCleaner.settings.consent, isA<ConsentDeclined>());
    controller.refresh();
    await tester.pump();
    expect(find.text('Tidy up old codes automatically?'), findsNothing);
    expect(moves(), isEmpty);
  });

  testWidgets('"Turn on" tidies up now, with Undo', (tester) async {
    seedCodes();
    code(23, 'Pinned login code', const Duration(days: 5), pinned: true);
    final controller = await show(tester);
    await tester.tap(find.text('Turn on'));
    await tester.pump();
    expect(find.text('Tidied up 2 old codes'), findsOneWidget);
    expect(find.text('Reset your password'), findsNothing);
    expect(find.text('Your sign-in code'), findsOneWidget, reason: 'recent');
    expect(find.text('Pinned login code'), findsOneWidget, reason: 'pinned');
    expect(moves(), hasLength(1));
    expect(controller.codeCleaner.settings.agreed, isTrue);
    expect(find.text('Tidy up old codes automatically?'), findsNothing);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(find.text('Reset your password'), findsOneWidget);
    expect(moves(), isEmpty);

    // Not taken again in the next run.
    store.settings.delete(CodeCleanupSettings.lastRunKey);
    controller.tidyCodes();
    await tester.pump();
    expect(find.text('Reset your password'), findsOneWidget);
    expect(moves(), isEmpty);
  });

  testWidgets('at most once an hour after syncs', (tester) async {
    seedCodes();
    final controller = await show(tester);
    await tester.tap(find.text('Turn on'));
    await tester.pump();
    expect(moves(), hasLength(1));

    code(24, 'Another old code', const Duration(days: 2));
    controller.tidyCodes();
    await tester.pump();
    expect(moves(), hasLength(1));
    controller.tidyCodes(DateTime.now().toUtc().add(const Duration(hours: 2)));
    await tester.pump();
    expect(moves(), hasLength(2));
    expect(find.text('Tidied up 1 old code'), findsOneWidget);
  });

  testWidgets('settings: choices, and choosing counts as the OK', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(services: app.services, isAndroid: false)),
    );
    final settings = CodeCleanupSettings(store);
    expect(find.text('Clean up old codes'), findsOneWidget);
    expect(
      find.textContaining('After a day: Archive. Verification codes'),
      findsOneWidget,
      reason: 'the default',
    );
    expect(find.textContaining('Pinned ones are kept'), findsOneWidget);
    expect(find.textContaining('asks you first'), findsOneWidget);

    await tester.tap(find.text('Clean up old codes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('After a week'));
    await tester.pump();
    expect(settings.age, CodeCleanupAge.week);
    expect(settings.agreed, isTrue);

    await tester.tap(find.text('Move to Trash'));
    await tester.pump();
    expect(settings.action, CodeCleanupAction.trash);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.textContaining('After a week: Move to Trash.'), findsOneWidget);
    expect(find.textContaining('asks you first'), findsNothing);

    await tester.tap(find.text('Clean up old codes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Off'));
    await tester.pump();
    expect(settings.age, CodeCleanupAge.off);
    expect(find.text('What happens'), findsNothing);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Off. Verification codes'), findsOneWidget);
  });
}
