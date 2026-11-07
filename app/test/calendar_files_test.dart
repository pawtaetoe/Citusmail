// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:citusmail/src/ui/calendar_files.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_view/mail_view.dart';

void main() {
  final invite = CalendarInvite.parse('''BEGIN:VCALENDAR
PRODID:-//Example//Bookings//EN
VERSION:2.0
METHOD:REQUEST
BEGIN:VEVENT
UID:q4-roadmap@example
DTSTAMP:20261101T090000Z
DTSTART:20261110T090000Z
DTEND:20261110T100000Z
SUMMARY:Q4 roadmap review
ORGANIZER;CN=boss@work.example:mailto:boss@work.example
ATTENDEE;RSVP=TRUE:mailto:alice@citusmail.test
END:VEVENT
END:VCALENDAR''')!;

  late Directory data;
  late List<Uri> opened;
  var takes = true;

  setUp(() {
    data = Directory.systemTemp.createTempSync('citusmail_calendar_test');
    opened = [];
    takes = true;
    CalendarFiles.dataDirectory = () async => data;
    CalendarFiles.launcher = (uri) async {
      opened.add(uri);
      return takes;
    };
    CalendarFiles.keepFor = const Duration(milliseconds: 100);
  });

  tearDown(() {
    if (data.existsSync()) data.deleteSync(recursive: true);
  });

  test('the file is written in the app\'s own folder, then removed', () async {
    expect(await CalendarFiles.open(invite), isTrue);
    final file = File(opened.single.toFilePath());
    expect(file.path, startsWith(data.path));
    expect(
      Directory('${Directory.systemTemp.path}/citusmail-events').existsSync(),
      isFalse,
      reason: 'nothing in the shared temporary folder',
    );
    expect(file.path, endsWith('Q4 roadmap review.ics'));
    expect(file.readAsStringSync(), contains('SUMMARY:Q4 roadmap review'));

    // Gone once the calendar app has had time to read it.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(file.existsSync(), isFalse);
    expect(file.parent.existsSync(), isFalse);
  }, skip: !CalendarFiles.canOpen);

  test('when no app takes it, the file goes at once', () async {
    takes = false;
    expect(await CalendarFiles.open(invite), isFalse);
    expect(File(opened.single.toFilePath()).existsSync(), isFalse);
  }, skip: !CalendarFiles.canOpen);
}
