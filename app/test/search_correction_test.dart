// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Search forgives typos, and says so above the results, with a way to
// search for exactly what was typed.

import 'dart:async';

import 'package:citusmail/src/core/state/validation.dart';
import 'package:citusmail/src/core/theme/citusmail_theme.dart';
import 'package:citusmail/src/features/inbox/state/mail_location.dart';
import 'package:citusmail/src/features/inbox/ui/mail_shell.dart';
import 'package:citusmail/src/features/inbox/ui/message_list_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  Future<void> show(WidgetTester tester) async {
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
  }

  Future<void> search(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
  }

  testWidgets('a typo finds the message, and the line says so', (tester) async {
    await show(tester);
    await search(tester, 'parcle');
    expect(find.text('Your parcel'), findsOneWidget);
    expect(find.text('Showing results for "parcel"'), findsOneWidget);
    final instead = find.text('Search for "parcle" instead');
    expect(instead, findsOneWidget);

    // Only exact matches: none.
    await tester.tap(instead);
    await tester.pump();
    expect(find.text('Your parcel'), findsNothing);
    expect(find.text('Showing results for "parcel"'), findsNothing);
    expect(find.text('No messages found.'), findsOneWidget);
    expect(
      app.services.store.messages.search('parcle'),
      isEmpty,
      reason: 'exactly what was typed',
    );

    // Searching again corrects again.
    await search(tester, 'parcle');
    expect(find.text('Your parcel'), findsOneWidget);
    expect(find.text('Showing results for "parcel"'), findsOneWidget);
  });

  testWidgets('no line when what was typed is found', (tester) async {
    await show(tester);
    await search(tester, 'parcel');
    expect(find.text('Your parcel'), findsOneWidget);
    expect(find.textContaining('Showing results for'), findsNothing);
    expect(find.textContaining('instead'), findsNothing);
  });

  testWidgets('mail from an older version is counted in the background', (
    tester,
  ) async {
    // As after the upgrade: none of the stored mail's words are counted.
    final store = app.store;
    store.database
      ..execute('DELETE FROM search_words')
      ..execute(
        'UPDATE search_words_pending SET below = (SELECT max(id) FROM messages)',
      );
    expect(store.searchWords.hasPending, isTrue);
    int? counted;
    unawaited(app.services.countSearchWordsWhenIdle().then((n) => counted = n));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(counted, isNull, reason: 'the app is still starting');
    await tester.pump(const Duration(seconds: 1));
    // The worker is another isolate: real time passes while it works.
    for (var i = 0; i < 100 && counted == null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(counted, greaterThan(0));
    expect(store.searchWords.hasPending, isFalse);
    expect(store.searchWords.count('parcel'), greaterThan(0));
  });

  test('an exact search is a place of its own', () {
    expect(
      const SearchLocation('parcle', exact: true),
      isNot(const SearchLocation('parcle')),
    );
  });

  testWidgets('pasted text is searched as one line, at most 200 characters', (
    tester,
  ) async {
    await show(tester);
    await search(tester, 'parcel\r\u0000update');
    final controller = tester
        .widget<MessageListPane>(find.byType(MessageListPane))
        .controller;
    expect(controller.location.value, const SearchLocation('parcel  update'));
    await search(tester, 'x' * 5000);
    expect(
      (controller.location.value as SearchLocation).text,
      hasLength(SearchText.defaultMaxLength),
    );
  });
}
