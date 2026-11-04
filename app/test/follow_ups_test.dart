// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/compose/compose_controller.dart';
import 'package:citusmail/src/compose/compose_page.dart';
import 'package:citusmail/src/mail/follow_up_times.dart';
import 'package:citusmail/src/mail/send_later_times.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import 'support/test_app.dart';

MailAddress _address(String a, [String? name]) => MailAddress(
  displayName: name,
  localPart: a.split('@').first,
  domain: a.split('@').last,
);

/// Wednesday 4 November 2026, 9:10 in the morning.
final _now = DateTime(2026, 11, 4, 9, 10);

void main() {
  late TestApp app;
  setUp(() async {
    app = await TestApp.create();
    FollowUpTimes.clock = () => _now;
    SendLaterTimes.clock = () => _now;
  });
  tearDown(() {
    FollowUpTimes.clock = DateTime.now;
    SendLaterTimes.clock = DateTime.now;
    return app.dispose();
  });

  MailStore store() => app.store;
  int accountId() => store().accounts.all().single.id;
  StoredMailbox folder(SpecialUse use) =>
      store().mailboxes.bySpecialUse(accountId(), use)!;
  StoredMailbox inbox() => store().mailboxes.inbox(accountId())!;
  FollowUpReminders followUps() => FollowUpReminders(store());

  /// Two emails Alice sent, as synced from her Sent folder.
  void seedSent() =>
      store().messages.upsertSummaries(folder(SpecialUse.sent).id, [
        MessageSummary(
          uid: 20,
          receivedAt: DateTime.utc(2026, 11, 1, 10),
          sentAt: DateTime.utc(2026, 11, 1, 10),
          subject: 'Quote for the kitchen',
          from: _address('alice@citusmail.test', 'Alice'),
          to: [_address('ana@buildright.example', 'Ana Costa')],
          messageId: 'quote.kitchen@citusmail.test',
          flags: MessageFlags.fromImap([r'\Seen']),
        ),
        MessageSummary(
          uid: 21,
          receivedAt: DateTime.utc(2026, 11, 3, 16),
          sentAt: DateTime.utc(2026, 11, 3, 16),
          subject: 'Venue for the reunion',
          from: _address('alice@citusmail.test', 'Alice'),
          to: [
            _address('ben@x.example', 'Ben Okafor'),
            _address('chloe@x.example'),
          ],
          messageId: 'reunion@citusmail.test',
          flags: MessageFlags.fromImap([r'\Seen']),
        ),
      ]);

  StoredMessage sent(String messageId) => store().messages
      .byMessageId(folder(SpecialUse.sent).id, messageId)
      .single;

  /// A follow-up on [messageId], due [due] (and back already when that is
  /// past).
  void remind(String messageId, DateTime due) {
    followUps().remind(followUps().forMessage(sent(messageId), due));
    followUps().check(now: DateTime.now());
  }

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

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
  }

  Future<void> openMessage(WidgetTester tester, String subject) async {
    await tester.tap(find.text(subject).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  group('times and words', () {
    test('1 day, 3 days, 1 week at the same time of day', () {
      final choices = FollowUpTimes.choicesFrom(DateTime(2026, 11, 4, 9, 10));
      expect(
        [for (final c in choices) c.label],
        ['In 1 day', 'In 3 days', 'In 1 week'],
      );
      expect(
        [for (final c in choices) c.at],
        [
          DateTime(2026, 11, 5, 9, 10),
          DateTime(2026, 11, 7, 9, 10),
          DateTime(2026, 11, 11, 9, 10),
        ],
      );
      // Across a month end.
      expect(
        FollowUpTimes.choicesFrom(DateTime(2026, 1, 30, 18)).last.at,
        DateTime(2026, 2, 6, 18),
      );
      expect(
        FollowUpTimes.onDay(DateTime(2026, 11, 20)),
        DateTime(2026, 11, 20, 8),
      );
    });

    test('how long ago, and the notification', () {
      final now = DateTime(2026, 11, 4, 9);
      expect(FollowUpTimes.ago(DateTime(2026, 11, 4, 7), now), 'today');
      expect(FollowUpTimes.ago(DateTime(2026, 11, 3, 23), now), 'yesterday');
      expect(FollowUpTimes.ago(DateTime(2026, 11, 1, 10), now), '3 days ago');
      expect(FollowUpTimes.ago(DateTime(2026, 10, 14), now), '3 weeks ago');
      seedSent();
      final f = followUps().forMessage(
        sent('quote.kitchen@citusmail.test'),
        DateTime.utc(2026, 11, 4),
      );
      expect(
        FollowUpWords.notification(f, now),
        'No reply from Ana Costa to “Quote for the kitchen” — sent 3 days ago',
      );
      final two = followUps().forMessage(
        sent('reunion@citusmail.test'),
        DateTime.utc(2026, 11, 4),
      );
      expect(FollowUpWords.recipients(two), 'Ben Okafor and 1 other');
    });
  });

  testWidgets('on a sent email: Remind me if no reply, with Undo', (
    tester,
  ) async {
    seedSent();
    await show(tester);
    expect(find.text('Waiting for a reply'), findsNothing);
    await tester.tap(find.text('Sent').first);
    await settle(tester);
    await openMessage(tester, 'Quote for the kitchen');
    await tester.tap(find.byTooltip('Remind me if no reply'));
    await settle(tester);

    expect(find.byType(Dialog), findsOneWidget, reason: 'desktop: a dialog');
    String trailing(String kind) => tester
        .widget<Text>(
          find
              .descendant(
                of: find.byKey(ValueKey('follow-up-$kind')),
                matching: find.byType(Text),
              )
              .last,
        )
        .data!;
    expect(trailing('oneDay'), 'Thu 9:10 AM');
    expect(trailing('threeDays'), 'Sat 9:10 AM');
    expect(trailing('oneWeek'), 'Nov 11, 9:10 AM');
    expect(find.text('Pick a date'), findsOneWidget);
    expect(find.text('Don\'t remind me'), findsNothing);
    expect(
      find.textContaining('out-of-office replies don\'t count'),
      findsOneWidget,
    );

    await tester.tap(find.text('In 3 days'));
    await settle(tester);
    expect(
      find.text('Reminds you Sat 9:10 AM if no reply'),
      findsWidgets,
      reason: 'the notice and the note in the reader',
    );
    final f = followUps().find('quote.kitchen@citusmail.test')!;
    expect(f.due, DateTime(2026, 11, 7, 9, 10).toUtc());
    expect(f.recipients.single.address, 'ana@buildright.example');
    expect(find.text('Waiting for a reply'), findsOneWidget);
    // Nothing goes to the server.
    expect(store().outbox.all(accountId()), isEmpty);

    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect(followUps().all(), isEmpty);
    expect(find.text('Waiting for a reply'), findsNothing);
  });

  testWidgets('change or cancel it from the reader', (tester) async {
    seedSent();
    remind('quote.kitchen@citusmail.test', DateTime(2026, 12, 1, 9));
    await show(tester);
    await tester.tap(find.text('Sent').first);
    await settle(tester);
    await openMessage(tester, 'Quote for the kitchen');
    expect(find.text('Reminds you Dec 1, 9:00 AM if no reply'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Change'));
    await settle(tester);
    expect(find.text('Set for Dec 1, 9:00 AM'), findsOneWidget);
    await tester.tap(find.text('In 1 day'));
    await settle(tester);
    expect(
      followUps().find('quote.kitchen@citusmail.test')!.due,
      DateTime(2026, 11, 5, 9, 10).toUtc(),
    );

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await settle(tester);
    expect(followUps().all(), isEmpty);
    expect(find.text('Reminder cancelled'), findsOneWidget);
  });

  testWidgets('no reply in time: back at the top of the inbox, then Done', (
    tester,
  ) async {
    seedSent();
    remind(
      'quote.kitchen@citusmail.test',
      DateTime.now().subtract(const Duration(hours: 1)),
    );
    await show(tester);
    await settle(tester);

    expect(find.text('No reply yet'), findsWidgets);
    expect(find.text('To Ana Costa'), findsOneWidget);
    expect(find.text('Sent 3 days ago'), findsOneWidget);
    // Above the rest of the inbox.
    final top = tester.getTopLeft(find.text('Quote for the kitchen')).dy;
    expect(top, lessThan(tester.getTopLeft(find.text('Hello there')).dy));

    // Opens the sent message, with the same note.
    await openMessage(tester, 'Quote for the kitchen');
    expect(find.widgetWithText(TextButton, 'Remind me again'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Done').first);
    await settle(tester);
    expect(followUps().all(), isEmpty);
    expect(find.text('To Ana Costa'), findsNothing);
    expect(find.text('Marked done'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect(followUps().returned(), hasLength(1));
    expect(find.text('To Ana Costa'), findsOneWidget);
  });

  testWidgets('Waiting for a reply lists every reminder, each can go', (
    tester,
  ) async {
    seedSent();
    remind(
      'quote.kitchen@citusmail.test',
      DateTime.now().subtract(const Duration(hours: 1)),
    );
    remind('reunion@citusmail.test', DateTime(2026, 11, 6, 16));
    await show(tester);
    await tester.tap(find.text('Waiting for a reply'));
    await settle(tester);

    expect(find.text('To Ana Costa'), findsOneWidget);
    expect(find.text('To Ben Okafor and 1 other'), findsOneWidget);
    expect(find.text('Reminds you Fri 4:00 PM if no reply'), findsOneWidget);
    expect(find.text('Waiting'), findsOneWidget);
    expect(find.textContaining('A reply in the conversation'), findsOneWidget);

    // Cancel the waiting one.
    await tester.tap(find.byTooltip('Cancel reminder'));
    await settle(tester);
    expect(followUps().waiting(), isEmpty);
    expect(find.text('To Ben Okafor and 1 other'), findsNothing);

    // "Not needed" for the one back.
    await tester.tap(find.byTooltip('Reminder options'));
    await settle(tester);
    await tester.tap(find.text('Not needed'));
    await settle(tester);
    expect(followUps().all(), isEmpty);
    expect(
      find.textContaining('Nothing is waiting for a reply'),
      findsOneWidget,
    );
  });

  testWidgets('a reply ends it quietly; an out-of-office does not', (
    tester,
  ) async {
    seedSent();
    remind('quote.kitchen@citusmail.test', DateTime(2026, 12, 1));
    store().messages.upsertSummaries(inbox().id, [
      MessageSummary(
        uid: 40,
        receivedAt: DateTime.utc(2026, 11, 2, 8),
        subject: 'Automatic reply: Quote for the kitchen',
        from: _address('ana@buildright.example', 'Ana Costa'),
        inReplyTo: 'quote.kitchen@citusmail.test',
        headers: {
          'auto-submitted': ['auto-replied'],
        },
      ),
    ]);
    await show(tester);
    await settle(tester);
    expect(followUps().waiting(), hasLength(1));
    expect(find.text('Waiting for a reply'), findsOneWidget);

    store().messages.upsertSummaries(inbox().id, [
      MessageSummary(
        uid: 41,
        receivedAt: DateTime.utc(2026, 11, 3, 8),
        subject: 'RE: Quote for the kitchen',
        from: _address('ana@buildright.example', 'Ana Costa'),
        inReplyTo: 'quote.kitchen@citusmail.test',
        references: ['quote.kitchen@citusmail.test'],
      ),
    ]);
    // Checked again when the app comes back to the front (as after a
    // sync): the reply ends it, without a word.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect(followUps().all(), isEmpty);
    expect(find.text('Waiting for a reply'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('on a phone: from the reader, as a bottom sheet', (tester) async {
    seedSent();
    await show(tester, size: const Size(400, 800));
    await tester.tap(find.byTooltip('Folders'));
    await settle(tester);
    await tester.tap(find.text('Sent').first);
    await settle(tester);
    await openMessage(tester, 'Venue for the reunion');
    // In the bottom bar, beside Archive.
    await tester.tap(find.byTooltip('Remind me if no reply'));
    await settle(tester);
    expect(find.byType(BottomSheet), findsOneWidget);
    await tester.tap(find.text('In 1 week'));
    await settle(tester);
    expect(followUps().waiting().single.messageId, 'reunion@citusmail.test');
  });

  group('compose', () {
    Finder field(String hint) => find.widgetWithText(TextField, hint);
    Finder toField() => find
        .descendant(
          of: find.byType(ComposePage),
          matching: find.byType(TextField),
        )
        .first;

    Future<void> write(WidgetTester tester) async {
      await tester.tap(find.byTooltip('New message (C)'));
      await tester.pumpAndSettle();
      await tester.enterText(toField(), 'ana@buildright.example,');
      await tester.enterText(field('Subject'), 'Quote for the kitchen');
      await tester.enterText(field('Write your message'), 'Could you send it?');
    }

    String queuedId() => const MimeParser()
        .parse(store().outbox.sends().single.data!)
        .messageId!;

    testWidgets('a toggle next to Send; Undo takes the reminder back too', (
      tester,
    ) async {
      await show(tester);
      await write(tester);
      await tester.tap(find.byTooltip('Remind me if no reply'));
      await settle(tester);
      expect(find.text('Remind me if no reply'), findsOneWidget);
      await tester.tap(find.text('In 3 days'));
      await settle(tester);
      expect(
        find.byTooltip('Reminds you Sat 9:10 AM if no reply (tap to change)'),
        findsOneWidget,
      );
      // Changed my mind, then on again.
      await tester.tap(find.byKey(const ValueKey('compose-follow-up')));
      await settle(tester);
      await tester.tap(find.text('Don\'t remind me'));
      await settle(tester);
      expect(find.byTooltip('Remind me if no reply'), findsOneWidget);
      await tester.tap(find.byTooltip('Remind me if no reply'));
      await settle(tester);
      await tester.tap(find.text('In 3 days'));
      await settle(tester);

      await tester.tap(find.text('Send'));
      await settle(tester);
      expect(find.byType(ComposePage), findsNothing);
      expect(find.textContaining('Sending… Reminds you'), findsOneWidget);
      final f = followUps().waiting().single;
      expect(f.messageId, queuedId());
      expect(f.subject, 'Quote for the kitchen');
      expect(f.recipients.single.address, 'ana@buildright.example');
      expect(FollowUpTimes.daysBetween(f.sentAt, f.due), 3);
      expect(find.text('Waiting for a reply'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await settle(tester);
      expect(followUps().all(), isEmpty);
      await tester.pump(ComposeController.autosaveDelay);
    });

    testWidgets('with Send later, it counts from when the email goes out', (
      tester,
    ) async {
      await show(tester);
      await write(tester);
      await tester.tap(find.byTooltip('Remind me if no reply'));
      await settle(tester);
      await tester.tap(find.text('In 1 day'));
      await settle(tester);
      await tester.tap(find.byTooltip('Send later'));
      await settle(tester);
      await tester.tap(find.text('Tomorrow morning'));
      await settle(tester);

      // Thursday 8:00, then a day later.
      var f = followUps().waiting().single;
      expect(f.sentAt, DateTime(2026, 11, 5, 8).toUtc());
      expect(f.due, DateTime(2026, 11, 6, 8).toUtc());
      expect(f.messageId, queuedId());

      // Moved to Monday in the Outbox: the reminder moves with it.
      await tester.pump(const Duration(seconds: 6));
      await tester.tap(find.text('Outbox'));
      await settle(tester);
      await tester.tap(find.byTooltip('Scheduled message options'));
      await settle(tester);
      await tester.tap(find.text('Change time'));
      await settle(tester);
      await tester.tap(find.text('Monday morning'));
      await settle(tester);
      f = followUps().waiting().single;
      expect(f.messageId, queuedId());
      expect(f.sentAt, DateTime(2026, 11, 9, 8).toUtc());
      expect(f.due, DateTime(2026, 11, 10, 8).toUtc());

      // Not sent after all: no reminder.
      await tester.tap(find.byTooltip('Scheduled message options'));
      await settle(tester);
      await tester.tap(find.text('Cancel sending'));
      await settle(tester);
      expect(followUps().all(), isEmpty);
    });
  });
}
