// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/page_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

/// A page's title sits at the top of its content column, not at the
/// window's far left.
void main() {
  void wide(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  const column = (1400 - PageScaffold.width) / 2;

  testWidgets('title and help line up with the column', (tester) async {
    wide(tester);
    var helped = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: PageScaffold(
          title: 'Deliveries',
          help: (tooltip: 'How is this found?', onPressed: () => helped = true),
          body: const Text('content'),
        ),
      ),
    );

    final title = tester.getTopLeft(find.text('Deliveries'));
    expect(title.dx, column + 20);
    final help = tester.getRect(find.byTooltip('How is this found?'));
    expect(help.right, lessThanOrEqualTo(1400 - column));
    expect(help.right, greaterThan(1400 - column - 16));
    // The app bar no longer carries the title.
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.byType(Text)),
      findsNothing,
    );
    await tester.tap(find.byTooltip('How is this found?'));
    expect(helped, isTrue);
  });

  group('in the app', () {
    late TestApp app;
    setUp(() async => app = await TestApp.create());
    tearDown(() => app.dispose());

    testWidgets('Settings has its title over its column', (tester) async {
      wide(tester);
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
      await tester.tap(find.byTooltip('Settings'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      final title = find.byKey(const ValueKey('page-title'));
      expect(tester.widget<Text>(title).data, 'Settings');
      // Settings has a wider column: its groups beside the settings.
      const settingsColumn = (1400 - 1080) / 2;
      expect(tester.getTopLeft(title).dx, settingsColumn + 20);
      // The groups and the settings themselves are in the same column.
      final search = tester.getRect(
        find.byKey(const ValueKey('settings-search')).first,
      );
      expect(search.left, greaterThanOrEqualTo(settingsColumn));
      expect(search.left, lessThan(settingsColumn + 24));
      final first = tester.getRect(find.byType(SwitchListTile).first);
      expect(first.right, 1400 - settingsColumn);
    });
  });
}
