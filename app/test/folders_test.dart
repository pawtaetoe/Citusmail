// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmail/src/ui/fmail_theme.dart';
import 'package:fmail/src/ui/mail_shell.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  StoredMailbox projects() => app.store.mailboxes
      .forAccount(app.store.accounts.all().single.id)
      .firstWhere((m) => m.encodedName == 'Projects');

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: FmailTheme.light(),
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

  testWidgets('a folder\'s rules can be added, checked and removed', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.text('Projects'));
    await tester.pump();
    await tester.tap(find.byTooltip('Folder rules'));
    await tester.pumpAndSettle();
    expect(find.text('No rules yet.'), findsOneWidget);

    // A bad address is pointed out.
    await tester.enterText(find.byType(TextField).last, 'not-an-address');
    await tester.tap(find.text('Add rule'));
    await tester.pump();
    expect(find.text('Enter an email address.'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'Orders@Shop.example');
    await tester.tap(find.text('Add rule'));
    await tester.pump();
    expect(find.text('From orders@shop.example'), findsOneWidget);
    expect(
      app.store.folderRules.forMailbox(projects().id).single.field,
      RuleField.fromAddress,
    );

    await tester.tap(find.byTooltip('Remove rule'));
    await tester.pump();
    expect(app.store.folderRules.forMailbox(projects().id), isEmpty);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
  });

  testWidgets('the inbox, Drafts and Sent have no rules button', (
    tester,
  ) async {
    await show(tester);
    for (final folder in ['Sent', 'Drafts']) {
      await tester.tap(find.text(folder));
      await tester.pump();
      expect(find.byTooltip('Folder rules'), findsNothing, reason: folder);
    }
  });

  testWidgets('Move with "always" files the sender from now on', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.text('Classic'));
    await tester.pump();
    await tester.tap(find.text('Weekly deals'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Move to folder (V)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Always move mail from news@shop.example here'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ListTile, 'Projects'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final rule = app.store.folderRules.forMailbox(projects().id).single;
    expect(rule.field, RuleField.fromAddress);
    expect(rule.value, 'news@shop.example');
    final move = app.store.outbox
        .all(rule.accountId)
        .whereType<OutboxEntry>()
        .map((e) => e.action)
        .whereType<MoveAction>()
        .single;
    expect(move.targetMailboxId, projects().id);
    expect(find.text('Weekly deals'), findsNothing, reason: 'left the inbox');
  });

  testWidgets('creating a folder offline says so', (tester) async {
    await show(tester);
    await tester.tap(find.byTooltip('New folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Receipts');
    await tester.tap(find.text('Create'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();
    expect(
      find.text('Folders can only be created while online.'),
      findsOneWidget,
    );

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'star*');
    await tester.tap(find.text('Create'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();
    expect(find.text('That can\'t be a folder name.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });
}
