// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/mail/mail_controller.dart';
import 'package:citusmail/src/mail/mail_location.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/deliveries_page.dart';
import 'package:citusmail/src/ui/discover_page.dart';
import 'package:citusmail/src/ui/features.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

/// "All features": everything in one place, each with "Open".
void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  void desktop(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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

  test('ids are unique; Android-only ones are left out elsewhere', () {
    final ids = [for (final f in Features.all) f.id];
    expect(ids.toSet(), hasLength(ids.length));
    expect([
      for (final f in Features.available(android: false)) f.id,
    ], isNot(contains('instantMail')));
    expect([
      for (final f in Features.available(android: true)) f.id,
    ], contains('instantMail'));
  });

  testWidgets('from the sidebar: every feature, grouped, each opens', (
    tester,
  ) async {
    desktop(tester);
    await tester.pumpWidget(shell());
    await tester.pump();
    // The Tools group, unfolded.
    await tester.tap(find.text('Tools'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All features'));
    await tester.pumpAndSettle();
    expect(find.byType(DiscoverPage), findsOneWidget);
    for (final group in FeatureGroup.values) {
      expect(find.text(group.title), findsWidgets, reason: group.title);
    }
    for (final f in Features.available(android: false)) {
      expect(
        find.byKey(ValueKey('feature-${f.id}')),
        findsOneWidget,
        reason: f.title,
      );
    }

    // A page.
    await tester.tap(find.bySemanticsLabel('Open Deliveries'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(DeliveriesPage), findsOneWidget);
  });

  testWidgets('a place in the mail: back to the mail, there', (tester) async {
    desktop(tester);
    final controller = MailController(app.services);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    DiscoverPage(controller: controller, isAndroid: false),
              ),
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Open Snooze'));
    await tester.pumpAndSettle();
    expect(find.byType(DiscoverPage), findsNothing);
    expect(controller.location.value, const SnoozedLocation());
  });

  testWidgets('a setting: Settings, at that setting', (tester) async {
    desktop(tester);
    final controller = MailController(app.services);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: DiscoverPage(controller: controller, isAndroid: false),
      ),
    );
    await tester.tap(find.bySemanticsLabel('Open App lock'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(
      find.descendant(
        of: find.byWidgetPredicate((w) => w is SettingHighlight && w.on),
        matching: find.text('App lock'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('from Settings, Help & about', (tester) async {
    desktop(tester);
    final controller = MailController(app.services);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: SettingsPage(
          services: app.services,
          controller: controller,
          isAndroid: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('All features'));
    await tester.pumpAndSettle();
    expect(find.byType(DiscoverPage), findsOneWidget);
  });
}
