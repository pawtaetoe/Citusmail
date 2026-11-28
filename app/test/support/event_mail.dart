// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'appointment_mail.dart';

/// "20261112", [days] from [now].
String _icsDay(DateTime now, int days) {
  final d = appointmentDay(now, days);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}${two(d.month)}${two(d.day)}';
}

/// Made-up event mail for the Events page and the calendar (tests and
/// screenshots), relative to [now]; every company, person and number is
/// invented: a factory tour (downloaded, labelled), a concert in words, a
/// video meeting with a calendar file tomorrow, a show that was
/// cancelled, a film last week, a ticket not on the device yet, and mail
/// that is not an event (a sale, a newsletter).
void seedEvents(MailStore store, {required DateTime now}) {
  final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
  var uid = 1200;
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

  final tour = mail(
    'shop@cocoahouse.example',
    'House of Cocoa',
    'Thank you! Your «House of Cocoa» order has been received.',
    day * 6,
    snippet: 'Thank you for purchasing tickets for «Guided Factory Tour».',
  );
  final meeting = mail(
    'dana@northwind.example',
    'Dana Lee',
    'Invitation: Design review',
    day,
    snippet: 'Join Zoom Meeting.',
    category: MessageCategory.general,
  );
  store.messages.upsertSummaries(inbox.id, [
    tour,
    meeting,
    // Words only, not downloaded: the preview says it all.
    mail(
      'orders@ticketsite.example',
      'TicketSite',
      'Your tickets: The Lanterns – World Tour',
      day * 20,
      snippet:
          'Your booking is confirmed. ${on(3)} at 7:30 PM, Riverside Arena. '
          'Order number: TS-448812. Your tickets are attached.',
    ),
    mail(
      'box-office@grandtheatre.example',
      'Grand Theatre',
      'Your tickets for The Glass Garden are confirmed',
      day * 30,
      snippet:
          'Your booking is confirmed. The Glass Garden, ${on(12)} at '
          '7:00 PM. Booking reference: GT-20931. Venue: Grand Theatre.',
    ),
    mail(
      'box-office@grandtheatre.example',
      'Grand Theatre',
      'Performance cancelled: The Glass Garden',
      day * 2,
      snippet:
          "We're sorry: this performance has been cancelled. Booking "
          'reference: GT-20931. You will be refunded in full.',
    ),
    mail(
      'tix@starcineplex.example',
      'Star Cineplex',
      'Your Movie Tix: Starlight Odyssey',
      day * 8,
      snippet:
          'Here is your e-ticket. Confirmation ID: 551200. '
          '${on(-7)} at 6:40 PM, Hall 3.',
    ),
    // Not on the device yet, says too little in its preview.
    mail(
      'hello@cityballet.example',
      'City Ballet',
      'Your e-tickets for Swan Lake',
      day * 4,
      snippet: 'Your e-tickets are attached.',
    ),
    // Not events.
    mail(
      'news@ticketsite.example',
      'TicketSite',
      'Tickets on sale now: The Lanterns – World Tour',
      day,
      snippet: 'Get your tickets: ${on(40)} at 7:30 PM, Riverside Arena.',
    ),
    mail(
      'hello@riverside.example',
      'Riverside Arena',
      'This week at Riverside Arena',
      day * 3,
      snippet:
          'Your tickets for the concert on ${on(5)} at 8:00 PM. Booking '
          'confirmed for members.',
      category: MessageCategory.newsletters,
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

  body(tour, '''${head(tour, 'text/html; charset=utf-8')}
<html><body>
<p>Dear Alice,</p>
<p>Thank you for purchasing tickets for «Guided Factory Tour». Your
order is below; show it at the front desk when you arrive.</p>
<p>Date of Event: ${on(8)}</p>
<p>Arrival: 10:15</p>
<p>Start time: 10:30</p>
<p>Event location: House of Cocoa, Fabrikweg 12, Zurich</p>
<p>Order Number #418822</p>
</body></html>
''', 'Thank you for purchasing tickets for «Guided Factory Tour».');
  body(meeting, '''${head(meeting, 'multipart/mixed; boundary="b1"')}
--b1
Content-Type: text/plain; charset=utf-8

Join Zoom Meeting: https://northwind.zoom.us/j/81234567890
--b1
Content-Type: text/calendar; charset=utf-8; method=REQUEST

BEGIN:VCALENDAR
PRODID:-//Example//Calendar//EN
VERSION:2.0
METHOD:REQUEST
BEGIN:VEVENT
UID:design-review@northwind.example
DTSTAMP:${_icsDay(now, -1)}T090000Z
DTSTART:${_icsDay(now, 1)}T020000Z
DTEND:${_icsDay(now, 1)}T030000Z
SUMMARY:Design review
LOCATION:https://northwind.zoom.us/j/81234567890
ORGANIZER;CN=Dana Lee:mailto:dana@northwind.example
ATTENDEE;RSVP=TRUE:mailto:alice@citusmail.test
ATTENDEE;RSVP=TRUE:mailto:bo@northwind.example
ATTENDEE;RSVP=TRUE:mailto:chen@northwind.example
ATTENDEE;RSVP=TRUE:mailto:dev@northwind.example
END:VEVENT
END:VCALENDAR
--b1--
''', 'Join Zoom Meeting.');
}
