// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// The day [days] from [now].
DateTime appointmentDay(DateTime now, int days) =>
    DateTime.utc(now.year, now.month, now.day + days);

/// "Thursday 12 November 2026", [days] from [now].
String appointmentDayText(DateTime now, int days) {
  final d = appointmentDay(now, days);
  return '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]} '
      '${d.year}';
}

/// "20261112", [days] from [now].
String _icsDay(DateTime now, int days) {
  final d = appointmentDay(now, days);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}${two(d.month)}${two(d.day)}';
}

/// "2026-11-12", [days] from [now].
String _isoDay(DateTime now, int days) {
  final d = appointmentDay(now, days);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

/// Made-up appointment mail for the Appointments page (tests and
/// screenshots), relative to [now]: a dentist and a salon with their
/// links, a car service that moved, a physio booking with markup, a
/// vaccination as a calendar file, a barber that was cancelled, a past
/// visit to the doctor, one not on the device yet, and mail that is not
/// an appointment (a newsletter, a meeting among colleagues, a table, a
/// parcel).
void seedAppointments(MailStore store, {required DateTime now}) {
  final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
  var uid = 900;
  MessageSummary mail(
    String address,
    String name,
    String subject,
    Duration ago, {
    String? snippet,
    MessageCategory category = MessageCategory.notifications,
    int size = 30000,
  }) {
    final at = address.indexOf('@');
    return MessageSummary(
      uid: uid++,
      receivedAt: now.subtract(ago),
      subject: subject,
      from: MailAddress(
        localPart: address.substring(0, at),
        domain: address.substring(at + 1),
        displayName: name,
      ),
      snippet: snippet,
      size: size,
      category: category,
      flags: MessageFlags.fromImap([r'\Seen']),
    );
  }

  const day = Duration(days: 1);
  String on(int days) => appointmentDayText(now, days);

  final dentist = mail(
    'appointments@brightsmiledental.co.uk',
    'Bright Smile Dental',
    'Appointment confirmation - Bright Smile Dental',
    day * 10,
    snippet: 'Dear Alice, this is to confirm your appointment.',
  );
  final salon = mail(
    'no-reply@fresha.com',
    'Fresha',
    'Your appointment at Hair by Mia is confirmed',
    day * 4,
    snippet: 'Hi Alice, your appointment is confirmed.',
  );
  final physio = mail(
    'bookings@corephysio.co.uk',
    'Core Physio',
    'Your booking is confirmed',
    day * 2,
    snippet: 'Thanks for booking with Core Physio.',
  );
  final clinic = mail(
    'noreply@hollandvclinic.co.uk',
    'Holland Village Clinic',
    'Appointment confirmation',
    day * 6,
    snippet: 'Your appointment is attached.',
  );
  final colleague = mail(
    'dana@acme.com',
    'Dana Lee',
    'Invitation: Q4 roadmap review',
    day * 2,
    snippet: 'Join with Google Meet.',
    category: MessageCategory.general,
  );
  store.messages.upsertSummaries(inbox.id, [
    dentist,
    salon,
    physio,
    clinic,
    colleague,
    // Words only, not downloaded: the preview says it all.
    mail(
      'service@northsidemotors.co.uk',
      'Northside Motors',
      'Your service booking is confirmed',
      day * 20,
      snippet:
          'Booking confirmed: Full service for your Ford Fiesta on '
          '${on(2)}, drop-off 08:30. Booking reference: NSM-20931. '
          'Where: Unit 4, Mill Lane, Leeds LS6 2AB',
    ),
    mail(
      'service@northsidemotors.co.uk',
      'Northside Motors',
      'Your service booking has been rescheduled',
      day * 3,
      snippet:
          'Your booking NSM-20931 has been moved from ${on(2)} at 08:30 to '
          '${on(9)} at 08:30. Sorry for any trouble.',
    ),
    mail(
      'no-reply@booksy.com',
      'Booksy',
      'Booking confirmed: Skin fade at Kings Cuts',
      day * 6,
      snippet:
          "You're booked! Your booking at Kings Cuts is confirmed. "
          'Service: Skin fade. When: ${on(4)}, 5:45 PM - 6:30 PM.',
    ),
    mail(
      'no-reply@booksy.com',
      'Booksy',
      'Your booking at Kings Cuts was cancelled',
      day,
      snippet:
          'Your booking at Kings Cuts on ${on(4)} at 5:45 PM has been '
          'cancelled.',
    ),
    mail(
      'reception@tbfamilyclinic.sg',
      'Tiong Bahru Family Clinic',
      'Appointment reminder',
      day * 41,
      snippet:
          'A reminder that your appointment with Dr Wong is on ${on(-40)} '
          'at 9:00 AM.',
    ),
    // Not on the device yet, says too little in its preview.
    mail(
      'hello@harbourphysio.example',
      'Harbour Physio',
      'Your appointment is confirmed',
      day * 5,
      snippet: 'Thanks for booking. View your appointment details.',
    ),
    // Not appointments.
    mail(
      'news@serenityspa.example',
      'Serenity Spa',
      'Black Friday: 20% off spa days – book now',
      day,
      snippet: 'Book your appointment now! Offer ends ${on(20)} at 11:59 PM.',
      category: MessageCategory.newsletters,
    ),
    mail(
      'reservations@opentable.com',
      'OpenTable',
      'Your reservation at Burnt Ends is confirmed',
      day * 2,
      snippet:
          'Your reservation is confirmed. Table for 4 on ${on(5)} at '
          '7:30 PM.',
    ),
    mail(
      'support@ninjavan.co',
      'Ninja Van',
      'Your parcel is out for delivery',
      Duration.zero,
      snippet: 'Your parcel is out for delivery today, by 8:00 PM.',
    ),
  ]);

  void body(MessageSummary m, String raw, String text) {
    final stored = store.messages.byUid(inbox.id, m.uid)!;
    store.messages.saveBody(
      stored.id,
      utf8.encode(raw.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n')),
      searchableText: text,
    );
  }

  String head(MessageSummary m, String type) =>
      '''From: ${m.from!.displayName} <${m.from!.address}>
To: alice@citusmail.test
Subject: ${m.subject}
Content-Type: $type
''';

  body(dentist, '''${head(dentist, 'text/html; charset=utf-8')}
<html><body>
<p>Dear Alice,</p>
<p>This is to confirm your appointment with Dr Patel on ${on(6)} at 3.30pm.</p>
<p>Treatment: Scale and polish<br>
Address: 14 High Street, Oxford OX1 4AA</p>
<p><a href="https://brightsmiledental.co.uk/manage?id=88213"><b>Manage</b> your appointment</a>
 · <a href="https://brightsmiledental.co.uk/ics?id=88213">Add to calendar</a></p>
<p>If you need to reschedule or cancel, please call us on 01865 123456.</p>
<p><a href="https://brightsmiledental.co.uk/unsubscribe">Unsubscribe</a></p>
</body></html>
''', 'This is to confirm your appointment with Dr Patel.');
  body(salon, '''${head(salon, 'text/html; charset=utf-8')}
<html><body>
<p>Hi Alice, your appointment is confirmed.</p>
<p>${on(3)} at 11:00<br>
Women's cut &amp; blow dry with Mia · 1h</p>
<p>Hair by Mia<br>22 Tiong Bahru Road, Singapore 168731</p>
<p>Booking ref: #A1B2C3D4</p>
<p><a href="https://www.fresha.com/a/hair-by-mia/manage/A1B2C3D4">Manage appointment</a></p>
</body></html>
''', 'Hi Alice, your appointment is confirmed.');
  body(physio, '''${head(physio, 'text/html; charset=utf-8')}
<html><head><script type="application/ld+json">
{"@context": "https://schema.org", "@type": "ServiceReservation",
 "reservationNumber": "PHY-1192",
 "reservationStatus": "https://schema.org/ReservationConfirmed",
 "underName": {"@type": "Person", "name": "Alice Tan"},
 "startTime": "${_isoDay(now, 12)}T14:00:00+00:00",
 "endTime": "${_isoDay(now, 12)}T14:45:00+00:00",
 "modifyReservationUrl": "https://corephysio.co.uk/manage/PHY-1192",
 "provider": {"@type": "MedicalClinic", "name": "Core Physio",
   "address": {"@type": "PostalAddress", "streetAddress": "80 Baker Street",
     "addressLocality": "London", "postalCode": "W1U 6AE"}},
 "reservationFor": {"@type": "Service", "name": "Physiotherapy assessment"}}
</script></head>
<body><p>Thanks for booking with Core Physio.</p></body></html>
''', 'Thanks for booking with Core Physio.');
  String ics({
    required String uid,
    required String summary,
    required String start,
    required String end,
    required String organizer,
    List<String> attendees = const ['alice@citusmail.test'],
    String? location,
  }) =>
      '''BEGIN:VCALENDAR
PRODID:-//Example//Bookings//EN
VERSION:2.0
METHOD:REQUEST
BEGIN:VEVENT
UID:$uid
DTSTAMP:${_icsDay(now, -2)}T090000Z
DTSTART;TZID=Europe/London:$start
DTEND;TZID=Europe/London:$end
SUMMARY:$summary
${location == null ? '' : 'LOCATION:$location\n'}ORGANIZER;CN=$organizer:mailto:$organizer
${[for (final a in attendees) 'ATTENDEE;RSVP=TRUE:mailto:$a'].join('\n')}
END:VEVENT
END:VCALENDAR''';
  String multipart(MessageSummary m, String text, String calendar) =>
      '''${head(m, 'multipart/mixed; boundary="b1"')}
--b1
Content-Type: text/plain; charset=utf-8

$text
--b1
Content-Type: text/calendar; charset=utf-8; method=REQUEST

$calendar
--b1--
''';
  body(
    clinic,
    multipart(
      clinic,
      'Your appointment is attached. Please arrive 5 minutes early.',
      ics(
        uid: 'appt-55120@hollandvclinic.co.uk',
        summary: 'Flu vaccination at Holland Village Clinic',
        start: '${_icsDay(now, 20)}T093000',
        end: '${_icsDay(now, 20)}T094500',
        organizer: 'noreply@hollandvclinic.co.uk',
        location: '118 Holland Park Avenue, London W11 4UA',
      ),
    ),
    'Your appointment is attached.',
  );
  body(
    colleague,
    multipart(
      colleague,
      'Join with Google Meet: https://meet.google.com/abc-defg-hij',
      ics(
        uid: 'q4review@google.com',
        summary: 'Q4 roadmap review',
        start: '${_icsDay(now, 6)}T150000',
        end: '${_icsDay(now, 6)}T160000',
        organizer: 'dana@acme.com',
        attendees: [
          'alice@citusmail.test',
          'bo@acme.com',
          'chen@acme.com',
          'dev@acme.com',
        ],
      ),
    ),
    'Join with Google Meet.',
  );
}
