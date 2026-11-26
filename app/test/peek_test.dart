// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/core/theme/citusmail_theme.dart';
import 'package:citusmail/src/features/discover/ui/keyboard_shortcuts.dart';
import 'package:citusmail/src/features/inbox/state/mail_controller.dart';
import 'package:citusmail/src/features/inbox/ui/mail_shell.dart';
import 'package:citusmail/src/features/inbox/ui/message_list_pane.dart';
import 'package:citusmail/src/features/inbox/ui/peek.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  StoredMessage message(String subject) => app.store.messages
      .list(const MessageQuery.inbox())
      .firstWhere((m) => m.subject == subject);

  MailController controller(WidgetTester tester) =>
      tester.widget<MessageListPane>(find.byType(MessageListPane)).controller;

  Future<void> show(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: MediaQuery.withClampedTextScaling(
          minScaleFactor: textScale,
          maxScaleFactor: textScale,
          child: MailShell(
            notifications: false,
            services: app.services,
            onAddAccount: () {},
            onAccountsChanged: () {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Lets real isolates (the worker, reading the text) finish.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Finder inPeek(Finder finder) =>
      find.descendant(of: find.byType(PeekCard), matching: finder);

  Finder avatarOf(String sender) => find.byWidgetPredicate(
    (w) => w is Semantics && w.properties.label == 'Select $sender',
  );

  test('the first lines, without runs of blank lines', () {
    final text = [
      '',
      'Hi Alice,',
      '',
      '',
      '',
      'Line two.   ',
      for (var i = 0; i < 20; i++) 'More $i',
    ].join('\r\n');
    final excerpt = Peek.excerpt(text);
    expect(excerpt.split('\n').take(3), ['Hi Alice,', '', 'Line two.']);
    expect(excerpt.split('\n'), hasLength(Peek.lines));
  });

  testWidgets('phone: press and hold peeks; the email stays unread', (
    tester,
  ) async {
    await show(tester);
    await tester.longPress(find.text('Hello there'));
    await tester.pump();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(inPeek(find.text('Stranger Danger')), findsOneWidget);
    expect(inPeek(find.text('Hello there')), findsOneWidget);
    // The body's text, plain: no link, no image.
    await settle(tester);
    expect(inPeek(find.textContaining('Visible body text.')), findsOneWidget);
    expect(inPeek(find.textContaining('a link')), findsOneWidget);
    expect(inPeek(find.text('Loading…')), findsNothing);
    expect(inPeek(find.byType(Image)), findsNothing);

    // Closed: still unread, not open, nothing sent.
    await tester.tapAt(const Offset(200, 40));
    await tester.pumpAndSettle();
    expect(find.byType(PeekCard), findsNothing);
    expect(message('Hello there').flags.seen, isFalse);
    expect(controller(tester).selected, isNull);
    expect(app.store.outbox.sends(), isEmpty);
  });

  testWidgets('a body not downloaded yet: the preview, then more', (
    tester,
  ) async {
    final inbox = app.store.mailboxes.inbox(
      app.store.accounts.all().single.id,
    )!;
    app.store.messages.upsertSummaries(inbox.id, [
      MessageSummary(
        uid: 40,
        receivedAt: DateTime.utc(2026, 10, 20, 10),
        subject: 'Plans for Friday',
        from: const MailAddress(
          localPart: 'erin',
          domain: 'x.example',
          displayName: 'Erin',
        ),
        snippet: 'Shall we meet at the station at six?',
      ),
    ]);
    await show(tester);
    await tester.longPress(find.text('Plans for Friday'));
    await tester.pump();
    expect(
      inPeek(find.text('Shall we meet at the station at six?')),
      findsOneWidget,
    );
    expect(inPeek(find.text('Loading…')), findsOneWidget);
    // Offline here: it says so, and the preview stays.
    await settle(tester);
    expect(inPeek(find.textContaining('Can\'t show more')), findsOneWidget);
    expect(
      inPeek(find.text('Shall we meet at the station at six?')),
      findsOneWidget,
    );
    expect(message('Plans for Friday').flags.seen, isFalse);
  });

  testWidgets('select from the avatar, and from the peek', (tester) async {
    await show(tester);
    await tester.tap(avatarOf('Carol'));
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);
    expect(controller(tester).selected, isNull, reason: 'not opened');

    await tester.longPress(find.text('Hello there'));
    await tester.pumpAndSettle();
    await tester.tap(inPeek(find.text('Select')));
    await tester.pumpAndSettle();
    expect(find.byType(PeekCard), findsNothing);
    expect(find.text('2 selected'), findsOneWidget);
    expect(controller(tester).selection.value, {
      message('Lunch?').id,
      message('Hello there').id,
    });
  });

  testWidgets('the peek\'s actions', (tester) async {
    await show(tester);
    final c = controller(tester);
    Future<void> peekThen(String subject, String action) async {
      await tester.longPress(find.text(subject));
      await tester.pumpAndSettle();
      await tester.tap(inPeek(find.text(action)));
      await tester.pumpAndSettle();
      expect(find.byType(PeekCard), findsNothing);
    }

    await peekThen('Lunch?', 'Pin');
    expect(message('Lunch?').flags.flagged, isTrue);
    await peekThen('Lunch?', 'Unpin');
    expect(message('Lunch?').flags.flagged, isFalse);
    await peekThen('Lunch?', 'Mark read');
    expect(message('Lunch?').flags.seen, isTrue);
    await peekThen('Lunch?', 'Mark unread');
    expect(message('Lunch?').flags.seen, isFalse);

    await peekThen('Lunch?', 'Archive');
    expect(find.text('Archived'), findsOneWidget);
    expect(
      app.store.messages
          .list(const MessageQuery.inbox())
          .where((m) => m.subject == 'Lunch?'),
      isEmpty,
    );

    // Open: the reader, as a tap on the row (it shows a spinner while the
    // message is read, so no settling here).
    await tester.longPress(find.text('Hello there'));
    await tester.pumpAndSettle();
    await tester.tap(inPeek(find.text('Open')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(PeekCard), findsNothing);
    expect(c.selected?.subject, 'Hello there');
    expect(message('Hello there').flags.seen, isTrue);
  });

  testWidgets('desktop: Space on the row in focus peeks beside the list; '
      'Space or Esc closes it', (tester) async {
    await show(tester, size: const Size(1400, 900));
    Focus.of(tester.element(find.text('Lunch?'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.byType(PeekCard), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    final list = tester.getRect(find.byType(MessageListPane));
    final card = tester.getRect(find.byType(PeekCard));
    expect(card.left, greaterThan(list.right), reason: 'beside the list');
    expect(controller(tester).selected, isNull, reason: 'not opened');

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.byType(PeekCard), findsNothing);

    Focus.of(tester.element(find.text('Lunch?'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.byType(PeekCard), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(PeekCard), findsNothing);
    expect(message('Lunch?').flags.seen, isFalse);

    // In the keyboard shortcuts.
    expect(
      MailKeyboardShortcuts.shortcuts.map((s) => s.keys),
      contains('Space'),
    );
  });

  testWidgets('the checkbox, Ctrl-click and Shift-click still select', (
    tester,
  ) async {
    await show(tester, size: const Size(1400, 900));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('Lunch?'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);
    expect(controller(tester).selected, isNull);
  });

  testWidgets('screen readers: the avatar selects, the row can peek', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await show(tester);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Select Carol')),
      matchesSemantics(
        label: 'Select Carol',
        isButton: true,
        hasTapAction: true,
      ),
    );
    final row = tester.getSemantics(
      find.bySemanticsLabel(RegExp('^Unread. From Carol')),
    );
    expect(
      row.getSemanticsData().customSemanticsActionIds,
      isNotEmpty,
      reason: 'a Peek action',
    );
    semantics.dispose();
  });

  for (final width in [360.0, 390.0, 412.0]) {
    testWidgets('the peek fits at $width wide, text 1.3 times larger', (
      tester,
    ) async {
      await show(tester, size: Size(width, 800), textScale: 1.3);
      await tester.longPress(find.text('Hello there'));
      await settle(tester);
      expect(find.byType(PeekCard), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
