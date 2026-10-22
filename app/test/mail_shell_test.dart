// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmail/src/services/app_services.dart';
import 'package:fmail/src/ui/fmail_theme.dart';
import 'package:fmail/src/ui/mail_shell.dart';
import 'package:fmail/src/ui/message_tile.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  late AppServices services;
  late MailStore store;

  setUp(() async {
    app = await TestApp.create();
    services = app.services;
    store = app.store;
  });

  tearDown(() => app.dispose());

  Future<void> show(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: FmailTheme.light(),
        home: MailShell(
          notifications: false,
          services: services,
          onAddAccount: () {},
          onAccountsChanged: () {},
        ),
      ),
    );
    await tester.pump();
  }

  /// Lets real isolates (worker, message parsing) finish.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }

  double top(WidgetTester tester, String text) =>
      tester.getTopLeft(find.text(text).first).dy;

  testWidgets('wide: sidebar, Smart Inbox accordion, reader', (tester) async {
    await show(tester, const Size(1400, 900));

    // Sidebar.
    for (final folder in ['Pins', 'Sent', 'Archive', 'Projects']) {
      expect(find.text(folder), findsOneWidget, reason: folder);
    }

    // Every section with mail, in order.
    for (final title in [
      'Pinned',
      'Important',
      'General',
      'Notifications',
      'Newsletters',
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    expect(top(tester, 'Pinned') < top(tester, 'Important'), isTrue);
    expect(top(tester, 'Important') < top(tester, 'General'), isTrue);
    expect(top(tester, 'Keep this') < top(tester, 'Lunch?'), isTrue);
    expect(
      top(tester, 'Lunch?') < top(tester, 'Hello there'),
      isTrue,
      reason: 'Carol is important',
    );

    // Notifications and Newsletters start collapsed, naming their senders.
    expect(find.text('Weekly deals'), findsNothing);
    expect(
      find.text('Shop'),
      findsOneWidget,
      reason: 'sender shown on the collapsed header',
    );
    await tester.tap(find.text('Newsletters'));
    await tester.pump();
    expect(find.text('Weekly deals'), findsOneWidget);
    await tester.tap(find.text('Newsletters'));
    await tester.pump();
    expect(find.text('Weekly deals'), findsNothing);
    expect(
      store.settings.read('ui.collapsedSections'),
      contains('newsletters'),
    );

    // Open a message: safe body, blocked tracker, read.
    await tester.tap(find.text('Hello there'));
    await settle(tester);
    expect(find.textContaining('Visible', findRichText: true), findsWidgets);
    expect(
      find.textContaining('Blocked a tracker that would tell tracker.example'),
      findsOneWidget,
    );
    expect(
      store.messages
          .list(const MessageQuery.inbox())
          .firstWhere((m) => m.subject == 'Hello there')
          .flags
          .seen,
      isTrue,
    );

    // A link asks before opening anything.
    final link = find.textContaining('a link', findRichText: true).last;
    await tester.tapAt(tester.getTopLeft(link) + const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.text('Open this link?'), findsOneWidget);
    expect(find.text('shop.example'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Pin from the reader moves it to Pinned.
    await tester.tap(find.byTooltip('Pin (S)'));
    await tester.pump();
    expect(top(tester, 'Hello there') < top(tester, 'Important'), isTrue);
  });

  testWidgets('archive: the next message opens, and Undo brings it back', (
    tester,
  ) async {
    await show(tester, const Size(1400, 900));
    await tester.tap(find.text('Lunch?'));
    await settle(tester);
    await tester.tap(find.byTooltip('Archive (E)').last);
    await tester.pump();
    expect(find.text('Archived'), findsOneWidget);
    expect(find.text('Lunch?'), findsNothing);
    await settle(tester);
    // The message below it is open now.
    expect(find.textContaining('Visible', findRichText: true), findsWidgets);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(find.text('Lunch?'), findsOneWidget);
    final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
    expect(
      store.outbox
          .all(inbox.accountId)
          .whereType<OutboxEntry>()
          .where((e) => e.action is MoveAction),
      isEmpty,
    );
  });

  testWidgets('keyboard: J/K move, U toggles read, E archives, ? helps', (
    tester,
  ) async {
    await show(tester, const Size(1400, 900));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await settle(tester);
    expect(find.text('Keep this'), findsWidgets, reason: 'first message open');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await settle(tester);
    final carol = store.messages
        .list(const MessageQuery.inbox())
        .firstWhere((m) => m.subject == 'Lunch?');
    expect(carol.flags.seen, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
    await tester.pump();
    expect(store.messages.byId(carol.id)!.flags.seen, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.pump();
    expect(find.text('Archived'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '?');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Keyboard shortcuts'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('shortcuts never fire while typing', (tester) async {
    await show(tester, const Size(1400, 900));
    await tester.tap(find.byType(TextField).first);
    await tester.enterText(find.byType(TextField).first, 'e');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.pump();
    expect(find.text('Archived'), findsNothing);
  });

  testWidgets('select several messages and act on all of them', (tester) async {
    await show(tester, const Size(1400, 900));
    // Touch: long-press selects (tests run as Android).
    await tester.longPress(find.text('Lunch?'));
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(
      find.text('Hello there'),
    ); // in selection mode, taps select
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.byTooltip('Mark as read (U)').first);
    await tester.pump();
    expect(find.text('Marked as read (2)'), findsOneWidget);
    expect(find.textContaining('selected'), findsNothing);
    final inbox = store.messages.list(const MessageQuery.inbox());
    for (final subject in ['Lunch?', 'Hello there']) {
      expect(
        inbox.firstWhere((m) => m.subject == subject).flags.seen,
        isTrue,
        reason: subject,
      );
    }
  });

  testWidgets('Classic shows one list, newest first', (tester) async {
    await show(tester, const Size(1400, 900));
    await tester.tap(find.text('Classic'));
    await tester.pump();
    expect(find.text('Pinned'), findsNothing);
    for (final subject in [
      'Hello there',
      'Lunch?',
      'Weekly deals',
      'Your parcel',
      'Keep this',
    ]) {
      expect(find.text(subject), findsOneWidget);
    }
    expect(top(tester, 'Keep this') < top(tester, 'Hello there'), isTrue);
  });

  testWidgets('narrow: one pane at a time, back returns to the list', (
    tester,
  ) async {
    await show(tester, const Size(400, 800));
    expect(find.text('Pins'), findsNothing, reason: 'sidebar is in the drawer');
    await tester.tap(find.text('Hello there'));
    await settle(tester);
    expect(find.byTooltip('Back (Esc)'), findsOneWidget);
    expect(find.text('Lunch?'), findsNothing);
    await tester.tap(find.byTooltip('Back (Esc)'));
    await tester.pump();
    expect(find.text('Lunch?'), findsOneWidget);

    await tester.tap(find.byTooltip('Folders'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pins'));
    await tester.pumpAndSettle();
    expect(find.text('Keep this'), findsOneWidget);
    expect(find.text('Lunch?'), findsNothing);
  });

  testWidgets('thousands of messages: only what is on screen is built', (
    tester,
  ) async {
    final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
    store.messages.upsertSummaries(inbox.id, [
      for (var i = 100; i < 3100; i++)
        MessageSummary(
          uid: i,
          receivedAt: DateTime.utc(2025, 1, 1).add(Duration(minutes: i)),
          subject: 'Bulk $i',
          from: MailAddress(localPart: 'p$i', domain: 'x.example'),
        ),
    ]);
    await show(tester, const Size(1400, 900));
    await tester.tap(find.text('Classic'));
    await tester.pump();
    final built = find.byType(MessageTile).evaluate().length;
    expect(built, lessThan(30), reason: 'built $built rows for 3005 messages');
    // Scrolling far down loads more pages and still builds only a screenful.
    await tester.drag(
      find.byType(CustomScrollView).first,
      const Offset(0, -20000),
    );
    await tester.pump();
    expect(find.byType(MessageTile).evaluate().length, lessThan(30));
  });

  testWidgets('search finds stored mail', (tester) async {
    await show(tester, const Size(1400, 900));
    await tester.enterText(find.byType(TextField), 'parcel');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(find.text('Results for "parcel"'), findsOneWidget);
    expect(find.text('Your parcel'), findsOneWidget);
    expect(find.text('Lunch?'), findsNothing);
  });
}
