// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/mail/mail_controller.dart';
import 'package:citusmail/src/services/app_services.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/message_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
        theme: CitusmailTheme.light(),
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

  test('Gmail: archiving goes to All Mail when there is no Archive', () {
    final accountId = store.accounts.all().single.id;
    final inbox = store.mailboxes.inbox(accountId)!;
    final message = store.messages
        .list(MessageQuery(mailboxIds: [inbox.id]))
        .first;
    final controller = MailController(services);
    addTearDown(controller.dispose);
    expect(controller.archiveFor(message)?.name, 'Archive');

    store.mailboxes.replaceAll(accountId, [
      ImapMailboxInfo(encodedName: 'INBOX', delimiter: '/', attributes: {}),
      ImapMailboxInfo(
        encodedName: '[Gmail]/All Mail',
        delimiter: '/',
        attributes: {r'\All'},
      ),
    ]);
    expect(controller.archiveFor(message)?.specialUse, SpecialUse.all);
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

  testWidgets('the inbox is always the Smart Inbox', (tester) async {
    await show(tester, const Size(1400, 900));
    expect(find.text('Classic'), findsNothing);
    expect(find.text('Pinned'), findsOneWidget);
    // Another view and back: still sections.
    await tester.tap(find.text('Archive'));
    await tester.pump();
    expect(find.text('Pinned'), findsNothing);
    await tester.tap(find.byTooltip('Back to Inbox'));
    await tester.pump();
    expect(find.text('Pinned'), findsOneWidget);
  });

  testWidgets('phone: controls at the bottom, within reach of the thumb', (
    tester,
  ) async {
    await show(tester, const Size(400, 800));
    // List: menu, search and New message under the messages.
    final search = tester.getTopLeft(find.byType(TextField)).dy;
    expect(search, greaterThan(top(tester, 'Hello there')));
    expect(search, greaterThan(600));
    expect(tester.getTopLeft(find.byTooltip('Folders')).dy, greaterThan(600));
    expect(
      tester.getTopLeft(find.byTooltip('New message (C)')).dy,
      greaterThan(600),
    );
    // Open message: its actions under it too.
    await tester.tap(find.text('Hello there'));
    await settle(tester);
    expect(
      tester.getTopLeft(find.byTooltip('Back (Esc)')).dy,
      greaterThan(600),
    );
    expect(
      tester.getTopLeft(find.byTooltip('Move to Trash (#)')).dy,
      greaterThan(600),
    );
    // Selecting: the actions replace the search bar at the bottom.
    await tester.tap(find.byTooltip('Back (Esc)'));
    await tester.pump();
    await tester.longPress(find.text('Hello there'));
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);
    expect(tester.getTopLeft(find.text('1 selected')).dy, greaterThan(600));
    expect(find.byType(TextField), findsNothing);
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

  testWidgets('codes: own section, code in the row, five per section', (
    tester,
  ) async {
    final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
    store.messages.upsertSummaries(inbox.id, [
      MessageSummary(
        uid: 20,
        receivedAt: DateTime.utc(2026, 10, 20, 8),
        subject: 'Your verification code',
        from: MailAddress(localPart: 'no-reply', domain: 'bank.example'),
        category: MessageCategory.codes,
        code: '482913',
      ),
      for (var i = 0; i < 8; i++)
        MessageSummary(
          uid: 30 + i,
          receivedAt: DateTime.utc(2026, 10, 1, i),
          subject: 'Older general $i',
          from: MailAddress(localPart: 'p$i', domain: 'x.example'),
        ),
    ]);
    await show(tester, const Size(1400, 1400));

    expect(find.text('Verification'), findsOneWidget);
    expect(top(tester, 'Pinned') < top(tester, 'Verification'), isTrue);
    expect(top(tester, 'Verification') < top(tester, 'Important'), isTrue);

    // The code instead of the preview; a tap copies it.
    expect(find.text('482913'), findsOneWidget);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    await tester.tap(find.byKey(const ValueKey('copy-code-482913')));
    await tester.pump();
    expect(copied, '482913');
    expect(find.text('Copied 482913'), findsOneWidget);
    expect(
      store.messages
          .list(const MessageQuery.inbox())
          .firstWhere((m) => m.subject == 'Your verification code')
          .flags
          .seen,
      isFalse,
      reason: 'copying does not open the message',
    );

    // An open section shows five messages first. General has 9: Hello
    // there, then the older ones, newest first.
    expect(find.text('Older general 4'), findsOneWidget);
    expect(find.text('Older general 3'), findsNothing);
    expect(find.text('Show more (4 more)'), findsOneWidget);
  });

  testWidgets('thousands of messages: only what is on screen is built', (
    tester,
  ) async {
    // A folder shows one long list, loaded a page at a time.
    final archive = store.mailboxes
        .forAccount(store.accounts.all().single.id)
        .firstWhere((b) => b.encodedName == 'Archive');
    store.messages.upsertSummaries(archive.id, [
      for (var i = 100; i < 3100; i++)
        MessageSummary(
          uid: i,
          receivedAt: DateTime.utc(2025, 1, 1).add(Duration(minutes: i)),
          subject: 'Bulk $i',
          from: MailAddress(localPart: 'p$i', domain: 'x.example'),
        ),
    ]);
    await show(tester, const Size(1400, 900));
    await tester.tap(find.text('Archive'));
    await tester.pump();
    final built = find.byType(MessageTile).evaluate().length;
    expect(built, lessThan(30), reason: 'built $built rows for 3000 messages');
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
