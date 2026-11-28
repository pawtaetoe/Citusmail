// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/core/theme/citusmail_theme.dart';
import 'package:citusmail/src/core/widgets/inset_sheet.dart';
import 'package:citusmail/src/features/inbox/ui/mail_shell.dart';
import 'package:citusmail/src/features/inbox/ui/peek.dart';
import 'package:citusmail/src/features/organise/ui/snooze_sheet.dart';
import 'package:citusmail/src/features/settings/ui/settings_catalog.dart';
import 'package:citusmail/src/features/settings/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

/// Android draws the app under its own bars (edge to edge): what sits at
/// the bottom of a screen stays above the navigation bar (gesture bar or
/// buttons), whose height differs from phone to phone.
void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  /// A phone of [size] whose navigation bar takes [bottom] and status bar
  /// [top], with the keyboard taking [keyboard] (it covers the bar).
  void phone(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double bottom = 48,
    double top = 24,
    double keyboard = 0,
  }) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.viewPadding = FakeViewPadding(top: top, bottom: bottom);
    // As the engine reports it: what the keyboard covers is not padding.
    tester.view.padding = FakeViewPadding(
      top: top,
      bottom: (bottom - keyboard).clamp(0, bottom),
    );
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.reset);
  }

  /// How far down the screen content may reach: above the navigation bar.
  double limit(WidgetTester tester, {double inset = 48}) =>
      tester.view.physicalSize.height / tester.view.devicePixelRatio - inset;

  void expectAbove(WidgetTester tester, Finder finder, double y) {
    expect(finder, findsWidgets);
    for (final element in finder.evaluate()) {
      final box = element.renderObject! as RenderBox;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      expect(
        rect.bottom,
        lessThanOrEqualTo(y),
        reason: '${element.widget} reaches under the navigation bar',
      );
    }
  }

  /// Scrolls the page's list to its end.
  Future<void> toEnd(WidgetTester tester) async {
    final position = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    // The end is known once the last rows are laid out.
    for (var i = 0; i < 5; i++) {
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
    }
  }

  Widget shell() => MaterialApp(
    theme: CitusmailTheme.light(),
    home: MailShell(
      notifications: false,
      services: app.services,
      onAddAccount: () {},
      onAccountsChanged: () {},
    ),
  );

  /// Lets real isolates (the worker, reading the text) finish.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  testWidgets('the peek sheet\'s actions are above the navigation bar', (
    tester,
  ) async {
    phone(tester);
    await tester.pumpWidget(shell());
    await tester.pump();
    await tester.longPress(find.text('Hello there'));
    await tester.pumpAndSettle();
    await settle(tester);
    final sheet = find.byType(BottomSheet);
    expect(sheet, findsOneWidget);
    for (final label in ['Open', 'Select', 'Pin', 'Mark read']) {
      expectAbove(
        tester,
        find.ancestor(
          of: find.descendant(
            of: find.byType(PeekCard),
            matching: find.text(label),
          ),
          matching: find.byType(InkWell),
        ),
        limit(tester),
      );
    }
    // The sheet itself still reaches the bottom edge (no gap under it),
    // and stays below the status bar.
    final rect = tester.getRect(sheet);
    expect(rect.bottom, 844);
    expect(rect.top, greaterThanOrEqualTo(24));
  });

  testWidgets('a wider inset: the actions move up with it', (tester) async {
    phone(tester, bottom: 96);
    await tester.pumpWidget(shell());
    await tester.pump();
    await tester.longPress(find.text('Hello there'));
    await tester.pumpAndSettle();
    await settle(tester);
    expectAbove(
      tester,
      find.ancestor(
        of: find.descendant(
          of: find.byType(PeekCard),
          matching: find.text('Open'),
        ),
        matching: find.byType(InkWell),
      ),
      limit(tester, inset: 96),
    );
  });

  testWidgets('the tabs and New message are above the navigation bar', (
    tester,
  ) async {
    phone(tester);
    await tester.pumpWidget(shell());
    await tester.pump();
    expect(find.byType(NavigationBar), findsOneWidget);
    expectAbove(tester, find.byType(NavigationDestination), limit(tester));
    expectAbove(tester, find.byType(FloatingActionButton), limit(tester));
  });

  testWidgets('the end of Settings scrolls above the navigation bar', (
    tester,
  ) async {
    // Short, so the list scrolls.
    phone(tester, size: const Size(390, 520));
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: SettingsPage(services: app.services, isAndroid: true),
      ),
    );
    await tester.pumpAndSettle();
    await toEnd(tester);
    final last = find.byKey(
      ValueKey('settings-group-${SettingsCatalog.sections.last.id}'),
    );
    expectAbove(tester, last, limit(tester));
  });

  testWidgets('the end of Advanced scrolls above the navigation bar', (
    tester,
  ) async {
    phone(tester, size: const Size(390, 520));
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: AdvancedSettingsPage(services: app.services),
      ),
    );
    await tester.pumpAndSettle();
    await toEnd(tester);
    expectAbove(
      tester,
      find.ancestor(
        of: find.text('Forget what it learned'),
        matching: find.byType(ListTile),
      ),
      limit(tester),
    );
  });

  testWidgets('a sheet\'s last choice is above the navigation bar', (
    tester,
  ) async {
    phone(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => SnoozeSheet.pick(context),
              child: const Text('Snooze'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Snooze'));
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    expect(sheet, findsOneWidget);
    expectAbove(
      tester,
      find.descendant(of: sheet, matching: find.byType(InkWell)),
      limit(tester),
    );
    expect(tester.getRect(sheet).top, greaterThanOrEqualTo(24));
  });

  testWidgets('typing in a sheet: its content is above the keyboard', (
    tester,
  ) async {
    phone(tester, keyboard: 300);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showInsetSheet<void>(
                context,
                builder: (_) => const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(),
                    SizedBox(height: 8),
                    Text('Done', key: ValueKey('done')),
                  ],
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final done = tester.getRect(find.byKey(const ValueKey('done')));
    // Just above the keyboard: not lifted again by the navigation bar
    // the keyboard already covers.
    expect(done.bottom, lessThanOrEqualTo(844 - 300));
    expect(done.bottom, greaterThan(844 - 300 - 48));
  });
}
