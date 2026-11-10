// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

/// Settings reads as a list of settings: each explained in one short
/// line, the rest behind "Learn more".
void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: SettingsPage(services: app.services, isAndroid: true),
      ),
    );
    await tester.pump();
  }

  List<String> long(WidgetTester tester) => [
    for (final t in tester.widgetList<Text>(find.byType(Text)))
      if ((t.data ?? '').length > 70) t.data!,
  ];

  testWidgets('no wall of text on the first look', (tester) async {
    await show(tester);
    expect(long(tester), isEmpty);
    expect(find.text('Learn more'), findsAtLeastNWidgets(8));
  });

  testWidgets('Learn more opens one explanation, Show less folds it', (
    tester,
  ) async {
    await show(tester);
    final notifications = find.widgetWithText(
      SwitchListTile,
      'New mail notifications',
    );
    final before = app.services.settings.notifications;
    await tester.tap(
      find.descendant(of: notifications, matching: find.text('Learn more')),
    );
    await tester.pump();
    expect(
      find.textContaining('with a Copy code button for codes'),
      findsOneWidget,
    );
    expect(long(tester), hasLength(1), reason: 'only the one opened');
    expect(app.services.settings.notifications, before);

    await tester.tap(
      find.descendant(of: notifications, matching: find.text('Show less')),
    );
    await tester.pump();
    expect(long(tester), isEmpty);
  });

  testWidgets('a line between groups', (tester) async {
    await show(tester);
    final notifications = tester
        .getTopLeft(find.text('Notifications & checking mail').last)
        .dy;
    final inbox = tester.getTopLeft(find.text('Inbox & sorting').last).dy;
    final dividers = tester
        .widgetList<Divider>(find.byType(Divider))
        .where((d) => d.indent == 16)
        .length;
    expect(dividers, greaterThanOrEqualTo(6));
    expect(notifications, lessThan(inbox));
  });
}
