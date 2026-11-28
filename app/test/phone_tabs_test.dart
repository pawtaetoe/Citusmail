// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:citusmail/src/core/theme/citusmail_theme.dart';
import 'package:citusmail/src/core/widgets/skeleton_rows.dart';
import 'package:citusmail/src/features/calendar/ui/calendar_view.dart';
import 'package:citusmail/src/features/discover/ui/discover_page.dart';
import 'package:citusmail/src/features/found/ui/deliveries_page.dart';
import 'package:citusmail/src/features/inbox/ui/mail_shell.dart';
import 'package:citusmail/src/features/inbox/ui/phone_home.dart';
import 'package:citusmail/src/features/inbox/ui/sidebar.dart';
import 'package:citusmail/src/features/organise/ui/sender_cleanup_page.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'support/settle.dart';
import 'support/test_app.dart';

/// Phones: search at the top of the inbox, a navigation bar with Inbox,
/// Pins, Found and Folders at the bottom, and New message above it.
void main() {
  /// Selecting on touch: the sender's avatar (press and hold peeks).
  Finder selectFrom(String sender) => find.byWidgetPredicate(
    (w) => w is Semantics && w.properties.label == 'Select $sender',
  );

  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  Future<void> show(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    bool dark = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        darkTheme: CitusmailTheme.dark(),
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
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

  Future<void> tab(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text(label),
      ),
    );
    await tester.pumpAndSettle();
  }

  int selectedTab(WidgetTester tester) =>
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  Finder searchField() => find.widgetWithText(TextField, 'Search mail');

  bool searchFocused(WidgetTester tester) =>
      tester.widget<TextField>(searchField()).focusNode!.hasFocus;

  final foundPages = [
    'Subscriptions',
    'Deliveries',
    'Trips',
    'Appointments',
    'Events',
    'Online accounts',
  ];

  testWidgets('the bar switches between Inbox, Pins, Calendar, Tools and '
      'Folders', (tester) async {
    await show(tester);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(selectedTab(tester), 0);
    expect(find.text('Lunch?'), findsOneWidget);
    // Search on top, the messages under it, the bar at the bottom.
    expect(
      tester.getTopLeft(searchField()).dy,
      lessThan(tester.getTopLeft(find.text('Lunch?')).dy),
    );
    expect(tester.getTopLeft(searchField()).dy, lessThan(100));
    expect(tester.getTopLeft(find.byType(NavigationBar)).dy, greaterThan(700));

    await tab(tester, 'Pins');
    expect(selectedTab(tester), 1);
    expect(find.text('Keep this'), findsOneWidget);
    expect(find.text('Lunch?'), findsNothing);
    // A tab, not a place to come back from.
    expect(find.byTooltip('Back'), findsNothing);
    expect(searchField(), findsNothing);

    await tab(tester, 'Calendar');
    expect(selectedTab(tester), 2);
    expect(find.byType(CalendarView), findsOneWidget);
    expect(find.text('Nothing on the calendar'), findsOneWidget);
    expect(find.byTooltip('New message (C)'), findsNothing);

    await tab(tester, 'Tools');
    expect(selectedTab(tester), 3);
    expect(find.byType(ToolsHub), findsOneWidget);
    for (final page in foundPages) {
      await tester.scrollUntilVisible(
        find.text(page),
        100,
        scrollable: find.descendant(
          of: find.byType(ToolsHub),
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.text(page), findsOneWidget, reason: page);
    }

    await tab(tester, 'Folders');
    expect(selectedTab(tester), 4);
    // Everything the drawer had, but the tabs' own places.
    for (final label in [
      'alice@citusmail.test',
      'Sent',
      'Drafts',
      'Archive',
      'Spam',
      'Projects',
      'Notification settings',
      'Add account',
    ]) {
      expect(
        find.descendant(of: find.byType(Sidebar), matching: find.text(label)),
        findsOneWidget,
        reason: label,
      );
    }
    expect(find.byTooltip('Settings'), findsOneWidget);
    expect(find.text('Found in your mail'), findsNothing);
    // Both groups of pages are on the Tools tab instead.
    expect(
      find.descendant(of: find.byType(Sidebar), matching: find.text('Tools')),
      findsNothing,
    );
    expect(find.byType(Drawer), findsNothing);
    // All features is at the end of the Tools tab, not here.
    expect(
      find.descendant(
        of: find.byType(Sidebar),
        matching: find.text('All features'),
      ),
      findsNothing,
    );
    await tab(tester, 'Tools');
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('tools-all-features')),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const ValueKey('tools-all-features')));
    await tester.pumpAndSettle();
    expect(find.byType(DiscoverPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tab(tester, 'Inbox');
    expect(selectedTab(tester), 0);
    expect(find.text('Lunch?'), findsOneWidget);
  });

  /// The fade of the tab shown (the nearest one above [of]).
  double tabOpacity(WidgetTester tester, Finder of) => tester
      .widget<FadeTransition>(
        find.ancestor(of: of, matching: find.byType(FadeTransition)).first,
      )
      .opacity
      .value;

  final tabAsItWas = find.byKey(const ValueKey('tab-as-it-was'));

  testWidgets('Calendar fades through from and to the other tabs, as they '
      'all do', (tester) async {
    await show(tester);
    await settle(tester);

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Calendar'),
      ),
    );
    await tester.pump();
    // The first frame: the calendar is there, loading (with the light
    // moving across it), and the inbox as it was fades out over it.
    final calendar = find.byType(CalendarView);
    expect(calendar, findsOneWidget);
    expect(
      find.descendant(of: calendar, matching: find.byType(SkeletonRows)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: calendar,
        matching: find.byKey(const ValueKey('skeleton-shimmer')),
      ),
      findsOneWidget,
    );
    expect(tabAsItWas, findsOneWidget);
    expect(tabOpacity(tester, calendar), 0);
    // A third of the way: the inbox is gone, the calendar comes in.
    await tester.pump(const Duration(milliseconds: 150));
    final midway = tabOpacity(tester, calendar);
    expect(midway, greaterThan(0));
    expect(midway, lessThan(1));
    final scale = tester
        .widget<ScaleTransition>(
          find.ancestor(of: calendar, matching: find.byType(ScaleTransition)),
        )
        .scale
        .value;
    expect(scale, greaterThan(0.92));
    expect(scale, lessThan(1));
    await tester.pumpAndSettle();
    expect(tabOpacity(tester, calendar), 1);
    expect(tabAsItWas, findsNothing);
    expect(find.text('Nothing on the calendar'), findsOneWidget);

    // The same from the calendar to each other tab, and back to it.
    for (final (label, shown) in [
      ('Pins', find.text('Keep this')),
      ('Calendar', calendar),
      ('Tools', find.byType(ToolsHub)),
      ('Calendar', calendar),
      ('Folders', find.byType(Sidebar)),
      ('Calendar', calendar),
      ('Inbox', find.text('Lunch?')),
    ]) {
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(label),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(tabAsItWas, findsOneWidget, reason: label);
      expect(tabOpacity(tester, shown), 0, reason: label);
      await tester.pump(const Duration(milliseconds: 120));
      expect(tabOpacity(tester, shown), inExclusiveRange(0, 1), reason: label);
      await tester.pumpAndSettle();
      expect(tabOpacity(tester, shown), 1, reason: label);
      expect(tabAsItWas, findsNothing, reason: label);
    }
  });

  testWidgets('with less motion, tabs change at once', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await show(tester);
    await settle(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Calendar'),
      ),
    );
    await tester.pump();
    final calendar = find.byType(CalendarView);
    expect(tabOpacity(tester, calendar), 1);
    expect(tabAsItWas, findsNothing);
    // Loading, standing still.
    expect(
      find.descendant(of: calendar, matching: find.byType(SkeletonRows)),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('skeleton-shimmer')), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('Nothing on the calendar'), findsOneWidget);
  });

  testWidgets('the Inbox tab shows how many are unread', (tester) async {
    await show(tester);
    Finder badge(String count) => find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text(count),
    );
    expect(badge('4'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('4 unread')), findsOneWidget);

    // Reading one counts down.
    await tester.tap(find.text('Lunch?'));
    await settle(tester);
    expect(find.byType(NavigationBar), findsNothing, reason: 'reading');
    await back(tester);
    await settle(tester);
    expect(badge('3'), findsOneWidget);
    // Shown on the other tabs too.
    await tab(tester, 'Tools');
    expect(badge('3'), findsOneWidget);
  });

  testWidgets('Tools lists the pages found in mail and opens one', (
    tester,
  ) async {
    // Tall enough for every page found in mail at once.
    await show(tester, size: const Size(390, 1100));
    await tab(tester, 'Tools');
    expect(find.text('Found in your mail'), findsOneWidget);
    // In the sidebar's order.
    for (var i = 1; i < foundPages.length; i++) {
      expect(
        tester.getTopLeft(find.text(foundPages[i - 1])).dy,
        lessThan(tester.getTopLeft(find.text(foundPages[i])).dy),
      );
    }
    await tester.tap(find.text('Deliveries'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(DeliveriesPage), findsOneWidget);
    // On top of the tabs.
    expect(find.byType(NavigationBar), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ToolsHub), findsOneWidget);
    expect(selectedTab(tester), 3);
  });

  testWidgets('Tools also holds Clean up and the Privacy report', (
    tester,
  ) async {
    await show(tester);
    await tab(tester, 'Tools');
    expect(find.text('Found in your mail'), findsOneWidget);
    // The tools group, below what is found in mail.
    await tester.scrollUntilVisible(
      find.text('Privacy report'),
      200,
      scrollable: find.descendant(
        of: find.byType(ToolsHub),
        matching: find.byType(Scrollable),
      ),
    );
    final tools = find.descendant(
      of: find.byType(ToolsHub),
      matching: find.text('Tools'),
    );
    expect(tools, findsOneWidget);
    expect(find.text('Clean up'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Online accounts')).dy,
      lessThan(tester.getTopLeft(tools).dy),
    );
    await tester.tap(find.text('Clean up'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(SenderCleanupPage), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(selectedTab(tester), 3);

    // The Folders tab holds only folders now.
    await tab(tester, 'Folders');
    expect(find.text('Clean up'), findsNothing);
    expect(find.text('Privacy report'), findsNothing);
  });

  testWidgets('Folders opens a folder; Back returns to Folders', (
    tester,
  ) async {
    await show(tester);
    await tab(tester, 'Folders');
    await tester.tap(find.text('Projects'));
    await tester.pumpAndSettle();
    // The folder covers the tab: no bar, a way back, New message.
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(Sidebar), findsNothing);
    expect(find.text('Projects'), findsOneWidget);
    expect(find.byTooltip('New message (C)'), findsOneWidget);
    await back(tester);
    expect(find.byType(Sidebar), findsOneWidget);
    expect(selectedTab(tester), 4);

    // The arrow in the header does the same.
    await tester.tap(find.text('Sent'));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(Sidebar), findsOneWidget);
    expect(selectedTab(tester), 4);
  });

  testWidgets('Back from Pins, Calendar, Tools or Folders returns to the '
      'Inbox', (tester) async {
    await show(tester);
    for (final label in ['Pins', 'Calendar', 'Tools', 'Folders']) {
      await tab(tester, label);
      expect(selectedTab(tester), isNot(0), reason: label);
      await back(tester);
      expect(selectedTab(tester), 0, reason: label);
      expect(find.text('Lunch?'), findsOneWidget, reason: label);
    }
    // From the Inbox, as before: nothing in the app is closed.
    final popped = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        popped.add(call.method);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await back(tester);
    expect(popped, contains('SystemNavigator.pop'));
  });

  testWidgets('search at the top finds mail', (tester) async {
    await show(tester);
    await tester.enterText(searchField(), 'parcel');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(find.text('Results for "parcel"'), findsOneWidget);
    expect(find.text('Your parcel'), findsOneWidget);
    expect(find.text('Lunch?'), findsNothing);
    // Still the Inbox tab, with the bar.
    expect(selectedTab(tester), 0);
    // Inbox again: the whole inbox.
    await tab(tester, 'Inbox');
    expect(find.text('Lunch?'), findsOneWidget);
  });

  testWidgets('a tap elsewhere lets go of the search box', (tester) async {
    await show(tester);
    await tester.tap(searchField());
    await tester.pump();
    expect(searchFocused(tester), isTrue);
    // A tap on the list below.
    await tester.tap(find.text('Lunch?'));
    await tester.pump();
    expect(searchFocused(tester), isFalse);
  });

  testWidgets('closing the keyboard lets go of the search box', (tester) async {
    await show(tester);
    await tester.tap(searchField());
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    expect(searchFocused(tester), isTrue);
    // Android's back button closes the keyboard.
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump();
    expect(searchFocused(tester), isFalse);
  });

  testWidgets('pulling down at the top of the list focuses search', (
    tester,
  ) async {
    await show(tester);
    expect(searchFocused(tester), isFalse);
    await tester.drag(find.text('Lunch?'), const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(searchFocused(tester), isTrue);
    // New message steps aside while typing.
    expect(find.byTooltip('New message (C)'), findsNothing);
  });

  testWidgets('search slides away while scrolling down, back on the way up', (
    tester,
  ) async {
    // A long inbox.
    final inbox = app.store.mailboxes.inbox(
      app.store.accounts.all().single.id,
    )!;
    app.store.messages.upsertSummaries(inbox.id, [
      for (var i = 0; i < 40; i++)
        MessageSummary(
          uid: 700 + i,
          receivedAt: DateTime.utc(2026, 10, 1, 9, i),
          subject: 'Long list $i',
          from: MailAddress(localPart: 'news', domain: 'list$i.example'),
        ),
    ]);
    await show(tester);
    await settle(tester);
    double searchHeight() => tester.getSize(find.byType(ClipRect).first).height;
    final shown = tester.getRect(searchField());
    expect(shown.top, greaterThanOrEqualTo(0));

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tester.getRect(searchField()).bottom, lessThanOrEqualTo(1));
    expect(searchHeight(), lessThan(1));

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 60));
    await tester.pumpAndSettle();
    expect(tester.getRect(searchField()).top, closeTo(shown.top, 0.5));
  });

  testWidgets('New message floats above the bar and opens compose', (
    tester,
  ) async {
    await show(tester);
    final fab = find.byType(FloatingActionButton);
    expect(fab, findsOneWidget);
    expect(
      tester.getRect(fab).bottom,
      lessThan(tester.getTopLeft(find.byType(NavigationBar)).dy),
    );
    final style = tester.widget<FloatingActionButton>(fab);
    expect(style.backgroundColor, CitusPalette.citrus);
    // Not over the Found and Folders pages.
    await tab(tester, 'Tools');
    expect(fab, findsNothing);
    await tab(tester, 'Pins');
    expect(fab, findsOneWidget);

    await tester.tap(find.byTooltip('New message (C)'));
    await tester.pumpAndSettle();
    expect(find.text('Send'), findsOneWidget);
  });

  testWidgets('selecting: the actions take the bar\'s place', (tester) async {
    await show(tester, size: const Size(360, 740));
    await tester.tap(selectFrom('Stranger Danger'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    expect(tester.getTopLeft(find.text('1 selected')).dy, greaterThan(600));
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.byTooltip('Archive (E)'), findsOneWidget);
    // This account has no Trash folder: deleting is for good, so it asks.
    await tester.tap(find.byTooltip('Delete forever'));
    await tester.pumpAndSettle();
    expect(find.text('Delete forever?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget, reason: 'nothing deleted');
    // The rest, under More.
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Select all shown'), findsOneWidget);
    await tester.tap(find.text('Select all shown'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsNothing);

    // Back ends selecting, and the bar comes back.
    await back(tester);
    expect(find.textContaining('selected'), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);

    // An action works on what is selected.
    await tester.tap(selectFrom('Stranger Danger'));
    await tester.pump();
    await tester.tap(find.byTooltip('Archive (E)'));
    await tester.pump();
    expect(find.text('Hello there'), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('fits 360, 390 and 412 wide, light and dark, larger text', (
    tester,
  ) async {
    for (final scale in [1.0, 1.3]) {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      for (final width in [360.0, 390.0, 412.0]) {
        for (final dark in [false, true]) {
          final what = '$width wide, text x$scale, ${dark ? 'dark' : 'light'}';
          await show(tester, size: Size(width, 760), dark: dark);
          for (final label in [
            'Pins',
            'Calendar',
            'Tools',
            'Folders',
            'Inbox',
          ]) {
            await tab(tester, label);
            expect(tester.takeException(), isNull, reason: '$label, $what');
          }
          await tester.tap(selectFrom('Stranger Danger'));
          await tester.pump();
          expect(tester.takeException(), isNull, reason: 'selecting, $what');
          await back(tester);
        }
      }
    }
  });

  testWidgets('five labels fit on one line, 360 wide, with the app\'s font', (
    tester,
  ) async {
    // The test font draws every letter as a square: measure the real one.
    final loader = FontLoader(CitusmailTheme.fontFamily);
    for (final f in Directory('assets/fonts/IBMPlexSans').listSync()) {
      if (f is File && f.path.endsWith('.ttf')) {
        loader.addFont(Future.value(ByteData.view(f.readAsBytesSync().buffer)));
      }
    }
    await loader.load();
    const labels = ['Inbox', 'Pins', 'Calendar', 'Tools', 'Folders'];
    for (final scale in [1.0, 1.3, 2.0]) {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await show(tester, size: const Size(360, 760));
      final bar = tester.getRect(find.byType(NavigationBar));
      Rect label(String l) => tester.getRect(
        find.descendant(of: find.byType(NavigationBar), matching: find.text(l)),
      );
      final line = label('Pins').height;
      for (final (i, l) in labels.indexed) {
        final r = label(l);
        expect(r.height, line, reason: '$l at x$scale: one line');
        expect(
          r.left,
          greaterThanOrEqualTo(bar.left + bar.width / 5 * i),
          reason: '$l at x$scale: in its slot',
        );
        expect(
          r.right,
          lessThanOrEqualTo(bar.left + bar.width / 5 * (i + 1)),
          reason: '$l at x$scale: in its slot',
        );
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('tabs are named and easy to tap', (tester) async {
    final semantics = tester.ensureSemantics();
    await show(tester);
    for (final label in ['Inbox', 'Pins', 'Calendar', 'Tools', 'Folders']) {
      final rect = tester.getRect(
        find
            .ancestor(
              of: find.descendant(
                of: find.byType(NavigationBar),
                matching: find.text(label),
              ),
              matching: find.byType(NavigationDestination),
            )
            .first,
      );
      expect(rect.height, greaterThanOrEqualTo(48), reason: label);
      expect(rect.width, greaterThanOrEqualTo(48), reason: label);
    }
    expect(find.bySemanticsLabel(RegExp('^Inbox')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('^Tools')), findsWidgets);
    expect(find.byTooltip('New message (C)'), findsOneWidget);
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    // The inbox too: section headers, avatars, the search field.
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    expect(tester.getSize(searchField()).height, greaterThanOrEqualTo(48));

    await tab(tester, 'Pins');
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await tab(tester, 'Calendar');
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await tab(tester, 'Tools');
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await tab(tester, 'Folders');
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    semantics.dispose();
  });

  testWidgets('desktop and tablet: no navigation bar', (tester) async {
    for (final size in [const Size(1400, 900), const Size(800, 900)]) {
      await show(tester, size: size);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byType(PhoneHome), findsNothing);
      expect(find.byTooltip('New message (C)'), findsOneWidget);
    }
    // Wide: the sidebar beside the list, Found in your mail in it, and
    // the calendar under Pins.
    await show(tester, size: const Size(1400, 900));
    expect(find.byType(Sidebar), findsOneWidget);
    expect(find.text('Found in your mail'), findsOneWidget);
    final calendar = find.descendant(
      of: find.byType(Sidebar),
      matching: find.text('Calendar'),
    );
    expect(
      tester.getTopLeft(calendar).dy,
      greaterThan(
        tester
            .getTopLeft(
              find.descendant(
                of: find.byType(Sidebar),
                matching: find.text('Pins'),
              ),
            )
            .dy,
      ),
    );
    await tester.tap(calendar);
    await tester.pumpAndSettle();
    expect(find.byType(CalendarPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    // Tablet: the sidebar in a drawer, behind the menu button.
    await show(tester, size: const Size(800, 900));
    expect(find.byType(Sidebar), findsNothing);
    await tester.tap(find.byTooltip('Folders'));
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsOneWidget);
  });
}
