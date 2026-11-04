// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/services/app_settings.dart';
import 'package:citusmail/src/services/mail_notices.dart';
import 'package:citusmail/src/services/mail_notifier.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/snooze_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
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

/// Records what would be posted, instead of the system.
final class _FakePlugin implements FlutterLocalNotificationsPlugin {
  final shown = <({int id, String? title, String? body, String? payload})>[];

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async => shown.add((id: id, title: title, body: body, payload: payload));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Wednesday 4 November 2026, 9:10 in the morning.
final _now = DateTime(2026, 11, 4, 9, 10);

void main() {
  late TestApp app;
  setUp(() async {
    app = await TestApp.create();
    SnoozeSheet.clock = () => _now;
  });
  tearDown(() {
    SnoozeSheet.clock = DateTime.now;
    return app.dispose();
  });

  MailStore store() => app.store;
  int accountId() => store().accounts.all().single.id;
  StoredMailbox inbox() => store().mailboxes.inbox(accountId())!;
  StoredMessage message(String subject) => store().messages
      .list(MessageQuery(mailboxIds: [inbox().id], limit: 100))
      .followedBy(
        store().messages.list(
          MessageQuery(
            mailboxIds: [inbox().id],
            section: SmartSection.snoozed,
            limit: 100,
          ),
        ),
      )
      .firstWhere((m) => m.subject == subject);

  /// Two emails that can be snoozed (they have a Message-ID).
  void seed() => store().messages.upsertSummaries(inbox().id, [
    MessageSummary(
      uid: 30,
      receivedAt: DateTime.utc(2026, 10, 20, 8),
      subject: 'Draft contract for review',
      from: _address('maria@studio.example', 'Maria Lopez'),
      snippet: 'Could you look at clause 4 before Friday?',
      messageId: 'contract@studio.example',
      flags: MessageFlags.fromImap([r'\Seen']),
    ),
    MessageSummary(
      uid: 31,
      receivedAt: DateTime.utc(2026, 10, 20, 7),
      subject: 'Team offsite agenda',
      from: _address('tom@studio.example', 'Tom Baker'),
      messageId: 'offsite@studio.example',
    ),
  ]);

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

  /// Lets dialogs and sheets animate (an open message that isn't
  /// downloaded keeps a spinner going, so nothing ever settles).
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
  }

  Future<void> openMessage(WidgetTester tester, String subject) async {
    await tester.tap(find.text(subject).first);
    // Not downloaded (offline): the reader keeps trying, so no settling.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('the sheet shows each choice with its time, and the small '
      'print', (tester) async {
    seed();
    await show(tester);
    await openMessage(tester, 'Draft contract for review');
    await tester.tap(find.byTooltip('Snooze (B)'));
    await settle(tester);

    expect(find.byType(Dialog), findsOneWidget, reason: 'desktop: a dialog');
    expect(find.text('Snooze until…'), findsOneWidget);
    Finder row(String kind) => find.byKey(ValueKey('snooze-$kind'));
    String trailing(String kind) => tester
        .widget<Text>(
          find.descendant(of: row(kind), matching: find.byType(Text)).last,
        )
        .data!;
    expect(trailing('laterToday'), '12:15 PM');
    expect(trailing('tonight'), '8:00 PM');
    expect(trailing('tomorrow'), 'Thu 8:00 AM');
    expect(trailing('weekend'), 'Sat 9:00 AM');
    expect(trailing('nextWeek'), 'Mon 8:00 AM');
    expect(find.text('Pick date & time'), findsOneWidget);
    expect(
      find.textContaining('other mail apps still show it'),
      findsOneWidget,
    );
  });

  testWidgets('snoozing hides the message, with Undo; the Snoozed list '
      'shows when it comes back', (tester) async {
    seed();
    await show(tester);
    expect(find.text('Snoozed'), findsNothing, reason: 'nothing snoozed yet');
    await openMessage(tester, 'Draft contract for review');
    await tester.tap(find.byTooltip('Snooze (B)'));
    await settle(tester);
    await tester.tap(find.text('Tomorrow'));
    await tester.pump();

    expect(find.text('Snoozed until Tomorrow 8:00 AM'), findsOneWidget);
    expect(find.text('Draft contract for review'), findsNothing);
    expect(
      store().snoozes.find('contract@studio.example')!.until,
      DateTime(2026, 11, 5, 8).toUtc(),
    );
    // Nothing moves on the server (the next message opened, so it is
    // marked read there).
    expect(
      store().outbox.all(accountId()).map((e) => e.action),
      everyElement(isA<SetFlagsAction>()),
    );

    // Undo brings it back.
    await settle(tester);
    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect(find.text('Draft contract for review'), findsOneWidget);
    expect(store().snoozes.all(), isEmpty);

    // Snoozed again by keyboard (B), then the Snoozed list.
    await openMessage(tester, 'Draft contract for review');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await settle(tester);
    await tester.tap(find.text('This weekend'));
    await settle(tester);
    await tester.tap(find.text('Snoozed'));
    await settle(tester);
    expect(find.text('Draft contract for review'), findsOneWidget);
    expect(find.text('Sat 9:00 AM'), findsOneWidget);
    expect(find.textContaining('Each comes back to the top'), findsOneWidget);
  });

  testWidgets('from the Snoozed list: change the time, then unsnooze', (
    tester,
  ) async {
    seed();
    store().snoozes.snooze('contract@studio.example', DateTime(2026, 11, 5, 8));
    await show(tester);
    await tester.tap(find.text('Snoozed'));
    await settle(tester);
    await openMessage(tester, 'Draft contract for review');
    expect(find.text('Snoozed until Tomorrow 8:00 AM'), findsOneWidget);

    await tester.tap(find.text('Change time'));
    await settle(tester);
    expect(find.text('Change snooze time'), findsOneWidget);
    expect(find.text('Now coming back Tomorrow 8:00 AM'), findsOneWidget);
    await tester.tap(find.text('Next week'));
    await settle(tester);
    expect(find.text('Snoozed until Mon 8:00 AM'), findsWidgets);
    expect(store().snoozes.all(), hasLength(1));

    await tester.tap(find.widgetWithText(TextButton, 'Unsnooze'));
    await settle(tester);
    expect(store().snoozes.all(), isEmpty);
    expect(find.text('Unsnoozed'), findsOneWidget);
    expect(find.textContaining('Nothing is snoozed'), findsOneWidget);
    // Back where it was (not as new) in the inbox.
    final back = message('Draft contract for review');
    expect(back.section, isNot(SmartSection.snoozed));
    expect(back.backFromSnooze, isFalse);
  });

  testWidgets('on a phone: from the bottom bar, as a bottom sheet', (
    tester,
  ) async {
    seed();
    await show(tester, size: const Size(400, 800));
    await openMessage(tester, 'Team offsite agenda');
    await tester.tap(find.byTooltip('Snooze (B)'));
    await settle(tester);
    expect(find.byType(BottomSheet), findsOneWidget);
    await tester.tap(find.text('Tonight'));
    await tester.pump();
    expect(find.text('Snoozed until 8:00 PM'), findsOneWidget);
    expect(message('Team offsite agenda').section, SmartSection.snoozed);
  });

  testWidgets('selected messages are snoozed together', (tester) async {
    seed();
    await show(tester);
    await tester.longPress(find.text('Draft contract for review'));
    await tester.pump();
    await tester.longPress(find.text('Team offsite agenda'));
    await tester.pump();
    await tester.tap(find.byTooltip('Snooze (B)'));
    await settle(tester);
    await tester.tap(find.text('Tomorrow'));
    await tester.pump();
    expect(find.text('Snoozed 2 until Tomorrow 8:00 AM'), findsOneWidget);
    expect(store().snoozes.all(), hasLength(2));
  });

  testWidgets('due mail comes back to the top, unread, with a badge', (
    tester,
  ) async {
    seed();
    store().snoozes.snooze(
      'contract@studio.example',
      DateTime.now().subtract(const Duration(minutes: 1)),
    );
    await show(tester);
    await settle(tester);

    final back = message('Draft contract for review');
    expect(back.section, isNot(SmartSection.snoozed));
    expect(back.flags.seen, isFalse);
    expect(back.backFromSnooze, isTrue);
    final queued = store().outbox.all(accountId()).single.action;
    expect((queued as SetFlagsAction).remove, [r'\Seen']);
    expect(find.text('Snoozed'), findsOneWidget, reason: 'the badge');
    // At the top of the inbox, before newer mail.
    final top = tester.getTopLeft(find.text('Draft contract for review')).dy;
    expect(top, lessThan(tester.getTopLeft(find.text('Hello there')).dy));

    await openMessage(tester, 'Draft contract for review');
    expect(find.textContaining('Back from snooze'), findsOneWidget);
  });

  group('notifications', () {
    StoredMessage woken() {
      seed();
      store().snoozes.snooze('contract@studio.example', DateTime.utc(2026));
      return store().snoozes.wake().single.message;
    }

    test('one per message: sender and subject, with a preview', () async {
      final m = woken();
      final plugin = _FakePlugin();
      final notifier = MailNotifier.forTesting(plugin, NoticeLayout.separate);
      await notifier.announceBackFromSnooze(
        store(),
        BackFromSnooze([
          WokenMessage(m, WakeReason.due, DateTime.utc(2026)),
        ], const {}),
      );
      final shown = plugin.shown.single;
      expect(shown.title, 'Back from snooze: Maria Lopez');
      expect(
        shown.body,
        'Draft contract for review\nCould you look at clause 4 before Friday?',
      );
      expect(shown.payload, 'message:${m.id}');
    });

    test('previews off, and the app lock', () async {
      final m = woken();
      AppSettings(store()).notificationPreviews = false;
      expect(
        MailNotices.backFromSnooze(m, previews: false).text,
        'Draft contract for review',
      );
      store().settings.write('lock.enabled', 'on');
      final plugin = _FakePlugin();
      await MailNotifier.forTesting(
        plugin,
        NoticeLayout.grouped,
      ).announceBackFromSnooze(
        store(),
        BackFromSnooze([
          WokenMessage(m, WakeReason.due, DateTime.utc(2026)),
        ], const {}),
      );
      expect(plugin.shown.single.title, 'A snoozed email is back');
      expect(plugin.shown.single.body, 'Unlock Citusmail to read it.');
      expect(plugin.shown.single.payload, isNull);
    });

    test('snoozed mail never notifies as new mail', () {
      seed();
      final m = message('Team offsite agenda');
      store().snoozes.snooze(m.messageId!, DateTime.utc(2030));
      final account = store().accounts.byId(accountId())!;
      final notices = MailNotices.build(
        account,
        NewMail(accountId(), [message('Team offsite agenda')], total: 1),
        layout: NoticeLayout.separate,
      );
      expect(notices, isEmpty);
    });
  });
}
