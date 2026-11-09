// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/mail/mail_controller.dart';
import 'package:citusmail/src/mail/mail_location.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/message_list_pane.dart';
import 'package:citusmail/src/ui/skeleton_rows.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';

import 'support/test_app.dart';

/// While mail is checked for the first time an empty list shows grey
/// rows on their way, not "No messages here."
void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  testWidgets('the first check shows rows; after it, the empty state', (
    tester,
  ) async {
    final controller = MailController(app.services);
    addTearDown(controller.dispose);
    final searchFocus = FocusNode();
    addTearDown(searchFocus.dispose);
    final account = app.store.accounts.all().single.id;
    final drafts = app.store.mailboxes.bySpecialUse(
      account,
      SpecialUse.drafts,
    )!;

    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: Scaffold(
          body: MessageListPane(
            controller: controller,
            onCompose: () {},
            searchFocus: searchFocus,
          ),
        ),
      ),
    );
    controller.goTo(FolderLocation(drafts.id, account));
    controller.status.value = const SyncRunning();
    await tester.pump();
    expect(find.byType(SkeletonRows), findsOneWidget);
    expect(find.bySemanticsLabel('Checking for mail…'), findsOneWidget);
    expect(find.text('No messages here.'), findsNothing);

    // Checked: the folder really is empty.
    controller.status.value = SyncIdle(DateTime.now());
    await tester.pump();
    expect(find.byType(SkeletonRows), findsNothing);
    expect(find.text('No messages here.'), findsOneWidget);

    // A later check doesn't bring the grey rows back.
    controller.status.value = const SyncRunning();
    await tester.pump();
    expect(find.byType(SkeletonRows), findsNothing);
    expect(find.text('No messages here.'), findsOneWidget);
  });

  testWidgets('on a page, in its content column', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: const Scaffold(
          body: SkeletonRows(label: 'Finding deliveries…', maxWidth: 760),
        ),
      ),
    );
    final rows = tester.getRect(find.byKey(const ValueKey('skeleton-rows')));
    expect(rows.width, 760);
    expect(rows.left, (1400 - 760) / 2);
    expect(find.bySemanticsLabel('Finding deliveries…'), findsOneWidget);
  });
}
