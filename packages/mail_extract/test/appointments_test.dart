// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_extract/mail_extract.dart';
import 'package:test/test.dart';

List<AppointmentInfo> _read(String html) =>
    AppointmentInfo.allIn(StructuredData.extract(html));

void main() {
  test('a ServiceReservation from a clinic, in JSON-LD', () {
    final found = _read('''
<html><head><script type="application/ld+json">
{"@context": "https://schema.org", "@type": "ServiceReservation",
 "reservationNumber": "PHY-1192",
 "reservationStatus": "https://schema.org/ReservationConfirmed",
 "underName": {"@type": "Person", "name": "Alice Tan"},
 "startTime": "2026-11-21T14:00:00+08:00",
 "endTime": "2026-11-21T14:45:00+08:00",
 "modifyReservationUrl": "https://corephysio.example/manage/PHY-1192",
 "provider": {"@type": "MedicalClinic", "name": "Core Physio",
   "address": {"@type": "PostalAddress", "streetAddress": "80 Robinson Road",
     "addressLocality": "Singapore", "postalCode": "068898"}},
 "reservationFor": {"@type": "Service", "name": "Physiotherapy assessment"}}
</script></head><body>Your booking is confirmed.</body></html>''');
    final a = found.single;
    expect(a.name, 'Physiotherapy assessment');
    expect(a.provider, 'Core Physio');
    expect(a.start, PlaceTime.parse('2026-11-21T14:00:00+08:00'));
    expect(a.end, PlaceTime.parse('2026-11-21T14:45:00+08:00'));
    expect(a.place?.name, 'Core Physio');
    expect(a.place?.address, '80 Robinson Road, Singapore, 068898');
    expect(a.online, isFalse);
    expect(a.reservationNumber, 'PHY-1192');
    expect(a.underName, 'Alice Tan');
    expect(a.status, ReservationStatus.confirmed);
    expect(a.url, Uri.parse('https://corephysio.example/manage/PHY-1192'));
    // Not a booking for the Trips page.
    expect(
      ReservationInfo.allIn(
        StructuredData.extract('''
<script type="application/ld+json">
{"@type": "ServiceReservation", "startTime": "2026-11-21T14:00:00+08:00",
 "reservationFor": {"@type": "Service", "name": "Physio"}}
</script>'''),
      ),
      isEmpty,
    );
  });

  test('a plain Reservation for a service, in microdata, cancelled', () {
    final a = _read('''
<div itemscope itemtype="http://schema.org/Reservation">
  <meta itemprop="reservationNumber" content="B-77120">
  <link itemprop="reservationStatus" href="http://schema.org/ReservationCancelled">
  <meta itemprop="startTime" content="2026-11-18T08:30:00">
  <div itemprop="reservationFor" itemscope itemtype="http://schema.org/AutoRepair">
    <span itemprop="name">Northside Motors</span>
    <div itemprop="address" itemscope itemtype="http://schema.org/PostalAddress">
      <span itemprop="streetAddress">Unit 4, Mill Lane</span>
      <span itemprop="addressLocality">Leeds</span>
    </div>
  </div>
</div>''').single;
    expect(a.name, 'Northside Motors');
    expect(a.place?.locality, 'Leeds');
    expect(a.start!.hasTime, isTrue);
    expect(a.start!.offset, isNull);
    expect(a.reservationNumber, 'B-77120');
    expect(a.status, ReservationStatus.cancelled);
  });

  test('an online class as an Event', () {
    final a = _read('''
<script type="application/ld+json">
{"@context": "https://schema.org", "@type": "EducationEvent",
 "name": "Beginners' pottery, week 3",
 "startDate": "2026-11-20T19:00:00Z",
 "eventAttendanceMode": "https://schema.org/OnlineEventAttendanceMode",
 "location": {"@type": "VirtualLocation", "url": "https://meet.example/abc"},
 "organizer": {"@type": "Organization", "name": "Clay Studio"}}
</script>''').single;
    expect(a.name, "Beginners' pottery, week 3");
    expect(a.provider, 'Clay Studio');
    expect(a.online, isTrue);
    expect(a.place, isNull);
    expect(a.isEvent, isTrue);
  });

  test('tables, tickets and travel are left to Trips', () {
    expect(
      _read('''
<script type="application/ld+json">
[{"@type": "FoodEstablishmentReservation", "startTime": "2026-11-23T19:30:00+08:00",
  "reservationFor": {"@type": "Restaurant", "name": "Burnt Ends"}},
 {"@type": "EventReservation", "reservationNumber": "38-12345",
  "reservationFor": {"@type": "Event", "name": "Open day",
    "startDate": "2026-11-30T10:00:00+08:00"}},
 {"@type": "Reservation",
  "reservationFor": {"@type": "Restaurant", "name": "Odette"},
  "startTime": "2026-11-24T19:00:00+08:00"},
 {"@type": "MusicEvent", "name": "Coldplay",
  "startDate": "2026-12-01T19:30:00+08:00"},
 {"@type": "LodgingReservation", "checkinDate": "2026-12-12",
  "reservationFor": {"@type": "Hotel", "name": "Park Hotel"}}]
</script>'''),
      isEmpty,
    );
  });

  test('without a start, nothing', () {
    expect(
      _read('''
<script type="application/ld+json">
{"@type": "ServiceReservation", "reservationFor": {"@type": "Service", "name": "Haircut"}}
</script>'''),
      isEmpty,
    );
  });
}
