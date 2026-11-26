// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/deliveries_page.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/phone_home.dart';
import 'package:citusmail/src/ui/sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

/// Phones: search at the top of the inbox, a navigation bar with Inbox,
/// Pins, Found and Folders at the bottom, and New message above it.
void main() {
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
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }

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
    'Online accounts',
  ];

  testWidgets('the bar switches between Inbox, Pins, Found and Folders', (
    tester,
  ) async {
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

    await tab(tester, 'Found');
    expect(selectedTab(tester), 2);
    expect(find.byType(FoundHub), findsOneWidget);
    for (final page in foundPages) {
      expect(find.text(page), findsOneWidget, reason: page);
    }

    await tab(tester, 'Folders');
    expect(selectedTab(tester), 3);
    // Everything the drawer had, but the tabs' own places.
    for (final label in [
      'alice@citusmail.test',
      'Sent',
      'Drafts',
      'Archive',
      'Spam',
      'Projects',
      'Tools',
      'Notification settings',
      'All features',
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
    expect(find.byType(Drawer), findsNothing);

    await tab(tester, 'Inbox');
    expect(selectedTab(tester), 0);
    expect(find.text('Lunch?'), findsOneWidget);
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
    await tab(tester, 'Found');
    expect(badge('3'), findsOneWidget);
  });

  testWidgets('Found lists the pages found in mail and opens one', (
    tester,
  ) async {
    await show(tester);
    await tab(tester, 'Found');
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
    expect(find.byType(FoundHub), findsOneWidget);
    expect(selectedTab(tester), 2);
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
    expect(selectedTab(tester), 3);

    // The arrow in the header does the same.
    await tester.tap(find.text('Sent'));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(Sidebar), findsOneWidget);
    expect(selectedTab(tester), 3);
  });

  testWidgets('Back from Pins, Found or Folders returns to the Inbox', (
    tester,
  ) async {
    await show(tester);
    for (final label in ['Pins', 'Found', 'Folders']) {
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
    await tab(tester, 'Found');
    expect(fab, findsNothing);
    await tab(tester, 'Pins');
    expect(fab, findsOneWidget);

    await tester.tap(find.byTooltip('New message (C)'));
    await tester.pumpAndSettle();
    expect(find.text('Send'), findsOneWidget);
  });

  testWidgets('selecting: the actions take the bar\'s place', (tester) async {
    await show(tester, size: const Size(360, 740));
    await tester.longPress(find.text('Hello there'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    expect(tester.getTopLeft(find.text('1 selected')).dy, greaterThan(600));
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.byTooltip('Archive (E)'), findsOneWidget);
    expect(find.byTooltip('Move to Trash (#)'), findsOneWidget);
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
    await tester.longPress(find.text('Hello there'));
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
          for (final label in ['Pins', 'Found', 'Folders', 'Inbox']) {
            await tab(tester, label);
            expect(tester.takeException(), isNull, reason: '$label, $what');
          }
          await tester.longPress(find.text('Hello there'));
          await tester.pump();
          expect(tester.takeException(), isNull, reason: 'selecting, $what');
          await back(tester);
        }
      }
    }
  });

  testWidgets('tabs are named and easy to tap', (tester) async {
    final semantics = tester.ensureSemantics();
    await show(tester);
    for (final label in ['Inbox', 'Pins', 'Found', 'Folders']) {
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
    expect(find.bySemanticsLabel(RegExp('^Found')), findsWidgets);
    expect(find.byTooltip('New message (C)'), findsOneWidget);
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    expect(tester.getSize(searchField()).height, greaterThanOrEqualTo(48));

    await tab(tester, 'Pins');
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await tab(tester, 'Found');
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
    // Wide: the sidebar beside the list, Found in your mail in it.
    await show(tester, size: const Size(1400, 900));
    expect(find.byType(Sidebar), findsOneWidget);
    expect(find.text('Found in your mail'), findsOneWidget);
    // Tablet: the sidebar in a drawer, behind the menu button.
    await show(tester, size: const Size(800, 900));
    expect(find.byType(Sidebar), findsNothing);
    await tester.tap(find.byTooltip('Folders'));
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsOneWidget);
  });
}
