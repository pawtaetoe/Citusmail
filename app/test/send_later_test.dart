// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/compose/compose_controller.dart';
import 'package:citusmail/src/compose/compose_page.dart';
import 'package:citusmail/src/mail/send_later_times.dart';
import 'package:citusmail/src/services/mail_notices.dart';
import 'package:citusmail/src/services/mail_notifier.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_compose/mail_compose.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

/// Records what would be posted, instead of the system.
final class _FakePlugin implements FlutterLocalNotificationsPlugin {
  final shown = <({int id, String? title, String? body})>[];

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async => shown.add((id: id, title: title, body: body));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Wednesday 4 November 2026, 9:10 in the morning.
final _now = DateTime(2026, 11, 4, 9, 10);
final _thursday8 = DateTime(2026, 11, 5, 8);

void main() {
  group('the choices', () {
    List<(String, DateTime)> at(DateTime now) => [
      for (final c in SendLaterTimes.choicesAt(now)) (c.label, c.at),
    ];

    test('on a Wednesday morning: tomorrow 8 and 1, and Monday', () {
      expect(at(_now), [
        ('Tomorrow morning', _thursday8),
        ('Tomorrow afternoon', DateTime(2026, 11, 5, 13)),
        ('Monday morning', DateTime(2026, 11, 9, 8)),
      ]);
    });

    test('on a Sunday, Monday morning is tomorrow morning: offered once', () {
      expect(at(DateTime(2026, 11, 8, 10)), [
        ('Tomorrow morning', DateTime(2026, 11, 9, 8)),
        ('Tomorrow afternoon', DateTime(2026, 11, 9, 13)),
      ]);
    });

    test('not on a Monday morning; on a Monday afternoon, next week', () {
      expect(
        at(DateTime(2026, 11, 9, 9)).map((c) => c.$1),
        isNot(contains('Monday morning')),
      );
      expect(at(DateTime(2026, 11, 9, 15)).last, (
        'Monday morning',
        DateTime(2026, 11, 16, 8),
      ));
    });

    test('in the small hours, "tomorrow" is the day starting', () {
      expect(at(DateTime(2026, 11, 4, 1, 30)).take(2), [
        ('This morning', DateTime(2026, 11, 4, 8)),
        ('This afternoon', DateTime(2026, 11, 4, 13)),
      ]);
    });

    test('late on a Friday, and across the end of the month', () {
      expect(at(DateTime(2026, 10, 30, 23, 50)), [
        ('Tomorrow morning', DateTime(2026, 10, 31, 8)),
        ('Tomorrow afternoon', DateTime(2026, 10, 31, 13)),
        ('Monday morning', DateTime(2026, 11, 2, 8)),
      ]);
    });
  });

  group('in the app', () {
    late TestApp app;
    setUp(() async {
      app = await TestApp.create();
      SendLaterTimes.clock = () => _now;
    });
    tearDown(() {
      SendLaterTimes.clock = DateTime.now;
      return app.dispose();
    });

    MailStore store() => app.store;
    int accountId() => store().accounts.all().single.id;

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

    Finder field(String hint) => find.widgetWithText(TextField, hint);
    Finder toField() => find
        .descendant(
          of: find.byType(ComposePage),
          matching: find.byType(TextField),
        )
        .first;

    /// A message scheduled for Thursday 8:00, as if from the compose
    /// window.
    ScheduledSend scheduleOne({String subject = 'Quarterly numbers'}) {
      app.services.sender.schedule(
        Draft(
          accountId: accountId(),
          to: [const MailAddress(localPart: 'bob', domain: 'x.example')],
          subject: subject,
          body: 'Here they are, as promised.',
        ),
        _thursday8,
        now: _now,
      );
      return ScheduledSends(
        store(),
        app.services.sender,
      ).all().firstWhere((s) => s.entry.data != null);
    }

    Future<void> openOutbox(WidgetTester tester) async {
      await show(tester);
      await tester.tap(find.text('Outbox'));
      await settle(tester);
    }

    Future<void> chooseInMenu(WidgetTester tester, String item) async {
      await tester.tap(find.byTooltip('Scheduled message options'));
      await settle(tester);
      await tester.tap(find.text(item));
      await settle(tester);
    }

    testWidgets('compose: Send later shows each time, then it waits in the '
        'Outbox', (tester) async {
      await show(tester);
      await tester.tap(find.byTooltip('New message (C)'));
      await tester.pumpAndSettle();
      await tester.enterText(toField(), 'bob@x.example,');
      await tester.enterText(field('Subject'), 'Quarterly numbers');
      await tester.enterText(field('Write your message'), 'Here they are.');
      await tester.tap(find.byTooltip('Send later'));
      await settle(tester);

      expect(find.text('Send later'), findsWidgets);
      String trailing(String kind) => tester
          .widget<Text>(
            find
                .descendant(
                  of: find.byKey(ValueKey('send-later-$kind')),
                  matching: find.byType(Text),
                )
                .last,
          )
          .data!;
      expect(trailing('morning'), 'Thu 8:00 AM');
      expect(trailing('afternoon'), 'Thu 1:00 PM');
      expect(trailing('monday'), 'Mon 8:00 AM');
      expect(find.text('Pick date & time'), findsOneWidget);
      expect(
        find.textContaining('it will send when Citusmail next runs'),
        findsOneWidget,
      );

      await tester.tap(find.text('Tomorrow morning'));
      await settle(tester);
      expect(find.byType(ComposePage), findsNothing, reason: 'window closed');
      expect(
        find.text('Sends Thu 8:00 AM. It waits in your Outbox.'),
        findsOneWidget,
      );
      final queued = store().outbox.sends().single;
      final schedule = (queued.action as SendAction).schedule!;
      expect(schedule.at, _thursday8.toUtc());
      expect(queued.notBefore, _thursday8.toUtc());
      expect(
        const MimeParser().parse(queued.data!).subject,
        'Quarterly numbers',
      );
    });

    testWidgets('a long press on Send offers the times too', (tester) async {
      await show(tester, size: const Size(400, 800));
      await tester.tap(find.byTooltip('New message (C)'));
      await tester.pumpAndSettle();
      await tester.enterText(toField(), 'bob@x.example,');
      await tester.longPress(find.text('Send'));
      await settle(tester);
      expect(find.byType(BottomSheet), findsOneWidget, reason: 'phone: sheet');
      expect(find.text('Tomorrow afternoon'), findsOneWidget);
      expect(find.textContaining('on this phone'), findsOneWidget);
      await tester.pump(ComposeController.autosaveDelay);
    });

    testWidgets('Send later needs a recipient first', (tester) async {
      await show(tester);
      await tester.tap(find.byTooltip('New message (C)'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Subject'), 'Nobody yet');
      await tester.tap(find.byTooltip('Send later'));
      await settle(tester);
      expect(find.text('Tomorrow morning'), findsNothing);
      expect(find.text('Add at least one recipient.'), findsOneWidget);
      expect(store().outbox.sends(), isEmpty);
      await tester.pump(ComposeController.autosaveDelay);
    });

    testWidgets('the Outbox shows when it sends, and the honest note '
        '(Android: the background check sends it)', (tester) async {
      scheduleOne();
      await openOutbox(tester);
      expect(find.text('Quarterly numbers'), findsOneWidget);
      expect(find.textContaining('Sends Thu 8:00 AM'), findsOneWidget);
      expect(
        find.textContaining('a message will send when Citusmail next runs'),
        findsOneWidget,
      );
      expect(find.textContaining('stay on this phone'), findsOneWidget);
      expect(find.textContaining('in the background too'), findsOneWidget);
    });

    testWidgets('on a computer, the note says the app must be running', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      scheduleOne();
      await openOutbox(tester);
      expect(find.textContaining('stay on this device'), findsOneWidget);
      expect(
        find.textContaining('Citusmail needs to be running at that time'),
        findsOneWidget,
      );
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Send now: an ordinary send at once', (tester) async {
      scheduleOne();
      await openOutbox(tester);
      await chooseInMenu(tester, 'Send now');
      expect(find.text('Sending…'), findsOneWidget);
      final send = store().outbox.sends().single;
      expect((send.action as SendAction).schedule, isNull);
      expect(send.notBefore.isBefore(_thursday8), isTrue);
    });

    testWidgets('Change time: to Monday morning', (tester) async {
      scheduleOne();
      await openOutbox(tester);
      await chooseInMenu(tester, 'Change time');
      expect(find.text('Change send time'), findsOneWidget);
      expect(find.text('Set for Thu 8:00 AM'), findsOneWidget);
      await tester.tap(find.text('Monday morning'));
      await settle(tester);
      expect(find.text('Sends Mon 8:00 AM'), findsWidgets);
      final s = ScheduledSends(store(), app.services.sender).all().single;
      expect(s.at, DateTime(2026, 11, 9, 8).toUtc());
      expect(store().outbox.sends(), hasLength(1));
    });

    testWidgets('Edit: back in the compose window, no longer scheduled', (
      tester,
    ) async {
      scheduleOne();
      await openOutbox(tester);
      await chooseInMenu(tester, 'Edit');
      expect(find.byType(ComposePage), findsOneWidget);
      final body = tester.widget<TextField>(field('Write your message'));
      expect(body.controller!.text, 'Here they are, as promised.');
      expect(store().outbox.sends(), isEmpty);
      expect(store().drafts.all(), hasLength(1), reason: 'kept as a draft');
    });

    testWidgets('Cancel: to Drafts, not sent', (tester) async {
      scheduleOne();
      await openOutbox(tester);
      await chooseInMenu(tester, 'Cancel sending');
      expect(find.text('It won\'t be sent. It\'s in Drafts.'), findsOneWidget);
      expect(store().outbox.sends(), isEmpty);
      final append = store().outbox
          .all(accountId())
          .singleWhere((e) => e.action is AppendAction);
      expect(
        const MimeParser().parse(append.data!).subject,
        'Quarterly numbers',
      );
    });

    testWidgets('a failed scheduled send: Try again in the Outbox', (
      tester,
    ) async {
      final s = scheduleOne();
      store().outbox.markFailed(s.entry.id, '550 mailbox unavailable');
      await openOutbox(tester);
      expect(find.textContaining('550 mailbox unavailable'), findsOneWidget);
      expect(find.byTooltip('Scheduled message options'), findsNothing);
      await tester.tap(find.byTooltip('Try again'));
      await tester.pump();
      expect(store().outbox.byId(s.entry.id)!.state, OutboxState.pending);
    });

    test('a failed scheduled send: one quiet notification', () async {
      final s = scheduleOne();
      final plugin = _FakePlugin();
      final notifier = MailNotifier.forTesting(plugin, NoticeLayout.grouped);
      await notifier.announceFailedSends(store());
      expect(plugin.shown, isEmpty, reason: 'nothing failed yet');

      store().outbox.markFailed(s.entry.id, '550 mailbox unavailable');
      await notifier.announceFailedSends(store());
      await notifier.announceFailedSends(store());
      expect(plugin.shown, hasLength(1), reason: 'once');
      expect(plugin.shown.single.title, 'A scheduled email wasn\'t sent');
      expect(plugin.shown.single.body, contains('Quarterly numbers'));
    });
  });
}
