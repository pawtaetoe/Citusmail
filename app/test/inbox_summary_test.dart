// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:ui' show SemanticsRole;

import 'package:citusmail/src/mail/inbox_summary.dart';
import 'package:citusmail/src/ui/appointment_detail_page.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/deliveries_page.dart';
import 'package:citusmail/src/ui/inbox_summary_line.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

import 'support/appointment_mail.dart';
import 'support/test_app.dart';
import 'support/today_mail.dart';

/// Today at 9 in the morning, on this device's clock.
final _now = () {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day, 9);
}();

Delivery _parcel(String key) => Delivery(
  key: key,
  shop: 'shop.example',
  shopName: 'Shop',
  records: const [],
  status: DeliveryStatus.outForDelivery,
);

/// A dentist on [_now]'s day (found as the page finds it).
Appointment _dentist({String time = '3.30pm'}) => AppointmentFinder.find([
  AppointmentEmail(
    messageId: 1,
    sender: 'brightsmiledental.co.uk',
    senderName: 'Bright Smile Dental',
    subject: 'Appointment confirmation - Bright Smile Dental',
    text:
        'Dear Alice, this is to confirm your appointment with Dr Patel '
        'on ${appointmentDayText(_now, 0)} at $time.',
    at: _now.subtract(const Duration(days: 3)),
  ),
]).single;

/// A table at [hour] on [_now]'s day.
Booking _table(int hour) => TripFinder.bookings([
  TripEmail(
    messageId: 2,
    sender: 'burntends.com.sg',
    senderName: 'Burnt Ends',
    subject: 'Your reservation is confirmed',
    text: '',
    at: _now.subtract(const Duration(days: 2)),
    reservations: [
      FoodEstablishmentReservationInfo(
        reservationNumber: 'BE123',
        restaurant: const ReservationPlace(name: 'Burnt Ends'),
        startTime: PlaceTime(_now.year, _now.month, _now.day, hour: hour),
      ),
    ],
  ),
]).single;

Reminder _bill({int days = 1, int messageId = 1}) => Reminder(
  kind: ReminderKind.billDue,
  company: 'myrepublic.com.sg',
  name: 'MyRepublic',
  date: DateTime.utc(_now.year, _now.month, _now.day + days),
  messageId: messageId,
);

void main() {
  late TestApp app;
  setUp(() async {
    app = await TestApp.create();
    InboxSummary.clock = () => _now;
  });
  tearDown(() {
    InboxSummary.clock = DateTime.now;
    InboxSummary.find = findToday;
    return app.dispose();
  });

  StoredMessage message(String subject) => app.store.messages
      .list(const MessageQuery.inbox())
      .firstWhere((m) => m.subject == subject);

  group('the pieces', () {
    final code = StoredMessage(
      id: 9,
      mailboxId: 1,
      accountId: 1,
      uid: 9,
      receivedAt: _now,
      size: 0,
      flags: MessageFlags.none,
      hasAttachments: false,
      category: MessageCategory.codes,
      categorySource: CategorySource.rule,
      code: '123456',
    );

    test('nothing true: no pieces', () {
      expect(InboxSummary.compose(unread: 0, now: _now), isEmpty);
    });

    test('in order, at most four', () {
      final pieces = InboxSummary.compose(
        unread: 3,
        code: code,
        found: FoundToday(
          deliveries: [_parcel('a')],
          appointments: [_dentist()],
          bills: [_bill()],
        ),
        now: _now,
      );
      expect(pieces.map((p) => p.runtimeType), [
        NewMailPiece,
        CodePiece,
        DeliveriesPiece,
        AppointmentPiece,
      ]);
    });

    test('each only when true', () {
      expect(
        InboxSummary.compose(
          unread: 0,
          found: FoundToday(bills: [_bill()]),
          now: _now,
        ).single,
        isA<BillPiece>(),
      );
      expect(
        InboxSummary.compose(
          unread: 0,
          found: FoundToday(bills: [_bill()]),
          bills: false,
          now: _now,
        ),
        isEmpty,
        reason: 'bill reminders off',
      );
      // Over by now.
      expect(
        InboxSummary.compose(
          unread: 0,
          found: FoundToday(appointments: [_dentist(time: '7.30am')]),
          now: _now,
        ),
        isEmpty,
      );
      // The next of today's appointments and bookings.
      SummaryPiece next(int tableAt) => InboxSummary.compose(
        unread: 0,
        found: FoundToday(
          appointments: [_dentist()],
          bookings: [_table(tableAt)],
        ),
        now: _now,
      ).single;
      expect(next(13), isA<BookingPiece>());
      expect(next(19), isA<AppointmentPiece>());
      // The soonest bill.
      final bill = InboxSummary.compose(
        unread: 0,
        found: FoundToday(bills: [_bill(), _bill(days: 0)]),
        now: _now,
      ).single;
      expect((bill as BillPiece).reminder.daysFrom(_now), 0);
    });
  });

  test('today\'s findings, from the mail on the device', () async {
    seedToday(app.store, now: _now);
    final found = await findToday(app.store, _now, monthlyRenewals: false);
    expect([for (final d in found.deliveries) d.shopName], ['Shopee']);
    expect(
      [for (final a in found.appointments) a.title],
      ['Bright Smile Dental'],
    );
    expect([for (final r in found.bills) r.name], ['MyRepublic']);
    expect(found.bookings, isEmpty);
  });

  // ------------------------------------------------------------ the line

  Future<void> show(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: MediaQuery.withClampedTextScaling(
          minScaleFactor: textScale,
          maxScaleFactor: textScale,
          child: MailShell(
            notifications: false,
            services: app.services,
            onAddAccount: () {},
            onAccountsChanged: () {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Today's findings are read a moment after the line shows.
  Future<void> findings(WidgetTester tester) async {
    await tester.pump(InboxSummary.delay + const Duration(milliseconds: 100));
    await tester.pump();
  }

  /// What the line says, piece by piece.
  List<String> line(WidgetTester tester) => [
    for (final t in tester.widgetList<Text>(
      find.descendant(
        of: find.byType(InboxSummaryLine),
        matching: find.byType(Text),
      ),
    ))
      t.data!,
  ];

  InboxSummaryLine lineWidget(WidgetTester tester) =>
      tester.widget<InboxSummaryLine>(find.byType(InboxSummaryLine));

  Finder piece(String text) => find.descendant(
    of: find.byType(InboxSummaryLine),
    matching: find.text(text),
  );

  /// Today: everything at once.
  void everything() {
    seedToday(app.store, now: _now);
    InboxSummary.find = (store, now, {required monthlyRenewals}) async =>
        FoundToday(
          deliveries: [_parcel('a')],
          appointments: [_dentist()],
          bills: [_bill()],
        );
  }

  testWidgets('what is true, in order, at most four', (tester) async {
    everything();
    await show(tester);
    // New mail and the code at once; today's findings a moment later.
    expect(line(tester), ['5 new', 'Code from Northwind']);
    await findings(tester);
    expect(line(tester), [
      '5 new',
      'Code from Northwind',
      'Parcel arriving today',
      'Bright Smile Dental at 3:30 PM',
    ]);
  });

  testWidgets('follows the mail as it is read; nothing true, no line', (
    tester,
  ) async {
    InboxSummary.find = (store, now, {required monthlyRenewals}) async =>
        FoundToday.none;
    await show(tester);
    expect(line(tester), ['4 new']);
    final controller = lineWidget(tester).controller;
    app.services.actions.markRead([message('Lunch?')]);
    controller.refresh();
    await tester.pump();
    expect(line(tester), ['3 new']);

    app.services.actions.markRead([
      for (final m in app.store.messages.list(const MessageQuery.inbox()))
        if (!m.flags.seen) m,
    ]);
    controller.refresh();
    await findings(tester);
    expect(line(tester), isEmpty);
    expect(
      tester.getSize(find.byType(InboxSummaryLine, skipOffstage: false)).height,
      0,
    );
    expect(find.bySemanticsLabel('Summary'), findsNothing);
  });

  testWidgets('a code that is old is no longer offered', (tester) async {
    seedToday(app.store, now: _now);
    InboxSummary.find = (store, now, {required monthlyRenewals}) async =>
        FoundToday.none;
    await show(tester);
    expect(piece('Code from Northwind'), findsOneWidget);
    InboxSummary.clock = () => _now.add(InboxSummary.codeFresh);
    // The line looks again when the code gets old.
    await tester.pump(const Duration(minutes: 14));
    expect(piece('Code from Northwind'), findsNothing);
  });

  testWidgets('only in the inbox, and not with the setting off', (
    tester,
  ) async {
    await show(tester, size: const Size(1400, 900));
    expect(line(tester), ['4 new']);
    final controller = lineWidget(tester).controller;
    await tester.tap(find.text('Archive'));
    await tester.pump();
    expect(find.byType(InboxSummaryLine), findsNothing);
    await tester.tap(find.byTooltip('Back to Inbox'));
    await tester.pump();
    expect(line(tester), ['4 new']);

    app.services.settings.summaryLine = false;
    controller.refresh();
    await tester.pump();
    expect(line(tester), isEmpty);
    app.services.settings.summaryLine = true;
    controller.refresh();
    await tester.pump();
    expect(line(tester), ['4 new']);
  });

  testWidgets('reading bookings automatically off: no findings', (
    tester,
  ) async {
    everything();
    app.services.settings.autoRead = false;
    await show(tester);
    await findings(tester);
    expect(line(tester), ['5 new', 'Code from Northwind']);
  });

  testWidgets('bill reminders off: no bill', (tester) async {
    InboxSummary.find = (store, now, {required monthlyRenewals}) async =>
        FoundToday(bills: [_bill()]);
    await show(tester);
    await findings(tester);
    expect(line(tester), ['4 new', 'MyRepublic bill due tomorrow']);
    app.services.settings.reminders = false;
    lineWidget(tester).controller.refresh();
    await tester.pump();
    expect(line(tester), ['4 new']);
  });

  testWidgets('each piece goes where it belongs', (tester) async {
    everything();
    await show(tester);
    await findings(tester);
    NavigatorState navigator() =>
        tester.state<NavigatorState>(find.byType(Navigator).first);

    // The code: copied, never shown in the line; the email stays unread.
    Map<Object?, Object?>? copied;
    const plugin = MethodChannel('citusmail/background-clipboard');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(plugin, (
      call,
    ) async {
      if (call.method == 'copy') copied = call.arguments as Map;
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        plugin,
        null,
      ),
    );
    await tester.tap(piece('Code from Northwind'));
    await tester.pump();
    expect(copied?['text'], todayCode);
    expect(copied?['sensitive'], isTrue);
    expect(find.text('Copied $todayCode'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(InboxSummaryLine),
        matching: find.textContaining(todayCode),
      ),
      findsNothing,
    );
    expect(message('Your Northwind sign-in code').flags.seen, isFalse);

    // Deliveries: the page.
    await tester.tap(piece('Parcel arriving today'));
    await tester.pumpAndSettle();
    expect(find.byType(DeliveriesPage), findsOneWidget);
    navigator().pop();
    await tester.pumpAndSettle();

    // The appointment: its page.
    await tester.tap(piece('Bright Smile Dental at 3:30 PM'));
    await tester.pumpAndSettle();
    expect(find.byType(AppointmentDetailPage), findsOneWidget);
    navigator().pop();
    await tester.pumpAndSettle();

    // New mail: the first unread email opens.
    final controller = lineWidget(tester).controller;
    final first = controller.list.visible.firstWhere((m) => !m.flags.seen);
    await tester.tap(piece('5 new'));
    await tester.pump();
    expect(controller.selected?.id, first.id);
  });

  testWidgets('a bill opens its email', (tester) async {
    final hello = message('Hello there');
    InboxSummary.find = (store, now, {required monthlyRenewals}) async =>
        FoundToday(bills: [_bill(messageId: hello.id)]);
    await show(tester, size: const Size(1400, 900));
    await findings(tester);
    final controller = lineWidget(tester).controller;
    await tester.tap(piece('MyRepublic bill due tomorrow'));
    await tester.pump();
    expect(controller.selected?.id, hello.id);
  });

  testWidgets('screen readers: a list of buttons with clear labels', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    everything();
    await show(tester);
    await findings(tester);
    for (final label in [
      '5 new emails',
      'Copy the code from Northwind',
      'Parcel arriving today. Open Deliveries',
      'Bright Smile Dental at 3:30 PM. Open the appointment',
    ]) {
      expect(
        tester.getSemantics(find.bySemanticsLabel(label)),
        matchesSemantics(label: label, isButton: true, hasTapAction: true),
        reason: label,
      );
    }
    final list = tester.getSemantics(find.bySemanticsLabel('Summary'));
    expect(list.role, SemanticsRole.list);
    semantics.dispose();
  });

  for (final width in [360.0, 390.0, 412.0]) {
    testWidgets('no overflow at $width wide, text 1.3 times larger', (
      tester,
    ) async {
      everything();
      await show(tester, size: Size(width, 800), textScale: 1.3);
      await findings(tester);
      expect(line(tester), hasLength(4));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a switch in Settings, synced like other inbox choices', (
    tester,
  ) async {
    expect(SyncedPreferences.preferenceOf('inbox.summaryLine'), isNotNull);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          services: app.services,
          onShowMail: (_) {},
          isAndroid: false,
          show: 'summaryLine',
        ),
      ),
    );
    await tester.pumpAndSettle();
    final tile = find.widgetWithText(SwitchListTile, 'Summary line');
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    await tester.tap(tile);
    await tester.pump();
    expect(app.services.settings.summaryLine, isFalse);
  });
}
