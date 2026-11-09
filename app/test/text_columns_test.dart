// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/compose/recipient_field.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/reader_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

/// On wide windows the text being read or written stays a column of
/// readable width in the middle; the bars around it keep the full width.
void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  Future<void> show(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
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
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 400));
  }

  test('the reader centres a 720 column once the pane is wider', () {
    expect(ReaderPane.readingMargin(600), ReaderPane.sideMargin(600));
    expect(ReaderPane.readingMargin(1300), 290);
  });

  testWidgets('a wide reader keeps the message in the middle', (tester) async {
    await show(tester, const Size(2200, 900));
    await settle(tester);
    await tester.tap(find.text('Hello there'));
    await settle(tester);
    final pane = tester.getRect(find.byType(ReaderPane));
    final body = tester.getRect(
      find.textContaining('Visible', findRichText: true).last,
    );
    expect(body.left - pane.left, greaterThan(200));
    expect(body.width, lessThanOrEqualTo(CitusmailTheme.readingWidth));
    // The reply bar still spans the pane.
    expect(tester.getRect(find.text('Forward')).right, greaterThan(pane.left));
  });

  testWidgets('a wide compose window bounds the fields, not the toolbar', (
    tester,
  ) async {
    await show(tester, const Size(1400, 900));
    await settle(tester);
    await tester.tap(find.byTooltip('New message (C)'));
    await settle(tester);
    expect(
      tester.getSize(find.byType(RecipientField).first).width,
      lessThanOrEqualTo(CitusmailTheme.writingWidth),
    );
    expect(tester.getRect(find.text('Send')).right, greaterThan(1300));
  });

  testWidgets('a narrow compose window uses the whole width', (tester) async {
    await show(tester, const Size(800, 900));
    await settle(tester);
    await tester.tap(find.byTooltip('New message (C)'));
    await settle(tester);
    expect(
      tester.getSize(find.byType(RecipientField).first).width,
      greaterThan(CitusmailTheme.writingWidth),
    );
  });
}
