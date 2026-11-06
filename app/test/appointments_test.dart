// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/mail/appointments_model.dart';
import 'package:citusmail/src/services/auto_reader.dart';
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
}

final _manage = Uri.parse('https://clinic.example/manage');
final _http = Uri.parse('http://clinic.example/old');

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);
