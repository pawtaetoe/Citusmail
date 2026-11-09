// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/ui/app_icons.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/mail_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

/// Outlined glyphs everywhere; filled only for what is on.
void main() {
  test('the vocabulary is outlined, with filled "on" states', () {
    expect(AppIcons.inbox, Icons.inbox_outlined);
    expect(AppIcons.snooze, Icons.snooze_outlined);
    expect(AppIcons.unsnooze, Icons.alarm_off_outlined);
    expect(AppIcons.block, Icons.block_outlined);
    expect(AppIcons.original, Icons.data_object);
    expect(AppIcons.pinOff, Icons.push_pin_outlined);
    expect(AppIcons.pinOn, Icons.push_pin);
    expect(AppIcons.receiptOn, Icons.mark_email_read);
    expect(AppIcons.remindOff, Icons.alarm_off_outlined);
    expect(AppIcons.reminder, Icons.alarm_outlined);
  });

  test('a Smart Inbox section uses the same icon as its place', () {
    expect(MailText.sectionIcon(SmartSection.pinned), AppIcons.pins);
    expect(MailText.sectionIcon(SmartSection.snoozed), AppIcons.snoozed);
    expect(MailText.sectionIcon(SmartSection.screener), AppIcons.screener);
  });

  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  testWidgets('the sidebar and reader use it', (tester) async {
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
    expect(find.byIcon(Icons.inbox), findsNothing);
    expect(find.byIcon(AppIcons.inbox), findsWidgets);

    await tester.tap(find.text('Hello there'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byIcon(Icons.code), findsNothing);
    expect(find.byIcon(Icons.block), findsNothing);
    expect(find.byIcon(Icons.snooze), findsNothing);
    expect(find.byIcon(AppIcons.block), findsOneWidget);
    expect(find.byIcon(AppIcons.original), findsOneWidget);
  });
}
