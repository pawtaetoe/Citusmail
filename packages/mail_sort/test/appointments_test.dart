// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:test/test.dart';

/// Mail sent around noon, so "tomorrow" is the same day everywhere.
final _now = DateTime.utc(2026, 11, 4, 12);
var _ids = 0;

AppointmentEmail mail(
  String subject, {
  required String sender,
  String? name,
  String text = '',
  int daysAgo = 0,
  DateTime? at,
  String? html,
  AppointmentInvite? invite,
  List<MailLink> links = const [],
  bool bulk = false,
}) {
  final things = html == null
      ? const <SchemaThing>[]
      : StructuredData.extract(html);
  return AppointmentEmail(
    messageId: ++_ids,
    sender: sender,
    senderName: name,
    subject: subject,
    text: text,
    at: at ?? _now.subtract(Duration(days: daysAgo)),
    appointments: AppointmentInfo.allIn(things),
    reservations: ReservationInfo.allIn(things),
    invite: invite,
    links: links,
    bulk: bulk,
  );
}

List<Appointment> find(List<AppointmentEmail> emails) =>
    AppointmentFinder.find(emails);

/// The wall clock time of [t]: "2026-11-12 15:30".
String wall(PlaceTime t) =>
    '${t.wall.toIso8601String().substring(0, 10)} '
    '${t.wall.toIso8601String().substring(11, 16)}';

AppointmentEmail _dentistUk() => mail(
  'Appointment confirmation - Bright Smile Dental',
  sender: 'brightsmiledental.co.uk',
  name: 'Bright Smile Dental',
  daysAgo: 10,
  text:
      'Dear Alice,\n\n'
      'This is to confirm your appointment with Dr Patel on Thursday 12th '
      'November 2026 at 3.30pm.\n\n'
      'Treatment: Scale and polish\n'
      'Address: 14 High Street, Oxford OX1 4AA\n\n'
      'If you need to reschedule or cancel, please call us on 01865 123456 '
      'at least 24 hours before your appointment. A late cancellation fee '
      'may apply.\n\n'
      'Kind regards,\nBright Smile Dental',
  links: [
    MailLink(
      'Manage your appointment',
      Uri.parse('https://brightsmiledental.co.uk/manage?id=88213'),
    ),
    MailLink(
      'Add to calendar',
      Uri.parse('https://brightsmiledental.co.uk/ics?id=88213'),
    ),
    MailLink('Visit our website', Uri.parse('https://brightsmiledental.co.uk')),
    MailLink('Unsubscribe', Uri.parse('https://brightsmiledental.co.uk/u')),
  ],
);

AppointmentEmail _fresha() => mail(
  'Your appointment at Hair by Mia is confirmed',
  sender: 'fresha.com',
  name: 'Fresha',
  daysAgo: 3,
  text:
      'Hi Alice, your appointment is confirmed.\n\n'
      'Sat, 21 Nov 2026 at 11:00\n'
      "Women's cut & blow dry with Mia · 1h\n\n"
      'Hair by Mia\n'
      '22 Tiong Bahru Road, Singapore 168731\n\n'
      'Booking ref: #A1B2C3D4\n\n'
      'Manage appointment\nAdd to calendar\n\n'
      'Cancellation policy: cancel for free up to 24 hours before.',
  links: [
    MailLink(
      'Manage appointment',
      Uri.parse('https://www.fresha.com/a/hair-by-mia/manage/A1B2C3D4'),
    ),
  ],
);

void main() {
  group('confirmations in words', () {
    test('a dentist, UK wording', () {
      final a = find([_dentistUk()]).single;
      expect(a.title, 'Bright Smile Dental');
      expect(a.kind, AppointmentKind.health);
      expect(a.service, 'Scale and polish');
      expect(wall(a.start), '2026-11-12 15:30');
      expect(a.start.offset, isNull);
      expect(a.place, '14 High Street, Oxford OX1 4AA');
      expect(a.cancelled, isFalse);
      // Only the links that manage it or add it to a calendar.
      expect(
        [for (final l in a.links) l.label],
        ['Manage your appointment', 'Add to calendar'],
      );
      expect(AppointmentFinder.word(a), 'Dentist');
    });

    test('a dentist, Singapore wording with a numeric date', () {
      final a = find([
        mail(
          'Appointment Confirmation',
          sender: 'smiledental.com.sg',
          name: 'Smile Dental Centre (Tampines)',
          daysAgo: 2,
          text:
              'Dear Ms Alice Tan,\n'
              'Your appointment at Smile Dental Centre (Tampines) is '
              'confirmed for 14/11/2026, 10:15 AM.\n'
              'Booking ref: SDC-48213\n'
              'Address: 1 Tampines Central 5, #02-11, Singapore 529508\n'
              'Please arrive 10 minutes early and bring your NRIC.',
        ),
      ]).single;
      expect(a.title, 'Smile Dental Centre (Tampines)');
      expect(a.kind, AppointmentKind.health);
      expect(wall(a.start), '2026-11-14 10:15');
      expect(a.reference, 'SDC-48213');
      expect(a.place, '1 Tampines Central 5, #02-11, Singapore 529508');
    });

    test('a hair salon booked through Fresha', () {
      final a = find([_fresha()]).single;
      // The business, not the booking site.
      expect(a.title, 'Hair by Mia');
      expect(a.kind, AppointmentKind.beauty);
      expect(wall(a.start), '2026-11-21 11:00');
      expect(a.reference, 'A1B2C3D4');
      expect(a.place, '22 Tiong Bahru Road, Singapore 168731');
      expect(a.links.single.label, 'Manage appointment');
    });

    test('a barber booked through Booksy', () {
      final a = find([
        mail(
          'Booking confirmed: Skin fade at Kings Cuts',
          sender: 'booksy.com',
          name: 'Booksy',
          daysAgo: 1,
          text:
              "You're booked! Your booking at Kings Cuts is confirmed.\n"
              'Service: Skin fade\n'
              'When: Friday, November 20, 2026, 5:45 PM - 6:30 PM\n'
              'Where: 9 Arab Street, Singapore 199723',
        ),
      ]).single;
      expect(a.title, 'Kings Cuts');
      expect(a.service, 'Skin fade');
      expect(a.kind, AppointmentKind.beauty);
      expect(wall(a.start), '2026-11-20 17:45');
      expect(wall(a.end!), '2026-11-20 18:30');
      expect(a.place, '9 Arab Street, Singapore 199723');
    });

    test('a car service', () {
      final a = find([
        mail(
          'Your service booking is confirmed',
          sender: 'northsidemotors.co.uk',
          name: 'Northside Motors Bookings',
          daysAgo: 5,
          text:
              'Thanks for booking with Northside Motors.\n'
              'Booking confirmed: Full service and MOT for your Ford Fiesta '
              '(AB12 CDE) on Mon 16 Nov 2026, drop-off 08:30.\n'
              'Booking reference: NSM-20931\n'
              'Where: Unit 4, Mill Lane, Leeds LS6 2AB',
        ),
      ]).single;
      expect(a.title, 'Northside Motors');
      expect(a.kind, AppointmentKind.car);
      expect(wall(a.start), '2026-11-16 08:30');
      expect(a.reference, 'NSM-20931');
      expect(a.place, 'Unit 4, Mill Lane, Leeds LS6 2AB');
      expect(AppointmentFinder.word(a), 'Car service');
    });

    test('a government appointment', () {
      final a = find([
        mail(
          'Appointment confirmed: Passport collection',
          sender: 'ica.gov.sg',
          name: 'ICA',
          daysAgo: 7,
          text:
              'Your appointment has been booked.\n\n'
              'Service: Passport collection\n'
              'Date: 20/11/2026\n'
              'Time: 9:40 AM\n'
              'Appointment ID: P-7781-2210\n'
              'Location: ICA Building, 10 Kallang Road, Singapore 208718\n\n'
              'Please bring your NRIC and the old passport.',
        ),
      ]).single;
      expect(a.kind, AppointmentKind.official);
      expect(a.title, 'ICA');
      expect(a.service, 'Passport collection');
      expect(wall(a.start), '2026-11-20 09:40');
      expect(a.reference, 'P-7781-2210');
      expect(a.place, 'ICA Building, 10 Kallang Road, Singapore 208718');
    });

    test(
      'an interview, a parent-teacher meeting, a class, a delivery slot',
      () {
        final found = find([
          mail(
            'Interview invitation – Product Designer',
            sender: 'acme-careers.com',
            name: 'Acme Careers',
            daysAgo: 3,
            text:
                'Hi Alice, we would like to invite you to an interview for the '
                'Product Designer role. Your interview is scheduled for '
                'Wednesday 18 November 2026 at 2:00 PM (video call, link to '
                'follow).',
          ),
          mail(
            'Parent-teacher meeting booked',
            sender: 'greenwood.edu.sg',
            name: 'Greenwood Primary School',
            daysAgo: 4,
            text:
                'Your parent-teacher meeting with Mrs Koh (Class 3B) is booked '
                'for 19 Nov 2026 at 4:20 pm in Classroom 3B.',
          ),
          mail(
            "You're booked: Reformer Pilates",
            sender: 'corestudio.sg',
            name: 'Core Studio',
            daysAgo: 1,
            text:
                "You're booked! Reformer Pilates with Jess on Tue 17 Nov 2026 "
                'at 7:30 AM. Please arrive 10 minutes early.',
          ),
          mail(
            'Your delivery slot is booked',
            sender: 'freshgrocer.sg',
            name: 'FreshGrocer',
            daysAgo: 1,
            text:
                'Thanks for your order! Your delivery slot is booked for '
                'Wed 11 Nov 2026, 10:00 - 12:00.',
          ),
        ]);
        expect(
          {for (final a in found) a.title: a.kind},
          {
            'Acme Careers': AppointmentKind.interview,
            'Greenwood Primary School': AppointmentKind.school,
            'Core Studio': AppointmentKind.lesson,
            'FreshGrocer': AppointmentKind.delivery,
          },
        );
        final interview = found.firstWhere((a) => a.title == 'Acme Careers');
        expect(interview.online, isTrue);
        final slot = found.firstWhere((a) => a.title == 'FreshGrocer');
        expect(wall(slot.start), '2026-11-11 10:00');
        expect(wall(slot.end!), '2026-11-11 12:00');
      },
    );
  });

  group('markup and calendar files', () {
    test('a schema.org ServiceReservation', () {
      final a = find([
        mail(
          'Your booking is confirmed',
          sender: 'corephysio.example',
          name: 'Core Physio',
          daysAgo: 2,
          html: '''
<script type="application/ld+json">
{"@context": "https://schema.org", "@type": "ServiceReservation",
 "reservationNumber": "PHY-1192",
 "reservationStatus": "https://schema.org/ReservationConfirmed",
 "startTime": "2026-11-21T14:00:00+08:00",
 "endTime": "2026-11-21T14:45:00+08:00",
 "modifyReservationUrl": "https://corephysio.example/manage/PHY-1192",
 "provider": {"@type": "MedicalClinic", "name": "Core Physio",
   "address": {"@type": "PostalAddress", "streetAddress": "80 Robinson Road",
     "addressLocality": "Singapore", "postalCode": "068898"}},
 "reservationFor": {"@type": "Service", "name": "Physiotherapy assessment"}}
</script>''',
        ),
      ]).single;
      expect(a.title, 'Core Physio');
      expect(a.service, 'Physiotherapy assessment');
      expect(a.kind, AppointmentKind.health);
      // An exact moment: shown in the reader's own time zone.
      expect(a.start.instant, DateTime.utc(2026, 11, 21, 6));
      expect(a.end!.instant, DateTime.utc(2026, 11, 21, 6, 45));
      expect(a.reference, 'PHY-1192');
      expect(a.place, '80 Robinson Road, Singapore, 068898');
      expect(a.links.first.label, 'Manage booking');
    });

    test('a calendar file from a clinic', () {
      final a = find([
        mail(
          'Appointment confirmation',
          sender: 'rafflesmedical.example',
          name: 'Raffles Medical Holland V',
          daysAgo: 6,
          text: 'Please find your appointment attached.',
          invite: AppointmentInvite(
            uid: 'appt-55120@rafflesmedical.example',
            summary: 'Flu vaccination at Raffles Medical Holland V',
            location: '118 Holland Avenue, #02-01, Singapore 278997',
            start: PlaceTime(
              2026,
              11,
              25,
              hour: 9,
              minute: 30,
              offset: const Duration(hours: 8),
            ),
            end: PlaceTime(
              2026,
              11,
              25,
              hour: 9,
              minute: 45,
              offset: const Duration(hours: 8),
            ),
            organizerEmail: 'noreply@rafflesmedical.example',
            guests: 1,
          ),
        ),
      ]).single;
      expect(a.title, 'Raffles Medical Holland V');
      expect(a.service, 'Flu vaccination');
      expect(a.kind, AppointmentKind.health);
      expect(a.start.instant, DateTime.utc(2026, 11, 25, 1, 30));
      expect(a.place, '118 Holland Avenue, #02-01, Singapore 278997');
      expect(AppointmentFinder.word(a), 'Vaccination');
    });

    test('meeting invites from colleagues stay invitations', () {
      expect(
        find([
          mail(
            'Invitation: Q4 roadmap review @ Thu 12 Nov 2026 3pm - 4pm',
            sender: 'acme.com',
            name: 'Dana Lee',
            daysAgo: 2,
            text: 'Join with Google Meet. Reply for alice@acme.com.',
            invite: AppointmentInvite(
              uid: 'q4review@google.com',
              summary: 'Q4 roadmap review',
              start: PlaceTime(
                2026,
                11,
                12,
                hour: 15,
                minute: 0,
                offset: const Duration(hours: 8),
              ),
              organizerEmail: 'dana@acme.com',
              guests: 6,
              meetingLink: Uri.parse('https://meet.google.com/abc-defg-hij'),
            ),
          ),
          mail(
            'Invitation: Weekly 1:1 Alice / Dana',
            sender: 'acme.com',
            name: 'Dana Lee',
            daysAgo: 2,
            invite: AppointmentInvite(
              uid: 'one-on-one@google.com',
              summary: 'Weekly 1:1 Alice / Dana',
              start: PlaceTime(
                2026,
                11,
                13,
                hour: 10,
                minute: 0,
                offset: const Duration(hours: 8),
              ),
              organizerEmail: 'dana@acme.com',
              guests: 1,
            ),
          ),
          mail(
            'Meeting confirmed: Project sync with Dana',
            sender: 'calendarly.example',
            name: 'Calendarly',
            daysAgo: 1,
            text:
                'Your meeting is scheduled for Tue 10 Nov 2026 10:00. Join '
                'with the video link. Reschedule or cancel from your '
                'calendar.',
          ),
        ]),
        isEmpty,
      );
    });
  });

  group('updates', () {
    test('a reschedule: the newest time wins', () {
      final found = find([
        _dentistUk(),
        mail(
          'Your appointment has been rescheduled',
          sender: 'brightsmiledental.co.uk',
          name: 'Bright Smile Dental',
          daysAgo: 4,
          text:
              'Dear Alice, your appointment with Bright Smile Dental has been '
              'moved from Thursday 12 November 2026 at 3:30 PM to Friday 13 '
              'November 2026 at 10:00 AM. We look forward to seeing you.',
        ),
      ]);
      final a = found.single;
      expect(wall(a.start), '2026-11-13 10:00');
      expect(wall(a.previousStart!), '2026-11-12 15:30');
      expect(a.changed, isTrue);
      expect(a.cancelled, isFalse);
      expect(a.records, hasLength(2));
      // What the first email said still shows.
      expect(a.service, 'Scale and polish');
    });

    test('a cancellation shows as cancelled', () {
      final a = find([
        _fresha(),
        mail(
          'Your appointment has been cancelled',
          sender: 'fresha.com',
          name: 'Fresha',
          daysAgo: 1,
          text:
              'Hi Alice, your appointment at Hair by Mia on Sat, 21 Nov 2026 '
              'at 11:00 has been cancelled. We hope to see you again soon.',
        ),
      ]).single;
      expect(a.cancelled, isTrue);
      expect(wall(a.start), '2026-11-21 11:00');
      expect(a.records, hasLength(2));
    });

    test('a cancellation with only the reference', () {
      final a = find([
        _fresha(),
        mail(
          'Booking cancelled',
          sender: 'fresha.com',
          name: 'Fresha',
          daysAgo: 1,
          text: 'Booking ref: #A1B2C3D4 at Hair by Mia was cancelled by you.',
        ),
      ]).single;
      expect(a.cancelled, isTrue);
    });

    test('"your appointment is tomorrow" belongs to the same appointment', () {
      final a = find([
        _dentistUk(),
        mail(
          'Reminder: your appointment is tomorrow',
          sender: 'brightsmiledental.co.uk',
          name: 'Bright Smile Dental',
          at: DateTime.utc(2026, 11, 11, 12),
          text:
              'Hi Alice, a friendly reminder that your appointment with '
              'Bright Smile Dental is tomorrow at 3:30 PM. Reply C to cancel.',
        ),
      ]).single;
      expect(a.records, hasLength(2));
      expect(a.records.last.reminds, isTrue);
      expect(a.changed, isFalse);
      expect(wall(a.start), '2026-11-12 15:30');
    });

    test('two visits to the same clinic are two appointments', () {
      final found = find([
        _dentistUk(),
        mail(
          'Appointment confirmation - Bright Smile Dental',
          sender: 'brightsmiledental.co.uk',
          name: 'Bright Smile Dental',
          daysAgo: 1,
          text:
              'This is to confirm your appointment with Dr Patel on 10 '
              'December 2026 at 9:00 AM.',
        ),
      ]);
      expect(found, hasLength(2));
      expect(found.map((a) => a.key).toSet(), hasLength(2));
    });
  });

  group('not appointments', () {
    test('newsletters and offers that say "book now"', () {
      expect(
        find([
          mail(
            'Black Friday: 20% off spa days – book now',
            sender: 'serenityspa.example',
            name: 'Serenity Spa',
            text:
                'Book your appointment now! Offer valid until 30 Nov 2026 at '
                '11:59 PM. Unsubscribe.',
            bulk: true,
          ),
          mail(
            "It's time for your check-up",
            sender: 'brightsmiledental.co.uk',
            name: 'Bright Smile Dental',
            text:
                'You are due for a check-up. Book your appointment online. '
                'Our clinic is open Mon to Fri, 9:00 AM to 6:00 PM.',
          ),
          mail(
            'New this month at Hair by Mia',
            sender: 'hairbymia.example',
            name: 'Hair by Mia',
            text:
                'Our new stylist starts on 1 Dec 2026 at 10:00. Book now to '
                'get your appointment confirmed early!',
            bulk: true,
          ),
        ]),
        isEmpty,
      );
    });

    test('marketing "schedule a demo"', () {
      expect(
        find([
          mail(
            'See Acme CRM in action – schedule a demo',
            sender: 'acmecrm.example',
            name: 'Acme CRM',
            text:
                'Pick a time that suits you: our team is available Tue 10 '
                'Nov 2026 at 3:00 PM. Your demo is booked in one click.',
          ),
        ]),
        isEmpty,
      );
    });

    test('restaurant tables and tickets are Trips', () {
      expect(
        find([
          mail(
            'Your reservation at Burnt Ends is confirmed',
            sender: 'opentable.com',
            name: 'OpenTable',
            text:
                'Your reservation is confirmed. Table for 4 on Sat 14 Nov '
                '2026 at 7:30 PM. Reservation number 118273.',
          ),
          mail(
            'Your booking is confirmed',
            sender: 'chope.co',
            name: 'Chope',
            html: '''
<script type="application/ld+json">
{"@type": "FoodEstablishmentReservation", "startTime": "2026-11-14T19:30:00+08:00",
 "reservationFor": {"@type": "Restaurant", "name": "Odette"}}
</script>''',
            text: 'Your booking at Odette is confirmed for 14 Nov 2026 at 7:30 PM.',
          ),
          mail(
            'Your tickets: Coldplay – Music of the Spheres',
            sender: 'ticketmaster.sg',
            name: 'Ticketmaster',
            text:
                'Your booking is confirmed. Sat 28 Nov 2026 at 7:30 PM, '
                'National Stadium. Your tickets are attached.',
          ),
          mail(
            'Booking confirmed: Park Hotel Shinjuku',
            sender: 'agoda.com',
            name: 'Agoda',
            text:
                'Your booking is confirmed. Check-in: 12 Dec 2026 15:00. '
                'Check-out: 15 Dec 2026 11:00. Booking ID 1234567.',
          ),
        ]),
        isEmpty,
      );
    });

    test('delivery notices without a booked slot', () {
      expect(
        find([
          mail(
            'Your parcel is out for delivery',
            sender: 'ninjavan.co',
            name: 'Ninja Van',
            text:
                'Your parcel is out for delivery today and will arrive by '
                '8:00 PM. Tracking number NVSGAMZN000123.',
          ),
          mail(
            'Your order has shipped',
            sender: 'amazon.sg',
            name: 'Amazon.sg',
            text:
                'Your order has been shipped. Estimated delivery: Tue 10 Nov '
                '2026 by 9:00 PM. Track your package.',
          ),
        ]),
        isEmpty,
      );
    });

    test('replies and a confirmation without a time', () {
      expect(
        find([
          mail(
            'Re: Your appointment is confirmed',
            sender: 'gmail.com',
            name: 'Bob',
            text:
                'Your appointment is confirmed for Thu 12 Nov 2026 at 3:30 '
                'PM? Can I come along?',
          ),
          mail(
            'Your booking is confirmed',
            sender: 'cleanhome.example',
            name: 'CleanHome',
            text: 'Your cleaning is booked. We will call you to agree a time.',
          ),
        ]),
        isEmpty,
      );
    });
  });

  group('reading words', () {
    test('times', () {
      List<String> times(String s) => [
        for (final t in AppointmentText.timesIn(s))
          '${t.hour}:${t.minute.toString().padLeft(2, '0')}',
      ];
      expect(times('3:30 PM'), ['15:30']);
      expect(times('3.30pm'), ['15:30']);
      expect(times('at 3pm'), ['15:00']);
      expect(times('15:30 hrs'), ['15:30']);
      expect(times('12 am and 12 pm'), ['0:00', '12:00']);
      // Not times: a price, a number, a word starting with "am".
      expect(times(r'S$12.50, 3 Amazon gift cards, room 12'), isEmpty);
    });

    test('which subjects are worth downloading', () {
      expect(
        AppointmentFinder.looksLikeAppointment('Your appointment is confirmed'),
        isTrue,
      );
      expect(
        AppointmentFinder.looksLikeAppointment('Booking confirmed: Haircut'),
        isTrue,
      );
      expect(
        AppointmentFinder.looksLikeAppointment('Your flight booking SQ 638'),
        isFalse,
      );
      expect(
        AppointmentFinder.looksLikeAppointment(
          'Your reservation at Burnt Ends is confirmed',
        ),
        isFalse,
      );
      expect(
        AppointmentFinder.looksLikeAppointment(
          'Appointment reservation confirmed',
        ),
        isTrue,
      );
      expect(
        AppointmentFinder.looksLikeAppointment('Book now: 20% off'),
        isFalse,
      );
      expect(
        AppointmentFinder.looksLikeAppointment('Re: appointment tomorrow'),
        isFalse,
      );
    });
  });
}
