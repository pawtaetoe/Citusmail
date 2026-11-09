// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/mail/mail_controller.dart';
import 'package:citusmail/src/services/app_services.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/message_tile.dart';
import 'package:citusmail/src/ui/privacy_report_page.dart';
import 'package:citusmail/src/ui/sender_cleanup_page.dart';
import 'package:citusmail/src/ui/sidebar.dart';
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

  Finder inSidebar(String text) =>
      find.descendant(of: find.byType(Sidebar), matching: find.text(text));

  /// A folding header in the sidebar, by what screen readers hear.
  Finder fold(String label) => find.byWidgetPredicate(
    (w) => w is Semantics && w.properties.label == label,
  );

  /// The count shown on a folding header.
  Finder countOn(String header, int count) =>
      find.descendant(of: fold(header), matching: find.text('$count'));

  /// A second account, with an inbox (and [unread] unread messages in it)
  /// and a folder of its own.
  Account addBob({int unread = 0}) {
    final bob = store.accounts.add(
      NewAccount(
        email: 'bob@citusmail.test',
        username: 'bob@citusmail.test',
        imap: ServerSettings(
          host: 'mail.citusmail.test',
          port: 993,
          security: ConnectionSecurity.implicitTls,
        ),
        smtp: ServerSettings(
          host: 'mail.citusmail.test',
          port: 465,
          security: ConnectionSecurity.implicitTls,
        ),
      ),
    );
    final boxes = store.mailboxes.replaceAll(bob.id, [
      ImapMailboxInfo(
        encodedName: 'INBOX',
        delimiter: '/',
        attributes: const {},
      ),
      ImapMailboxInfo(
        encodedName: 'Bob Projects',
        delimiter: '/',
        attributes: const {},
      ),
    ]);
    store.messages.upsertSummaries(boxes.firstWhere((b) => b.isInbox).id, [
      for (var i = 0; i < unread; i++)
        MessageSummary(
          uid: 500 + i,
          receivedAt: DateTime.utc(2026, 11, 1, 9, i),
          subject: 'For Bob ${i + 1}',
          from: MailAddress(localPart: 'school', domain: 'district.example'),
        ),
    ]);
    return bob;
  }

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

  testWidgets('sidebar: mail places, accounts, then the feature groups', (
    tester,
  ) async {
    for (final (size, drawer) in [
      (const Size(1400, 900), false),
      (const Size(400, 860), true),
    ]) {
      await show(tester, size);
      if (drawer) {
        await tester.tap(find.byTooltip('Folders'));
        await tester.pumpAndSettle();
      }
      // The groups start folded.
      for (final page in ['Subscriptions', 'Clean up', 'Privacy report']) {
        expect(find.text(page), findsNothing, reason: page);
      }
      await tester.tap(fold('Show Found in your mail'));
      await tester.pumpAndSettle();
      await tester.tap(fold('Show Tools'));
      await tester.pumpAndSettle();
      final order = [
        'Inbox',
        'Pins',
        'alice@citusmail.test',
        'Sent',
        'Projects',
        'Found in your mail',
        'Subscriptions',
        'Deliveries',
        'Trips',
        'Appointments',
        'Online accounts',
        'Tools',
        'Clean up',
        'Privacy report',
      ];
      for (final label in order) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      // Top to bottom, within the sidebar.
      for (var i = 1; i < order.length; i++) {
        expect(
          top(tester, order[i - 1]) < top(tester, order[i]),
          isTrue,
          reason: '${order[i - 1]} above ${order[i]}',
        );
      }
      // In search (Files) now.
      expect(find.text('Attachments'), findsNothing);
      // Fold them again for the next size.
      await tester.tap(fold('Hide Found in your mail'));
      await tester.pumpAndSettle();
      await tester.tap(fold('Hide Tools'));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('an account folds away even with one of its folders open', (
    tester,
  ) async {
    addBob();
    await show(tester, const Size(1400, 900));

    // Alice's block: open it, show Projects.
    await tester.tap(fold('Show folders of alice@citusmail.test'));
    await tester.pumpAndSettle();
    expect(find.text('Archive'), findsOneWidget);
    await tester.tap(find.text('Projects'));
    await settle(tester);

    // Folding it away works; the folder being shown stays in sight.
    await tester.tap(fold('Hide folders of alice@citusmail.test'));
    await tester.pumpAndSettle();
    expect(fold('Show folders of alice@citusmail.test'), findsOneWidget);
    expect(find.text('Archive'), findsNothing);
    expect(find.text('Projects'), findsWidgets);

    // And it opens again.
    await tester.tap(fold('Show folders of alice@citusmail.test'));
    await tester.pumpAndSettle();
    expect(find.text('Archive'), findsOneWidget);
  });

  testWidgets('Not spam moves a message from Spam back to the inbox', (
    tester,
  ) async {
    final account = store.accounts.all().single;
    final boxes = store.mailboxes.forAccount(account.id);
    final junk = boxes.firstWhere((b) => b.specialUse == SpecialUse.junk);
    final inbox = store.mailboxes.inbox(account.id)!;
    store.messages.upsertSummaries(junk.id, [
      MessageSummary(
        uid: 70,
        receivedAt: DateTime.utc(2026, 11, 6, 15, 38),
        subject: 'test from my other address',
        from: MailAddress(localPart: 'me', domain: 'other.example'),
      ),
    ]);
    await show(tester, const Size(1400, 900));
    await tester.tap(find.text('Spam'));
    await settle(tester);
    await tester.tap(find.text('test from my other address'));
    await settle(tester);
    await tester.tap(find.byTooltip('Not spam'));
    await settle(tester);
    expect(find.text('Not spam. Moved to Inbox.'), findsOneWidget);
    expect(find.text('test from my other address'), findsNothing);
    // Queued for the server: from Spam to the inbox (how the provider
    // learns it isn't spam).
    final moves = store.outbox
        .all(account.id)
        .map((e) => e.action)
        .whereType<MoveAction>();
    expect(moves.single.mailboxId, junk.id);
    expect(moves.single.targetMailboxId, inbox.id);

    // Mail outside Spam has no such button.
    await tester.tap(find.text('Inbox').first);
    await settle(tester);
    await tester.tap(find.text('Lunch?').first);
    await settle(tester);
    expect(find.byTooltip('Not spam'), findsNothing);
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

  testWidgets('notices with Undo close by themselves, or with their X', (
    tester,
  ) async {
    await show(tester, const Size(1400, 900));
    await tester.tap(find.text('Lunch?'));
    await settle(tester);
    await tester.tap(find.byTooltip('Archive (E)').last);
    await tester.pump();
    expect(find.text('Archived'), findsOneWidget);
    final closeNotice = find.descendant(
      of: find.byType(SnackBar),
      matching: find.byIcon(Icons.close),
    );
    expect(closeNotice, findsOneWidget);
    // Gone after its few seconds, Undo or not.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('Archived'), findsNothing);

    // The next one closes with its X.
    await tester.tap(find.byTooltip('Archive (E)').last);
    await tester.pump();
    expect(find.text('Archived'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500)); // slid in
    await tester.tap(closeNotice);
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.text('Archived'), findsNothing);
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

    // The code instead of the preview; a tap copies it, marked sensitive
    // (through the clipboard plugin, as the test platform is Android).
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
    Map<Object?, Object?>? pluginCall;
    const plugin = MethodChannel('citusmail/background-clipboard');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(plugin, (
      call,
    ) async {
      if (call.method == 'copy') pluginCall = call.arguments as Map;
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        plugin,
        null,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('copy-code-482913')));
    await tester.pump();
    expect(copied, isNull, reason: 'not through the plain clipboard');
    expect(pluginCall, isNotNull);
    expect(pluginCall!['text'], '482913');
    expect(pluginCall!['sensitive'], isTrue);
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

  testWidgets('show original, and forward the whole message as an .eml', (
    tester,
  ) async {
    await show(tester, const Size(1400, 900));
    await tester.tap(find.text('Hello there'));
    await settle(tester);

    await tester.tap(find.byTooltip('Show original'));
    await tester.pumpAndSettle();
    expect(find.text('Original message'), findsOneWidget);
    expect(find.textContaining('Subject:'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Forward as attachment'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Hello there.eml'), findsOneWidget);
  });

  testWidgets('several accounts: each folds away, remembered', (tester) async {
    final bob = addBob(unread: 3);
    final alice = store.accounts.all().first;
    await show(tester, const Size(1400, 900));

    // Folded: a heading, each account's header with its unread count, no
    // folders.
    expect(find.text('Accounts'), findsOneWidget);
    expect(find.text('alice@citusmail.test'), findsWidgets);
    expect(find.text('bob@citusmail.test'), findsWidgets);
    expect(find.text('Bob Projects'), findsNothing);
    expect(find.text('Archive'), findsNothing);
    final controller = MailController(services);
    addTearDown(controller.dispose);
    final aliceUnread = controller.counts.value.perAccountUnread[alice.id]!;
    expect(aliceUnread, greaterThan(0));
    expect(countOn('Show folders of bob@citusmail.test', 3), findsOneWidget);
    expect(
      countOn('Show folders of alice@citusmail.test', aliceUnread),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Semantics>(fold('Show folders of bob@citusmail.test'))
          .properties
          .value,
      '3 unread',
    );
    // One status line instead of a row per account.
    expect(find.text('Up to date'), findsNothing);
    // The top Inbox is every account's, as one Smart Inbox.
    expect(inSidebar('Inbox'), findsOneWidget);

    // Open Bob's block: his inbox (its count moves there) and folders, not
    // Alice's.
    await tester.tap(find.text('bob@citusmail.test').last);
    await tester.pumpAndSettle();
    expect(find.text('Bob Projects'), findsOneWidget);
    expect(find.text('Archive'), findsNothing);
    expect(inSidebar('Inbox'), findsNWidgets(2));
    expect(countOn('Hide folders of bob@citusmail.test', 3), findsNothing);
    expect(store.settings.read('ui.openAccounts'), '${bob.id}');

    // Bob's Inbox is his Smart Inbox alone.
    await tester.tap(inSidebar('Inbox').last);
    await settle(tester);
    expect(find.text('For Bob 1'), findsOneWidget);
    expect(find.text('Lunch?'), findsNothing);

    // Remembered on the next start; folded, his inbox, being shown, stays
    // in sight.
    await show(tester, const Size(1400, 900));
    expect(find.text('Bob Projects'), findsOneWidget);
    await tester.tap(fold('Hide folders of bob@citusmail.test'));
    await tester.pumpAndSettle();
    expect(find.text('Bob Projects'), findsNothing);
    expect(store.settings.read('ui.openAccounts'), '');
  });

  testWidgets('one account: its folders under its address, nothing folds', (
    tester,
  ) async {
    await show(tester, const Size(1400, 900));
    // No "Accounts" heading, no second Inbox, no fold on the account.
    expect(find.text('Accounts'), findsNothing);
    expect(inSidebar('Inbox'), findsOneWidget);
    expect(find.text('alice@citusmail.test'), findsOneWidget);
    expect(fold('Show folders of alice@citusmail.test'), findsNothing);
    expect(fold('Hide folders of alice@citusmail.test'), findsNothing);
    for (final folder in ['Sent', 'Drafts', 'Archive', 'Spam', 'Projects']) {
      expect(find.text(folder), findsOneWidget, reason: folder);
    }
    // Its menu is there.
    await tester.tap(find.byTooltip('Account'));
    await tester.pumpAndSettle();
    expect(find.text('New folder'), findsOneWidget);
    expect(find.text('Update password'), findsOneWidget);
    expect(find.text('Remove account'), findsOneWidget);
  });

  testWidgets('feature groups: folded at first, open, remembered', (
    tester,
  ) async {
    await show(tester, const Size(1400, 900));
    expect(fold('Show Found in your mail'), findsOneWidget);
    expect(fold('Show Tools'), findsOneWidget);
    expect(find.text('Subscriptions'), findsNothing);
    expect(find.text('Clean up'), findsNothing);

    // Open Tools only.
    await tester.tap(find.text('Tools'));
    await tester.pumpAndSettle();
    expect(find.text('Clean up'), findsOneWidget);
    expect(find.text('Privacy report'), findsOneWidget);
    expect(find.text('Subscriptions'), findsNothing);
    expect(
      tester.widget<Semantics>(fold('Hide Tools')).properties.expanded,
      isTrue,
    );
    expect(store.settings.read('ui.openSidebarGroups'), 'tools');

    // Remembered on the next start.
    await show(tester, const Size(1400, 900));
    expect(find.text('Clean up'), findsOneWidget);
    expect(find.text('Subscriptions'), findsNothing);

    // Keyboard: Enter and Space open and fold the focused header.
    final inHeader = find
        .descendant(
          of: fold('Show Found in your mail'),
          matching: find.byType(Row),
        )
        .first;
    Focus.of(tester.element(inHeader)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Subscriptions'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.text('Subscriptions'), findsNothing);
    // Enter worked the header, not the mail shortcut (open a message).
    expect(find.text('Select a message to read it'), findsOneWidget);
  });

  testWidgets('Tools: Clean up and the Privacy report open from the sidebar', (
    tester,
  ) async {
    for (final (size, drawer) in [
      (const Size(1400, 900), false),
      (const Size(400, 860), true),
    ]) {
      await show(tester, size);
      Future<void> openTools() async {
        if (drawer) {
          await tester.tap(find.byTooltip('Folders'));
          await tester.pumpAndSettle();
        }
        if (find.text('Clean up').evaluate().isEmpty) {
          await tester.tap(find.text('Tools'));
          await tester.pumpAndSettle();
        }
      }

      // The pages count in the background; only the way there matters.
      Future<void> open() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
      }

      await openTools();
      await tester.tap(find.text('Clean up'));
      await open();
      expect(find.byType(SenderCleanupPage), findsOneWidget);
      await tester.pageBack();
      await open();

      await openTools();
      await tester.tap(find.text('Privacy report'));
      await open();
      expect(find.byType(PrivacyReportPage), findsOneWidget);
      await tester.pageBack();
      await open();
    }
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
