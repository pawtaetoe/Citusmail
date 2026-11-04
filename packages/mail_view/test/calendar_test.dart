// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:mail_view/mail_view.dart';
import 'package:test/test.dart';

final fixtureDir = Directory('../../test-data/invites');

CalendarInvite fixture(String name) =>
    MessageView.parse(File('${fixtureDir.path}/$name').readAsBytesSync())
        .invite!;

/// A reader at a fixed UTC offset (Lisbon in winter is +0, Berlin +1).
CalendarText reader(int hours, {bool use24Hour = false}) => CalendarText(
  offsetAt: (_) => Duration(hours: hours),
  now: DateTime(2026, 11, 4),
  use24Hour: use24Hour,
);

/// A minimal invitation around [event] lines.
CalendarInvite? invite(String event, {String extra = ''}) =>
    CalendarInvite.parse(
      'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\n$extra'
      'BEGIN:VEVENT\r\nUID:x@example.test\r\n$event\r\nEND:VEVENT\r\n'
      'END:VCALENDAR\r\n',
    );

void main() {
  group('real-world invitations', () {
    test('Outlook / Teams: VTIMEZONE, folded lines, base64 part', () {
      final i = fixture('outlook-teams-request.eml');
      expect(i.method, CalendarMethod.request);
      expect(i.summary, 'Q4 roadmap review');
      expect(i.sequence, 2);
      expect(
        i.uid,
        '040000008200E00074C5B7101A82E00800000000B0B6A1C2E5C9DC01000000000000000'
        '010000000B9F3C0A55F0CC64A8B5D0E1F2A3B4C5D',
      );
      // 14:00 in Amsterdam in November is 13:00 UTC.
      expect(i.start!.instant, DateTime.utc(2026, 11, 12, 13));
      expect(i.end!.instant, DateTime.utc(2026, 11, 12, 14));
      expect(i.location, 'Room 4.12 (Lisbon); Microsoft Teams Meeting');
      expect(i.organizer!.name, 'Ana Lima');
      expect(i.organizer!.email, 'ana.lima@contoso.example');
      expect(i.attendees, hasLength(4));
      expect(i.guests.map((g) => g.label), [
        'Alice Example',
        'Bruno Costa',
        'Chen Wei',
      ]);
      final me = i.attendeeFor(['someone@else.test', 'ALICE@citusmail.test'])!;
      expect(me.answer, CalendarAnswer.needsAction);
      expect(me.rsvp, isTrue);
      expect(i.answerable, isTrue);
      expect(i.cancelled, isFalse);
      expect(i.meetingLink!.host, 'teams.microsoft.com');
      expect(
        i.meetingLink.toString().toLowerCase(),
        contains('meetup-join/19%3ameeting'),
      );
      expect(MeetingLinks.service(i.meetingLink!), 'Teams');
      // The joining block is left to the button.
      expect(
        i.description,
        'Hi all,\n\nLet\'s go over the Q4 roadmap: priorities, owners and '
        'dates.',
      );
      expect(i.recurrenceRule, isNull);

      expect(reader(1).when(i), 'Thu, 12 Nov · 2:00–3:00 pm');
      expect(reader(1).zoneNote(i), isNull, reason: 'same zone');
      expect(reader(0).when(i), 'Thu, 12 Nov · 1:00–2:00 pm');
      expect(
        reader(0).zoneNote(i),
        'Shown in your time zone. Set for W. Europe Standard Time: '
        '2:00–3:00 pm.',
      );
      expect(reader(0, use24Hour: true).when(i), 'Thu, 12 Nov · 13:00–14:00');
      expect(reader(0).short(i), 'Thu 12 Nov, 1 pm');
    });

    test('Google: TZID only, weekly on two days, Meet, .ics attached too', () {
      final view = MessageView.parse(
        File('${fixtureDir.path}/google-weekly-request.eml').readAsBytesSync(),
      );
      final i = view.invite!;
      expect(view.attachments.single.fileName, 'invite.ics');
      expect(i.method, CalendarMethod.request);
      expect(i.summary, 'Launch stand-up');
      // New York is back on standard time (UTC-5) after 1 November.
      expect(i.start!.zoneId, 'America/New_York');
      expect(i.start!.instant, DateTime.utc(2026, 11, 16, 14, 30));
      expect(i.end!.instant, DateTime.utc(2026, 11, 16, 14, 45));
      expect(reader(1).when(i), 'Mon, 16 Nov · 3:30–3:45 pm');
      expect(
        reader(1).zoneNote(i),
        'Shown in your time zone. Set for New York: 9:30–9:45 am.',
      );
      expect(reader(1).recurrence(i), 'Repeats weekly on Monday and Wednesday');
      expect(i.meetingLink, Uri.parse('https://meet.google.com/abc-defg-hij'));
      expect(i.location, isNull, reason: 'empty LOCATION');
      expect(
        i.description,
        'Quick sync on the launch, twice a week.\n\nAgenda:\n- blockers\n'
        '- next steps',
      );
      final me = i.attendeeFor(['alice@citusmail.test'])!;
      expect(me.name, isNull, reason: 'Google puts the address in CN');
      expect(me.label, 'alice@citusmail.test');
      expect(i.organizer!.label, 'Sam Rivera');
      // Sam (the organizer) is not counted as a guest.
      expect(i.guests, hasLength(2));
      expect(
        i.attendees.firstWhere((a) => a.name == 'Priya Shah').answer,
        CalendarAnswer.tentative,
      );
    });

    test('Zoom: UTC times, link in LOCATION, only an attached .ics', () {
      final i = fixture('zoom-webinar.eml');
      expect(i.method, CalendarMethod.publish);
      expect(i.answerable, isFalse, reason: 'nothing to answer');
      expect(i.summary, 'Webinar: Privacy by design, in practice');
      expect(i.start!.utc, isTrue);
      expect(i.start!.instant, DateTime.utc(2026, 11, 19, 17));
      expect(reader(1).when(i), 'Thu, 19 Nov · 6:00–7:00 pm');
      expect(reader(1).zoneNote(i), isNull);
      expect(i.meetingLink!.host, 'us06web.zoom.us');
      expect(MeetingLinks.service(i.meetingLink!), 'Zoom');
      expect(i.organizer, isNull);
      expect(i.attendeeFor(['alice@citusmail.test']), isNull);
    });

    test('all day over two days, address matched in any case', () {
      final i = fixture('all-day-request.eml');
      expect(i.summary, 'Team offsite – Sintra');
      expect(i.start!.allDay, isTrue);
      expect(i.start!.wall, DateTime.utc(2026, 12, 10));
      expect(reader(-8).when(i), 'Thu, 10 Dec – Fri, 11 Dec · All day');
      expect(reader(9).when(i), 'Thu, 10 Dec – Fri, 11 Dec · All day');
      expect(reader(0).short(i), 'Thu 10 Dec');
      expect(i.location, 'Quinta da Regaleira, Sintra');
      expect(i.description, 'Bring walking shoes.\nLunch is on us.');
      expect(i.organizer!.name, 'Dana Friend');
      final me = i.attendeeFor(['alice@citusmail.test'])!;
      expect(me.email, 'Alice@Citusmail.test');
      expect(me.answer, CalendarAnswer.accepted);
      expect(i.answerKey, '9b1f-offsite-2026@friends.example#1');
    });

    test('a cancellation is not answerable', () {
      final i = fixture('outlook-cancel.eml');
      expect(i.method, CalendarMethod.cancel);
      expect(i.cancelled, isTrue);
      expect(i.answerable, isFalse);
      expect(i.summary, 'Canceled: Budget planning');
      expect(i.description, 'Moving this to next quarter.');
    });

    test('an answer to the user\'s own invitation', () {
      final i = fixture('google-reply-accepted.eml');
      expect(i.method, CalendarMethod.reply);
      expect(i.organizedBy(['alice@citusmail.test']), isTrue);
      final bob = i.attendees.single;
      expect(bob.name, 'Bob Example');
      expect(bob.shortLabel, 'Bob');
      expect(bob.answer, CalendarAnswer.accepted);
      expect(i.event.property('COMMENT')!.text, 'See you there!');
      expect(i.answerable, isFalse);
    });

    test('ordinary mail has no invitation', () {
      final view = MessageView.parse(
        File('../../test-data/mail/people/html-alternative.eml')
            .readAsBytesSync(),
      );
      expect(view.invite, isNull);
    });
  });

  group('time zones', () {
    test('a VTIMEZONE switches to summer time on its own rule', () {
      const zone =
          'BEGIN:VTIMEZONE\r\nTZID:Romance Standard Time\r\n'
          'BEGIN:STANDARD\r\nDTSTART:16010101T030000\r\nTZOFFSETFROM:+0200\r\n'
          'TZOFFSETTO:+0100\r\nRRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10\r\n'
          'END:STANDARD\r\nBEGIN:DAYLIGHT\r\nDTSTART:16010101T020000\r\n'
          'TZOFFSETFROM:+0100\r\nTZOFFSETTO:+0200\r\n'
          'RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=3\r\nEND:DAYLIGHT\r\n'
          'END:VTIMEZONE\r\n';
      DateTime? at(String time) => invite(
        'DTSTART;TZID=Romance Standard Time:$time',
        extra: zone,
      )!.start!.instant;
      expect(at('20260715T100000'), DateTime.utc(2026, 7, 15, 8));
      expect(at('20260115T100000'), DateTime.utc(2026, 1, 15, 9));
      // Last Sunday of March 2026 is the 29th.
      expect(at('20260328T120000'), DateTime.utc(2026, 3, 28, 11));
      expect(at('20260329T120000'), DateTime.utc(2026, 3, 29, 10));
    });

    test('the file\'s own definition wins over the built-in one', () {
      const zone =
          'BEGIN:VTIMEZONE\r\nTZID:Europe/Berlin\r\nBEGIN:STANDARD\r\n'
          'DTSTART:19700101T000000\r\nTZOFFSETFROM:+0300\r\n'
          'TZOFFSETTO:+0300\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\n';
      final i = invite(
        'DTSTART;TZID=Europe/Berlin:20260715T100000',
        extra: zone,
      )!;
      expect(i.start!.offset, const Duration(hours: 3));
    });

    test('well-known IANA and Windows names, with daylight saving', () {
      Duration? offset(String zone, DateTime wall) =>
          CalendarTimeZones.builtInOffset(zone, wall);
      final july = DateTime.utc(2026, 7, 1, 12);
      final december = DateTime.utc(2026, 12, 1, 12);
      expect(offset('Pacific Standard Time', july), const Duration(hours: -7));
      expect(
        offset('Pacific Standard Time', december),
        const Duration(hours: -8),
      );
      expect(offset('Europe/London', july), const Duration(hours: 1));
      expect(offset('Europe/London', december), Duration.zero);
      expect(
        offset('Asia/Kolkata', july),
        const Duration(hours: 5, minutes: 30),
      );
      expect(offset('Australia/Sydney', july), const Duration(hours: 10));
      expect(offset('Australia/Sydney', december), const Duration(hours: 11));
      expect(offset('Pacific/Auckland', december), const Duration(hours: 13));
      expect(offset('America/Phoenix', july), const Duration(hours: -7));
      expect(
        offset('/mozilla.org/20050126_1/Europe/Berlin', july),
        const Duration(hours: 2),
      );
      expect(
        offset('(UTC-05:00) Eastern Time (US & Canada)', july),
        const Duration(hours: -4),
      );
      expect(
        offset('(UTC+01:00) Amsterdam, Berlin, Bern, Rome', december),
        const Duration(hours: 1),
      );
      expect(offset('Mars/Olympus_Mons', july), isNull);
      // US: 8 March 2026 at 2:00 is the switch.
      expect(
        offset('America/New_York', DateTime.utc(2026, 3, 8, 1)),
        const Duration(hours: -5),
      );
      expect(
        offset('America/New_York', DateTime.utc(2026, 3, 8, 3)),
        const Duration(hours: -4),
      );
    });

    test('an unknown zone is shown as written, and said so', () {
      final i = invite(
        'DTSTART;TZID=Customized Time Zone 7:20261112T140000\r\n'
        'DTEND;TZID=Customized Time Zone 7:20261112T150000',
      )!;
      expect(i.start!.zoneUnknown, isTrue);
      expect(i.start!.instant, isNull);
      expect(reader(5).when(i), 'Thu, 12 Nov · 2:00–3:00 pm');
      expect(reader(5).zoneNote(i), contains('isn\'t known here'));
    });

    test('floating times stay as written', () {
      final i = invite('DTSTART:20261112T090000\r\nDURATION:PT1H30M')!;
      expect(i.start!.floating, isTrue);
      expect(reader(-8).when(i), 'Thu, 12 Nov · 9:00–10:30 am');
      expect(reader(-8).zoneNote(i), isNull);
    });
  });

  group('times and text', () {
    test('ranges across noon, midnight and days; other years', () {
      final text = reader(0);
      expect(
        text.when(
          invite('DTSTART:20261112T113000Z\r\nDTEND:20261112T123000Z')!,
        ),
        'Thu, 12 Nov · 11:30 am–12:30 pm',
      );
      expect(
        text.when(
          invite('DTSTART:20261112T230000Z\r\nDTEND:20261113T000000Z')!,
        ),
        'Thu, 12 Nov · 11:00 pm–12:00 am',
      );
      expect(
        text.when(
          invite('DTSTART:20261112T140000Z\r\nDTEND:20261113T100000Z')!,
        ),
        'Thu, 12 Nov, 2:00 pm – Fri, 13 Nov, 10:00 am',
      );
      expect(
        text.when(invite('DTSTART:20270105T090000Z')!),
        'Tue, 5 Jan 2027 · 9:00 am',
      );
      expect(
        text.when(invite('DTSTART;VALUE=DATE:20261112')!),
        'Thu, 12 Nov · All day',
      );
      expect(text.when(invite('SUMMARY:No date')!), 'No date given');
    });

    test('repeating events in words', () {
      String? rule(String rrule, {String start = '20261112T090000Z'}) =>
          reader(0).recurrence(invite('DTSTART:$start\r\nRRULE:$rrule')!);
      expect(rule('FREQ=DAILY'), 'Repeats daily');
      expect(rule('FREQ=DAILY;INTERVAL=3'), 'Repeats every 3 days');
      expect(rule('FREQ=WEEKLY'), 'Repeats weekly on Thursday');
      expect(rule('FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR'), 'Repeats every weekday');
      expect(
        rule('FREQ=WEEKLY;INTERVAL=2;BYDAY=TU'),
        'Repeats every 2 weeks on Tuesday',
      );
      expect(
        rule('FREQ=WEEKLY;BYDAY=FR,MO,WE'),
        'Repeats weekly on Monday, Wednesday and Friday',
      );
      expect(
        rule('FREQ=MONTHLY;BYDAY=-1FR'),
        'Repeats monthly on the last Friday',
      );
      expect(
        rule('FREQ=MONTHLY;BYDAY=2TU;COUNT=6'),
        'Repeats monthly on the second Tuesday, 6 times',
      );
      expect(rule('FREQ=MONTHLY;BYMONTHDAY=15'), 'Repeats monthly on day 15');
      expect(
        rule('FREQ=YEARLY;UNTIL=20301231T235959Z'),
        'Repeats yearly, until 31 Dec 2030',
      );
      expect(rule('FREQ=SECONDLY'), 'Repeats');
      expect(reader(0).recurrence(invite('DTSTART:20261112T090000Z')!), isNull);
    });

    test('escaped text: commas, semicolons, backslashes and new lines', () {
      final i = invite(
        r'SUMMARY:Lunch\, then talks\; bring C:\\docs\Nand a pen',
      )!;
      expect(i.summary, 'Lunch, then talks; bring C:\\docs\nand a pen');
      expect(ICalText.escape('a, b; c\\d\ne'), r'a\, b\; c\\d\ne');
    });

    test('folding: long lines unfold; UTF-8 is never split when writing', () {
      final i = CalendarInvite.parse(
        'BEGIN:VCALENDAR\nMETHOD:REQUEST\nBEGIN:VEVENT\nUID:1\n'
        'SUMMARY:Réunion d\'équipe\n  à Lyon\n\tet café\nEND:VEVENT\n'
        'END:VCALENDAR',
      )!;
      expect(i.summary, 'Réunion d\'équipe à Lyonet café');

      final writer = ICalWriter()..line('SUMMARY:${'é' * 100}');
      final lines = writer.toString().split('\r\n')..removeLast();
      for (final line in lines) {
        expect(utf8.encode(line).length, lessThanOrEqualTo(75));
      }
      expect(
        ICalParser.unfold(writer.toString()).first,
        'SUMMARY:${'é' * 100}',
      );
    });

    test('parameters: quoted values with colons and semicolons', () {
      final p = ICalParser.parseLine(
        'ATTENDEE;CN="Doe; Jane: Ops";PARTSTAT=TENTATIVE;'
        'DELEGATED-FROM="mailto:a@x.test","mailto:b@x.test":mailto:j@x.test',
      )!;
      expect(p.parameter('CN'), 'Doe; Jane: Ops');
      expect(p.parameter('partstat'), 'TENTATIVE');
      expect(ICalProperty.parameterValues(p.parameters['DELEGATED-FROM']!), [
        'mailto:a@x.test',
        'mailto:b@x.test',
      ]);
      expect(p.value, 'mailto:j@x.test');
      expect(ICalProperty.quoteParameter('A "B": C'), '"A B: C"');
    });
  });

  group('malformed and hostile files', () {
    test('garbage, no event, or no calendar gives nothing', () {
      expect(CalendarInvite.parse(''), isNull);
      expect(CalendarInvite.parse('hello\nworld'), isNull);
      expect(
        CalendarInvite.parse('BEGIN:VCALENDAR\nMETHOD:REQUEST\nEND:VCALENDAR'),
        isNull,
      );
      expect(
        CalendarInvite.parse('BEGIN:VEVENT\nSUMMARY:x\nEND:VEVENT'),
        isNull,
      );
    });

    test('broken lines, bad dates and missing ENDs are survived', () {
      final i = CalendarInvite.parse(
        'BEGIN:VCALENDAR\nMETHOD:REQUEST\nBEGIN:VEVENT\nUID:1\n'
        'this line is junk\n;:also junk\nDTSTART:20261345T250000Z\n'
        'DTEND:yesterday\nSUMMARY:Still here\nATTENDEE:not-mailto\n'
        'ORGANIZER:mailto:\nSEQUENCE:many\nBEGIN:VALARM\nTRIGGER:-PT5M\n',
      )!;
      expect(i.summary, 'Still here');
      expect(i.start, isNull);
      expect(i.end, isNull);
      expect(i.sequence, 0);
      expect(i.organizer, isNull);
      expect(i.attendees, isEmpty);
      expect(i.answerable, isFalse, reason: 'no organizer to answer');
      expect(reader(0).when(i), 'No date given');
    });

    test('an end before the start is dropped', () {
      final i = invite('DTSTART:20261112T140000Z\r\nDTEND:20261112T130000Z')!;
      expect(i.end, isNull);
      expect(reader(0).when(i), 'Thu, 12 Nov · 2:00 pm');
    });

    test('very large files are not read; deep nesting is cut', () {
      final huge =
          'BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:1\n'
          'DESCRIPTION:${'x' * (ICalParser.maxLength + 10)}\nEND:VEVENT\n'
          'END:VCALENDAR';
      expect(CalendarInvite.parse(huge), isNull);

      final deep = StringBuffer('BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:1\n');
      for (var i = 0; i < 1000; i++) {
        deep.write('BEGIN:X$i\nSUMMARY:deep\n');
      }
      deep.write('SUMMARY:lost\n');
      final roots = const ICalParser().parse(deep.toString());
      var depth = 0;
      for (var c = roots.single; c.children.isNotEmpty; c = c.children.single) {
        depth++;
      }
      expect(depth, lessThan(ICalParser.maxDepth));
      expect(CalendarInvite.parse(deep.toString())!.uid, '1');
    });

    test('links: only https, and only meeting services or a bare location', () {
      expect(
        invite(
          'LOCATION:http://zoom.us/j/1\r\nDESCRIPTION:see https://evil.test/x',
        )!.meetingLink,
        isNull,
      );
      expect(
        invite('LOCATION:https://video.example.test/room/7')!.meetingLink,
        Uri.parse('https://video.example.test/room/7'),
      );
      expect(
        invite('DESCRIPTION:Join: https://acme.zoom.us/j/123?pwd=abc.')!
            .meetingLink,
        Uri.parse('https://acme.zoom.us/j/123?pwd=abc'),
      );
      expect(
        MeetingLinks.service(Uri.parse('https://zoom.us.evil.test/j/1')),
        isNull,
      );
    });
  });

  group('answering (iTIP REPLY)', () {
    test('accepting an Outlook invitation', () {
      final i = fixture('outlook-teams-request.eml');
      final me = i.attendeeFor(['alice@citusmail.test'])!;
      final text = CalendarReply.build(
        i,
        attendee: me,
        answer: CalendarAnswer.accepted,
        now: DateTime.utc(2026, 11, 4, 10, 30),
        comment: 'Thanks, see you there;\nI\'ll join remotely',
      );
      for (final line in text.split('\r\n')) {
        expect(utf8.encode(line).length, lessThanOrEqualTo(75));
      }
      expect(text, endsWith('END:VCALENDAR\r\n'));
      expect(text.contains(RegExp(r'[^\r]\n')), isFalse, reason: 'CRLF only');

      final calendar = const ICalParser().parse(text).single;
      expect(calendar.property('METHOD')!.value, 'REPLY');
      expect(calendar.property('VERSION')!.value, '2.0');
      expect(calendar.property('PRODID'), isNotNull);
      expect(
        calendar.components('VTIMEZONE').single.property('TZID')!.value,
        'W. Europe Standard Time',
      );
      final event = calendar.components('VEVENT').single;
      expect(event.property('UID')!.value, i.uid);
      expect(event.property('SEQUENCE')!.value, '2');
      expect(event.property('DTSTAMP')!.value, '20261104T103000Z');
      expect(
        event.property('ORGANIZER')!.line,
        'ORGANIZER;CN=Ana Lima:mailto:ana.lima@contoso.example',
      );
      expect(
        event.property('DTSTART')!.line,
        'DTSTART;TZID=W. Europe Standard Time:20261112T140000',
      );
      expect(event.property('SUMMARY')!.text, 'Q4 roadmap review');
      final attendee = event.all('ATTENDEE').single;
      expect(attendee.value, 'mailto:alice@citusmail.test');
      expect(attendee.parameter('PARTSTAT'), 'ACCEPTED');
      expect(attendee.parameter('CN'), 'Alice Example');
      expect(attendee.parameter('RSVP'), isNull);
      expect(
        event.property('COMMENT')!.text,
        'Thanks, see you there;\nI\'ll join remotely',
      );
      // Nothing else of the invitation is repeated (other guests,
      // description, alarms).
      expect(event.property('DESCRIPTION'), isNull);
      expect(event.children, isEmpty);

      // And it reads back as an answer.
      final back = CalendarInvite.parse(text)!;
      expect(back.method, CalendarMethod.reply);
      expect(back.attendees.single.answer, CalendarAnswer.accepted);
      expect(back.start!.instant, i.start!.instant);
    });

    test('declining a Google invitation keeps the address as invited', () {
      final i = fixture('all-day-request.eml');
      final text = CalendarReply.build(
        i,
        attendee: i.attendeeFor(['alice@citusmail.test'])!,
        answer: CalendarAnswer.declined,
        now: DateTime.utc(2026, 11, 4),
      );
      final event = const ICalParser()
          .parse(text)
          .single
          .components('VEVENT')
          .single;
      expect(event.property('ATTENDEE')!.value, 'mailto:Alice@Citusmail.test');
      expect(event.property('ATTENDEE')!.parameter('PARTSTAT'), 'DECLINED');
      expect(event.property('SEQUENCE')!.value, '1');
      expect(event.property('DTSTART')!.line, 'DTSTART;VALUE=DATE:20261210');
      expect(event.property('COMMENT'), isNull);
      expect(text, isNot(contains('VTIMEZONE')));
      expect(text, isNot(contains('eve@friends.example')));
    });
  });
}
