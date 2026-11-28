// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/core/theme/citusmail_theme.dart';
import 'package:citusmail/src/features/found/state/events_model.dart';
import 'package:citusmail/src/features/found/ui/event_text.dart';
import 'package:citusmail/src/features/found/ui/events_page.dart';
import 'package:citusmail/src/features/inbox/state/mail_controller.dart';
import 'package:citusmail/src/services/auto_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_extract/mail_extract.dart';
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

  group('the model', () {
    test('finds events in stored mail, and what to read', () async {
      final now = DateTime.now().toUtc();
      seedEvents(app.store, now: now);
      final found = await findEvents(app.store, now);
      Event named(String t) => found.all.firstWhere((e) => e.title == t);
      expect(
        {for (final e in found.all) e.title},
        {
          'Guided Factory Tour',
          'The Lanterns – World Tour',
          'Design review',
          'The Glass Garden',
          'Starlight Odyssey',
        },
      );
      // The downloaded email was read whole: its labelled date and time.
      final tour = named('Guided Factory Tour');
      expect(tour.kind, EventKind.tour);
      expect(tour.start.day, _day(appointmentDay(now, 8)));
      expect(tour.start.wall.hour, 10);
      expect(tour.venue, 'House of Cocoa, Fabrikweg 12, Zurich');
      expect(tour.reference, '418822');
      // The calendar file: a video meeting.
      final meeting = named('Design review');
      expect(meeting.kind, EventKind.meeting);
      expect(meeting.online, isTrue);
      expect(meeting.link?.host, 'northwind.zoom.us');
      // The show was cancelled.
      expect(named('The Glass Garden').cancelled, isTrue);
      expect(named('The Lanterns – World Tour').kind, EventKind.concert);
      // A ticket not on the device that may say more.
      expect(found.toRead, hasLength(1));
      expect(
        app.store.messages.byId(found.toRead.single)!.from!.displayName,
        'City Ballet',
      );
      expect(
        await AutoReader.wanted(app.store, now, cap: 50),
        contains(found.toRead.single),
      );
    });

    test('a schema.org event ticket is an event, not a trip', () async {
      final now = DateTime.now().toUtc();
      seedTrips(app.store, now: now);
      final found = await findEvents(app.store, now);
      final concert = found.all.single;
      expect(concert.title, 'Coldplay: Music of the Spheres');
      expect(concert.kind, EventKind.concert);
      expect(concert.venue, startsWith('National Stadium'));
    });

    test('upcoming, past, and "Not an event" with Undo', () async {
      seedEvents(app.store, now: DateTime.now().toUtc());
      final model = EventsModel(app.services);
      await model.load();
      expect(model.upcoming.first.title, 'Design review');
      expect(
        model.comingUp.map((e) => e.title),
        isNot(contains('The Glass Garden')),
      );
      expect([for (final e in model.past) e.title], ['Starlight Odyssey']);
      final meeting = model.upcoming.first;
      model.hide(meeting.key);
      await model.load();
      expect(
        model.upcoming.map((e) => e.title),
        isNot(contains('Design review')),
      );
      expect(model.hiddenOnes.single.title, 'Design review');
      model.unhide(meeting.key);
      await model.load();
      expect(model.upcoming.first.title, 'Design review');
      model.dispose();
    });
  });

  group('the page', () {
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    Future<void> open(
      WidgetTester tester, {
      Size size = const Size(1200, 1400),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: CitusmailTheme.light(),
          home: EventsPage(controller: MailController(app.services)),
        ),
      );
      await settle(tester);
      await tester.pumpAndSettle();
    }

    testWidgets('coming up, the past folded; an event opens its page and '
        'its email', (tester) async {
      app.services.settings.autoRead = false;
      seedEvents(app.store, now: DateTime.now().toUtc());
      await open(tester);

      expect(find.text('3 coming up'), findsOneWidget);
      expect(
        find.textContaining('Next: Design review, tomorrow'),
        findsOneWidget,
      );
      expect(find.text('Guided Factory Tour'), findsOneWidget);
      expect(find.text('Meeting · Online'), findsOneWidget);
      expect(find.text('Tour · House of Cocoa'), findsOneWidget);
      expect(find.text('Cancelled'), findsOneWidget);
      // Not events.
      expect(find.textContaining('on sale'), findsNothing);
      expect(find.textContaining('This week'), findsNothing);
      // A ticket not on the device yet is offered for reading.
      expect(find.text('Read ticket emails'), findsOneWidget);
      expect(find.text('Starlight Odyssey'), findsNothing);
      expect(find.text('Show 1 past event'), findsOneWidget);

      await tester.tap(find.text('Guided Factory Tour'));
      await tester.pumpAndSettle();
      expect(find.text('418822'), findsOneWidget);
      expect(find.text('House of Cocoa, Fabrikweg 12, Zurich'), findsOneWidget);
      expect(find.text('Add to calendar'), findsOneWidget);
      await tester.tap(find.text('Booked'));
      await settle(tester);
      expect(find.text('Email'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      // "Not an event": hidden, with Undo.
      await tester.tap(find.text('Not an event'));
      await settle(tester);
      expect(
        find.text('Guided Factory Tour won\'t be listed as an event'),
        findsOneWidget,
      );
      expect(find.text('2 coming up'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await settle(tester);
      expect(find.text('3 coming up'), findsOneWidget);
    });

    testWidgets('a meeting offers Join, after asking', (tester) async {
      seedEvents(app.store, now: DateTime.now().toUtc());
      await open(tester, size: const Size(390, 844));
      await tester.tap(find.text('Design review'));
      await tester.pumpAndSettle();
      expect(find.text('northwind.zoom.us'), findsOneWidget);
      await tester.tap(find.text('Join'));
      await tester.pumpAndSettle();
      expect(find.text('Open this link?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('nothing found', (tester) async {
      await open(tester);
      expect(find.text('No events found'), findsOneWidget);
    });
  });

  test('an event as a calendar event', () {
    final now = DateTime.utc(2026, 11, 4, 12);
    final event = EventFinder.find([
      EventEmail(
        messageId: MessageId(1),
        sender: 'ticketsite.example',
        senderName: 'TicketSite',
        subject: 'Your tickets: The Lanterns – World Tour',
        text:
            'Your booking is confirmed. 28 Nov 2026 at 7:30 PM, Riverside '
            'Arena. Order number: TS-448812.',
        at: now,
      ),
    ]).single;
    final ics = EventCalendar.ics(event, now: now);
    expect(ics, contains('DTSTART:20261128T193000\r\n'));
    expect(ics, contains('DURATION:PT2H\r\n'));
    expect(ics, contains('SUMMARY:The Lanterns – World Tour\r\n'));
    expect(ics, contains('Booking reference: TS-448812'));
    expect(EventCalendar.invite(event, now: now)!.summary, event.title);
    expect(event.start, isA<PlaceTime>());
  });
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);
