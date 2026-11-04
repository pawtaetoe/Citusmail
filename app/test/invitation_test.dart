// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/mail/invitation_answers.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_view/mail_view.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;

  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  Future<void> show(
    WidgetTester tester, {
    Size size = const Size(1400, 900),
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

  Future<void> open(WidgetTester tester, String subject) async {
    await tester.tap(find.text(subject).first);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }

  void seed(String fixture, String subject, int uid) => app.seedFixture(
    '../invites/$fixture',
    subject: subject,
    uid: uid,
    receivedAt: DateTime.now().toUtc(),
  );

  testWidgets('accepting sends a REPLY to the organizer only, with undo', (
    tester,
  ) async {
    seed('outlook-teams-request.eml', 'Q4 roadmap review', 70);
    await show(tester);
    await open(tester, 'Q4 roadmap review');

    expect(find.text('Invitation'), findsOneWidget);
    expect(find.textContaining('Thu, 12 Nov'), findsOneWidget);
    expect(
      find.text('Room 4.12 (Lisbon); Microsoft Teams Meeting'),
      findsOneWidget,
    );
    expect(find.text('Ana Lima invited you and 2 others'), findsOneWidget);
    expect(find.text('Join on Teams'), findsOneWidget);
    expect(find.text('You accepted'), findsNothing);
    // Nothing is sent just by reading.
    expect(app.store.outbox.sends(), isEmpty);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Accept'));
    await tester.pump();
    expect(find.text('You accepted'), findsOneWidget);
    expect(find.text('Accepted. Telling Ana Lima…'), findsOneWidget);

    final queued = app.store.outbox.sends().single;
    final action = queued.action as SendAction;
    expect(action.recipients, ['ana.lima@contoso.example']);
    expect(queued.notBefore.isAfter(DateTime.now()), isTrue, reason: 'undo');
    final sent = const MimeParser().parse(queued.data!);
    expect(sent.subject, 'Accepted: Q4 roadmap review');
    final calendar = sent.root.allParts.firstWhere(
      (p) => p.contentType.mimeType == 'text/calendar',
    );
    expect(calendar.contentType.parameters['method'], 'REPLY');
    final reply = CalendarInvite.parse(calendar.decodeText().text)!;
    expect(reply.method, CalendarMethod.reply);
    expect(reply.attendees.single.email, 'alice@citusmail.test');
    expect(reply.attendees.single.answer, CalendarAnswer.accepted);
    expect(
      app.store.settings.read(InvitationAnswers.key),
      contains('#2":"ACCEPTED"'),
    );

    // Undo takes the answer back, and the card forgets it.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(app.store.outbox.sends(), isEmpty);
    expect(app.store.drafts.all(), isEmpty, reason: 'not kept as a draft');
    expect(find.text('You accepted'), findsNothing);
  });

  testWidgets('a note goes with the answer; the answer is remembered', (
    tester,
  ) async {
    seed('all-day-request.eml', 'Team offsite', 71);
    await show(tester, size: const Size(390, 844));
    await open(tester, 'Team offsite');
    // The file says Alice already accepted.
    expect(find.text('You accepted'), findsOneWidget);
    expect(find.text('Thu, 10 Dec – Fri, 11 Dec · All day'), findsOneWidget);

    await tester.ensureVisible(find.text('Add a note'));
    await tester.tap(find.text('Add a note'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      'Away that week, sorry!',
    );
    await tester.tap(find.widgetWithText(OutlinedButton, 'Decline').last);
    await tester.pump();
    expect(find.text('You declined'), findsOneWidget);
    final sent = const MimeParser().parse(
      app.store.outbox.sends().single.data!,
    );
    expect(sent.to.single.address, 'dana@friends.example');
    expect(sent.subject, startsWith('Declined: Team offsite'));
    expect(
      sent.textBody!.decodeText().text,
      contains('Away that week, sorry!'),
    );
  });

  testWidgets(
    'cancellations and answers show what happened, nothing to answer',
    (tester) async {
      seed('outlook-cancel.eml', 'Canceled: Budget planning', 72);
      seed('google-reply-accepted.eml', 'Accepted: Coffee chat', 73);
      await show(tester);
      await open(tester, 'Canceled: Budget planning');
      expect(find.text('This event was cancelled'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Accept'), findsNothing);

      await open(tester, 'Accepted: Coffee chat');
      expect(find.text('Answer to your invitation'), findsOneWidget);
      expect(find.text('Bob accepted'), findsOneWidget);
      expect(find.text('“See you there!”'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Accept'), findsNothing);
      expect(app.store.outbox.sends(), isEmpty);
    },
  );

  testWidgets('a webinar with no guest list can only be saved', (tester) async {
    seed('zoom-webinar.eml', 'Privacy by design', 74);
    await show(tester);
    await open(tester, 'Privacy by design');
    expect(find.text('Event'), findsOneWidget);
    expect(find.text('Join on Zoom'), findsOneWidget);
    expect(find.text('Save .ics'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Accept'), findsNothing);
  });
}
