// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

/// A section header's second line is the summary of what is folded away;
/// an open section shows its messages instead.
void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  testWidgets('"N messages" only under a folded header', (tester) async {
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

    // Pinned, Important and General are open: no count under them.
    expect(find.text('1 message'), findsNothing);
    // Newsletters starts folded: its sender is the summary.
    expect(find.text('Shop'), findsOneWidget);
    // Fold General: the sender appears as its summary.
    await tester.tap(find.text('General'));
    await tester.pump();
    expect(find.text('Stranger Danger'), findsOneWidget);
    expect(find.text('Hello there'), findsNothing);
  });
}
