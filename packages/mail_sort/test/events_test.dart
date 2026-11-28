// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

/// Every company, person, place and number below is made up.
final _now = DateTime.utc(2026, 11, 20, 12);
var _ids = 0;

EventEmail mail(
  String subject, {
  required String sender,
  String? name,
  String text = '',
  int daysAgo = 0,
  String? html,
  AppointmentInvite? invite,
  List<MailLink> links = const [],
  bool bulk = false,
}) {
  final things = html == null
      ? const <SchemaThing>[]
      : StructuredData.extract(html);
  return EventEmail(
    messageId: MessageId(++_ids),
    sender: sender,
    senderName: name,
    subject: subject,
    text: text,
    at: _now.subtract(Duration(days: daysAgo)),
    reservations: ReservationInfo.allIn(things),
    appointments: AppointmentInfo.allIn(things),
    invite: invite,
    links: links,
    bulk: bulk,
  );
}

List<Event> find(List<EventEmail> emails) => EventFinder.find(emails);

/// The wall clock time of [t]: "2026-11-12 15:30".
String wall(PlaceTime t) =>
    '${t.wall.toIso8601String().substring(0, 10)} '
    '${t.wall.toIso8601String().substring(11, 16)}';

PlaceTime _sgt(int month, int day, int hour, [int minute = 0]) => PlaceTime(
  2026,
  month,
  day,
  hour: hour,
  minute: minute,
  offset: const Duration(hours: 8),
);

EventEmail _factoryTour() => mail(
  'Thank you! Your «House of Cocoa» order has been received.',
  sender: 'cocoahouse.example',
  name: 'House of Cocoa',
  daysAgo: 6,
  text:
      'Dear Sam,\n\n'
      'Thank you for purchasing tickets for «Guided Factory Tour & Praline '
      'Workshop». Your order is below; show it at the front desk when you '
      'arrive.\n\n'
      'Date of Event: 18 December 2026\n'
      'Arrival: 10:15\n'
      'Start time: 10:30\n\n'
      'Event location: House of Cocoa, Fabrikweg 12, 8000 Zurich\n\n'
      'Total amount: CHF 64.00\n\n'
      'Order Number #418822\n\n'
      'We are looking forward to seeing you!',
);

EventEmail _distillery({int daysAgo = 30}) => mail(
  'Your Booking is Confirmed - THE HIGHLAND STILLS EXPERIENCE',
  sender: 'bookinghub.example',
  name: 'Highland Stills',
  daysAgo: daysAgo,
  text:
      'Hi Sam,\nYour Booking is Confirmed.\n\n'
      'Here are your tickets: keep them on your phone or print '
      'them.\n\n'
      'Booking Details\n'
      'Booking ID: 7712003\n'
      'Experience: THE HIGHLAND STILLS EXPERIENCE\n'
      'Date: Thursday, December 10, 2026 at 2:00pm\n'
      'Duration: 3 Hours\n'
      'Location: Glenmoor Road, Kinloch KL1 2AB, UK\n\n'
      'Free cancellation up to 24 hours before. Cancel at least 24 hours '
      'ahead for a full refund.',
  links: [
    MailLink(
      'View your tickets →',
      Uri.parse('https://bookinghub.example/tickets/abc'),
    ),
    MailLink('Unsubscribe', Uri.parse('https://bookinghub.example/u')),
  ],
);

EventEmail _concert() => mail(
  'Your tickets: The Lanterns – World Tour 2027',
  sender: 'ticketsite.example',
  name: 'TicketSite',
  daysAgo: 20,
  text:
      'Your booking is confirmed. Sat 28 Nov 2026 at 7:30 PM, Riverside '
      'Arena. Order number: TS-448812. Your tickets are attached. Doors open '
      'at 6:30 PM.',
);

void main() {
  group('tickets and bookings', () {
    test('a guided factory tour, with a labelled date and start time', () {
      final e = find([_factoryTour()]).single;
      expect(e.kind, EventKind.tour);
      expect(e.title, 'Guided Factory Tour & Praline Workshop');
      expect(wall(e.start), '2026-12-18 10:30');
      expect(e.start.offset, isNull, reason: 'the clock time as written');
      expect(e.venue, 'House of Cocoa, Fabrikweg 12, 8000 Zurich');
      expect(e.reference, '418822');
      expect(e.cancelled, isFalse);
      expect(e.online, isFalse);
    });

    test('an experience booked through a booking site, and its reminder', () {
      final events = find([
        _distillery(),
        mail(
          'THE HIGHLAND STILLS EXPERIENCE is in 2 days.',
          sender: 'bookinghub.example',
          name: 'Highland Stills',
          daysAgo: -18,
          text:
              'Hi Sam, THE HIGHLAND STILLS EXPERIENCE is in 2 days. See you '
              'there; bring your tickets.',
        ),
      ]);
      final e = events.single;
      expect(e.records, hasLength(2));
      expect(e.kind, EventKind.tour);
      expect(e.title, 'The Highland Stills Experience');
      // The reminder gives the day only: the booking's time stays.
      expect(wall(e.start), '2026-12-10 14:00');
      expect(wall(e.end!), '2026-12-10 17:00', reason: '3 hours');
      expect(e.reference, '7712003');
      expect(e.venue, 'Glenmoor Road, Kinloch KL1 2AB, UK');
      expect(e.cancelled, isFalse, reason: 'only the cancellation terms');
      expect(e.links.map((l) => l.label), ['View your tickets']);
    });

    test('an escape room booked through a booking site', () {
      final e = find([
        mail(
          'Booking confirmed: The Clockmaker escape room',
          sender: 'activitybook.example',
          name: 'ActivityBook',
          daysAgo: 5,
          text:
              'Your booking is confirmed!\n'
              'Activity: The Clockmaker (escape room, 60 min)\n'
              'Date: Sat 12 Dec 2026, 3:00 PM\n'
              'Meeting point: 8 Mill Lane, Unit 2\n'
              'Booking reference: AB-55120',
        ),
      ]).single;
      expect(e.kind, EventKind.tour);
      expect(e.title, 'The Clockmaker (escape room, 60 min)');
      expect(wall(e.start), '2026-12-12 15:00');
      expect(e.venue, '8 Mill Lane, Unit 2');
      expect(e.reference, 'AB-55120');
    });

    test('a cinema ticket', () {
      final e = find([
        mail(
          'Your Star Cineplex e-ticket',
          sender: 'starcineplex.example',
          name: 'Star Cineplex',
          daysAgo: 1,
          text:
              'Here is your e-ticket\n'
              'Show the QR code at the entrance\n'
              'Confirmation ID: 551200\n'
              'STARLIGHT ODYSSEY\n'
              '(PG13)\n'
              '19 Dec 2026 06:40 PM Star Cineplex Downtown Hall 3 Seat: F7, F8\n'
              '2 x Ticket(s) S\$27.00',
        ),
      ]).single;
      expect(e.kind, EventKind.movie);
      expect(e.title, 'Starlight Odyssey');
      expect(wall(e.start), '2026-12-19 18:40');
      expect(e.reference, '551200');
    });

    test('a concert ticket in words', () {
      final e = find([_concert()]).single;
      expect(e.kind, EventKind.concert);
      expect(e.title, 'The Lanterns – World Tour 2027');
      expect(wall(e.start), '2026-11-28 19:30');
      expect(e.reference, 'TS-448812');
    });

    test('a schema.org EventReservation (no longer a trip)', () {
      final e = find([
        mail(
          'Your tickets for City Ballet: The Nutcracker',
          sender: 'stagetickets.example',
          name: 'Stage Tickets',
          daysAgo: 3,
          html: '''
<script type="application/ld+json">
{"@type": "EventReservation", "reservationNumber": "ST-30021",
 "reservationStatus": "http://schema.org/ReservationConfirmed",
 "reservationFor": {"@type": "Event", "name": "The Nutcracker",
   "startDate": "2026-12-20T19:00:00+08:00",
   "location": {"@type": "Place", "name": "Grand Theatre",
     "address": "1 Harbour Road"}}}
</script>''',
          text: 'Your tickets are attached.',
        ),
      ]).single;
      expect(e.title, 'The Nutcracker');
      expect(e.kind, EventKind.show);
      expect(e.start.instant, DateTime.utc(2026, 12, 20, 11));
      expect(e.venue, 'Grand Theatre, 1 Harbour Road');
      expect(e.reference, 'ST-30021');
    });
  });

  group('meetings', () {
    test('an online meeting invitation with a calendar file', () {
      final e = find([
        mail(
          'Invitation: Design review @ Tue 1 Dec 2026 10am - 11am (SGT)',
          sender: 'northwind.example',
          name: 'Dana Lee',
          daysAgo: 2,
          text: 'Join with Google Meet. Reply for sam@northwind.example.',
          invite: AppointmentInvite(
            uid: 'design-review-1@northwind.example',
            summary: 'Design review',
            start: _sgt(12, 1, 10),
            end: _sgt(12, 1, 11),
            organizerEmail: 'dana@northwind.example',
            guests: 6,
            meetingLink: Uri.parse('https://meet.google.com/abc-defg-hij'),
          ),
        ),
      ]).single;
      expect(e.kind, EventKind.meeting);
      expect(e.title, 'Design review');
      expect(e.online, isTrue);
      expect(e.link, Uri.parse('https://meet.google.com/abc-defg-hij'));
      expect(e.start.instant, DateTime.utc(2026, 12, 1, 2));
      expect(e.end!.instant, DateTime.utc(2026, 12, 1, 3));
      expect(e.reference, isNull);
    });

    test('an interview on a video call with a panel', () {
      final e = find([
        mail(
          'Invitation: Interview – Product Designer',
          sender: 'brightpath.example',
          name: 'BrightPath Recruiting',
          daysAgo: 4,
          invite: AppointmentInvite(
            uid: 'iv-77@brightpath.example',
            summary: 'Interview – Product Designer',
            location: 'https://brightpath.zoom.us/j/81234567890',
            start: _sgt(11, 26, 15),
            end: _sgt(11, 26, 16),
            guests: 4,
          ),
        ),
      ]).single;
      expect(e.kind, EventKind.interview);
      expect(e.venue, isNull);
      expect(e.link.toString(), 'https://brightpath.zoom.us/j/81234567890');
    });

    test('an updated invitation moves it; a cancelled one cancels it', () {
      AppointmentInvite invite(
        PlaceTime start,
        int sequence, {
        bool cancelled = false,
      }) => AppointmentInvite(
        uid: 'planning-q1@northwind.example',
        sequence: sequence,
        summary: 'Q1 planning',
        start: start,
        guests: 5,
        cancelled: cancelled,
        meetingLink: Uri.parse('https://northwind.zoom.us/j/9988776655'),
      );
      final moved = find([
        mail(
          'Invitation: Q1 planning',
          sender: 'northwind.example',
          daysAgo: 10,
          invite: invite(_sgt(12, 2, 9), 0),
        ),
        mail(
          'Updated invitation: Q1 planning',
          sender: 'northwind.example',
          daysAgo: 5,
          invite: invite(_sgt(12, 3, 14), 1),
        ),
      ]).single;
      expect(moved.records, hasLength(2));
      expect(moved.start.instant, DateTime.utc(2026, 12, 3, 6));
      expect(moved.changed, isTrue);
      expect(moved.previousStart!.instant, DateTime.utc(2026, 12, 2, 1));
      expect(moved.cancelled, isFalse);

      final gone = find([
        mail(
          'Invitation: Q1 planning',
          sender: 'northwind.example',
          daysAgo: 10,
          invite: invite(_sgt(12, 2, 9), 0),
        ),
        mail(
          'Canceled event: Q1 planning',
          sender: 'northwind.example',
          daysAgo: 1,
          invite: invite(_sgt(12, 2, 9), 2, cancelled: true),
        ),
      ]).single;
      expect(gone.cancelled, isTrue);
    });

    test('an interview: a one-to-one invitation, and one in words', () {
      final events = find([
        mail(
          'Invitation: Interview with Acme Example',
          sender: 'acme.example',
          name: 'Acme Recruiting',
          daysAgo: 3,
          invite: AppointmentInvite(
            uid: 'iv-1@acme.example',
            summary: 'Interview with Acme Example',
            location: 'Acme Example, 3 Quay Street',
            start: _sgt(12, 4, 10),
            end: _sgt(12, 4, 11),
            guests: 1,
          ),
        ),
        mail(
          'Your interview with Northwind Example',
          sender: 'northwind-careers.example',
          name: 'Northwind Careers',
          daysAgo: 1,
          text:
              'Hi Sam,\nThank you for applying. Your interview has been '
              'scheduled for Wed 9 Dec 2026 at 2:30 PM.\n'
              'Location: 12 Harbour Road, Level 5\n'
              'Please bring a photo ID.',
        ),
      ]);
      expect(events.map((e) => e.kind), [
        EventKind.interview,
        EventKind.interview,
      ]);
      expect(events.first.title, 'Interview with Acme Example');
      expect(events.first.venue, 'Acme Example, 3 Quay Street');
      expect(wall(events.last.start), '2026-12-09 14:30');
      expect(events.last.venue, '12 Harbour Road, Level 5');
      expect(events.last.online, isFalse);
    });

    test('a webinar registration with a Zoom link', () {
      final e = find([
        mail(
          'Portfolio Clinic Confirmation',
          sender: 'zoom.us',
          name: 'Careers Office',
          daysAgo: 2,
          text:
              'Hello Sam,\n'
              'Thank you for registering for Portfolio Clinic. Details of the '
              'meeting are below.\n'
              'Portfolio Clinic\n'
              'Date & Time Dec 3, 2026 11:00 AM Singapore\n'
              'Meeting ID 850 0000 1111\n'
              'Passcode 000000',
          links: [
            MailLink(
              'Join Meeting',
              Uri.parse('https://careers.zoom.us/w/85000001111?tk=abc'),
            ),
          ],
        ),
      ]).single;
      expect(e.title, 'Portfolio Clinic');
      expect(e.kind, EventKind.meeting);
      expect(e.online, isTrue);
      expect(wall(e.start), '2026-12-03 11:00');
      expect(e.reference, isNull, reason: 'a meeting id is not a booking');
    });
  });

  group('updates', () {
    test('a rescheduled show: the new date counts', () {
      final e = find([
        _concert(),
        mail(
          'Your event has been rescheduled',
          sender: 'ticketsite.example',
          name: 'TicketSite',
          daysAgo: 2,
          text:
              'The Lanterns – World Tour 2027 at Riverside Arena has been '
              'moved to Sat 5 Dec 2026 at 7:30 PM. Your tickets remain valid. '
              'Order number: TS-448812.',
        ),
      ]).single;
      expect(e.records, hasLength(2));
      expect(wall(e.start), '2026-12-05 19:30');
      expect(e.changed, isTrue);
      expect(wall(e.previousStart!), '2026-11-28 19:30');
      expect(e.title, 'The Lanterns – World Tour 2027');
    });

    test('a cancellation, by its order number', () {
      final e = find([
        _concert(),
        mail(
          'Event cancelled: The Lanterns – World Tour 2027',
          sender: 'ticketsite.example',
          name: 'TicketSite',
          daysAgo: 1,
          text:
              "We're sorry: this event has been cancelled. Order number: "
              'TS-448812. Your tickets will be refunded.',
        ),
      ]).single;
      expect(e.cancelled, isTrue);
      expect(wall(e.start), '2026-11-28 19:30');
    });
  });

  group('not events', () {
    test('promotions, announcements and reviews', () {
      expect(
        find([
          mail(
            'Tickets on sale now: The Lanterns World Tour 2027',
            sender: 'ticketsite.example',
            text:
                'Get your tickets before they go! Sat 27 Nov 2027 at 7:30 PM, '
                'Riverside Arena.',
          ),
          mail(
            'New events near you this weekend',
            sender: 'eventfinder.example',
            text:
                'Concerts, comedy and festivals on Sat 28 Nov 2026 at 8 PM. '
                'Book now.',
          ),
          mail(
            'This week at the Riverside Arena',
            sender: 'riverside.example',
            bulk: true,
            text:
                'Your tickets for the concert on Sat 28 Nov 2026 at 7:30 PM '
                'are waiting. Booking confirmed for members.',
          ),
          mail(
            'Last chance: 20% off museum entry',
            sender: 'citymuseum.example',
            text: 'Buy tickets by 30 Nov 2026 at 11:59 PM.',
          ),
          mail(
            'Tell us about your House of Cocoa visit',
            sender: 'cocoahouse.example',
            text:
                'How was your tour on 18 Dec 2026 at 11:30? Leave a review '
                'of order 418822.',
          ),
          mail(
            'Invitation to attend Alumni Mixer (3 Dec 2026 7PM)',
            sender: 'campus.example',
            text: 'Register now. 3 Dec 2026 at 7:00 PM, Hall A.',
          ),
          mail(
            'Meet our new note taker',
            sender: 'zoom.us',
            text:
                'Join our webinar on 2 Dec 2026 at 10:00 AM. '
                'https://zoom.us/webinar/register/abc',
          ),
          mail(
            '[Help Desk] Ticket 51207 opened',
            sender: 'burgerplace.example',
            text: 'Ticket ID (#51207) was opened at 09:12 on 15 Nov 2026.',
          ),
        ]),
        isEmpty,
      );
    });

    test('flights, stays and tables stay on Trips', () {
      expect(
        find([
          mail(
            'Your booking is confirmed',
            sender: 'tablebook.example',
            html: '''
<script type="application/ld+json">
{"@type": "FoodEstablishmentReservation", "startTime": "2026-12-14T19:30:00+08:00",
 "reservationFor": {"@type": "Restaurant", "name": "Harbour Grill"}}
</script>''',
            text: 'Your table at Harbour Grill is confirmed.',
          ),
          mail(
            'Booking confirmed: Park Hotel Example',
            sender: 'staysite.example',
            text:
                'Your booking is confirmed. Check-in: 12 Dec 2026 15:00. '
                'Check-out: 15 Dec 2026 11:00. Booking ID 1234567.',
          ),
        ]),
        isEmpty,
      );
    });

    test('an appointment stays an appointment', () {
      final dentist = mail(
        'Appointment confirmation - Bright Smile Dental',
        sender: 'brightsmile.example',
        name: 'Bright Smile Dental',
        daysAgo: 3,
        text:
            'This is to confirm your appointment on Thursday 10 December 2026 '
            'at 3.30pm. Address: 14 High Street, Oxford.',
      );
      final salon = mail(
        'Your appointment at Hair by Mia is confirmed',
        sender: 'bookingsite.example',
        name: 'Hair by Mia',
        daysAgo: 2,
        text:
            'Your appointment is confirmed for Sat 5 Dec 2026 at 11:00. '
            "Women's cut & blow dry.",
      );
      expect(find([dentist, salon]), isEmpty);
      expect(
        AppointmentFinder.find([
          AppointmentEmail(
            messageId: dentist.messageId,
            sender: dentist.sender,
            senderName: dentist.senderName,
            subject: dentist.subject,
            text: dentist.text,
            at: dentist.at,
          ),
        ]),
        hasLength(1),
      );
    });

    test('replies, forwards and answers to invitations', () {
      expect(
        find([
          mail(
            'Re: Your tickets: The Lanterns – World Tour 2027',
            sender: 'friend.example',
            text: 'Your booking is confirmed. Sat 28 Nov 2026 at 7:30 PM.',
          ),
          mail(
            'Accepted: Design review',
            sender: 'northwind.example',
            invite: AppointmentInvite(
              uid: 'design-review-1@northwind.example',
              summary: 'Design review',
              start: _sgt(12, 1, 10),
              reply: true,
            ),
          ),
        ]),
        isEmpty,
      );
    });
  });

  group('reading words', () {
    test('which emails are worth downloading', () {
      expect(
        EventFinder.looksLikeEvent('Your tickets for The Nutcracker'),
        isTrue,
      );
      expect(
        EventFinder.looksLikeEvent(
          'Thank you! Your «House of Cocoa» order has been received.',
          preview: 'Thank you for purchasing tickets for «Guided Factory Tour»',
        ),
        isTrue,
      );
      expect(EventFinder.looksLikeEvent('Tickets on sale now'), isFalse);
      expect(EventFinder.looksLikeEvent('Your order has shipped'), isFalse);
      expect(EventFinder.looksLikeEvent('Re: concert tickets'), isFalse);
      expect(
        EventFinder.looksLikeEvent('Your flight booking is confirmed'),
        isFalse,
      );
    });

    test('titles from subjects', () {
      expect(
        EventText.titleOfSubject(
          'Invitation: Design review @ Tue 1 Dec 2026 10am - 11am (SGT)',
        ),
        'Design review',
      );
      expect(
        EventText.titleOfSubject('Your booking is confirmed - Harbour Cruise'),
        'Harbour Cruise',
      );
      expect(EventText.titleOfSubject('Your booking is confirmed'), isNull);
    });
  });
}
