// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/core/theme/citusmail_theme.dart';
import 'package:citusmail/src/features/calendar/state/calendar_model.dart';
import 'package:citusmail/src/features/calendar/ui/calendar_view.dart';
import 'package:citusmail/src/features/found/state/events_model.dart';
import 'package:citusmail/src/features/found/ui/booking_text.dart';
import 'package:citusmail/src/features/inbox/state/mail_controller.dart';
import 'package:citusmail/src/features/reader/ui/email_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

import 'support/appointment_mail.dart';
import 'support/event_mail.dart';
import 'support/test_app.dart';
import 'support/trip_mail.dart';

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  /// Three monthly receipts: a subscription that renews next month.
  void seedSubscription(DateTime now) {
    final inbox = app.store.mailboxes.inbox(
      app.store.accounts.all().single.id,
    )!;
    app.store.messages.upsertSummaries(inbox.id, [
      for (final (i, daysAgo) in [5, 35, 65].indexed)
        MessageSummary(
          uid: 9900 + i,
          receivedAt: now.subtract(Duration(days: daysAgo)),
          subject: 'Your StreamFlix receipt',
          from: const MailAddress(
            displayName: 'StreamFlix',
            localPart: 'info',
            domain: 'mailer.streamflix.example',
          ),
          snippet: 'Your membership has been renewed. Total S\$17.98',
        ),
    ]);
  }

  void seedAll(DateTime now) {
    seedTrips(app.store, now: now);
    seedAppointments(app.store, now: now);
    seedEvents(app.store, now: now);
    seedSubscription(now);
  }

  group('the model', () {
    test('merges trips, appointments and events, by day', () async {
      final now = DateTime.now().toUtc();
      seedAll(now);
      final model = CalendarModel(app.services);
      await model.load();
      final sources = {for (final i in model.items) i.source};
      expect(sources, CalendarSource.values.toSet());
      String title(CalendarItem i) => switch (i.item) {
        final Booking b => '${BookingText.title(b)}${i.checkOut ? ' out' : ''}',
        final Appointment a => a.title,
        final Event e => e.title,
        final Reminder r => '${r.name} ${r.kind.name}',
        _ => '',
      };
      final titles = [for (final i in model.items) title(i)];
      expect(
        titles,
        containsAll([
          'Flight to Tokyo',
          'Park Hotel Shinjuku',
          'Park Hotel Shinjuku out',
          'Table at Burnt Ends',
          'Bright Smile Dental',
          'Design review',
          'Guided Factory Tour',
          'Coldplay: Music of the Spheres',
          'StreamFlix renewal',
        ]),
      );
      // The renewal, all day, about a month after the last receipt.
      final renewal = model.items.singleWhere(
        (i) => i.source == CalendarSource.money,
      );
      expect(renewal.start.hasTime, isFalse);
      final last = now.subtract(const Duration(days: 5));
      expect(
        renewal.day
            .difference(DateTime(last.year, last.month, last.day))
            .inDays,
        inInclusiveRange(28, 31),
      );
      // Days in order, each day's items by time.
      final upcoming = model.upcoming;
      for (var i = 1; i < upcoming.length; i++) {
        expect(upcoming[i - 1].day.isBefore(upcoming[i].day), isTrue);
      }
      expect(upcoming.first.items.map(title), contains('Design review'));
      // The past, the latest first; the cancelled show is still listed.
      final past = model.past;
      for (var i = 1; i < past.length; i++) {
        expect(past[i - 1].day.isAfter(past[i].day), isTrue);
      }
      expect(
        past.expand((d) => d.items).map(title),
        contains('Starlight Odyssey'),
      );
      expect(
        model.items
            .where((i) => title(i) == 'The Glass Garden')
            .single
            .cancelled,
        isTrue,
      );
      model.dispose();
    });

    test('what a page left out is left out here too', () async {
      final now = DateTime.now().toUtc();
      seedEvents(app.store, now: now);
      final found = await findEvents(app.store, now);
      final tour = found.all.firstWhere(
        (e) => e.title == 'Guided Factory Tour',
      );
      EventsModel.hiddenSetting.write(app.store.settings, [tour.key]);
      final items = await findCalendar(app.store, now);
      expect(items.map((i) => i.key), isNot(contains(tour.key)));
      expect(items, isNotEmpty);
    });
  });

  group('the view', () {
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    Future<void> open(
      WidgetTester tester, {
      Size size = const Size(390, 844),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: CitusmailTheme.light(),
          home: CalendarPage(controller: MailController(app.services)),
        ),
      );
      await settle(tester);
      await tester.pumpAndSettle();
    }

    final list = find.byKey(const ValueKey('calendar-list'));

    testWidgets('grouped by day, the soonest first; an item opens its email', (
      tester,
    ) async {
      final now = DateTime.now();
      seedAll(now.toUtc());
      await open(tester);
      expect(tester.takeException(), isNull);
      // The month, with today in it.
      expect(
        find.text(
          MaterialLocalizations.of(tester.element(find.byType(CalendarView)))
              .formatMonthYear(DateTime(now.year, now.month)),
        ),
        findsOneWidget,
      );
      // Tomorrow's meeting, under "Tomorrow", with its icon and time.
      await tester.scrollUntilVisible(
        find.text('Design review'),
        200,
        scrollable: find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.text('Tomorrow'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Tomorrow')).dy,
        lessThan(tester.getTopLeft(find.text('Design review')).dy),
      );
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Design review'),
          matching: find.textContaining('Meeting · Online'),
        ),
        findsOneWidget,
      );
      // A later day by its date.
      final tourDay = BookingText.day(appointmentDay(now, 8), now: now);
      await tester.scrollUntilVisible(
        find.text('Guided Factory Tour'),
        200,
        scrollable: find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.text(tourDay), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(tourDay)).dy,
        lessThan(tester.getTopLeft(find.text('Guided Factory Tour')).dy),
      );
      expect(
        find.textContaining('10:30 AM · Tour · House of Cocoa'),
        findsOneWidget,
      );

      // Tapping one opens the email it came from.
      await tester.tap(find.text('Guided Factory Tour'));
      await settle(tester);
      expect(find.byType(EmailPage), findsOneWidget);
      expect(find.text('Email'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(CalendarView), findsOneWidget);
    });

    testWidgets('the past on request; a day picked in the month', (
      tester,
    ) async {
      final now = DateTime.now();
      seedEvents(app.store, now: now.toUtc());
      await open(tester);
      expect(find.text('Starlight Odyssey'), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('calendar-past')),
        200,
        scrollable: find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('calendar-past')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Starlight Odyssey'),
        200,
        scrollable: find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.text('Starlight Odyssey'), findsOneWidget);

      // Back to the top, and pick tomorrow in the month (or next month's
      // first day, at the end of one). A phone shows one week at first.
      await tester.drag(list, const Offset(0, 4000));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Show the month'));
      await tester.pumpAndSettle();
      final tomorrow = DateTime(now.year, now.month, now.day + 1);
      if (tomorrow.month != now.month) {
        await tester.tap(find.byTooltip('Next month'));
        await tester.pumpAndSettle();
      }
      await tester.tap(
        find.byKey(ValueKey('calendar-cell-${tomorrow.toIso8601String()}')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Design review'), findsOneWidget);
      expect(find.text('Guided Factory Tour'), findsNothing);
      await tester.tap(find.byTooltip('Show every day'));
      await tester.pumpAndSettle();
      expect(find.text('Guided Factory Tour'), findsOneWidget);
    });

    testWidgets('a phone shows one week; the month on request', (tester) async {
      final now = DateTime.now();
      seedEvents(app.store, now: now.toUtc());
      await open(tester);
      Finder cells() => find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('calendar-cell-'),
      );
      expect(cells(), findsNWidgets(7));
      final today = DateTime(now.year, now.month, now.day);
      expect(
        find.byKey(ValueKey('calendar-cell-${today.toIso8601String()}')),
        findsOneWidget,
      );
      // The next week, then the whole month.
      await tester.tap(find.byTooltip('Next week'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          ValueKey(
            'calendar-cell-${today.add(const Duration(days: 7)).toIso8601String()}',
          ),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Show the month'));
      await tester.pumpAndSettle();
      expect(
        cells(),
        findsNWidgets(DateUtils.getDaysInMonth(now.year, now.month)),
      );
      // A wide window shows the month from the start.
      await tester.pumpWidget(const SizedBox());
      await open(tester, size: const Size(1200, 900));
      expect(
        cells(),
        findsNWidgets(DateUtils.getDaysInMonth(now.year, now.month)),
      );
    });

    testWidgets('nothing found', (tester) async {
      await open(tester);
      expect(find.text('Nothing on the calendar'), findsOneWidget);
    });

    testWidgets('fits 360 wide with larger text', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      seedAll(DateTime.now().toUtc());
      await open(tester, size: const Size(360, 740));
      expect(tester.takeException(), isNull);
    });
  });
}
