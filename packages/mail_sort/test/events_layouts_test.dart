// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Event and appointment wordings found missing or misread in real mail,
// each as an invented fixture of the same shape.

import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

var _ids = 0;

EventEmail event(
  String subject, {
  required String sender,
  String? name,
  String text = '',
  DateTime? at,
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
    at: at ?? DateTime.utc(2026, 9, 1, 9),
    reservations: ReservationInfo.allIn(things),
    appointments: AppointmentInfo.allIn(things),
    invite: invite,
    links: links,
    bulk: bulk,
  );
}

AppointmentEmail appointment(EventEmail e) => AppointmentEmail(
  messageId: e.messageId,
  sender: e.sender,
  senderName: e.senderName,
  subject: e.subject,
  text: e.text,
  at: e.at,
  invite: e.invite,
  links: e.links,
);

void main() {
  group('not an event', () {
    test('a train booking, with its calendar file, is the Trips page\'s', () {
      final train = event(
        'Your Booking Confirmation: 70412236',
        sender: 'westvale-rail.example',
        name: 'Westvale Rail',
        text:
            'Your ticket is confirmed. Thank you for booking with Westvale '
            'Rail. Alder Central to Birchmoor Terminus. Outward Saturday 26 '
            'September 2026 Depart 08:00 Arrive 13:38. This train calls at '
            'Cedar Halt.',
        invite: AppointmentInvite(
          uid: 'rail-70412236',
          summary: 'Alder Central to Birchmoor Terminus',
          start: PlaceTime(2026, 9, 26, hour: 8),
          end: PlaceTime(2026, 9, 26, hour: 13, minute: 38),
        ),
      );
      expect(EventFinder.read(train), isNull);
    });

    test('a calendar file nobody else is invited to is no meeting', () {
      final r = EventFinder.read(
        event(
          'Your registration',
          sender: 'lanternfest.example',
          name: 'Lantern Night',
          invite: AppointmentInvite(
            uid: 'ln-1',
            summary: 'Lantern Night at Willowmere',
            start: PlaceTime(2026, 10, 24, hour: 19),
          ),
        ),
      );
      expect(r?.kind, isNot(EventKind.meeting));
    });

    test('a boarding pass is no match, whatever it must match', () {
      expect(
        EventFinder.read(
          event(
            'EI123/28Jul27/014C/ROE',
            sender: 'exampleair.example',
            text:
                'Names on this boarding pass must match your '
                'travel document. FLIGHT EI123 DUB HEL 28Jul27 07:45',
          ),
        ),
        isNull,
      );
      expect(
        EventText.kindOf('Your ID must match the booking'),
        EventKind.other,
      );
    });

    test('a medical screening is no film: an appointment', () {
      final e = event(
        'Your screening booking',
        sender: 'healthpoint.example',
        name: 'Healthpoint Clinics',
        text:
            'Thank you. You have booked your health screening '
            'appointment on 24 Oct 2026 at 8.00 AM.\n'
            'Location: Healthpoint Riverside, 3 Example Quay',
        at: DateTime.utc(2026, 10, 20, 2),
      );
      expect(EventText.kindOf('Your medical screening'), EventKind.other);
      expect(EventFinder.read(e), isNull);
      final a = AppointmentFinder.read(appointment(e))!;
      expect(a.kind, AppointmentKind.health);
      expect(a.start?.wall, DateTime.utc(2026, 10, 24, 8));
    });
  });

  group('booked events', () {
    test('markup in bulk mail counts when it names the booking', () {
      const ld = '''
<script type="application/ld+json">
{"@type": "EventReservation", "reservationNumber": "R-5521",
 "underName": {"@type": "Person", "name": "A Customer"},
 "reservationFor": {"@type": "Event", "name": "Rowing Boat Hire",
   "startDate": "2026-10-04T10:00:00",
   "location": {"@type": "Place", "name": "Mirror Lake Jetty",
     "address": {"@type": "PostalAddress", "addressLocality": "Fernbridge"}}}}
</script>''';
      final r = EventFinder.read(
        event(
          'Reminder of your booking for Sunday, October 4, 2026 at 10:00',
          sender: 'lakebookings.example',
          html: ld,
          bulk: true,
        ),
      )!;
      expect(r.title, 'Rowing Boat Hire');
      expect(r.start?.wall, DateTime.utc(2026, 10, 4, 10));
      // A promotion's markup names no booking.
      final promo = EventFinder.read(
        event(
          'Boat hire this weekend',
          sender: 'lakebookings.example',
          html: ld
              .replaceFirst('"reservationNumber": "R-5521",', '')
              .replaceFirst(
                '"underName": {"@type": "Person", "name": "A Customer"},',
                '',
              ),
          bulk: true,
        ),
      );
      expect(promo, isNull);
    });

    test('a ticket in words, its day with a weekday and no year', () {
      final e = event(
        'Hollowmere Palace - Ticket',
        sender: 'trips.example.ac.uk',
        text:
            'Hello Student, We have you booked onto the Hollowmere Palace '
            'Entrance on Sunday 13th September. Show your event QR code '
            'at the gate. The coach leaves at 9.15am.',
        at: DateTime.utc(2026, 9, 10, 9),
      );
      expect(EventFinder.looksLikeEvent(e.subject, preview: e.text), isTrue);
      final r = EventFinder.read(e)!;
      expect(r.title, 'Hollowmere Palace');
      expect(r.start?.day, DateTime(2026, 9, 13));
      expect(r.kind, EventKind.exhibition);
    });

    test('a visit booked in words: "enjoy your visit"', () {
      final e = event(
        'Museo Brightwater booking confirmation - QVX0004417',
        sender: 'villaesempio.example',
        text:
            'Payment received for your order (booking number: QVX0004417). '
            'We look forward to welcoming you at Museo Brightwater. Enjoy '
            'your visit!\nDate of visit: 05/12/2026 10:00\n'
            'ENTRANCE x2',
        at: DateTime.utc(2026, 11, 1, 9),
      );
      expect(EventFinder.looksLikeEvent(e.subject, preview: e.text), isTrue);
      final r = EventFinder.read(e)!;
      expect(r.start?.wall, DateTime.utc(2026, 12, 5, 10));
      expect(r.reference, 'QVX0004417');
    });

    test(
      'an activity site\'s booking: one event, tidy, its reminder joined',
      () {
        const subject =
            "Booking confirmed - 'PUZZLE VAULT' Saturday, 10 Oct 2026 10:30 AM";
        final preview = event(
          subject,
          sender: 'bookeo.com',
          name: 'Puzzle Vault',
          text: 'Your booking is confirmed! Booking number: 77104452198830',
          at: DateTime.utc(2026, 9, 20, 3),
        );
        // The preview is not an appointment.
        expect(AppointmentFinder.read(appointment(preview)), isNull);
        final body = event(
          subject,
          sender: 'bookeo.com',
          name: 'Puzzle Vault',
          text: '''
Price: \$90.00
Address: Unit 4, 12 Example Road, Fernbridge QX9 4ZZ (view map
Your booking is confirmed! The Lost Library Saturday, 10 Oct 2026 10:30 AM - 11:30 AM (60 minutes)
Booking number: 77104452198830
Thanks for choosing our escape room.
''',
          at: DateTime.utc(2026, 9, 20, 3),
        );
        final r = EventFinder.read(body)!;
        expect(r.title, 'Puzzle Vault');
        expect(r.start?.wall, DateTime.utc(2026, 10, 10, 10, 30));
        expect(r.end?.wall, DateTime.utc(2026, 10, 10, 11, 30));
        expect(r.venue, 'Unit 4, 12 Example Road, Fernbridge QX9 4ZZ');
        final events = EventFinder.find([
          body,
          event(
            'Reminder: Saturday, 10 Oct 2026 10:30 AM',
            sender: 'bookeo.com',
            name: 'Puzzle Vault',
            text: 'See you soon.',
            at: DateTime.utc(2026, 10, 9, 3),
          ),
        ]);
        expect(events.single.records, hasLength(2));
      },
    );

    test('a zone written in words gives the offset, summer time too', () {
      final r = EventFinder.read(
        event(
          'Clayworks Live: Glaze 201 Confirmation',
          sender: 'zoom.us',
          name: 'Example Academy',
          text:
              'Thank you for registering for Clayworks Live: Glaze 201.\n'
              'Date Time: Sep 2, 2026 12:00 PM Eastern Time (US and Canada)\n'
              'Join from a PC: https://example.zoom.us/w/95512345678',
          at: DateTime.utc(2026, 8, 20, 9),
        ),
      )!;
      expect(r.start?.wall, DateTime.utc(2026, 9, 2, 12));
      expect(r.start?.offset, const Duration(hours: -4));
      final winter = EventFinder.read(
        event(
          'Clayworks Live: Glaze 202 Confirmation',
          sender: 'zoom.us',
          name: 'Example Academy',
          text:
              'Thank you for registering for Clayworks Live: Glaze 202.\n'
              'Date Time: Dec 2, 2026 02:00 PM Osaka, Sapporo, Tokyo\n'
              'Join: https://example.zoom.us/w/95512345679',
          at: DateTime.utc(2026, 11, 20, 9),
        ),
      )!;
      expect(winter.start?.offset, const Duration(hours: 9));
    });

    test('a webinar\'s "starts in 1 hour" reminder', () {
      final r = EventFinder.read(
        event(
          'Reminder: Clayworks Live: Glaze 201 starts in 1 Hour',
          sender: 'zoom.us',
          name: 'Example Academy',
          text:
              'This is a reminder that "Clayworks Live: Glaze 201" will begin '
              'in 1 hour on:\nDate Time: Sep 2, 2026 12:00 PM Eastern Time '
              '(US and Canada)\nClick Here to Join\nPasscode: 424242',
          links: [
            MailLink(
              'Click Here to Join',
              Uri.parse('https://example.zoom.us/w/95512345678?tk=q'),
            ),
          ],
          at: DateTime.utc(2026, 9, 2, 15),
        ),
      )!;
      expect(r.title, 'Clayworks Live: Glaze 201');
      expect(r.start?.wall, DateTime.utc(2026, 9, 2, 12));
    });
  });

  group('appointments', () {
    test('a collection slot at a branch is an errand, its business the '
        'domain\'s', () {
      final a = AppointmentFinder.read(
        AppointmentEmail(
          messageId: MessageId(++_ids),
          sender: 'harbourbank.example',
          senderName: null,
          subject: 'Appointment confirmed',
          text:
              'You have booked the following appointment to collect your '
              'new card.\nDate: 14-10-2026 Time: 11.30 am (Collection slot '
              '11.30 am - 11.45 am)\nBranch: Riverside',
          at: DateTime.utc(2026, 10, 1, 2),
        ),
      )!;
      expect(a.kind, AppointmentKind.official);
      expect(a.business, 'Harbourbank');
      expect(a.start?.wall, DateTime.utc(2026, 10, 14, 11, 30));
    });
  });
}
