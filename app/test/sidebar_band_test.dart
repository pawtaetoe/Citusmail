// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

/// The pages below the accounts sit under small muted headings, part of
/// the navigation column rather than a boxed panel of their own.
void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  testWidgets('group headings are small and muted, with no box', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = CitusmailTheme.light();
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: MailShell(
          notifications: false,
          services: app.services,
          onAddAccount: () {},
          onAccountsChanged: () {},
        ),
      ),
    );
    await tester.pump();

    final sidebar = find.byType(Sidebar);
    final colors = theme.extension<SidebarColors>()!;
    for (final heading in ['Found in your mail', 'Tools']) {
      final text = tester.widget<Text>(
        find.descendant(of: sidebar, matching: find.text(heading)),
      );
      expect(text.style?.fontSize, 12, reason: heading);
      expect(text.style?.color, colors.muted, reason: heading);
    }
    // No tinted, bordered box around them.
    final boxes = tester
        .widgetList<Container>(
          find.ancestor(
            of: find.text('Tools'),
            matching: find.byType(Container),
          ),
        )
        .where((c) => c.decoration is BoxDecoration)
        .map((c) => c.decoration! as BoxDecoration);
    expect(boxes.where((d) => d.border != null), isEmpty);
  });
}
