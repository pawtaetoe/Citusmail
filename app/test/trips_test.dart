// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/ui/booking_text.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/trips_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_view/mail_view.dart';

import 'support/test_app.dart';
import 'support/trip_mail.dart';

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  /// Lets isolates (text and markup extraction) finish.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> openTrips(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1100);
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
    await tester.tap(find.text('Trips'));
    await tester.pump();
    await settle(tester);
    await tester.pumpAndSettle();
  }

  /// The Trips page's list.
  final list = find
      .descendant(of: find.byType(TripsPage), matching: find.byType(Scrollable))
      .first;

  DateTime day(DateTime now, int days) =>
      DateTime(now.year, now.month, now.day + days);

  testWidgets('upcoming trips with their timelines, then past ones', (
    tester,
  ) async {
    // Reading automatically off: the page offers it, as a card.
    app.services.settings.autoRead = false;
    final now = DateTime.now().toUtc();
    seedTrips(app.store, now: now);
    await openTrips(tester);

    expect(find.text('1 trip coming up'), findsOneWidget);
    expect(
      find.text('Next: Tokyo, in 38 days · 2 bookings at home'),
      findsOneWidget,
    );
    // Tokyo: the flight there, the hotel, the flight back, in order.
    expect(find.text('Tokyo'), findsOneWidget);
    expect(
      find.text(BookingText.range(day(now, 38), day(now, 44))),
      findsOneWidget,
    );
    final tokyo = find.ancestor(
      of: find.text('Tokyo'),
      matching: find.byType(Card),
    );
    final rows = [
      for (final t in tester.widgetList<Text>(
        find.descendant(of: tokyo, matching: find.byType(Text)),
      ))
        t.data,
    ];
    expect(
      rows.where(
        (r) => const [
          'Flight to Tokyo',
          'Park Hotel Shinjuku',
          'Flight to Singapore',
        ].contains(r),
      ),
      ['Flight to Tokyo', 'Park Hotel Shinjuku', 'Flight to Singapore'],
    );
    // Local times at the place, as the airline gives them.
    expect(find.text('SQ 638 · SIN 11:35 PM → NRT 7:30 AM +1'), findsOneWidget);
    expect(find.text('Tokyo · 5 nights'), findsOneWidget);
    // At home: a table and a concert, named by their day.
    expect(find.text('Table at Burnt Ends'), findsOneWidget);
    expect(find.text('4 people · Singapore'), findsOneWidget);
    expect(find.text('Coldplay: Music of the Spheres'), findsOneWidget);
    // Bali was cancelled.
    expect(find.text('Bali'), findsOneWidget);
    expect(find.text('Cancelled'), findsOneWidget);
    // Not bookings.
    expect(find.textContaining('Hotel Muse'), findsNothing);
    expect(find.textContaining('398'), findsNothing);
    // The past is folded away.
    expect(find.text('Bangkok'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Show 1 past trip'),
      200,
      scrollable: list,
    );
    await tester.tap(find.text('Show 1 past trip'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Bangkok'),
      200,
      scrollable: list,
    );
    expect(find.text('Bangkok'), findsOneWidget);
    expect(find.text('TR 616 · SIN 7:00 AM → BKK 8:25 AM'), findsOneWidget);
    // A booking email not on the device yet is offered for reading.
    expect(find.textContaining('found in 1 booking email'), findsOneWidget);
    expect(find.text('Read booking emails'), findsOneWidget);
  });

  testWidgets('a booking: details, copying the reference, its emails, '
      'hiding it', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    seedTrips(app.store, now: DateTime.now().toUtc());
    await openTrips(tester);

    await tester.tap(find.text('Flight to Tokyo'));
    await tester.pumpAndSettle();
    expect(find.text('XKQZPL'), findsOneWidget);
    expect(find.text('SQ 638'), findsOneWidget);
    expect(find.text('Singapore Airlines'), findsOneWidget);
    expect(find.textContaining('Singapore Changi (SIN)\n'), findsOneWidget);
    expect(find.textContaining('Terminal 3'), findsOneWidget);
    expect(find.textContaining('Tokyo Narita (NRT)\n'), findsOneWidget);
    expect(find.text('Alice Tan'), findsOneWidget);
    expect(find.text('Local times at each place.'), findsOneWidget);
    expect(find.text('Add to calendar'), findsOneWidget);

    // Copy with a tap.
    await tester.tap(find.byTooltip('Copy booking reference'));
    await tester.pump();
    expect(copied, ['XKQZPL']);
    expect(find.text('Booking reference copied'), findsOneWidget);

    // The airline's page opens only after asking.
    await tester.tap(find.text('Manage booking'));
    await tester.pumpAndSettle();
    expect(find.text('Open this link?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Its email opens right here; Back returns to the booking.
    await tester.tap(find.text('Booked'));
    await settle(tester);
    expect(find.text('Email'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('XKQZPL'), findsOneWidget);

    // "Not a booking": hidden, with Undo, and listed again from below.
    await tester.tap(find.text('Not a booking'));
    await settle(tester);
    expect(
      find.text('Flight to Tokyo won\'t be listed as a booking'),
      findsOneWidget,
    );
    expect(find.text('Flight to Tokyo'), findsNothing);
    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect(find.text('Flight to Tokyo'), findsOneWidget);

    await tester.tap(find.text('Table at Burnt Ends').last);
    await tester.pumpAndSettle();
    expect(find.text('4'), findsOneWidget);
    await tester.tap(find.text('Not a booking'));
    await settle(tester);
    expect(find.text('Table at Burnt Ends'), findsNothing);
    // The snackbar would cover the end of the list.
    ScaffoldMessenger.of(tester.element(find.byType(TripsPage)))
        .removeCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Show 1 marked "not a booking"'),
      200,
      scrollable: list,
    );
    await tester.tap(find.text('Show 1 marked "not a booking"'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('List again'),
      200,
      scrollable: list,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('List again'));
    await settle(tester);
    expect(find.text('Table at Burnt Ends'), findsOneWidget);
  });

  test('a booking as a calendar event', () {
    final html = StructuredData.extract('''
<script type="application/ld+json">
{"@type": "FlightReservation", "reservationNumber": "XKQZPL",
 "reservationFor": {"@type": "Flight", "flightNumber": "638",
   "airline": {"@type": "Airline", "name": "Singapore Airlines", "iataCode": "SQ"},
   "departureAirport": {"@type": "Airport", "name": "Singapore Changi", "iataCode": "SIN"},
   "departureTime": "2026-12-12T23:35:00+08:00",
   "arrivalAirport": {"@type": "Airport", "name": "Tokyo Narita", "iataCode": "NRT"},
   "arrivalTime": "2026-12-13T07:30:00+09:00"}}
</script>''');
    final booking = TripFinder.bookings([
      TripEmail(
        messageId: 1,
        sender: 'singaporeair.com',
        senderName: 'Singapore Airlines',
        subject: 'Booking confirmation',
        text: '',
        at: DateTime.utc(2026, 11, 1),
        reservations: ReservationInfo.allIn(html),
      ),
    ]).single;
    final ics = BookingCalendar.ics(booking, now: DateTime.utc(2026, 11, 4));
    expect(ics, contains('DTSTART:20261212T153500Z\r\n'));
    expect(ics, contains('DTEND:20261212T223000Z\r\n'));
    expect(ics, contains('SUMMARY:Flight to Tokyo (SQ 638)\r\n'));
    expect(ics, contains('LOCATION:Singapore Changi\r\n'));
    expect(ics, contains('Booking reference: XKQZPL'));
    final invite = CalendarInvite.parse(ics)!;
    expect(invite.summary, 'Flight to Tokyo (SQ 638)');
    expect(invite.start, isNotNull);
    expect(invite.end, isNotNull);
  });
}
