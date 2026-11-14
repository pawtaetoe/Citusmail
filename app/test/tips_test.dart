// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/mail/mail_controller.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/settings_page.dart';
import 'package:citusmail/src/ui/tips.dart';
import 'package:citusmail/src/ui/trips_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

/// One short tip at the moment a feature could help: each once, at most
/// one per session, never in the way, and never again after "Don't show
/// tips".
void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  StoredMessage inbox(int uid) => app.store.messages.byUid(
    app.store.mailboxes.inbox(app.store.accounts.all().single.id)!.id,
    uid,
  )!;

  group('which tip, when', () {
    test('a booking: Trips; a long conversation: Snooze', () {
      final hello = inbox(1);
      expect(Tips.forMessage(hello, canUnsubscribe: false), isNull);
      expect(Tips.forMessage(hello, canUnsubscribe: true), Tips.unsubscribe);
      final booking = app.seedFixture(
        'people/plain-text.eml',
        subject: 'Your flight booking to Lisbon',
        uid: 70,
      );
      expect(Tips.forMessage(booking, canUnsubscribe: false), Tips.trips);
    });

    test('someone new while the Screener is off: Screener, asked last', () {
      final hello = inbox(1);
      var asked = 0;
      bool isNew() {
        asked++;
        return true;
      }

      expect(
        Tips.forMessage(hello, canUnsubscribe: false, firstTimeSender: isNew),
        Tips.screener,
      );
      // Another tip that applies comes first, without asking.
      expect(
        Tips.forMessage(hello, canUnsubscribe: true, firstTimeSender: isNew),
        Tips.unsubscribe,
      );
      expect(asked, 1);
      expect(
        Tips.forMessage(
          hello,
          canUnsubscribe: false,
          firstTimeSender: () => false,
        ),
        isNull,
      );
      // Newsletters and notifications aren't what the Screener is for.
      expect(
        Tips.forMessage(
          inbox(3),
          canUnsubscribe: false,
          firstTimeSender: isNew,
        ),
        isNull,
      );
    });

    test('a first-time sender: one email, never written to, Screener off', () {
      final controller = MailController(app.services);
      addTearDown(controller.dispose);
      // Stranger: one email. Carol: the user wrote to her.
      expect(controller.isFirstTimeSender(inbox(1)), isTrue);
      expect(controller.isFirstTimeSender(inbox(2)), isFalse);
      // A second email from the stranger: not new any more.
      final inboxId = app.store.mailboxes
          .inbox(app.store.accounts.all().single.id)!
          .id;
      app.store.messages.upsertSummaries(inboxId, [
        MessageSummary(
          uid: 80,
          receivedAt: DateTime.utc(2026, 10, 21),
          subject: 'Following up',
          from: const MailAddress(localPart: 'stranger', domain: 'x.example'),
        ),
      ]);
      expect(controller.isFirstTimeSender(inbox(1)), isFalse);
      expect(controller.isFirstTimeSender(inbox(5)), isTrue);
      // With the Screener on, it decides instead.
      app.store.screener.enable();
      expect(controller.isFirstTimeSender(inbox(5)), isFalse);
    });

    test('couldTake asks without counting the tip as shown', () {
      final tips = Tips(app.store);
      expect(tips.couldTake(Tips.screener, where: 1), isTrue);
      expect(tips.seen, isEmpty);
      expect(tips.take(Tips.trips, where: 2), isTrue);
      expect(tips.couldTake(Tips.screener, where: 1), isFalse);
    });

    test('each tip once, one per session, none when turned off', () {
      final tips = Tips(app.store);
      expect(tips.enabled, isTrue, reason: 'on by default');
      expect(tips.take(Tips.trips, where: 1), isTrue);
      // The same email, shown again (a rebuild): still there.
      expect(tips.take(Tips.trips, where: 1), isTrue);
      // Another email: it was shown once already.
      expect(tips.take(Tips.trips, where: 2), isFalse);
      // Another tip: one per session.
      expect(tips.take(Tips.snooze, where: 3), isFalse);
      expect(tips.seen, {'trips'});

      tips.enabled = false;
      expect(Tips(app.store).take(Tips.trips, where: 1), isFalse);
    });
  });

  group('in the reader', () {
    void desktop(WidgetTester tester) {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }

    Future<void> showShell(WidgetTester tester) async {
      desktop(tester);
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
      await settle(tester);
    }

    testWidgets('the first booking shows Trips, once; "Open Trips" opens it', (
      tester,
    ) async {
      app.seedFixture(
        'people/plain-text.eml',
        subject: 'Your flight booking to Lisbon',
        uid: 70,
        receivedAt: DateTime.utc(2026, 10, 22),
      );
      app.seedFixture(
        'people/html-alternative.eml',
        subject: 'Hotel reservation confirmed',
        uid: 71,
        receivedAt: DateTime.utc(2026, 10, 21),
      );
      await showShell(tester);
      await tester.tap(find.text('Your flight booking to Lisbon'));
      await settle(tester);
      expect(find.text('Tip: Your trips in one place'), findsOneWidget);

      // Another booking: no tip, it was shown.
      await tester.tap(find.text('Hotel reservation confirmed'));
      await settle(tester);
      expect(find.textContaining('Tip:'), findsNothing);

      // Back to the first: still there, with its button.
      await tester.tap(find.text('Your flight booking to Lisbon'));
      await settle(tester);
      await tester.tap(find.text('Open Trips'));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(TripsPage), findsOneWidget);
    });

    testWidgets('mail from someone new: the Screener tip, once; its button '
        'opens the Screener setting', (tester) async {
      app.seedFixture(
        'people/html-alternative.eml',
        subject: 'Photos from the hike',
        uid: 71,
      );
      await showShell(tester);
      await tester.tap(find.text('Hello there'));
      await settle(tester);
      expect(find.text('Tip: Decide who reaches your inbox'), findsOneWidget);
      expect(Tips(app.store).seen, {'screener'});

      // Another first-time sender: no second tip.
      await tester.tap(find.text('Photos from the hike'));
      await settle(tester);
      expect(find.textContaining('Tip:'), findsNothing);

      await tester.tap(find.text('Hello there'));
      await settle(tester);
      await tester.tap(find.text('Set up Screener'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(
        find.descendant(
          of: find.byWidgetPredicate((w) => w is SettingHighlight && w.on),
          matching: find.text('Screen first-time senders'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('no Screener tip while the Screener is on, or tips are off', (
      tester,
    ) async {
      app.store.screener.enable();
      await showShell(tester);
      await tester.tap(find.text('Hello there'));
      await settle(tester);
      expect(find.textContaining('Tip:'), findsNothing);
      expect(Tips(app.store).seen, isEmpty);
    });

    testWidgets('no tip under a scam warning', (tester) async {
      app.seedFixture(
        'security/org-impersonation-form.eml',
        subject: 'STUDENT NOTICE - Skills Program',
        uid: 90,
      );
      await showShell(tester);
      await tester.tap(find.text('STUDENT NOTICE - Skills Program'));
      await settle(tester);
      expect(find.text('This message may be a scam'), findsOneWidget);
      expect(find.textContaining('Tip:'), findsNothing);
      expect(Tips(app.store).seen, isEmpty);
    });

    testWidgets('no Screener tip with tips turned off', (tester) async {
      Tips(app.store).enabled = false;
      await showShell(tester);
      await tester.tap(find.text('Hello there'));
      await settle(tester);
      expect(find.textContaining('Tip:'), findsNothing);
      expect(Tips(app.store).seen, isEmpty);
    });

    testWidgets('"Don\'t show tips" puts it away and stops them', (
      tester,
    ) async {
      app.seedFixture(
        'people/plain-text.eml',
        subject: 'Your flight booking to Lisbon',
        uid: 70,
      );
      await showShell(tester);
      await tester.tap(find.text('Your flight booking to Lisbon'));
      await settle(tester);
      expect(find.text('Tip: Your trips in one place'), findsOneWidget);
      await tester.tap(find.text('Don\'t show tips'));
      await tester.pump();
      expect(find.textContaining('Tip:'), findsNothing);
      expect(Tips(app.store).enabled, isFalse);
    });

    testWidgets('turned off in Settings: no tip', (tester) async {
      tester.view.physicalSize = const Size(900, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: CitusmailTheme.light(),
          home: SettingsPage(services: app.services, isAndroid: false),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show tips'));
      await tester.pump();
      expect(Tips(app.store).enabled, isFalse);

      app.seedFixture(
        'people/plain-text.eml',
        subject: 'Your flight booking to Lisbon',
        uid: 70,
      );
      await showShell(tester);
      await tester.tap(find.text('Your flight booking to Lisbon'));
      await settle(tester);
      expect(find.textContaining('Tip:'), findsNothing);
    });
  });
}
