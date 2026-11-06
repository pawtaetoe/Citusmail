// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/mail/appointments_model.dart';
import 'package:citusmail/src/mail/mail_controller.dart';
import 'package:citusmail/src/services/auto_reader.dart';
import 'package:citusmail/src/ui/appointment_text.dart';
import 'package:citusmail/src/ui/appointments_page.dart';
import 'package:citusmail/src/ui/booking_text.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_view/mail_view.dart';

import 'support/appointment_mail.dart';
import 'support/test_app.dart';

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  group('the model', () {
    test('finds appointments in stored mail, and what to read', () async {
      final now = DateTime.now().toUtc();
      seedAppointments(app.store, now: now);
      final found = await findAppointments(app.store, now);
      final titles = {for (final a in found.all) a.title};
      expect(titles, {
        'Bright Smile Dental',
        'Hair by Mia',
        'Northside Motors',
        'Core Physio',
        'Holland Village Clinic',
        'Kings Cuts',
        'Tiong Bahru Family Clinic',
      });
      Appointment named(String t) => found.all.firstWhere((a) => a.title == t);
      // The markup, the calendar file and the links were read.
      expect(named('Core Physio').service, 'Physiotherapy assessment');
      expect(named('Holland Village Clinic').service, 'Flu vaccination');
      expect(
        [for (final l in named('Bright Smile Dental').links) l.label],
        ['Manage your appointment', 'Add to calendar'],
      );
      // The car service moved; the barber was cancelled.
      final car = named('Northside Motors');
      expect(car.changed, isTrue);
      expect(car.start.day, _day(appointmentDay(now, 9)));
      expect(named('Kings Cuts').cancelled, isTrue);
      // An email not on the device that may say more.
      expect(found.toRead, hasLength(1));
      expect(
        app.store.messages.byId(found.toRead.single)!.from!.displayName,
        'Harbour Physio',
      );
      // Reading ahead takes it too.
      expect(
        await AutoReader.wanted(app.store, now, cap: 50),
        contains(found.toRead.single),
      );
    });

    test('upcoming, past, and "Not an appointment" with Undo', () async {
      final now = DateTime.now();
      seedAppointments(app.store, now: now.toUtc());
      final model = AppointmentsModel(app.services);
      await model.load();
      expect(
        [for (final a in model.upcoming) a.title],
        containsAllInOrder([
          'Hair by Mia',
          'Bright Smile Dental',
          'Northside Motors',
          'Core Physio',
          'Holland Village Clinic',
        ]),
      );
      expect(model.upcoming.map((a) => a.title), contains('Kings Cuts'));
      expect(model.comingUp.map((a) => a.title), isNot(contains('Kings Cuts')));
      expect(
        [for (final a in model.past) a.title],
        ['Tiong Bahru Family Clinic'],
      );

      final salon = model.upcoming.first;
      model.hide(salon.key);
      await model.load();
      expect(
        model.upcoming.map((a) => a.title),
        isNot(contains('Hair by Mia')),
      );
      expect(model.hiddenOnes.single.title, 'Hair by Mia');
      expect(
        app.store.settings.read(AppointmentsModel.hiddenKey),
        contains(salon.key),
      );
      model.unhide(salon.key);
      await model.load();
      expect(model.upcoming.first.title, 'Hair by Mia');
      model.dispose();
    });

    test('a calendar file and links as the finder reads them', () {
      final invite = CalendarInvite.parse('''BEGIN:VCALENDAR
METHOD:PUBLISH
BEGIN:VEVENT
UID:x1
SEQUENCE:2
DTSTART:20261125T013000Z
DTEND;TZID=Europe/London:20261125T014500
SUMMARY:Flu vaccination
ORGANIZER;CN=Clinic:mailto:noreply@clinic.example
ATTENDEE:mailto:alice@citusmail.test
END:VEVENT
END:VCALENDAR''')!;
      final read = appointmentInvite(invite);
      expect(read.uid, 'x1');
      expect(read.sequence, 2);
      expect(read.start!.instant, DateTime.utc(2026, 11, 25, 1, 30));
      expect(read.end!.offset, Duration.zero);
      expect(read.organizerName, 'Clinic');
      expect(read.guests, 1);
      expect(read.reply, isFalse);

      final links = linksIn(
        RichDocument([
          ParagraphBlock([
            TextRun('Manage ', link: _manage),
            TextRun('booking', link: _manage),
            TextRun(' or '),
            TextRun('call us', link: null),
            LineBreak(),
            TextRun('Old link', link: _http),
          ]),
        ]),
      );
      expect(links, [MailLink('Manage booking', _manage)]);
    });
  });

  group('the page', () {
    /// Lets isolates (text, markup and calendar reading) finish.
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
          home: AppointmentsPage(controller: MailController(app.services)),
        ),
      );
      await settle(tester);
      await tester.pumpAndSettle();
    }

    final list = find
        .descendant(
          of: find.byType(AppointmentsPage),
          matching: find.byType(Scrollable),
        )
        .first;

    testWidgets('coming up first, then the past year, folded', (tester) async {
      // Reading automatically off: the page offers it, as a card.
      app.services.settings.autoRead = false;
      final now = DateTime.now().toUtc();
      seedAppointments(app.store, now: now);
      await open(tester);

      expect(find.text('5 coming up'), findsOneWidget);
      expect(find.textContaining('Next: Hair by Mia, '), findsOneWidget);
      expect(find.text('Upcoming'), findsOneWidget);
      // The soonest first, each with its day and what it is for.
      final dentist = BookingText.day(appointmentDay(now, 6), now: now);
      expect(find.text('$dentist · 3:30 PM'), findsOneWidget);
      expect(find.text('Scale and polish · 14 High Street'), findsOneWidget);
      expect(
        find.text('Physiotherapy assessment · 80 Baker Street'),
        findsOneWidget,
      );
      expect(
        find.text('Flu vaccination · 118 Holland Park Avenue'),
        findsOneWidget,
      );
      // A cancelled one says so; one that moved too.
      expect(find.text('Cancelled'), findsOneWidget);
      expect(find.text('Moved'), findsOneWidget);
      // Not appointments.
      for (final t in [
        'Burnt Ends',
        'Serenity Spa',
        'Q4 roadmap',
        'Ninja Van',
      ]) {
        expect(find.textContaining(t), findsNothing);
      }
      // An email not on the device yet is offered for reading.
      expect(find.textContaining('found in 1 booking email'), findsOneWidget);
      expect(find.text('Read booking emails'), findsOneWidget);
      // The past is folded away.
      expect(find.text('Tiong Bahru Family Clinic'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('Show 1 past appointment'),
        200,
        scrollable: list,
      );
      await tester.tap(find.text('Show 1 past appointment'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Tiong Bahru Family Clinic'),
        200,
        scrollable: list,
      );
      expect(find.text('Past'), findsOneWidget);
    });

    testWidgets('an appointment: details, links after asking, its emails, '
        '"Not an appointment" with Undo', (tester) async {
      seedAppointments(app.store, now: DateTime.now().toUtc());
      await open(tester);

      await tester.tap(find.text('Bright Smile Dental'));
      await tester.pumpAndSettle();
      expect(find.text('14 High Street, Oxford OX1 4AA'), findsOneWidget);
      expect(find.text('Scale and polish'), findsOneWidget);
      // The app's own "Add to calendar", not the email's link as well.
      expect(find.text('Add to calendar'), findsOneWidget);

      // The clinic's page opens only after asking.
      await tester.tap(find.text('Manage your appointment'));
      await tester.pumpAndSettle();
      expect(find.text('Open this link?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // Its email opens right here; Back returns to the appointment.
      await tester.tap(find.text('Booked'));
      await settle(tester);
      expect(find.text('Email'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Scale and polish'), findsOneWidget);

      // "Not an appointment": hidden, with Undo.
      await tester.tap(find.text('Not an appointment'));
      await settle(tester);
      expect(
        find.text('Bright Smile Dental won\'t be listed as an appointment'),
        findsOneWidget,
      );
      expect(find.text('Bright Smile Dental'), findsNothing);
      expect(find.text('4 coming up'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await settle(tester);
      expect(find.text('Bright Smile Dental'), findsOneWidget);
      expect(find.text('5 coming up'), findsOneWidget);
    });

    testWidgets('the booking reference copies; a move and a cancellation '
        'say so', (tester) async {
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
      seedAppointments(app.store, now: DateTime.now().toUtc());
      await open(tester);

      await tester.tap(find.text('Hair by Mia'));
      await tester.pumpAndSettle();
      expect(find.text('A1B2C3D4'), findsOneWidget);
      expect(find.text('Fresha'), findsOneWidget); // booked with
      await tester.tap(find.byTooltip('Copy booking reference'));
      await tester.pump();
      expect(copied, ['A1B2C3D4']);
      expect(find.text('Booking reference copied'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Northside Motors'));
      await tester.pumpAndSettle();
      expect(find.textContaining('It was moved. It was '), findsOneWidget);
      expect(find.text('Moved'), findsOneWidget); // its email
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Kings Cuts'));
      await tester.pumpAndSettle();
      expect(
        find.text('An email says this appointment was cancelled.'),
        findsOneWidget,
      );
      expect(find.text('Add to calendar'), findsNothing);
    });

    testWidgets('fits a phone', (tester) async {
      seedAppointments(app.store, now: DateTime.now().toUtc());
      await open(tester, size: const Size(390, 844));
      expect(find.text('5 coming up'), findsOneWidget);
      await tester.tap(find.text('Core Physio'));
      await tester.pumpAndSettle();
      expect(find.text('PHY-1192'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  test('an appointment as a calendar event', () async {
    final now = DateTime.utc(2026, 11, 4, 12);
    final appointment = AppointmentFinder.find([
      AppointmentEmail(
        messageId: 1,
        sender: 'brightsmiledental.co.uk',
        senderName: 'Bright Smile Dental',
        subject: 'Appointment confirmation',
        text:
            'This is to confirm your appointment on 12 November 2026 at '
            '3:30 PM.\nTreatment: Scale and polish\nAddress: 14 High '
            'Street, Oxford\nBooking ref: BSD-88213',
        at: now,
      ),
    ]).single;
    final ics = AppointmentCalendar.ics(appointment, now: now);
    // As written: the clock time where the user is.
    expect(ics, contains('DTSTART:20261112T153000\r\n'));
    expect(ics, contains('DURATION:PT1H\r\n'));
    expect(
      ics,
      contains('SUMMARY:Scale and polish at Bright Smile Dental\r\n'),
    );
    expect(ics, contains('LOCATION:14 High Street\\, Oxford\r\n'));
    expect(ics, contains('Booking reference: BSD-88213'));
    final invite = AppointmentCalendar.invite(appointment, now: now)!;
    expect(invite.summary, 'Scale and polish at Bright Smile Dental');
  });
}

final _manage = Uri.parse('https://clinic.example/manage');
final _http = Uri.parse('http://clinic.example/old');

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);
