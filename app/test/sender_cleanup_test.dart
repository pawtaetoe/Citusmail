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
  late StoredMailbox inbox;
  setUp(() async {
    app = await TestApp.create();
    inbox = app.store.mailboxes.inbox(app.store.accounts.all().single.id)!;
  });
  tearDown(() => app.dispose());

  /// Lets isolates (grouping) finish.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  /// [count] newsletters from [from], one a day, the first [opened] of
  /// them read, and the first [pinned] of them pinned.
  void seed(
    String from,
    String name, {
    required int uid,
    required int count,
    int opened = 0,
    int pinned = 0,
  }) {
    final now = DateTime.now().toUtc();
    app.store.messages.upsertSummaries(inbox.id, [
      for (var i = 0; i < count; i++)
        MessageSummary(
          uid: uid + i,
          receivedAt: now.subtract(Duration(days: 1 + i)),
          subject: '$name news ${i + 1}',
          from: MailAddress(
            displayName: name,
            localPart: from.split('@').first,
            domain: from.split('@').last,
          ),
          category: MessageCategory.newsletters,
          flags: MessageFlags.fromImap([
            if (i < opened) r'\Seen',
            if (i < pinned) r'\Flagged',
          ]),
          headers: {
            'list-unsubscribe': ['<https://${from.split('@').last}/u>'],
          },
        ),
    ]);
  }

  int inInbox(String from) => app.store.messages
      .inboxFromList(inbox.accountId, fromAddress: from)
      .length;

  Future<void> openCleanUp(WidgetTester tester, {bool phone = false}) async {
    tester.view.physicalSize = phone
        ? const Size(400, 860)
        : const Size(1400, 900);
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
    if (phone) {
      await tester.tap(find.byTooltip('Folders'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clean up senders'));
    await tester.pump();
    await settle(tester);
    await tester.pumpAndSettle();
  }

  testWidgets('ranks senders; people and own mail are never listed', (
    tester,
  ) async {
    seed('deals@megastore.example', 'MegaStore', uid: 300, count: 8);
    seed('weekly@paper.example', 'The Paper', uid: 400, count: 5, opened: 5);
    await openCleanUp(tester);

    expect(find.text('8 emails from 1 sender you rarely open'), findsOneWidget);
    expect(find.text('MegaStore'), findsOneWidget);
    expect(find.textContaining('8 emails · none opened'), findsOneWidget);
    expect(find.textContaining('5 emails · all opened'), findsOneWidget);
    expect(find.text('Can unsubscribe'), findsNWidgets(2));
    expect(
      tester.getTopLeft(find.text('MegaStore')).dy,
      lessThan(tester.getTopLeft(find.text('The Paper')).dy),
    );

    // All senders: not Carol, whom the user has written to.
    await tester.tap(find.text('All senders'));
    await tester.pumpAndSettle();
    expect(find.text('Stranger Danger'), findsOneWidget);
    expect(find.text('Carol'), findsNothing);
  });

  testWidgets('Archive all from several senders, on a phone, with Undo', (
    tester,
  ) async {
    seed('deals@megastore.example', 'MegaStore', uid: 300, count: 6, pinned: 1);
    seed('weekly@paper.example', 'The Paper', uid: 400, count: 4);
    await openCleanUp(tester, phone: true);

    await tester.tap(find.text('MegaStore'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('The Paper'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    // The actions sit at the bottom, within thumb reach.
    final archive = find.byTooltip('Archive all');
    expect(tester.getCenter(archive).dy, greaterThan(760));
    await tester.tap(archive);
    await tester.pump();
    // The pinned one stays.
    expect(find.text('Archived 9 emails from 2 senders'), findsOneWidget);
    expect(inInbox('deals@megastore.example'), 1);
    expect(inInbox('weekly@paper.example'), 0);
    // One queued move for the whole folder, as the list's own archive.
    final queued = app.store.outbox.all(inbox.accountId);
    expect(queued, hasLength(1));
    expect((queued.single.action as MoveAction).uids, hasLength(9));

    await tester.pump(const Duration(milliseconds: 750));
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(inInbox('deals@megastore.example'), 6);
    expect(inInbox('weekly@paper.example'), 4);
    await settle(tester);
    expect(find.text('MegaStore'), findsOneWidget);
  });

  testWidgets('Keep hides a sender, remembered, with Undo', (tester) async {
    seed('deals@megastore.example', 'MegaStore', uid: 300, count: 6);
    await openCleanUp(tester);

    await tester.tap(find.byTooltip('What to do with MegaStore'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(find.text('MegaStore won\'t be listed here'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sender-deals@megastore.example')),
      findsNothing,
    );
    expect(app.store.settings.read('cleanup.kept'), 'deals@megastore.example');
    expect(find.text('Show 1 sender you keep'), findsOneWidget);
    // Its mail is untouched.
    expect(inInbox('deals@megastore.example'), 6);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('sender-deals@megastore.example')),
      findsOneWidget,
    );
    expect(app.store.settings.read('cleanup.kept'), '');
  });

  testWidgets('Delete all asks first and offers Undo', (tester) async {
    seed('deals@megastore.example', 'MegaStore', uid: 300, count: 3);
    await openCleanUp(tester);

    await tester.tap(find.byTooltip('What to do with MegaStore'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete all'));
    await tester.pumpAndSettle();
    expect(find.text('Delete 3 emails?'), findsOneWidget);
    await tester.tap(find.text('Move to Trash'));
    await tester.pump();
    expect(find.text('Moved 3 to Trash'), findsOneWidget);
    expect(inInbox('deals@megastore.example'), 0);
    await tester.pump(const Duration(milliseconds: 750));
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(inInbox('deals@megastore.example'), 3);
  });
}
