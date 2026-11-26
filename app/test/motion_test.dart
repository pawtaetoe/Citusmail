// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/message_tile.dart';
import 'package:citusmail/src/ui/motion.dart';
import 'package:citusmail/src/ui/reader_pane.dart';
import 'package:citusmail/src/ui/sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'support/settle.dart';
import 'support/test_app.dart';

void main() {
  /// Selecting on touch: the sender's avatar (press and hold peeks).
  Finder selectFrom(String sender) => find.byWidgetPredicate(
    (w) => w is Semantics && w.properties.label == 'Select $sender',
  );

  late TestApp app;

  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  const phone = Size(400, 800);
  const wide = Size(1400, 900);

  Future<void> show(WidgetTester tester, Size size) async {
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

  /// Lets real isolates (worker, message parsing) finish.
  Future<void> settle(WidgetTester tester) => settleMail(tester);

  /// Asks for less motion, as the system's accessibility setting does.
  void reduceMotion(WidgetTester tester) {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  }

  final growing = find.byKey(const ValueKey('growing-message'));

  /// The growing message's outline.
  Rect grown(WidgetTester tester) =>
      tester.widget<ClipRRect>(growing).clipper!.getClip(Size.zero).outerRect;

  double top(WidgetTester tester, String text) =>
      tester.getTopLeft(find.text(text).first).dy;

  /// Records the haptic feedback asked of the system.
  List<String> haptics(WidgetTester tester) {
    final calls = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        calls.add('${call.arguments}');
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    return calls;
  }

  group('phone: row to reader', () {
    testWidgets('the row grows into the message, and back into the row', (
      tester,
    ) async {
      await show(tester, phone);
      final row = tester.getRect(
        find.ancestor(
          of: find.text('Hello there'),
          matching: find.byType(MessageTile),
        ),
      );
      await tester.tap(find.text('Hello there'));
      await settle(tester); // the frame it starts
      await tester.pump(); // its first step
      await tester.pump(const Duration(milliseconds: 150));

      // Half-way: bigger than the row, smaller than the page, over the
      // list (still there underneath).
      final half = grown(tester);
      expect(half.height, greaterThan(row.height));
      expect(half.height, lessThan(700));
      expect(find.byType(ReaderPane), findsOneWidget);
      expect(find.text('Lunch?'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 200));
      // Done: the whole page, the list hidden away.
      expect(grown(tester).height, greaterThan(700));
      expect(find.text('Lunch?'), findsNothing);
      expect(find.byTooltip('Back (Esc)'), findsOneWidget);
      await settle(tester); // the body, parsed on its own isolate
      expect(find.textContaining('Visible', findRichText: true), findsWidgets);

      // Back: the list at once, the message shrinking into its row (as it
      // looked: the reader itself is empty by then).
      await tester.tap(find.byTooltip('Back (Esc)'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('Lunch?'), findsOneWidget);
      expect(growing, findsOneWidget);
      expect(find.byKey(const ValueKey('message-as-it-was')), findsOneWidget);
      final shrinking = grown(tester);
      expect(shrinking.height, lessThan(700));
      expect(shrinking.height, greaterThan(row.height));

      await tester.pump(const Duration(milliseconds: 200));
      expect(growing, findsNothing);
      expect(find.byType(ReaderPane), findsNothing);
      expect(find.text('Hello there'), findsOneWidget);
      expect(find.text('Lunch?'), findsOneWidget);
    });

    testWidgets('the list keeps its place under an open message', (
      tester,
    ) async {
      await show(tester, phone);
      final before = top(tester, 'Lunch?');
      await tester.tap(find.text('Lunch?'));
      await settle(tester);
      await tester.pumpAndSettle();
      expect(find.text('Lunch?'), findsOneWidget, reason: 'the reader');
      await tester.tap(find.byTooltip('Back (Esc)'));
      await tester.pumpAndSettle();
      expect(top(tester, 'Lunch?'), before);
    });

    testWidgets('less motion: the message opens and closes at once', (
      tester,
    ) async {
      reduceMotion(tester);
      await show(tester, phone);
      await tester.tap(find.text('Hello there'));
      await settle(tester);
      expect(growing, findsOneWidget);
      expect(find.text('Lunch?'), findsNothing, reason: 'covered at once');
      expect(grown(tester).height, greaterThan(700));

      await tester.tap(find.byTooltip('Back (Esc)'));
      await tester.pump();
      expect(growing, findsNothing);
      expect(find.byType(ReaderPane), findsNothing);
      expect(find.text('Lunch?'), findsOneWidget);
    });
  });

  testWidgets('desktop: no page transition; the reader eases in', (
    tester,
  ) async {
    await show(tester, wide);
    expect(growing, findsNothing);
    await tester.tap(find.text('Lunch?'));
    await settle(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Hello there'));
    await tester.pump();
    FadeTransition fade() => tester.widget<FadeTransition>(
      find
          .descendant(
            of: find.byType(ReaderFadeIn),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(fade().opacity.value, lessThan(1));
    expect(growing, findsNothing);
    await settle(tester);
    await tester.pumpAndSettle();
    expect(fade().opacity.value, 1);
  });

  group('sections', () {
    testWidgets('fold smoothly; the rows are gone after', (tester) async {
      await show(tester, wide);
      final start = top(tester, 'Notifications');
      await tester.tap(find.text('General'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Half-way: the rows still there, the next section on its way up.
      expect(find.text('Hello there'), findsOneWidget);
      final half = top(tester, 'Notifications');
      expect(half, lessThan(start));

      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('Hello there'), findsNothing);
      expect(top(tester, 'Notifications'), lessThan(half));

      // And out again.
      await tester.tap(find.text('General'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Hello there'), findsOneWidget);
      expect(top(tester, 'Notifications'), greaterThan(half - 1));
      await tester.pumpAndSettle();
      expect(top(tester, 'Notifications'), start);
    });

    testWidgets('a long section folds without building more rows', (
      tester,
    ) async {
      final store = app.store;
      final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
      store.messages.upsertSummaries(inbox.id, [
        for (var i = 0; i < 400; i++)
          MessageSummary(
            uid: 9000 + i,
            receivedAt: DateTime.utc(2026, 10, 1).add(Duration(minutes: i)),
            subject: 'Bulk $i',
            from: MailAddress(localPart: 'p$i', domain: 'x.example'),
          ),
      ]);
      await show(tester, wide);
      final built = find.byType(MessageTile).evaluate().length;
      expect(built, lessThan(40));
      await tester.tap(find.text('General'));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        expect(find.byType(MessageTile).evaluate().length, lessThan(40));
      }
      await tester.pumpAndSettle();
    });

    testWidgets('less motion: a section folds at once', (tester) async {
      reduceMotion(tester);
      await show(tester, wide);
      await tester.tap(find.text('General'));
      await tester.pump();
      expect(find.text('Hello there'), findsNothing);
    });
  });

  group('Undo', () {
    testWidgets('a ring empties beside Undo; Undo still works', (tester) async {
      await show(tester, wide);
      await tester.tap(find.text('Lunch?'));
      await settle(tester);
      await tester.tap(find.byTooltip('Archive (E)').last);
      await tester.pump();
      final ring = find.byKey(const ValueKey('undo-ring'));
      expect(ring, findsOneWidget);
      expect(
        find.descendant(of: find.byType(SnackBar), matching: ring),
        findsOneWidget,
      );
      CustomPainter painter() => tester
          .widget<CustomPaint>(
            find.descendant(of: ring, matching: find.byType(CustomPaint)),
          )
          .painter!;
      final full = painter();
      await tester.pump(const Duration(seconds: 2));
      expect(painter().shouldRepaint(full), isTrue, reason: 'it moved');

      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(find.text('Lunch?'), findsWidgets);
      await settle(tester);
    });

    testWidgets('the notice still goes after its time', (tester) async {
      await show(tester, wide);
      await tester.tap(find.text('Lunch?'));
      await settle(tester);
      await tester.tap(find.byTooltip('Archive (E)').last);
      // Its duration (5 seconds) as before the ring.
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.text('Archived'), findsOneWidget);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.text('Archived'), findsNothing);
      expect(find.byKey(const ValueKey('undo-ring')), findsNothing);
    });
  });

  group('haptics', () {
    testWidgets('a swipe ticks where letting go would act, and back', (
      tester,
    ) async {
      final calls = haptics(tester);
      await show(tester, phone);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Lunch?')),
      );
      await gesture.moveBy(const Offset(30, 0)); // past the touch slop
      await tester.pump();
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();
      expect(calls, isEmpty, reason: 'not far enough yet');
      await gesture.moveBy(const Offset(140, 0));
      await tester.pump();
      expect(calls, ['HapticFeedbackType.lightImpact']);
      await gesture.moveBy(const Offset(-150, 0));
      await tester.pump();
      expect(calls, [
        'HapticFeedbackType.lightImpact',
        'HapticFeedbackType.lightImpact',
      ]);
      // Let go short of it: nothing happens, no more ticks.
      await gesture.up();
      await tester.pumpAndSettle();
      expect(calls, hasLength(2));
      expect(find.text('Lunch?'), findsOneWidget);
    });

    testWidgets('selecting clicks', (tester) async {
      final calls = haptics(tester);
      await show(tester, phone);
      // Press and hold peeks (the system's own buzz); no click.
      await tester.longPress(find.text('Hello there'));
      await tester.pumpAndSettle();
      expect(calls, isNot(contains('HapticFeedbackType.selectionClick')));
      await tester.tapAt(const Offset(10, 10)); // closes the peek
      await tester.pumpAndSettle();
      calls.clear();
      // Selecting on touch: the avatar, then the rows, each with a click.
      await tester.tap(selectFrom('Stranger Danger'));
      await tester.pump();
      expect(find.text('1 selected'), findsOneWidget);
      expect(calls, ['HapticFeedbackType.selectionClick']);
      await tester.tap(find.text('Lunch?'));
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget);
      await tester.tap(find.text('Lunch?'));
      await tester.pump();
      expect(find.text('1 selected'), findsOneWidget);
      expect(calls, hasLength(3));
      expect(calls.toSet(), {'HapticFeedbackType.selectionClick'});
    });

    testWidgets('none on desktop', (tester) async {
      final calls = haptics(tester);
      await show(tester, wide);
      // Ctrl-click selects on a desktop.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.text('Hello there'));
      await tester.tap(find.text('Lunch?'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget);
      expect(calls, isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('still there with less motion (the system decides)', (
      tester,
    ) async {
      reduceMotion(tester);
      final calls = haptics(tester);
      await show(tester, phone);
      await tester.tap(selectFrom('Stranger Danger'));
      await tester.pump();
      expect(calls, contains('HapticFeedbackType.selectionClick'));
    });
  });

  group('small touches', () {
    testWidgets('the compose button gives a little while pressed', (
      tester,
    ) async {
      await show(tester, phone);
      final button = find.ancestor(
        of: find.byTooltip('New message (C)'),
        matching: find.byType(PressScale),
      );
      double scale() => tester
          .widget<AnimatedScale>(
            find.descendant(of: button, matching: find.byType(AnimatedScale)),
          )
          .scale;
      expect(scale(), 1);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byTooltip('New message (C)')),
      );
      await tester.pump();
      expect(scale(), 0.98);
      await gesture.cancel();
      await tester.pump();
      expect(scale(), 1);
    });

    testWidgets('the unread dot fades out; the count rolls', (tester) async {
      await show(tester, wide);
      final inboxCount = find
          .descendant(
            of: find.byType(Sidebar),
            matching: find.byType(CountSwitcher),
          )
          .first;
      final before = tester.widget<CountSwitcher>(inboxCount).count;
      await tester.tap(find.text('Lunch?'));
      await tester.pump();
      expect(find.byType(FadeAway), findsOneWidget);
      expect(tester.widget<CountSwitcher>(inboxCount).count, before - 1);
      // Both numbers while it rolls, the new one after.
      expect(
        find.descendant(of: inboxCount, matching: find.byType(Text)),
        findsNWidgets(2),
      );
      await settle(tester);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: inboxCount, matching: find.text('${before - 1}')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: inboxCount, matching: find.byType(Text)),
        findsOneWidget,
      );
    });
  });
}
