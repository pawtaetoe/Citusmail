// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmail/src/services/app_services.dart';
import 'package:fmail/src/ui/fmail_theme.dart';
import 'package:fmail/src/ui/mail_shell.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  late AppServices services;
  late MailStore store;

  setUp(() async {
    app = await TestApp.create();
    services = app.services;
    store = app.store;
  });

  tearDown(() => app.dispose());

  Future<void> show(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: FmailTheme.light(),
        home: MailShell(
          services: services,
          onAddAccount: () {},
          onAccountsChanged: () {},
        ),
      ),
    );
    await tester.pump();
  }

  /// Lets real isolates (worker, message parsing) finish.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('wide: sidebar, Smart Inbox sections, reader', (tester) async {
    await show(tester, const Size(1400, 900));

    // Sidebar.
    expect(find.text('Pins'), findsOneWidget);
    expect(find.text('Sent'), findsOneWidget);
    expect(find.text('Archive'), findsOneWidget);
    expect(find.text('Projects'), findsOneWidget);

    // Every section, in order, each message once.
    for (final title in [
      'Pinned',
      'Important',
      'General',
      'Notifications',
      'Newsletters',
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    double top(String text) => tester.getTopLeft(find.text(text).first).dy;
    expect(top('Pinned') < top('Important'), isTrue);
    expect(top('Important') < top('General'), isTrue);
    expect(top('Keep this') < top('Lunch?'), isTrue, reason: 'pinned first');
    expect(
      top('Lunch?') < top('Hello there'),
      isTrue,
      reason: 'Carol is important',
    );

    // Open a message: safe body, blocked tracker, unread dot gone.
    await tester.tap(find.text('Hello there'));
    await settle(tester);
    expect(find.textContaining('Visible', findRichText: true), findsWidgets);
    expect(find.textContaining('remote image was blocked'), findsOneWidget);
    expect(
      store.messages
          .list(const MessageQuery.inbox())
          .firstWhere((m) => m.subject == 'Hello there')
          .flags
          .seen,
      isTrue,
    );

    // A link asks before opening anything.
    // Tap on the words (the paragraph itself is as wide as the pane).
    final link = find.textContaining('a link', findRichText: true).last;
    await tester.tapAt(tester.getTopLeft(link) + const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.text('Open this link?'), findsOneWidget);
    expect(find.text('shop.example'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Pin from the reader moves it to Pinned.
    await tester.tap(find.byTooltip('Pin'));
    await tester.pump();
    expect(top('Hello there') < top('Important'), isTrue);
  });

  testWidgets('Classic shows one list; Show all opens a section', (
    tester,
  ) async {
    await show(tester, const Size(1400, 900));
    await tester.tap(find.text('Classic'));
    await tester.pump();
    expect(find.text('Pinned'), findsNothing);
    for (final subject in [
      'Hello there',
      'Lunch?',
      'Weekly deals',
      'Your parcel',
      'Keep this',
    ]) {
      expect(find.text(subject), findsOneWidget);
    }
    await tester.tap(find.text('Smart'));
    await tester.pump();
    await tester.tap(find.text('Newsletters'));
    await tester.pump();
    expect(find.byTooltip('Back to inbox'), findsOneWidget);
    expect(find.text('Weekly deals'), findsOneWidget);
    expect(find.text('Lunch?'), findsNothing);
  });

  testWidgets('narrow: one pane at a time, back returns to the list', (
    tester,
  ) async {
    await show(tester, const Size(400, 800));
    expect(find.text('Pins'), findsNothing, reason: 'sidebar is in the drawer');
    await tester.tap(find.text('Hello there'));
    await settle(tester);
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.text('Weekly deals'), findsNothing);
    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    expect(find.text('Weekly deals'), findsOneWidget);

    await tester.tap(find.byTooltip('Folders'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pins'));
    await tester.pumpAndSettle();
    expect(find.text('Keep this'), findsOneWidget);
    expect(find.text('Weekly deals'), findsNothing);
  });

  testWidgets('search finds stored mail', (tester) async {
    await show(tester, const Size(1400, 900));
    await tester.enterText(find.byType(TextField), 'parcel');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(find.text('Results for "parcel"'), findsOneWidget);
    expect(find.text('Your parcel'), findsOneWidget);
    expect(find.text('Lunch?'), findsNothing);
  });
}
