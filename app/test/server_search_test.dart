// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Search only sees the mail kept on the device. When it finds little, each
// account offers to search all of its mail on the server; what that finds
// joins the results. Offline, the results from the device stay, and the
// list says why nothing more came.

import 'package:citusmail/src/core/theme/citusmail_theme.dart';
import 'package:citusmail/src/features/inbox/state/mail_location.dart';
import 'package:citusmail/src/features/inbox/state/message_list_model.dart';
import 'package:citusmail/src/features/inbox/ui/mail_shell.dart';
import 'package:citusmail/src/features/inbox/ui/message_list_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  const offer = 'Search all of alice@citusmail.test on the server';

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

  MessageListModel listOf(WidgetTester tester) => tester
      .widget<MessageListPane>(find.byType(MessageListPane))
      .controller
      .list;

  /// Lets the sync worker (another isolate) answer.
  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
  }

  StoredMailbox archive() => app.store.mailboxes.bySpecialUse(
    app.store.accounts.all().single.id,
    SpecialUse.archive,
  )!;

  testWidgets('offline: the results on the device stay, and the list says '
      'so', (tester) async {
    await show(tester);
    await search(tester, 'parcel');
    expect(find.text('Your parcel'), findsOneWidget);
    expect(find.text(offer), findsOneWidget);

    await tester.tap(find.text(offer));
    await tester.pump();
    expect(
      find.text('Searching alice@citusmail.test on the server…'),
      findsOneWidget,
    );
    final offline = find.textContaining('You\'re offline');
    await waitFor(tester, offline);
    expect(offline, findsOneWidget);
    expect(find.textContaining('results on this device'), findsOneWidget);
    expect(find.text('Your parcel'), findsOneWidget, reason: 'kept');
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text(offer), findsNothing);
  });

  testWidgets('nothing found on the device: the offer is under the search, '
      'above "No messages found."', (tester) async {
    await show(tester);
    await search(tester, 'redemption');
    expect(find.text('No messages found.'), findsOneWidget);
    expect(find.text(offer), findsOneWidget);

    // Another search: offered again, from the start.
    await search(tester, 'lunch');
    expect(find.text('Lunch?'), findsOneWidget);
    expect(find.text(offer), findsOneWidget);
  });

  testWidgets('no offer when the device finds enough', (tester) async {
    app.store.messages.upsertSummaries(archive().id, [
      for (var i = 0; i < MessageListModel.fewResults; i++)
        MessageSummary(
          uid: 10 + i,
          receivedAt: DateTime.utc(2026, 9, 1 + i),
          subject: 'Quarterly report $i',
        ),
    ]);
    await show(tester);
    await search(tester, 'quarterly');
    expect(find.textContaining('Quarterly report'), findsWidgets);
    expect(find.text(offer), findsNothing);
  });

  testWidgets('what the server found joins the results, and opens', (
    tester,
  ) async {
    await show(tester);
    await search(tester, 'redemption');
    expect(find.text('No messages found.'), findsOneWidget);

    // As the worker leaves it: the booking's summary, stored in the
    // Archive. Its words ("redemption" is in the body) are not on the
    // device.
    app.store.messages.upsertSummaries(archive().id, [
      MessageSummary(
        uid: 40,
        receivedAt: DateTime.utc(2026, 3, 14),
        subject: 'Booking confirmed: SQ 322',
        from: const MailAddress(
          displayName: 'Singapore Airlines',
          localPart: 'noreply',
          domain: 'air.example',
        ),
      ),
    ]);
    final booking = app.store.messages.byUid(archive().id, 40)!;
    final list = listOf(tester);
    final accountId = app.store.accounts.all().single.id;
    list
      ..serverSearchStarted(accountId)
      ..serverSearchFinished(accountId, [booking.id]);
    await tester.pump();
    expect(find.text('Booking confirmed: SQ 322'), findsOneWidget);
    expect(find.text('No messages found.'), findsNothing);
    expect(
      find.text('1 more from the server for alice@citusmail.test.'),
      findsOneWidget,
    );
    expect(list.localResults, 0);

    await tester.tap(find.text('Booking confirmed: SQ 322'));
    await tester.pump();
    final controller = tester
        .widget<MessageListPane>(find.byType(MessageListPane))
        .controller;
    expect(controller.selected?.id, booking.id);

    // A new search starts without it (still open in the reader).
    await search(tester, 'parcel');
    expect(controller.list.messages.map((m) => m.subject), ['Your parcel']);
    expect(
      find.descendant(
        of: find.byType(MessageListPane),
        matching: find.text('Booking confirmed: SQ 322'),
      ),
      findsNothing,
    );
    expect(controller.location.value, const SearchLocation('parcel'));
    expect(find.text(offer), findsOneWidget);
  });
}
