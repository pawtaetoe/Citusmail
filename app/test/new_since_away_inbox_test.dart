// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/mail/new_since_away.dart';
import 'package:citusmail/src/services/app_settings.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/message_list_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'support/away_mail.dart';
import 'support/test_app.dart';

const _title = 'New since you were away';

/// Away overnight; back at 8:05 the next morning.
final _left = DateTime(2026, 11, 3, 18, 30);
final _back = DateTime(2026, 11, 4, 8, 5);

void main() {
  late TestApp app;
  setUp(() async {
    app = await TestApp.create();
    NewSinceAway.clock = () => _back;
  });
  tearDown(() {
    NewSinceAway.clock = DateTime.now;
    return app.dispose();
  });

  MailStore store() => app.store;
  StoredMessage message(String subject) => store().messages
      .list(const MessageQuery.inbox(limit: 100))
      .firstWhere((m) => m.subject == subject);

  /// Alice closed the app last night; this morning's mail is in.
  void seedAway() {
    seedAwayMail(store(), left: _left.toUtc(), back: _back.toUtc());
    NewSinceAway(store()).wentAway(_left);
  }

  Future<void> show(
    WidgetTester tester, {
    // Tall enough for every section.
    Size size = const Size(1400, 2000),
  }) async {
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
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
  }

  /// Where [text] is in the message list (not the sidebar).
  Finder inList(String text) => find.descendant(
    of: find.byType(MessageListPane),
    matching: find.text(text),
  );
  double top(WidgetTester tester, String text) =>
      tester.getTopLeft(inList(text).first).dy;

  testWidgets('at the top of the inbox, each message only there', (
    tester,
  ) async {
    seedAway();
    await show(tester);
    await settle(tester);

    expect(find.text(_title), findsOneWidget);
    expect(find.text('3 emails since yesterday'), findsOneWidget);
    expect(
      find.text('Plus 2 newsletters and 1 notification, in their sections'),
      findsOneWidget,
    );
    // Above everything else, and not repeated in Important or General.
    for (final subject in [
      'Standup moved to 10',
      'Contract draft, v3',
      'Dinner on Friday?',
    ]) {
      expect(find.text(subject), findsOneWidget);
      expect(top(tester, subject), greaterThan(top(tester, _title)));
      expect(top(tester, subject), lessThan(top(tester, 'Important')));
    }
    // Mail that came once she was back is in its usual section.
    expect(
      top(tester, 'Never mind, 9:30'),
      greaterThan(top(tester, 'General')),
    );
    // Left out: her own note, the blocked sender, the Screener's.
    expect(find.text('Passport number for the booking'), findsOneWidget);
    expect(
      top(tester, 'Passport number for the booking'),
      greaterThan(top(tester, 'General')),
    );
    expect(find.text('You have been selected!!!'), findsOneWidget);
    expect(find.text('Quick question about your next move'), findsNothing);
    expect(inList('Screener'), findsOneWidget);
  });

  testWidgets('Done puts them back in their sections, still unread', (
    tester,
  ) async {
    seedAway();
    await show(tester);
    await settle(tester);

    await tester.tap(find.widgetWithText(TextButton, 'Done'));
    await settle(tester);
    expect(find.text(_title), findsNothing);
    expect(find.text('Back in their sections'), findsOneWidget);
    expect(find.text('Dinner on Friday?'), findsOneWidget);
    expect(
      top(tester, 'Dinner on Friday?'),
      greaterThan(top(tester, 'Important')),
    );
    expect(message('Dinner on Friday?').flags.seen, isFalse);

    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect(find.text(_title), findsOneWidget);
  });

  testWidgets('Mark all as read keeps them there, read', (tester) async {
    seedAway();
    await show(tester);
    await settle(tester);

    await tester.tap(find.byTooltip('Mark all as read'));
    await settle(tester);
    expect(message('Dinner on Friday?').flags.seen, isTrue);
    expect(message('Standup moved to 10').flags.seen, isTrue);
    // Mail outside the section is untouched.
    expect(message('Never mind, 9:30').flags.seen, isFalse);
    expect(find.text(_title), findsOneWidget);
    expect(find.byTooltip('Mark all as read'), findsNothing);
  });

  testWidgets('archived mail leaves it', (tester) async {
    seedAway();
    await show(tester);
    await settle(tester);

    await tester.tap(find.text('Dinner on Friday?'));
    await settle(tester);
    await tester.tap(find.byTooltip('Archive (E)').first);
    await settle(tester);
    expect(find.text('2 emails since yesterday'), findsOneWidget);
  });

  testWidgets('rebuilt after more than a minute away, not after 30 seconds', (
    tester,
  ) async {
    seedAway();
    await show(tester);
    await settle(tester);
    final binding = tester.binding;

    Future<void> away(Duration gap, {required String arrives}) async {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      final left = NewSinceAway.clock();
      store().messages.upsertSummaries(
        store().mailboxes.inbox(store().accounts.all().single.id)!.id,
        [
          MessageSummary(
            uid: 90 + gap.inSeconds % 50,
            receivedAt: left.add(gap ~/ 2).toUtc(),
            subject: arrives,
            from: const MailAddress(
              displayName: 'Dave',
              localPart: 'dave',
              domain: 'x.example',
            ),
          ),
        ],
      );
      NewSinceAway.clock = () => left.add(gap);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
    }

    // A quick look at another app: the section stays as it was.
    await away(const Duration(seconds: 30), arrives: 'Quick one');
    expect(find.text('3 emails since yesterday'), findsOneWidget);

    // Ten minutes of reading, then an hour away: what came in that hour.
    NewSinceAway.clock = () => _back.add(const Duration(minutes: 10));
    await away(const Duration(hours: 1), arrives: 'Lunch at 12?');
    expect(find.text('1 email since 8:15 AM'), findsOneWidget);
    expect(top(tester, 'Lunch at 12?'), lessThan(top(tester, 'Important')));
    // It came in during the quick look, while the app counted as in use.
    expect(top(tester, 'Quick one'), greaterThan(top(tester, 'General')));
    expect(find.text('Dinner on Friday?'), findsOneWidget);
    expect(
      top(tester, 'Dinner on Friday?'),
      greaterThan(top(tester, 'Important')),
    );
  });

  testWidgets('not there on the first run, or with the setting off', (
    tester,
  ) async {
    seedAwayMail(store(), left: _left.toUtc(), back: _back.toUtc());
    await show(tester);
    await settle(tester);
    expect(find.text(_title), findsNothing);
    expect(find.text('Dinner on Friday?'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    NewSinceAway(store()).wentAway(_left);
    AppSettings(store()).newSinceAway = false;
    await show(tester);
    await settle(tester);
    expect(find.text(_title), findsNothing);
    expect(find.text('Dinner on Friday?'), findsOneWidget);
  });

  testWidgets('on a phone', (tester) async {
    seedAway();
    await show(tester, size: const Size(390, 844));
    await settle(tester);
    expect(find.text(_title), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Done'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
