// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

/// Sync status is said once per place: "Offline" in the list header, and
/// one line in the sidebar (under the account, not again at the bottom).
void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  testWidgets('one account offline: said once in the sidebar', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
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
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 600)),
    );
    await tester.pump(const Duration(milliseconds: 200));

    final sidebar = find.byType(Sidebar);
    expect(
      find.descendant(of: sidebar, matching: find.text('Offline, retrying')),
      findsOneWidget,
      reason: 'under the account',
    );
    expect(
      find.descendant(
        of: sidebar,
        matching: find.textContaining('alice@citusmail.test: Offline'),
      ),
      findsNothing,
      reason: 'not repeated at the bottom',
    );
    expect(find.text('Offline'), findsOneWidget, reason: 'the list header');
  });
}
