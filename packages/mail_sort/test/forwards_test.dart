// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

var _ids = 0;

/// A stay forwarded by a relative from a free mail address, in the
/// layout Outlook writes: a note, a rule, the original's header block.
const _personForward = '''
Have a look, see you there!
Robin
________________________________
From: Larkspur Lodge <stays@larkspur-lodge.example>
Sent: Tuesday, June 9, 2026 7:41 PM
To: robin@freemail.example <robin@freemail.example>
Subject: Your reservation at Larkspur Lodge Quayside is confirmed. #40718293 - 14 Sep 2026

Robin, your reservation is confirmed!
Confirmation #40718293
Larkspur Lodge Quayside
Address: 9 Ferry Lane, Dunmore
Check-in: 14 Sep 2026 3:00 pm
Check-out: 17 Sep 2026 12:00 pm
''';

/// A room booking a mailbox rule forwards from the user's other
/// account: no note, the original's header block at once.
String _ruleForward(String subject, String table) =>
    '''
________________________________
From: Room Desk <room-desk@campus.example.edu>
Sent: Tuesday, 3 March 2026 10:12:44 am (UTC+01:00) Amsterdam, Berlin, Bern, Rome, Stockholm, Vienna
To: STUDENT <s7654321@campus.example.edu>
Subject: $subject

CAUTION: This email originated from outside of the organisation. Do not click links unless you know the content is safe.
Dear STUDENT,
$table
 BOOKING ID RESOURCE START DATE END DATE PURPOSE REQUESTOR
 20260303BKG000417 Q7-03-11-SR204 4 Mar 2026 09:00 4 Mar 2026 11:00 project STUDENT
''';

/// A webinar registration a mailbox rule forwards.
const _zoomForward = '''
________________________________
From: Clay Studio <no-reply@zoom.us>
Sent: Friday, 6 March 2026 9:02:10 am (UTC+01:00) Amsterdam, Berlin, Bern, Rome, Stockholm, Vienna
To: STUDENT NAME <s7654321@campus.example.edu>
Subject: Glaze Basics Taster Session Confirmation

Hello STUDENT NAME,
Thank you for registering for Glaze Basics Taster Session. You can find information about this meeting below.
Glaze Basics Taster Session
Date & Time     Mar 6, 2026 10:00 AM Amsterdam
Meeting ID      955 0123 4567
Passcode        424242
Join Meeting<https://campus-example.zoom.us/w/95501234567?tk=qq&pwd=zz>
''';

void main() {
  group('Forwards', () {
    test('tells replies from forwards', () {
      expect(Forwards.isReply('Re: dinner'), isTrue);
      expect(Forwards.isForward('Re: dinner'), isFalse);
      expect(Forwards.isForward('Fw: Your booking'), isTrue);
      expect(Forwards.isForward('FW: Your booking'), isTrue);
      expect(Forwards.isForward('Fwd: FW: Your booking'), isTrue);
      expect(Forwards.isForward('WG: Ihre Buchung'), isTrue);
      expect(Forwards.isForward('Your booking'), isFalse);
      expect(Forwards.withoutPrefix('Fwd: FW: Your booking'), 'Your booking');
    });

    test('an Outlook forward by a person: the original sender and words', () {
      final f = Forwards.unwrap(
        'Fw: Your reservation at Larkspur Lodge Quayside is confirmed. '
        '#40718293 - 14 Sep 2026',
        _personForward,
      )!;
      expect(f.senderName, 'Larkspur Lodge');
      expect(f.address, 'stays@larkspur-lodge.example');
      expect(f.domain, 'larkspur-lodge.example');
      expect(f.to, 'robin@freemail.example');
      expect(f.subject, startsWith('Your reservation at Larkspur Lodge'));
      expect(f.sent, DateTime(2026, 6, 9, 19, 41));
      expect(f.text, startsWith('Robin, your reservation is confirmed!'));
      expect(f.text, isNot(contains('see you there')));
    });

    test('a rule forward: the zone of its date, without the banner', () {
      final f = Forwards.unwrap(
        'FW: Room Desk - Booking Confirmed',
        _ruleForward('Room Desk - Booking Confirmed', 'Accepted.'),
      )!;
      expect(f.sent, DateTime.utc(2026, 3, 3, 9, 12));
      expect(f.domain, 'example.edu');
      expect(f.text, startsWith('Dear STUDENT'));
      expect(f.text, isNot(contains('CAUTION')));
    });

    test('a Gmail forward, and one of a forward', () {
      final f = Forwards.unwrap('Fwd: Fwd: Weekly sync', '''
Please pass this on.

---------- Forwarded message ---------
From: Pat <pat@freemail.example>
Date: Tue, 9 Jun 2026, 9:00 am
Subject: Fwd: Weekly sync
To: <team@agency.example>

---------- Forwarded message ---------
From: Organiser Name <organiser@agency.example>
Date: Mon, 8 Jun 2026 at 18:15
Subject: Weekly sync
To: <pat@freemail.example>

Microsoft Teams meeting
''')!;
      expect(f.address, 'organiser@agency.example');
      expect(f.subject, 'Weekly sync');
      expect(f.sent, DateTime(2026, 6, 8, 18, 15));
      expect(f.text, startsWith('Microsoft Teams meeting'));
    });

    test('a preview, all on one line', () {
      final f = Forwards.unwrap(
        'Fw: Order 5521 has shipped',
        'FYI ________________________________ From: Quillmart '
            '<orders@quillmart.example> Sent: Monday, June 1, 2026 9:10 AM '
            'To: me@freemail.example Subject: Order 5521 has shipped '
            'Your parcel is on its way',
      )!;
      expect(f.domain, 'quillmart.example');
      expect(f.subject, 'Order 5521 has shipped');
      expect(f.text, 'Your parcel is on its way');
    });

    test('nothing to unwrap: not a forward, or no header block', () {
      expect(Forwards.unwrap('Your booking', _personForward), isNull);
      expect(Forwards.unwrap('Fw: photos', 'Look at these!'), isNull);
      // "From: Alpha Central" on a ticket is no header block.
      expect(
        Forwards.unwrap('Fw: tickets', 'From: Alpha Central\nTo: Beta Hbf'),
        isNull,
      );
    });

    test('the registrable domain of a host, roughly', () {
      expect(Forwards.registrableOf('mail.example.com'), 'example.com');
      expect(Forwards.registrableOf('a.b.example.co.uk'), 'example.co.uk');
      expect(Forwards.registrableOf('campus.example.edu.sg'), 'example.edu.sg');
    });
  });

  group('finders read a forward as the email it forwards', () {
    test('Trips: a stay forwarded by a person', () {
      final b = TripFinder.bookings([
        TripEmail(
          messageId: MessageId(++_ids),
          sender: 'freemail.example',
          senderName: 'Robin Example',
          subject:
              'Fw: Your reservation at Larkspur Lodge Quayside is confirmed. '
              '#40718293 - 14 Sep 2026',
          text: _personForward,
          at: DateTime.utc(2026, 6, 9, 18),
        ),
      ]);
      final stay = b.single.infos.single as LodgingReservationInfo;
      expect(stay.hotel?.name, 'Larkspur Lodge Quayside');
      expect(stay.reservationNumber, '40718293');
      expect(stay.checkin?.day, DateTime(2026, 9, 14));
      expect(stay.checkout?.day, DateTime(2026, 9, 17));
      // Attributed to the hotel, not the relative.
      expect(b.single.records.single.email.sender, 'larkspur-lodge.example');
      expect(b.single.records.single.email.senderName, 'Larkspur Lodge');
    });

    test('Trips: a reply is still left out', () {
      final b = TripFinder.bookings([
        TripEmail(
          messageId: MessageId(++_ids),
          sender: 'larkspur-lodge.example',
          senderName: 'Robin Example',
          subject:
              'Re: Your reservation at Larkspur Lodge Quayside is confirmed.',
          text: _personForward,
          at: DateTime.utc(2026, 6, 9, 18),
        ),
      ]);
      expect(b, isEmpty);
      expect(TripFinder.looksLikeBooking('Re: Your booking'), isFalse);
      expect(TripFinder.looksLikeBooking('Fw: Your booking'), isTrue);
    });

    AppointmentEmail room(String subject, String table, int hoursLater) =>
        AppointmentEmail(
          messageId: MessageId(++_ids),
          sender: 'example.edu',
          senderName: 'STUDENT',
          subject: 'FW: $subject',
          text: _ruleForward(subject, table),
          at: DateTime.utc(2026, 3, 3, 9, 13 + hoursLater),
        );

    test('Appointments: a room booking a rule forwards, then cancels', () {
      final booked = room(
        'Room Desk - Booking Confirmed',
        'The following bookings have been accepted successfully.',
        0,
      );
      expect(AppointmentFinder.looksLikeAppointment(booked.subject), isTrue);
      final a = AppointmentFinder.find([booked]).single;
      expect(a.start.wall, DateTime.utc(2026, 3, 4, 9));
      expect(a.end?.wall, DateTime.utc(2026, 3, 4, 11));
      expect(a.records.single.email.sender, 'example.edu');
      expect(a.records.single.email.senderName, 'Room Desk');
      expect(a.cancelled, isFalse);

      final cancelled = room(
        'Room Desk - Cancelled Own Booking',
        'The following bookings have been cancelled.',
        1,
      );
      final both = AppointmentFinder.find([booked, cancelled]);
      expect(both.single.cancelled, isTrue);
      expect(both.single.records, hasLength(2));
    });

    test('Events: a webinar registration a rule forwards', () {
      final e = EventFinder.find([
        EventEmail(
          messageId: MessageId(++_ids),
          sender: 'example.edu',
          senderName: 'STUDENT NAME',
          subject: 'FW: Glaze Basics Taster Session Confirmation',
          text: _zoomForward,
          at: DateTime.utc(2026, 3, 6, 8, 3),
          links: [
            MailLink(
              'Join Meeting',
              Uri.parse('https://campus-example.zoom.us/w/95501234567?tk=qq'),
            ),
          ],
        ),
      ]).single;
      expect(e.start.wall, DateTime.utc(2026, 3, 6, 10));
      expect(e.records.single.link?.host, 'campus-example.zoom.us');
      expect(e.records.single.email.sender, 'zoom.us');
    });

    test('Events: a forwarded invitation, its calendar file attached', () {
      final invite = AppointmentInvite(
        uid: 'inv-7741',
        summary: 'Project sync',
        start: PlaceTime(2026, 6, 10, hour: 14, offset: Duration(hours: 8)),
        end: PlaceTime(2026, 6, 10, hour: 15, offset: Duration(hours: 8)),
        organizerEmail: 'organiser@agency.example',
        guests: 4,
        meetingLink: Uri.parse(
          'https://teams.microsoft.com/l/meetup-join/qq-77',
        ),
      );
      EventEmail mail(String subject, String text) => EventEmail(
        messageId: MessageId(++_ids),
        sender: 'freemail.example',
        senderName: 'Teammate',
        subject: subject,
        text: text,
        at: DateTime.utc(2026, 6, 9, 2),
        invite: invite,
      );
      final forward = mail('Fwd: Project sync', '''
Sharing this one with you.

---------- Forwarded message ---------
From: Organiser Name <organiser@agency.example>
Date: Tue, 9 Jun 2026, 9:00 am
Subject: Project sync
To: <teammate@freemail.example>

Microsoft Teams meeting
Click here to join the meeting <https://teams.microsoft.com/l/meetup-join/qq-77>
Meeting ID: 310 221 908 774
Passcode: QpRsTu
''');
      final e = EventFinder.find([forward]).single;
      expect(e.kind, EventKind.meeting);
      expect(e.start.wall, DateTime.utc(2026, 6, 10, 14));
      expect(e.records.single.email.sender, 'agency.example');
      // A reply about it is no event.
      expect(
        EventFinder.read(mail('Re: Project sync', 'Can we move it?')),
        isNull,
      );
    });

    test('Deliveries and Subscriptions read the original sender', () {
      final d = DeliveryFinder.find([
        DeliveryEmail(
          messageId: MessageId(++_ids),
          shop: 'freemail.example',
          senderName: 'Robin',
          subject: 'Fw: Your order QM-55210 has shipped',
          text: '''
________________________________
From: Quillmart <orders@quillmart.example>
Sent: Monday, June 1, 2026 9:10 AM
To: robin@freemail.example
Subject: Your order QM-55210 has shipped

Your order QM-55210 has shipped and is on its way.
''',
          at: DateTime.utc(2026, 6, 1, 2),
        ),
      ], now: DateTime.utc(2026, 6, 2));
      expect(d.single.records.single.email.shop, 'quillmart.example');

      final email = SubscriptionEmail(
        messageId: MessageId(++_ids),
        company: 'freemail.example',
        senderName: 'Robin',
        subject: 'Fwd: Your receipt from Tunewave',
        text: '''
---------- Forwarded message ---------
From: Tunewave <billing@tunewave.example>
Date: Tue, 3 Feb 2026 at 10:00
Subject: Your receipt from Tunewave
To: <robin@freemail.example>

Your monthly subscription renewed. Total: \$9.99
''',
        at: DateTime.utc(2026, 2, 3, 3),
      );
      expect(email.original?.company, 'tunewave.example');
      expect(email.original?.biller, 'tunewave.example');
    });

    test('Accounts: only a forward of mail sent to the user', () {
      AccountEmail mail(String to) => AccountEmail(
        messageId: MessageId(++_ids),
        company: 'campus.example.edu',
        senderName: 'Me',
        subject: 'FW: Welcome to Pinecrest Notes',
        text:
            '''
________________________________
From: Pinecrest Notes <hello@pinecrest-notes.example>
Sent: Monday, June 1, 2026 9:10 AM
To: $to
Subject: Welcome to Pinecrest Notes

Thanks for signing up! Your account has been created.
''',
        at: DateTime.utc(2026, 6, 1, 2),
      );
      final mine = AccountFinder.find(
        [mail('me@freemail.example')],
        ownAddresses: {'me@freemail.example', 's7654321@campus.example.edu'},
      );
      expect(mine.single.company, 'pinecrest-notes.example');
      final theirs = AccountFinder.find(
        [mail('someone@else.example')],
        ownAddresses: {'me@freemail.example'},
      );
      expect(theirs, isEmpty);
    });
  });
}
