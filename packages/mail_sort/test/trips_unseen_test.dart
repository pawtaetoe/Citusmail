// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Trips are read by general rules, not by rules for the emails they were
// written from: other operators, airlines, stations and layouts, and a
// sender the app has never heard of, read the same way; look-alikes
// (offers, news, season tickets, a bank alert) are not trips.

import 'package:mail_extract/mail_extract.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:test/test.dart';

var _ids = 5000;

TripEmail _mail(String subject, String sender, String text) => TripEmail(
  messageId: MessageId(++_ids),
  sender: sender,
  senderName: null,
  subject: subject,
  text: text,
  at: DateTime.utc(2026, 11, 1),
);

ReservationInfo? _one(String subject, String sender, String text) =>
    TripFinder.read(_mail(subject, sender, text)).reservations.singleOrNull;

List<ReservationInfo> _all(String subject, String sender, String text) =>
    TripFinder.read(_mail(subject, sender, text)).reservations;

void main() {
  group('trains', () {
    test('"A > B", the travel date and not the purchase date', () {
      final r = _one(
        'Your Eurostar booking 7HQ2XK',
        'eurostar.com',
        'Booking reference:\n7HQ2XK\nPurchase date:\nNov 01 2026\n'
            'Paris Gare du Nord > London St Pancras\n'
            'Travel date: Dec 05 2026\nDeparts 09:13 Arrives 10:39',
      )!;
      expect(r, isA<TransitReservationInfo>());
      expect(r.start?.day, DateTime(2026, 12, 5));
      expect(r.reservationNumber, '7HQ2XK');
    });

    test('"Station (time) to Station (time)"', () {
      final r = _one(
        'Confirmation de votre voyage',
        'sncf-connect.com',
        'Your trip is confirmed\nOutbound\n12 March 2027\n'
            'Lyon Part-Dieu (07:04) to Marseille Saint-Charles (08:45)\n'
            'Booking reference: QX4LMR',
      )!;
      expect(r.start?.day, DateTime(2027, 3, 12));
      expect((r.start?.wall.hour, r.start?.wall.minute), (7, 4));
    });

    test('a route over two lines', () {
      final r = _one(
        'Your LNER tickets',
        'lner.co.uk',
        'Your booking\nEdinburgh Waverley\nto York / Return\n14 January 2027\n'
            'Edinburgh Waverley\n10:00\nYork\n12:31\n'
            'Booking reference:   58213307',
      )!;
      expect(r.start?.day, DateTime(2027, 1, 14));
      expect(TripFinder.cityOf((r as TransitReservationInfo).to), 'York');
    });

    test('German, a ticket code on the next line, not the booking date', () {
      final r = _one(
        'Ihr Ticket – 4421 9900 1182 7734',
        'sbb.ch',
        'Buchungscode:\n4421 9900 1182 7734\nBuchungsdatum:\n'
            '02. November 2026\nBern > Genève\nReisedatum: Feb 03 2027',
      )!;
      expect(r.start?.day, DateTime(2027, 2, 3));
    });

    test('a rail company the app has never heard of, from its words', () {
      final r = _one(
        'Your train tickets',
        'brightline-travel.example',
        'Your train journey\nLeeds > Manchester Piccadilly\n'
            'Date of travel: Jan 18 2027\nDeparts 07:42\n'
            'Booking reference: NR55821A\n'
            'Collect your tickets at the station.',
      )!;
      expect(r, isA<TransitReservationInfo>());
      expect(r.start?.day, DateTime(2027, 1, 18));
    });
  });

  group('flights', () {
    test('a table: number, aircraft, then code and time, then the date', () {
      final r = _all(
        'Your booking confirmation X7KQ2P',
        'ba.com',
        'Thank you for booking with us\nYour itinerary\nFlight\nDepart\n'
            'Arrive\nTravel class\nBA117\nBoeing 777-300ER\nBritish Airways\n'
            'LHR 08:25\n5 Jan (Tue)\nLondon Heathrow, Terminal 5\n'
            'JFK 11:05\n5 Jan (Tue)\nNew York JFK, Terminal 7\n'
            'Booking reference X7KQ2P',
      );
      final flight = r.single as FlightReservationInfo;
      expect(flight.flightNumber, 'BA 117');
      expect(flight.start?.day, DateTime(2027, 1, 5));
    });

    test('"LH 2471 MUC - LHR"', () {
      final flight =
          _one(
                'Booking confirmation 6TRK9L',
                'lufthansa.com',
                'Your flights\nLH 2471 MUC - LHR\n21 Feb 2027 07:15 - 08:10\n'
                    'Booking code: 6TRK9L',
              )!
              as FlightReservationInfo;
      expect(flight.flightNumber, 'LH 2471');
      expect(flight.start?.day, DateTime(2027, 2, 21));
    });
  });

  group('look-alikes are not trips', () {
    for (final (name, subject, sender, text) in [
      (
        'a rail offer',
        'Paris > London from £39',
        'eurostar.com',
        'Book now: Paris > London from £39. Travel between Jan 10 2027 and '
            'Mar 31 2027. Unsubscribe',
      ),
      (
        'airline news',
        'Meet our new Boeing 787',
        'ba.com',
        'Our Boeing 787-10 now flies LHR - JFK. Flight times from 5 Jan. '
            'Book today.',
      ),
      (
        'a season ticket',
        'Your season ticket renewal',
        'gwr.com',
        'Reading > London Paddington season ticket renews on Jan 01 2027. '
            'Ticket number: 1111 2222 3333 4444',
      ),
      (
        'a bank alert',
        'Card transaction alert',
        'dbs.com',
        'A transaction of GBP 270.00 to AVANTI WEST COAST was made on '
            '23 Jun 2026. Reference 88812345',
      ),
    ]) {
      test(name, () => expect(_all(subject, sender, text), isEmpty));
    }
  });
}
