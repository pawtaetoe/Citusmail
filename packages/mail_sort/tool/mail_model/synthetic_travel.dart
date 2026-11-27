// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Synthetic booking mail: flights, trains and buses, stays, events,
/// tables and hire cars, modelled on the layouts of many real senders.
/// Every company, person and reference in it is made up or generic.
library;

import 'package:mail_sort/mail_sort.dart';

import 'rng.dart';
import 'synthetic_mail.dart';
import 'synthetic_parts.dart';

// ---------------------------------------------------------------- flights

const _airlines = [
  ('Singapore Airlines', 'booking@singaporeair.com', 'SQ'),
  ('British Airways', 'ba@email.ba.com', 'BA'),
  ('Qantas', 'noreply@qantas.com.au', 'QF'),
  ('Emirates', 'do-not-reply@emirates.com', 'EK'),
  ('KLM', 'noreply@klm.com', 'KL'),
  ('Cathay Pacific', 'notification@cathaypacific.com', 'CX'),
  ('United Airlines', 'unitedairlines@united.com', 'UA'),
  ('Delta Air Lines', 'deltaairlines@t.delta.com', 'DL'),
  ('Qatar Airways', 'booking@qatarairways.com', 'QR'),
  ('Japan Airlines', 'jal@jal.com', 'JL'),
  ('Turkish Airlines', 'noreply@thy.com', 'TK'),
  ('Iberia', 'confirmaciones@iberia.com', 'IB'),
];

(String, String, String, String, String, String, DateTime, String) _flight(
  Rng r,
  String airline,
) {
  final ((fromCode, fromCity, fromName), (toCode, toCity, toName)) = route(r);
  final number = '$airline ${r.between(1, 999)}';
  final day = someDay(r);
  final (h, m) = someTime(r);
  final (h2, m2) = someTime(r);
  return (
    number,
    fromCode,
    fromName,
    toCode,
    toName,
    '$fromCity|$toCity',
    day,
    '${two(h)}:${two(m)}|${two(h2)}:${two(m2)}',
  );
}

/// A full-service airline's confirmation, the route on one line.
SynthMail airlineInline(Rng r) {
  final (name, from, code) = r.pick(_airlines);
  final (number, fc, fn, tc, tn, cities, day, times) = _flight(r, code);
  final [fromCity, toCity] = cities.split('|');
  final [dep, arr] = times.split('|');
  final ref = pnr(r);
  final lang = Lang.en;
  final subject = r.pick([
    'Booking confirmation - $fromCity to $toCity',
    'Your booking is confirmed: $ref',
    'Your e-ticket itinerary receipt',
    'Thank you for booking with $name',
    'Your trip to $toCity - booking reference $ref',
    'Booking Confirmation $ref',
    'Itinerary for your trip to $toCity',
    "You're booked! Confirmation #$ref",
    'Your flight confirmation $number',
    'Get ready for your flight to $toCity',
  ]);
  final lines = <String>[
    r.pick([
      'Dear ${person(r)},',
      'Hello ${first(r)},',
      'Thank you for booking with us.',
    ]),
    r.pick([
      'Your booking is confirmed.',
      'We are pleased to confirm your booking.',
      'Your flight has been booked and your e-ticket has been issued.',
    ]),
    '',
    '${r.pick(['Booking reference', 'Booking ref', 'Confirmation code', 'Reservation code'])}: $ref',
    if (r.chance(0.5)) 'E-ticket number: ${digits(r, 3)}-${digits(r, 10)}',
    '',
    r.pick(['Departing flight', 'Outbound', 'Flight 1', 'Your itinerary']),
    r.pick([
      '$number   $fc → $tc',
      '$number $fn ($fc) - $tn ($tc)',
      '$fn ($fc) to $tn ($tc), $number',
    ]),
    date(r, day, lang),
    'Depart $dep   Arrive $arr${r.chance(0.3) ? ' (+1)' : ''}',
    if (r.chance(0.6))
      r.pick([
        'Terminal ${r.between(1, 5)}',
        'Gate closes 20 minutes before departure',
      ]),
    r.pick([
      'Economy, 1 adult.',
      'Business, 2 adults.',
      'Premium Economy',
      'Economy Lite, 1 passenger',
    ]),
    if (r.chance(0.5))
      'Baggage allowance: ${r.pick(['23kg', '1 piece', '2 x 32kg', 'hand baggage only'])}',
    if (r.chance(0.5))
      'Total paid: ${money(r, price(r, 120, 2400), r.pick(['GBP', 'SGD', 'USD', 'EUR']), lang)}',
    if (r.chance(0.4)) 'Online check-in opens 48 hours before departure.',
    if (r.chance(0.3)) 'Manage booking',
  ];
  return synth(MailClass.flight, Sender(name, from), subject, finish(r, lines));
}

/// A confirmation laid out as a table, flattened: codes, names and times
/// each on their own line.
SynthMail airlineTable(Rng r) {
  final (name, from, code) = r.pick(_airlines);
  final ref = pnr(r);
  final legs = r.between(1, 3);
  final lines = <String>[
    r.pick([
      'Your booking',
      'Booking confirmed',
      'ITINERARY',
      'Flight details',
    ]),
    r.pick(['Booking reference', 'Booking code', 'PNR', 'Reservation number']),
    ref,
    '',
  ];
  for (var i = 0; i < legs; i++) {
    final (number, fc, fn, tc, tn, _, day, times) = _flight(r, code);
    final [dep, arr] = times.split('|');
    final d = date(r, day, Lang.en);
    if (r.chance(0.5)) {
      lines.addAll([
        r.pick(['Flight', 'Flight number']),
        number,
        'From',
        fc,
        fn,
        if (r.chance(0.5)) 'Terminal ${r.between(1, 5)}',
        'To',
        tc,
        tn,
        r.pick(['Departs', 'Departure']),
        d,
        dep,
        r.pick(['Arrives', 'Arrival']),
        arr,
        r.pick(['Economy', 'Business', 'Premium Economy', 'First']),
        '',
      ]);
    } else {
      lines.addAll([
        d,
        fc,
        dep,
        '',
        tc,
        arr,
        number,
        r.pick(['Operated by $name', 'Economy (Y)', 'Cabin: Business (J)']),
        '',
      ]);
    }
  }
  lines.addAll([
    if (r.chance(0.5)) 'Passenger',
    if (r.chance(0.5)) person(r).toUpperCase(),
    if (r.chance(0.4)) 'Ticket number ${digits(r, 3)} ${digits(r, 10)}',
  ]);
  final subject = r.pick([
    'Your flight booking $ref',
    'Booking confirmation',
    'Your itinerary - $ref',
    'Confirmation of your booking',
    'E-ticket confirmation $ref',
  ]);
  return synth(MailClass.flight, Sender(name, from), subject, finish(r, lines));
}

/// An award ticket paid with miles or points.
SynthMail awardBooking(Rng r) {
  final programmes = [
    (
      'KrisFlyer',
      'Singapore Airlines',
      'krisflyer@singaporeair.com',
      'SQ',
      'miles',
    ),
    ('Avios', 'British Airways', 'executiveclub@email.ba.com', 'BA', 'Avios'),
    ('Flying Blue', 'Air France', 'flyingblue@airfrance.fr', 'AF', 'Miles'),
    (
      'Miles & More',
      'Lufthansa',
      'miles-and-more@lufthansa.com',
      'LH',
      'miles',
    ),
    ('MileagePlus', 'United Airlines', 'mileageplus@united.com', 'UA', 'miles'),
    (
      'Qantas Frequent Flyer',
      'Qantas',
      'frequentflyer@qantas.com.au',
      'QF',
      'points',
    ),
    (
      'Asia Miles',
      'Cathay Pacific',
      'asiamiles@cathaypacific.com',
      'CX',
      'miles',
    ),
  ];
  final (prog, name, from, code, unit) = r.pick(programmes);
  final (number, fc, fn, tc, tn, _, day, times) = _flight(r, code);
  final [dep, arr] = times.split('|');
  final ref = pnr(r);
  final cost = '${r.between(12, 140)},${r.pick(['000', '500', '250'])} $unit';
  final subject = r.pick([
    'Your redemption booking is confirmed',
    'Award booking confirmation - $ref',
    'Your $prog reward flight booking',
    'Reward flight confirmed: $fc to $tc',
    '$prog Redemption Booking Confirmation ($ref)',
    'Your award ticket has been issued',
  ]);
  final lines = <String>[
    'Dear ${r.pick(['Mr', 'Ms', 'Mx'])} ${r.pick(lastNames)},',
    r.pick([
      'Thank you for redeeming your $unit with $prog.',
      'Your reward flight has been booked.',
      'We have issued your award ticket.',
    ]),
    if (r.chance(0.5))
      'Redemption type: ${r.pick(['Saver', 'Advantage', 'Classic Reward', 'Award'])}',
    '$unit deducted: $cost',
    'Taxes and carrier charges: ${money(r, price(r, 20, 600), r.pick(['GBP', 'SGD', 'USD', 'EUR']), Lang.en)}',
    'Booking reference: $ref',
    '',
    if (r.chance(0.5)) ...[
      number,
      fc,
      dep,
      tc,
      arr,
      date(r, day, Lang.en),
    ] else
      '$number  $fn ($fc) $dep - $tn ($tc) $arr, ${date(r, day, Lang.en)}',
    r.pick(['Business', 'Economy', 'First', 'Premium Economy']),
    if (r.chance(0.5))
      'Your remaining balance is ${r.between(1, 300)},${digits(r, 3)} $unit.',
  ];
  return synth(MailClass.flight, Sender(name, from), subject, finish(r, lines));
}

/// Lufthansa- and Austrian-style German confirmations.
SynthMail airlineGerman(Rng r) {
  final carriers = [
    ('Lufthansa', 'lufthansa@booking.lufthansa.com', 'LH'),
    ('Austrian Airlines', 'noreply@austrian.com', 'OS'),
    ('Eurowings', 'service@eurowings.com', 'EW'),
    ('Condor', 'buchung@condor.com', 'DE'),
    ('SWISS', 'booking@swiss.com', 'LX'),
  ];
  final (name, from, code) = r.pick(carriers);
  final (number, fc, fn, tc, tn, _, day, times) = _flight(r, code);
  final [dep, arr] = times.split('|');
  final ref = pnr(r);
  final subject = r.pick([
    'Ihre Buchungsbestätigung - $ref',
    'Buchungsbestätigung für Ihren Flug nach $tn',
    'Ihre Reiseunterlagen',
    'Ihr Flug am ${date(r, day, Lang.de)}',
    'Ihr elektronisches Ticket',
  ]);
  final lines = <String>[
    r.pick([
      'Sehr geehrte Frau ${r.pick(lastNames)},',
      'Sehr geehrter Herr ${r.pick(lastNames)},',
      'Hallo ${first(r)},',
    ]),
    r.pick([
      'vielen Dank für Ihre Buchung. Ihr Ticket wurde ausgestellt.',
      'hiermit bestätigen wir Ihre Buchung.',
      'Ihre Reise ist gebucht.',
    ]),
    'Buchungscode: $ref',
    if (r.chance(0.5)) 'Ticketnummer: ${digits(r, 3)}-${digits(r, 10)}',
    '',
    'Hinflug',
    'Flug $number',
    '$fn ($fc) – $tn ($tc)',
    'Abflug: ${date(r, day, Lang.de)}, ${time(r, int.parse(dep.substring(0, 2)), int.parse(dep.substring(3)), Lang.de)}',
    'Ankunft: ${time(r, int.parse(arr.substring(0, 2)), int.parse(arr.substring(3)), Lang.de)}',
    r.pick(['Economy Class', 'Business Class', 'Premium Economy']),
    if (r.chance(0.5)) 'Freigepäck: 1 x 23 kg',
    if (r.chance(0.5))
      'Gesamtpreis: ${money(r, price(r, 90, 1800), 'EUR', Lang.de)}',
    if (r.chance(0.4)) 'Online Check-in ist 23 Stunden vor Abflug möglich.',
  ];
  return synth(
    MailClass.flight,
    Sender(name, from, lang: Lang.de),
    subject,
    finish(r, lines),
  );
}

/// Air France-style French confirmations.
SynthMail airlineFrench(Rng r) {
  final carriers = [
    ('Air France', 'confirmation@airfrance.fr', 'AF'),
    ('Transavia', 'noreply@transavia.com', 'TO'),
    ('Corsair', 'reservation@corsair.fr', 'SS'),
  ];
  final (name, from, code) = r.pick(carriers);
  final (number, fc, fn, tc, tn, _, day, times) = _flight(r, code);
  final [dep, arr] = times.split('|');
  final ref = pnr(r);
  final subject = r.pick([
    'Confirmation de votre réservation $ref',
    'Votre billet électronique',
    'Votre voyage à destination de $tn',
    'Confirmation de réservation - vol $number',
  ]);
  final lines = <String>[
    r.pick(['Bonjour ${first(r)},', 'Madame, Monsieur,']),
    r.pick([
      'Nous avons le plaisir de vous confirmer votre réservation.',
      'Merci pour votre réservation. Votre billet a été émis.',
    ]),
    'Référence de réservation : $ref',
    '',
    'Vol aller',
    'Vol $number',
    'Départ : $fn ($fc), ${date(r, day, Lang.fr)} à $dep',
    'Arrivée : $tn ($tc) à $arr',
    r.pick(['Classe Economy', 'Classe Business', 'Premium']),
    if (r.chance(0.5)) 'Bagage en soute : 1 x 23 kg',
    if (r.chance(0.5))
      'Montant total : ${money(r, price(r, 80, 1600), 'EUR', Lang.fr)}',
    if (r.chance(0.4))
      "L'enregistrement en ligne ouvre 30 heures avant le départ.",
  ];
  return synth(
    MailClass.flight,
    Sender(name, from, lang: Lang.fr),
    subject,
    finish(r, lines),
  );
}

/// Low-cost carriers: short, reference-first.
SynthMail lowCost(Rng r) {
  final carriers = [
    ('easyJet', 'noreply@easyjet.com', 'U2'),
    ('Ryanair', 'itinerary@ryanair.com', 'FR'),
    ('Wizz Air', 'noreply@wizzair.com', 'W6'),
    ('Scoot', 'noreply@flyscoot.com', 'TR'),
    ('Jetstar', 'noreply@jetstar.com', 'JQ'),
    ('Vueling', 'booking@vueling.com', 'VY'),
  ];
  final (name, from, code) = r.pick(carriers);
  final (number, fc, fn, tc, tn, _, day, times) = _flight(r, code);
  final [dep, arr] = times.split('|');
  final ref = code == 'U2' ? 'EZY${digits(r, 4)}' : pnr(r);
  final subject = r.pick([
    'Your booking $ref is confirmed',
    'Booking confirmation $ref',
    'Travel Itinerary: $fc - $tc',
    "You're going to $tn!",
    'Your $name booking $ref',
  ]);
  final lines = <String>[
    r.pick(['Booking reference', 'Reservation number', 'Confirmation number']),
    ref,
    '',
    'Flight $number',
    '$fn ($fc) to $tn ($tc)',
    '${date(r, day, Lang.en)} Dep $dep Arr $arr',
    if (r.chance(0.6)) 'Passengers: ${r.between(1, 4)}',
    if (r.chance(0.5))
      'Bags: ${r.pick(['1 x 15kg hold bag', 'Small cabin bag only', 'Priority & 2 cabin bags'])}',
    if (r.chance(0.6))
      'Total: ${money(r, price(r, 25, 380), r.pick(['GBP', 'EUR', 'SGD', 'AUD']), Lang.en)}',
    if (r.chance(0.5)) 'Check in online from 30 days before your flight.',
    if (r.chance(0.3)) 'Add a hotel to your trip and save!',
  ];
  return synth(MailClass.flight, Sender(name, from), subject, finish(r, lines));
}

/// Online travel agencies: "Your flight to X has been booked".
SynthMail flightAgency(Rng r) {
  final agencies = [
    ('Expedia', 'travel@expedia.com'),
    ('Trip.com', 'en_noreply@trip.com'),
    ('Kiwi.com', 'noreply@kiwi.com'),
    ('Opodo', 'noreply@opodo.co.uk'),
    ('lastminute.com', 'noreply@lastminute.com'),
    ('eDreams', 'noreply@edreams.com'),
  ];
  final (name, from) = r.pick(agencies);
  final (number, fc, fn, tc, tn, cities, day, times) = _flight(
    r,
    r.pick(_airlines).$3,
  );
  final [_, toCity] = cities.split('|');
  final [dep, arr] = times.split('|');
  final ref = digits(r, r.between(8, 12));
  final subject = r.pick([
    'Your flight to $toCity has been booked',
    'Flight booked! Itinerary #$ref',
    'Booking confirmed - $fc to $tc - ${date(r, day, Lang.en)}',
    'Your trip to $toCity: booking confirmation',
    'Trip confirmation: $toCity, ${date(r, day, Lang.en)}',
  ]);
  final lines = <String>[
    r.pick([
      'Your flight is booked.',
      'Thanks for booking with $name!',
      'Your booking is confirmed.',
    ]),
    'Itinerary number: $ref',
    'Airline confirmation: ${pnr(r)}',
    '',
    '$fn ($fc) → $tn ($tc)',
    date(r, day, Lang.en),
    '$dep - $arr',
    number,
    if (r.chance(0.5))
      '${r.pick(['Nonstop', '1 stop', 'Direct'])} · ${r.between(1, 14)}h ${r.between(0, 59)}m',
    'Total: ${money(r, price(r, 90, 2000), r.pick(['USD', 'GBP', 'EUR', 'SGD']), Lang.en)}',
    if (r.chance(0.5)) 'View your trip in the app.',
  ];
  return synth(MailClass.flight, Sender(name, from), subject, finish(r, lines));
}

/// Changes and check-in reminders for a booked flight.
SynthMail flightUpdate(Rng r) {
  final (name, from, code) = r.pick(_airlines);
  final (number, fc, fn, tc, tn, _, day, times) = _flight(r, code);
  final [dep, arr] = times.split('|');
  final ref = pnr(r);
  final change = r.chance(0.5);
  final subject = change
      ? r.pick([
          'Important: your flight time has changed',
          'Schedule change for booking $ref',
          'Your itinerary has changed',
          'Flight $number: new departure time',
        ])
      : r.pick([
          'Check-in is now open for your flight to $tn',
          "It's time to check in: $fc to $tc",
          'Your boarding pass for $number',
          'Your trip to $tn is coming up',
        ]);
  final lines = <String>[
    'Booking reference: $ref',
    if (change) ...[
      r.pick([
        'We have had to make a change to your flight.',
        'There has been a schedule change to your booking.',
      ]),
      'New departure: $dep, ${date(r, day, Lang.en)}',
      'Previous departure: ${two(r.between(6, 22))}:${two(r.pick([0, 15, 30, 45]))}',
    ] else ...[
      r.pick([
        'Online check-in is now open.',
        'Your boarding pass is attached.',
        'Check in now to choose your seat.',
      ]),
      'Departure: ${date(r, day, Lang.en)} $dep',
    ],
    '$number $fc - $tc',
    'Arrives $arr',
    if (r.chance(0.5)) 'Gate closes 20 minutes before departure.',
  ];
  return synth(MailClass.flight, Sender(name, from), subject, finish(r, lines));
}

// ----------------------------------------------------------------- trains

/// UK rail: Avanti West Coast, LNER, GWR, Trainline and the like.
SynthMail ukRail(Rng r) {
  final senders = [
    ('Avanti West Coast', 'noreply@avantiwestcoast.co.uk'),
    ('LNER', 'tickets@lner.co.uk'),
    ('GWR', 'noreply@gwr.com'),
    ('Trainline', 'auto-confirm@info.thetrainline.com'),
    ('CrossCountry', 'tickets@crosscountrytrains.co.uk'),
    ('TransPennine Express', 'noreply@tpexpress.co.uk'),
    ('ScotRail', 'tickets@scotrail.co.uk'),
    ('Northern', 'noreply@northernrailway.co.uk'),
  ];
  final (name, from) = r.pick(senders);
  final (a, b) = pair(r, ukStations);
  final day = someDay(r);
  final (h, m) = someTime(r);
  final ret = r.chance(0.4);
  final ref = r.chance(0.5)
      ? code(r, 8)
      : '${code(r, 3, digits: false)}${digits(r, 5)}';
  final ticket = r.pick([
    'Advance Single',
    'Off-Peak Return',
    'Anytime Day Return',
    'Super Off-Peak Single', //
    'Advance Single (1st Class)', 'Off-Peak Day Return',
  ]);
  final subject = r.pick([
    'Your booking confirmation',
    'Your tickets for $a to $b',
    'Your eTickets: $a to $b',
    'Your eTickets are ready',
    'Your mobile tickets for ${date(r, day, Lang.en)}',
    'Booking confirmation: $a to $b',
    'Your e-tickets for ${date(r, day, Lang.en)}',
    'Your $name booking ($ref)',
    'Your journey on ${date(r, day, Lang.en)}',
    'Thanks for booking with $name',
    'Your train tickets are ready',
  ]);
  final lines = <String>[
    r.pick([
      'Hi ${first(r)},',
      'Dear ${person(r)},',
      'Thanks for booking with us.',
    ]),
    r.pick([
      'Your tickets are booked.',
      "Here's your booking confirmation.",
      'Your e-tickets are attached and in the app.',
      'Your booking is complete.',
    ]),
    '${r.pick(['Booking reference', 'Transaction ID', 'Ticket collection reference', 'Booking ref'])}: $ref',
    '',
    r.pick(['Outward journey', 'Outbound', 'Your journey', 'Out']),
    r.pick(['$a to $b', '$a → $b', 'From $a to $b']),
    date(r, day, Lang.en),
    '${r.pick(['Departs', 'Dep', 'Leaving'])} ${time(r, h, m, Lang.en)}',
    if (r.chance(0.6))
      '${r.pick(['Arrives', 'Arr'])} ${time(r, (h + r.between(1, 5)) % 24, m, Lang.en)}',
    if (r.chance(0.6))
      'Coach ${r.pick(['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'J', 'K', 'L', 'M', 'U'])}, Seat ${r.between(1, 80)}',
    'Ticket type: $ticket',
    if (r.chance(0.4))
      'Railcard: ${r.pick(['16-25 Railcard', 'Two Together', 'Senior Railcard', 'None'])}',
    if (ret) ...[
      '',
      'Return journey',
      '$b to $a',
      date(r, day.add(Duration(days: r.between(1, 7))), Lang.en),
    ],
    if (r.chance(0.6))
      'Total paid: ${money(r, price(r, 8, 260), 'GBP', Lang.en)}',
    r.pick([
      'Collect your tickets from the ticket machine at the station using your reference.',
      'Your e-ticket is valid only on the train and date shown.',
      'Download your mobile ticket in the app.',
      'Show your e-ticket to the guard on board.',
      'Your eTicket is attached as a PDF.',
    ]),
  ];
  return synth(MailClass.train, Sender(name, from), subject, finish(r, lines));
}

/// ÖBB, in German or in English.
SynthMail oebb(Rng r) {
  final de = r.chance(0.6);
  final lang = de ? Lang.de : Lang.en;
  final (a, b) = pair(r, atStations);
  final day = someDay(r);
  final (h, m) = someTime(r);
  final train =
      '${r.pick(['RJ', 'RJX', 'IC', 'EC', 'NJ', 'WB', 'REX'])} ${r.between(10, 1700)}';
  final ref = digits(r, r.between(10, 12));
  final ticketCode = code(r, 6);
  final from = r.pick([
    'tickets@oebb.at',
    'noreply@oebb.at',
    'ticketshop@oebb.at',
  ]);
  final subject = de
      ? r.pick([
          'Ihre Buchung bei den ÖBB',
          'Ihr ÖBB Ticket',
          'Buchungsbestätigung ÖBB Ticketshop',
          'Ihr Ticket: $a - $b',
          'Ihre Fahrkarte für ${date(r, day, lang)}',
        ])
      : r.pick([
          'Your ÖBB booking',
          'Your ÖBB ticket',
          'Booking confirmation ÖBB Ticketshop',
          'Your ticket: ${a.replaceAll('Wien', 'Vienna')} - $b',
        ]);
  final lines = de
      ? <String>[
          r.pick([
            'Sehr geehrte Kundin, sehr geehrter Kunde,',
            'Hallo ${first(r)},',
            'Grüß Gott,',
          ]),
          r.pick([
            'vielen Dank für Ihre Buchung. Ihr Ticket finden Sie im Anhang.',
            'Ihr Ticket wurde erfolgreich gebucht.',
            'danke, dass Sie mit uns reisen.',
          ]),
          'Buchungsnummer: $ref',
          'Ticketcode: $ticketCode',
          '',
          r.pick(['Hinfahrt', 'Ihre Verbindung', 'Fahrt']),
          date(r, day, lang),
          '$a ab ${time(r, h, m, lang)}',
          '$b an ${time(r, (h + r.between(1, 4)) % 24, (m + 13) % 60, lang)}',
          train,
          if (r.chance(0.6))
            'Sitzplatzreservierung: Wagen ${r.between(20, 39)}, Platz ${r.between(11, 128)}',
          r.pick([
            'Sparschiene',
            'Standard-Ticket',
            'Klimaticket nicht enthalten',
            '2. Klasse',
            '1. Klasse',
          ]),
          if (r.chance(0.6))
            'Preis: ${money(r, price(r, 9.9, 140), 'EUR', lang)}',
          if (r.chance(0.5)) 'Gültig nur für den gebuchten Zug.',
          if (r.chance(0.4))
            'Bitte halten Sie das Ticket bei der Kontrolle bereit.',
        ]
      : <String>[
          r.pick(['Dear customer,', 'Hello ${first(r)},']),
          r.pick([
            'thank you for your booking. Your ticket is attached.',
            'your ticket has been booked.',
          ]),
          'Booking number: $ref',
          'Ticket code: $ticketCode',
          '',
          r.pick(['Outward journey', 'Your connection']),
          date(r, day, lang),
          '${a.replaceAll('Wien', 'Vienna')} dep. ${time(r, h, m, lang)}',
          '$b arr. ${time(r, (h + r.between(1, 4)) % 24, (m + 13) % 60, lang)}',
          train,
          if (r.chance(0.6))
            'Seat reservation: coach ${r.between(20, 39)}, seat ${r.between(11, 128)}',
          r.pick(['Sparschiene', 'Standard ticket', '2nd class', '1st class']),
          if (r.chance(0.6))
            'Price: ${money(r, price(r, 9.9, 140), 'EUR', lang)}',
          if (r.chance(0.5)) 'Only valid on the booked train.',
        ];
  return synth(
    MailClass.train,
    Sender('ÖBB', from, lang: lang),
    subject,
    finish(r, lines),
  );
}

/// Deutsche Bahn, in German or in English.
SynthMail deutscheBahn(Rng r) {
  final de = r.chance(0.65);
  final lang = de ? Lang.de : Lang.en;
  final (a, b) = pair(r, deStations);
  final day = someDay(r);
  final (h, m) = someTime(r);
  final train =
      '${r.pick(['ICE', 'IC', 'EC', 'RE', 'FLX'])} ${r.between(10, 2000)}';
  final order = digits(r, 12);
  final subject = de
      ? r.pick([
          'Buchungsbestätigung (Auftrag $order)',
          'Ihre Fahrkarte für $a – $b',
          'Ihre Reise am ${date(r, day, lang)}',
          'Ihr Online-Ticket',
          'Ihre Buchung bei der Deutschen Bahn',
        ])
      : r.pick([
          'Booking confirmation (order $order)',
          'Your ticket for $a – $b',
          'Your journey on ${date(r, day, lang)}',
          'Your DB online ticket',
        ]);
  final lines = de
      ? <String>[
          r.pick([
            'Guten Tag ${person(r)},',
            'Hallo,',
            'Sehr geehrte Reisende,',
          ]),
          r.pick([
            'vielen Dank für Ihre Buchung.',
            'Ihre Fahrkarte ist gebucht.',
            'anbei Ihr Online-Ticket.',
          ]),
          'Auftragsnummer: $order',
          if (r.chance(0.5)) 'Ticketcode: ${code(r, 6)}',
          '',
          'Hinfahrt am ${date(r, day, lang)}',
          'ab $a ${time(r, h, m, lang)} Gl. ${r.between(1, 22)}',
          'an $b ${time(r, (h + r.between(1, 6)) % 24, m, lang)}',
          train,
          if (r.chance(0.6))
            'Reservierung: Wagen ${r.between(1, 14)}, Platz ${r.between(11, 118)}',
          r.pick(['Flexpreis', 'Sparpreis', 'Super Sparpreis', 'BahnCard 25']),
          if (r.chance(0.6))
            'Summe: ${money(r, price(r, 17.9, 190), 'EUR', lang)}',
          if (r.chance(0.5)) 'Zugbindung: Ja',
        ]
      : <String>[
          r.pick(['Hello ${person(r)},', 'Dear traveller,']),
          'Thank you for your booking.',
          'Order number: $order',
          '',
          'Outward journey on ${date(r, day, lang)}',
          'dep $a ${time(r, h, m, lang)} platform ${r.between(1, 22)}',
          'arr $b ${time(r, (h + r.between(1, 6)) % 24, m, lang)}',
          train,
          if (r.chance(0.6))
            'Seat reservation: coach ${r.between(1, 14)}, seat ${r.between(11, 118)}',
          r.pick(['Flexpreis', 'Saver Fare', 'Super Saver Fare']),
          if (r.chance(0.6))
            'Total: ${money(r, price(r, 17.9, 190), 'EUR', lang)}',
        ];
  return synth(
    MailClass.train,
    Sender(
      'DB Fernverkehr',
      r.pick(['buchungsbestaetigung@bahn.de', 'noreply@bahn.de']),
      lang: lang,
    ),
    subject,
    finish(r, lines),
  );
}

/// SNCF Connect, in French or in English.
SynthMail sncf(Rng r) {
  final fr = r.chance(0.65);
  final lang = fr ? Lang.fr : Lang.en;
  final (a, b) = pair(r, frStations);
  final day = someDay(r);
  final (h, m) = someTime(r);
  final train =
      '${r.pick(['TGV INOUI', 'OUIGO', 'TER', 'Intercités'])} ${r.between(1000, 9999)}';
  final ref = code(r, 6, digits: false);
  final subject = fr
      ? r.pick([
          'Confirmation de votre voyage',
          'Votre réservation $ref est confirmée',
          'Vos billets pour $b',
          'Votre e-billet : $a → $b',
          'Confirmation de commande - $ref',
        ])
      : r.pick([
          'Your trip confirmation',
          'Your booking $ref is confirmed',
          'Your tickets to $b',
        ]);
  final lines = fr
      ? <String>[
          r.pick(['Bonjour ${first(r)},', 'Bonjour,']),
          r.pick([
            'Votre voyage est confirmé.',
            'Merci pour votre réservation.',
            'Voici vos billets.',
          ]),
          'Référence dossier : $ref',
          '',
          'Aller',
          date(r, day, lang),
          '$a  ${time(r, h, m, lang)}',
          '$b  ${time(r, (h + r.between(1, 5)) % 24, m, lang)}',
          train,
          if (r.chance(0.6))
            'Voiture ${r.between(1, 20)} - Place ${r.between(1, 110)}',
          r.pick([
            '2nde classe',
            '1ère classe',
            'Tarif Avantage',
            'Carte Avantage Jeune',
          ]),
          if (r.chance(0.6))
            'Montant total : ${money(r, price(r, 16, 190), 'EUR', lang)}',
          if (r.chance(0.5))
            'Votre e-billet est disponible dans l\'application SNCF Connect.',
        ]
      : <String>[
          'Hello ${first(r)},',
          'Your trip is confirmed.',
          'Booking reference: $ref',
          '',
          'Outbound',
          date(r, day, lang),
          '$a  ${time(r, h, m, lang)}',
          '$b  ${time(r, (h + r.between(1, 5)) % 24, m, lang)}',
          train,
          if (r.chance(0.6))
            'Coach ${r.between(1, 20)} - Seat ${r.between(1, 110)}',
          r.pick(['2nd class', '1st class']),
          if (r.chance(0.6))
            'Total: ${money(r, price(r, 16, 190), 'EUR', lang)}',
        ];
  return synth(
    MailClass.train,
    Sender(
      'SNCF Connect',
      r.pick(['noreply@sncf-connect.com', 'confirmation@sncf.fr']),
      lang: lang,
    ),
    subject,
    finish(r, lines),
  );
}

/// Eurostar.
SynthMail eurostar(Rng r) {
  final (a, b) = pair(r, eurostarStations);
  final day = someDay(r);
  final (h, m) = someTime(r);
  final ref = code(r, 6, digits: false);
  final subject = r.pick([
    'Your Eurostar booking is confirmed',
    'Booking confirmation $ref',
    'Your e-tickets for $b',
    'Get ready for your trip to ${b.split(' ').first}',
  ]);
  final lines = <String>[
    'Hi ${first(r)},',
    r.pick([
      "You're all booked.",
      'Thanks for booking with Eurostar.',
      'Your tickets are ready.',
    ]),
    'Booking reference: $ref',
    '',
    r.pick(['Outbound', 'Your journey']),
    '$a to $b',
    date(r, day, Lang.en),
    'Departs ${time(r, h, m, Lang.en)} · Arrives ${time(r, (h + 2) % 24, (m + 22) % 60, Lang.en)}',
    'Train ${9000 + r.between(1, 999)}',
    'Coach ${r.between(1, 18)}, Seat ${r.between(1, 90)}',
    r.pick([
      'Standard',
      'Standard Premier',
      'Business Premier',
      'Eurostar Plus',
    ]),
    if (r.chance(0.5)) 'Check-in closes 30 minutes before departure.',
    if (r.chance(0.5))
      'Total: ${money(r, price(r, 39, 480), r.pick(['GBP', 'EUR']), Lang.en)}',
  ];
  return synth(
    MailClass.train,
    Sender(
      'Eurostar',
      r.pick(['tickets@eurostar.com', 'no-reply@eurostar.com']),
    ),
    subject,
    finish(r, lines),
  );
}

/// Buses and coaches: FlixBus, National Express, Megabus.
SynthMail coach(Rng r) {
  final senders = [
    ('FlixBus', 'booking@flixbus.com', Lang.en),
    ('FlixBus', 'buchung@flixbus.de', Lang.de),
    ('National Express', 'tickets@nationalexpress.com', Lang.en),
    ('Megabus', 'noreply@megabus.com', Lang.en),
    ('BlaBlaCar Bus', 'noreply@blablacar.fr', Lang.fr),
  ];
  final (name, from, lang) = r.pick(senders);
  final (a, b) = pair(r, busStops);
  final day = someDay(r);
  final (h, m) = someTime(r);
  final ref = digits(r, 10);
  final subject = switch (lang) {
    Lang.de => r.pick([
      'Deine Buchungsbestätigung',
      'Dein Ticket: $a – $b',
      'Buchung #$ref',
    ]),
    Lang.fr => r.pick([
      'Votre billet de bus',
      'Confirmation de réservation #$ref',
    ]),
    Lang.en => r.pick([
      'Your booking confirmation',
      'Your coach ticket: $a to $b',
      'Booking #$ref confirmed',
      'Your bus ticket',
    ]),
  };
  final lines = <String>[
    switch (lang) {
      Lang.de => 'Danke für deine Buchung!',
      Lang.fr => 'Merci pour votre réservation !',
      Lang.en => r.pick([
        'Thanks for your booking!',
        'Your ticket is attached.',
      ]),
    },
    '${lang == Lang.de
        ? 'Buchungsnummer'
        : lang == Lang.fr
        ? 'Numéro de réservation'
        : 'Booking number'}: $ref',
    '',
    date(r, day, lang),
    '${time(r, h, m, lang)} $a',
    '${time(r, (h + r.between(2, 9)) % 24, m, lang)} $b',
    if (r.chance(0.5))
      '${lang == Lang.de ? 'Linie' : 'Line'} ${r.pick(['N', '0', ''])}${r.between(1, 999)}',
    if (r.chance(0.5))
      '${lang == Lang.de ? 'Fahrgäste' : 'Passengers'}: ${r.between(1, 3)}',
    if (r.chance(0.6))
      '${lang == Lang.de ? 'Gesamt' : 'Total'}: ${money(r, price(r, 5, 80), r.pick(['EUR', 'GBP']), lang)}',
  ];
  return synth(
    MailClass.train,
    Sender(name, from, lang: lang),
    subject,
    finish(r, lines),
  );
}

/// A train booking that changed, or a reminder of one.
SynthMail trainUpdate(Rng r) {
  final uk = r.chance(0.6);
  final (a, b) = pair(r, uk ? ukStations : deStations);
  final day = someDay(r);
  final (h, m) = someTime(r);
  final lang = uk ? Lang.en : Lang.de;
  final subject = uk
      ? r.pick([
          'Your journey has changed',
          'Important information about your journey to $b',
          'Your journey tomorrow: $a to $b',
          'Reminder: you are travelling to $b soon',
        ])
      : r.pick([
          'Ihre Reise hat sich geändert',
          'Fahrplanänderung für Ihre Verbindung',
          'Erinnerung: Ihre Reise nach $b',
        ]);
  final lines = <String>[
    if (uk)
      'Booking reference: ${code(r, 8)}'
    else
      'Auftragsnummer: ${digits(r, 12)}',
    uk
        ? r.pick([
            'The time of your train has changed.',
            'Your train is now scheduled to depart at a different time.',
            "Here's everything you need for your journey.",
          ])
        : r.pick([
            'Die Abfahrtszeit Ihres Zuges hat sich geändert.',
            'Ihre Reise steht bald an.',
          ]),
    '$a → $b',
    date(r, day, lang),
    '${uk ? 'Departs' : 'Abfahrt'} ${time(r, h, m, lang)}',
    if (r.chance(0.5))
      uk ? 'Platform ${r.between(1, 16)}' : 'Gleis ${r.between(1, 16)}',
  ];
  return synth(
    MailClass.train,
    uk
        ? Sender(
            r.pick(['Avanti West Coast', 'LNER', 'Trainline']),
            r.pick([
              'noreply@avantiwestcoast.co.uk',
              'tickets@lner.co.uk',
              'service@info.thetrainline.com',
            ]),
          )
        : Sender('DB', 'noreply@bahn.de', lang: Lang.de),
    subject,
    finish(r, lines),
  );
}

// ------------------------------------------------------------------ stays

/// Booking sites and hotels, in English, German or French.
SynthMail stay(Rng r) {
  final senders = [
    ('Booking.com', 'noreply@booking.com', Lang.en),
    ('Booking.com', 'noreply@booking.com', Lang.de),
    ('Hotels.com', 'confirmation@mail.hotels.com', Lang.en),
    ('Expedia', 'travel@expedia.com', Lang.en),
    ('Agoda', 'no-reply@agoda.com', Lang.en),
    ('Marriott Bonvoy', 'reservations@marriott.com', Lang.en),
    ('Hilton', 'hiltonhotels@h1.hilton.com', Lang.en),
    ('Accor', 'confirmation@accor.com', Lang.fr),
    ('HRS', 'buchung@hrs.de', Lang.de),
    ('Premier Inn', 'bookings@premierinn.com', Lang.en),
  ];
  final (name, from, lang) = r.pick(senders);
  final city = r.pick(cities);
  final h = hotel(r, city);
  final day = someDay(r);
  final nights = r.between(1, 9);
  final out = day.add(Duration(days: nights));
  final ref = r.chance(0.5)
      ? '${digits(r, 4)}.${digits(r, 3)}.${digits(r, 3)}'
      : digits(r, r.between(8, 10));
  final changed = r.chance(0.15);
  final subject = switch (lang) {
    Lang.en =>
      changed
          ? r.pick([
              'Your booking at $h has been changed',
              'Booking modified: $h',
              'Your reservation has been updated',
            ])
          : r.pick([
              'Your booking is confirmed at $h',
              '$h has been booked',
              'Thanks! Your booking is confirmed at $h',
              'Reservation confirmation #$ref',
              'Your stay at $h',
              'Booking confirmation - $h, $city',
              'Your $city hotel has been booked',
              'Confirmation: $h (${date(r, day, lang)})',
            ]),
    Lang.de =>
      changed
          ? 'Ihre Buchung wurde geändert – $h'
          : r.pick([
              'Buchungsbestätigung – $h',
              'Ihre Buchung in $city ist bestätigt',
              'Danke! Ihre Buchung ist bestätigt.',
            ]),
    Lang.fr =>
      changed
          ? 'Votre réservation a été modifiée'
          : r.pick([
              'Confirmation de réservation – $h',
              'Votre séjour à $city est confirmé',
            ]),
  };
  final lines = switch (lang) {
    Lang.en => <String>[
      r.pick(['Hi ${first(r)},', 'Dear ${person(r)},', 'Thanks for booking!']),
      r.pick([
        'Your booking is confirmed.',
        'We look forward to welcoming you.',
        'Your reservation is now confirmed.',
      ]),
      h,
      if (r.chance(0.6)) address(r),
      '${r.pick(['Confirmation number', 'Booking number', 'Reservation number', 'Itinerary #'])}: $ref',
      if (r.chance(0.5)) 'PIN code: ${digits(r, 4)}',
      'Check-in: ${date(r, day, lang)}${r.chance(0.5) ? ' from 15:00' : ''}',
      'Check-out: ${date(r, out, lang)}${r.chance(0.5) ? ' until 11:00' : ''}',
      '$nights night${nights > 1 ? 's' : ''}, ${r.between(1, 3)} room${r.chance(0.3) ? 's' : ''}, ${r.between(1, 4)} adults',
      if (r.chance(0.5))
        r.pick([
          'Double Room with City View',
          'Standard Twin Room',
          'Deluxe King',
          'Studio Apartment',
        ]),
      if (r.chance(0.6))
        'Total price: ${money(r, price(r, 60, 2400), r.pick(['EUR', 'GBP', 'USD', 'SGD']), lang)}',
      if (r.chance(0.4))
        'Free cancellation until ${date(r, day.subtract(const Duration(days: 2)), lang)}',
      if (r.chance(0.3)) 'Manage your booking',
    ],
    Lang.de => <String>[
      'Hallo ${first(r)},',
      'Ihre Buchung ist bestätigt.',
      h,
      'Buchungsnummer: $ref',
      'Anreise: ${date(r, day, lang)} (ab 15:00 Uhr)',
      'Abreise: ${date(r, out, lang)} (bis 11:00 Uhr)',
      '$nights ${nights > 1 ? 'Nächte' : 'Nacht'}, ${r.between(1, 4)} Erwachsene',
      if (r.chance(0.6))
        'Gesamtpreis: ${money(r, price(r, 60, 2400), 'EUR', lang)}',
      if (r.chance(0.4))
        'Kostenlose Stornierung bis ${date(r, day.subtract(const Duration(days: 2)), lang)}',
    ],
    Lang.fr => <String>[
      'Bonjour ${first(r)},',
      'Votre réservation est confirmée.',
      h,
      'Numéro de réservation : $ref',
      'Arrivée : ${date(r, day, lang)} à partir de 15h00',
      'Départ : ${date(r, out, lang)} avant 12h00',
      '$nights nuit${nights > 1 ? 's' : ''}, ${r.between(1, 4)} adultes',
      if (r.chance(0.6))
        'Prix total : ${money(r, price(r, 60, 2400), 'EUR', lang)}',
    ],
  };
  return synth(
    MailClass.stay,
    Sender(name, from, lang: lang),
    subject,
    finish(r, lines),
  );
}

/// Holiday rentals: Airbnb, Vrbo.
SynthMail rental(Rng r) {
  final (name, from) = r.pick([
    ('Airbnb', 'automated@airbnb.com'),
    ('Vrbo', 'noreply@vrbo.com'),
    ('Holidu', 'service@holidu.com'),
  ]);
  final city = r.pick(cities);
  final host = first(r);
  final day = someDay(r);
  final nights = r.between(2, 12);
  final subject = r.pick([
    'Reservation confirmed for $city',
    'Your reservation is confirmed',
    "You're going to $city!",
    'Booking confirmed: ${r.pick(['Sunny loft', 'Cosy flat', 'Seaside cottage', 'Old town studio'])} in $city',
    'Your trip to $city is booked',
  ]);
  final lines = <String>[
    r.pick([
      'Pack your bags!',
      'Your reservation is confirmed.',
      'Get ready for $city.',
    ]),
    '$host is expecting you on ${date(r, day, Lang.en)}.',
    'Check-in: ${date(r, day, Lang.en)}, after ${r.between(14, 17)}:00',
    'Checkout: ${date(r, day.add(Duration(days: nights)), Lang.en)}, ${r.between(10, 12)}:00',
    'Guests: ${r.between(1, 6)}',
    'Confirmation code: ${code(r, 10, digits: false)}',
    if (r.chance(0.6))
      'Total (EUR): ${money(r, price(r, 120, 3000), 'EUR', Lang.en)}',
    if (r.chance(0.5)) 'Message your host',
    if (r.chance(0.4)) address(r),
  ];
  return synth(MailClass.stay, Sender(name, from), subject, finish(r, lines));
}

// ----------------------------------------------------------------- events

SynthMail event(Rng r) {
  final senders = [
    ('Ticketmaster', 'customer_support@email.ticketmaster.com', Lang.en),
    ('Eventbrite', 'orders@eventbrite.com', Lang.en),
    ('See Tickets', 'noreply@seetickets.com', Lang.en),
    ('AXS', 'noreply@axs.com', Lang.en),
    ('oeticket', 'service@oeticket.com', Lang.de),
    ('Eventim', 'service@eventim.de', Lang.de),
    ('Fnac Spectacles', 'billetterie@fnacspectacles.com', Lang.fr),
    ('Dice', 'tickets@dice.fm', Lang.en),
  ];
  final (name, from, lang) = r.pick(senders);
  final act = r.pick(acts);
  final venue = r.pick(venues);
  final day = someDay(r);
  final (h, m) = someTime(r);
  final order =
      '${r.between(10, 99)}-${digits(r, 5)}/${code(r, 3, digits: false)}';
  final subject = switch (lang) {
    Lang.de => r.pick([
      'Ihre Tickets für $act',
      'Bestellbestätigung: $act',
      'Deine Tickets sind da',
    ]),
    Lang.fr => r.pick([
      'Vos billets pour $act',
      'Confirmation de commande : $act',
    ]),
    Lang.en => r.pick([
      'Your order is confirmed: $act',
      'Your tickets for $act',
      "You're going to $act!",
      'Order confirmation #$order',
      'Your $act e-tickets',
      'Get ready: $act at $venue',
    ]),
  };
  final lines = switch (lang) {
    Lang.de => <String>[
      'Vielen Dank für Ihre Bestellung!',
      act,
      venue,
      '${date(r, day, lang)}, Einlass ${time(r, h, m, lang)}',
      'Bestellnummer: $order',
      '${r.between(1, 4)} x ${r.pick(['Stehplatz', 'Sitzplatz Kat. 2', 'Block C, Reihe 12'])}',
      if (r.chance(0.5)) 'Gesamt: ${money(r, price(r, 25, 300), 'EUR', lang)}',
      'Ihre E-Tickets finden Sie im Anhang.',
    ],
    Lang.fr => <String>[
      'Merci pour votre commande !',
      act,
      venue,
      '${date(r, day, lang)} à ${time(r, h, m, lang)}',
      'Numéro de commande : $order',
      '${r.between(1, 4)} billet(s) - ${r.pick(['Fosse', 'Catégorie 1', 'Balcon'])}',
      'Vos e-billets sont disponibles dans votre compte.',
    ],
    Lang.en => <String>[
      r.pick([
        "You're in!",
        'Thanks for your order.',
        'Your tickets are ready.',
      ]),
      act,
      venue,
      '${date(r, day, Lang.en)} · ${r.pick(['Doors open', 'Starts'])} ${time(r, h, m, Lang.en)}',
      'Order #$order',
      '${r.between(1, 6)} x ${r.pick(['General Admission', 'Standing', 'Section 112, Row F', 'Stalls', 'Adult'])}',
      if (r.chance(0.5))
        'Total: ${money(r, price(r, 15, 420), r.pick(['GBP', 'USD', 'EUR', 'AUD']), Lang.en)}',
      r.pick([
        'Your mobile tickets are in the app.',
        'Print your tickets or show them on your phone.',
        'Your e-tickets are attached.',
      ]),
    ],
  };
  return synth(
    MailClass.event,
    Sender(name, from, lang: lang),
    subject,
    finish(r, lines),
  );
}

/// Museums, attractions, tours with a timed entry.
SynthMail attraction(Rng r) {
  final places = [
    ('Tower of London', 'tickets@hrp.org.uk'),
    ('Louvre', 'billetterie@louvre.fr'),
    ('Schönbrunn Palace', 'tickets@schoenbrunn.at'),
    ('GetYourGuide', 'no-reply@getyourguide.com'),
    ('Klook', 'noreply@klook.com'),
    ('Gardens by the Bay', 'tickets@gardensbythebay.com.sg'),
  ];
  final (name, from) = r.pick(places);
  final day = someDay(r);
  final (h, m) = someTime(r);
  final subject = r.pick([
    'Your booking confirmation: $name',
    'Your tickets for ${date(r, day, Lang.en)}',
    'Booking confirmed - ${r.pick(['Skip-the-line entry', 'Guided tour', 'Timed entry ticket'])}',
    'Your activity is booked',
  ]);
  final lines = <String>[
    'Thanks for booking!',
    r.pick([
      'Timed entry ticket',
      'Guided walking tour',
      'Day pass',
      'Evening river cruise',
    ]),
    'Date: ${date(r, day, Lang.en)}',
    'Time: ${time(r, h, m, Lang.en)}',
    'Booking reference: ${code(r, 9)}',
    '${r.between(1, 5)} x Adult',
    'Show this voucher on your phone at the entrance.',
  ];
  return synth(MailClass.event, Sender(name, from), subject, finish(r, lines));
}

// ------------------------------------------------------------ restaurants

SynthMail restaurant(Rng r) {
  final senders = [
    ('OpenTable', 'member_services@opentable.com', Lang.en),
    ('Resy', 'notify@resy.com', Lang.en),
    ('Chope', 'noreply@chope.co', Lang.en),
    ('TheFork', 'noreply@thefork.com', Lang.fr),
    ('Quandoo', 'reservierung@quandoo.de', Lang.de),
    ('SevenRooms', 'reservations@sevenrooms.com', Lang.en),
    ('Tock', 'noreply@exploretock.com', Lang.en),
  ];
  final (name, from, lang) = r.pick(senders);
  final place = r.pick(restaurants);
  final day = someDay(r);
  final (h, m) = (r.between(12, 21), r.pick([0, 15, 30, 45]));
  final party = r.between(1, 8);
  final subject = switch (lang) {
    Lang.de => r.pick([
      'Ihre Reservierung im $place ist bestätigt',
      'Reservierungsbestätigung: $place',
    ]),
    Lang.fr => r.pick([
      'Votre réservation au restaurant $place est confirmée',
      'Réservation confirmée : $place',
    ]),
    Lang.en => r.pick([
      'Your reservation at $place is confirmed',
      'Your table reservation at $place is confirmed',
      'Reservation confirmed: $place, ${date(r, day, Lang.en)}',
      "You're booked at $place",
      'Table for $party at $place',
    ]),
  };
  final lines = switch (lang) {
    Lang.de => <String>[
      'Hallo ${first(r)},',
      'Ihre Reservierung ist bestätigt.',
      place,
      '${date(r, day, lang)} um ${time(r, h, m, lang)}',
      'Tisch für $party Personen',
      'Reservierungsnummer: ${code(r, 8)}',
      'Bitte erscheinen Sie pünktlich.',
    ],
    Lang.fr => <String>[
      'Bonjour ${first(r)},',
      'Votre réservation est confirmée.',
      place,
      '${date(r, day, lang)} à ${time(r, h, m, lang)}',
      '$party personnes',
      'Numéro de réservation : ${code(r, 8)}',
    ],
    Lang.en => <String>[
      r.pick(['Hi ${first(r)},', 'See you soon!', 'Your table is booked.']),
      place,
      if (r.chance(0.5)) address(r),
      '${date(r, day, Lang.en)} at ${time(r, h, m, Lang.en)}',
      r.pick([
        'Party of $party',
        'Table for $party',
        '$party guests',
        'Party size: $party',
      ]),
      'Reservation ID: ${r.pick(['CH-', 'R', '#', ''])}${digits(r, 6)}',
      if (r.chance(0.5))
        'Please arrive on time. The table is held for 15 minutes.',
      if (r.chance(0.4))
        'Need to change your plans? Modify or cancel your reservation.',
    ],
  };
  return synth(
    MailClass.restaurant,
    Sender(name, from, lang: lang),
    subject,
    finish(r, lines),
  );
}

// -------------------------------------------------------------- hire cars

SynthMail carHire(Rng r) {
  final senders = [
    ('Hertz', 'reservations@emails.hertz.com', Lang.en),
    ('Europcar', 'reservation@europcar.com', Lang.en),
    ('SIXT', 'reservierung@sixt.de', Lang.de),
    ('SIXT', 'reservations@sixt.com', Lang.en),
    ('Rentalcars.com', 'noreply@rentalcars.com', Lang.en),
    ('Avis', 'avis@e.avis.com', Lang.en),
    ('Enterprise', 'enterprise@email.enterprise.com', Lang.en),
    ('Ada', 'reservation@ada.fr', Lang.fr),
  ];
  final (name, from, lang) = r.pick(senders);
  final city = r.pick(cities);
  final day = someDay(r);
  final back = day.add(Duration(days: r.between(1, 14)));
  final (h, m) = someTime(r);
  final ref = r.chance(0.5)
      ? '${digits(r, 9)}${code(r, 2, digits: false)}'
      : code(r, 10);
  final car = r.pick([
    'VW Golf or similar',
    'Toyota Yaris or similar',
    'BMW 3 Series or similar',
    'Fiat 500 or similar',
    'Skoda Octavia Estate',
  ]);
  final subject = switch (lang) {
    Lang.de => r.pick([
      'Ihre Reservierung bei $name',
      'Reservierungsbestätigung $ref',
      'Ihr Mietwagen in $city',
    ]),
    Lang.fr => r.pick([
      'Votre réservation de véhicule',
      'Confirmation de location $ref',
    ]),
    Lang.en => r.pick([
      'Your $name reservation',
      'Your car hire booking is confirmed',
      'Rental car confirmation $ref',
      'Booking confirmed: car hire in $city',
      'Your $name car rental confirmation',
    ]),
  };
  final lines = switch (lang) {
    Lang.de => <String>[
      'Vielen Dank für Ihre Reservierung.',
      'Reservierungsnummer: $ref',
      'Abholung: ${date(r, day, lang)}, ${time(r, h, m, lang)}, $city Flughafen',
      'Rückgabe: ${date(r, back, lang)}, ${time(r, h, m, lang)}',
      'Fahrzeug: $car',
      if (r.chance(0.6))
        'Voraussichtlicher Preis: ${money(r, price(r, 60, 900), 'EUR', lang)}',
    ],
    Lang.fr => <String>[
      'Merci pour votre réservation.',
      'Numéro de réservation : $ref',
      'Prise en charge : ${date(r, day, lang)} à ${time(r, h, m, lang)}, $city',
      'Restitution : ${date(r, back, lang)}',
      'Véhicule : $car',
    ],
    Lang.en => <String>[
      r.pick([
        'Thanks for booking with $name.',
        'Your car is reserved.',
        'Your booking is confirmed.',
      ]),
      '${r.pick(['Confirmation number', 'Reservation number', 'Booking reference'])}: $ref',
      'Pick-up: ${date(r, day, Lang.en)} ${time(r, h, m, Lang.en)}',
      r.pick(['$city Airport', '$city Central Station', '$city Downtown']),
      'Drop-off: ${date(r, back, Lang.en)} ${time(r, h, m, Lang.en)}',
      'Vehicle: $car',
      if (r.chance(0.5)) 'Mileage: Unlimited',
      if (r.chance(0.5)) 'Main driver: ${person(r)}',
      if (r.chance(0.6))
        'Estimated total: ${money(r, price(r, 60, 900), r.pick(['EUR', 'GBP', 'USD', 'AUD']), Lang.en)}',
      if (r.chance(0.4))
        'Please bring your driving licence and the credit card used to book.',
    ],
  };
  return synth(
    MailClass.car,
    Sender(name, from, lang: lang),
    subject,
    finish(r, lines),
  );
}

/// All the booking templates.
/// Hotels writing themselves, without a booking site's wording.
SynthMail hotelDirect(Rng r) {
  final lang = r.pick([Lang.en, Lang.en, Lang.de, Lang.fr]);
  final city = r.pick(cities);
  final name = hotel(r, city);
  final domain = name.toLowerCase().replaceAll(RegExp('[^a-z]'), '');
  final day = someDay(r);
  final nights = r.between(1, 6);
  final out = day.add(Duration(days: nights));
  final ref = digits(r, r.between(5, 9));
  final subject = switch (lang) {
    Lang.en => r.pick([
      'Reservation confirmation',
      'Your reservation at $name',
      '$name has been booked',
      'Your stay with us, ${date(r, day, lang)}',
      'Confirmation of your room reservation',
      'We look forward to your stay',
    ]),
    Lang.de => r.pick([
      'Reservierungsbestätigung',
      'Ihre Zimmerreservierung',
      'Bestätigung Ihres Aufenthalts',
      'Ihre Reservierung im $name',
    ]),
    Lang.fr => r.pick([
      'Confirmation de votre séjour',
      'Votre réservation à $name',
      'Confirmation de réservation de chambre',
    ]),
  };
  final room = switch (lang) {
    Lang.en => r.pick([
      '1 Double Room',
      'Superior Twin Room',
      'Junior Suite',
      'Single Room',
    ]),
    Lang.de => r.pick([
      '1 Doppelzimmer',
      'Einzelzimmer',
      'Superior Doppelzimmer',
      'Familienzimmer',
    ]),
    Lang.fr => r.pick(['Chambre double', 'Chambre twin', 'Suite junior']),
  };
  final lines = switch (lang) {
    Lang.en => <String>[
      r.pick([
        'Dear ${r.pick(['Mr', 'Ms', 'Dr'])} ${r.pick(lastNames)},',
        'Dear guest,',
      ]),
      r.pick([
        'we are delighted to confirm your reservation.',
        'thank you for choosing $name.',
        'it is our pleasure to confirm your stay.',
      ]),
      '${r.pick(['Arrival', 'Arrival date', 'Check-in'])}: ${date(r, day, lang)}',
      '${r.pick(['Departure', 'Departure date', 'Check-out'])}: ${date(r, out, lang)}',
      '$room, ${r.between(1, 3)} ${r.pick(['guests', 'adults', 'persons'])}',
      if (r.chance(0.5))
        r.pick(['Breakfast included', 'Room only', 'Half board']),
      if (r.chance(0.6))
        'Rate: ${money(r, price(r, 70, 400), r.pick(['EUR', 'GBP', 'USD']), lang)} per night',
      '${r.pick(['Reservation no.', 'Confirmation number', 'Booking number'])} $ref',
      if (r.chance(0.4))
        'Cancellations are free of charge until 48 hours before arrival.',
    ],
    Lang.de => <String>[
      'Sehr geehrte${r.chance(0.5) ? 'r Herr' : ' Frau'} ${r.pick(lastNames)},',
      r.pick([
        'wir freuen uns, Ihre Reservierung zu bestätigen:',
        'vielen Dank für Ihre Zimmerreservierung.',
        'herzlichen Dank für Ihre Buchung in unserem Haus.',
      ]),
      'Anreise ${date(r, day, lang)}',
      'Abreise ${date(r, out, lang)}',
      '$room, ${r.between(1, 3)} Personen${r.chance(0.5) ? ', inkl. Frühstück' : ''}',
      if (r.chance(0.6))
        'Zimmerpreis: ${money(r, price(r, 70, 400), 'EUR', lang)} pro Nacht',
      'Reservierungsnummer $ref',
      if (r.chance(0.4))
        'Eine kostenfreie Stornierung ist bis 48 Stunden vor Anreise möglich.',
    ],
    Lang.fr => <String>[
      'Madame, Monsieur,',
      'nous avons le plaisir de confirmer votre réservation.',
      'Arrivée : ${date(r, day, lang)}',
      'Départ : ${date(r, out, lang)}',
      '$room, ${r.between(1, 3)} personnes',
      'Numéro de confirmation : $ref',
    ],
  };
  return synth(
    MailClass.stay,
    Sender(name, 'reservations@$domain.example', lang: lang),
    subject,
    finish(r, lines),
  );
}

/// Tables booked in German with "du", and by the restaurant itself.
SynthMail restaurantDirect(Rng r) {
  final place = r.pick(restaurants);
  final domain = place.toLowerCase().replaceAll(RegExp('[^a-z]'), '');
  final de = r.chance(0.5);
  final day = someDay(r);
  final (h, m) = (r.between(12, 21), r.pick([0, 15, 30, 45]));
  final n = r.between(2, 10);
  final subject = de
      ? r.pick([
          'Deine Reservierung im $place',
          'Deine Tischreservierung ist bestätigt',
          'Reservierung für $n Personen',
          'Wir freuen uns auf deinen Besuch',
        ])
      : r.pick([
          'See you on ${date(r, day, Lang.en)}',
          'Your table at $place',
          'Booking confirmed at $place',
          'We look forward to welcoming you',
        ]);
  final lines = de
      ? <String>[
          'Hallo ${first(r)},',
          r.pick([
            'deine Tischreservierung ist bestätigt.',
            'danke für deine Reservierung.',
          ]),
          place,
          '${date(r, day, Lang.de)}, ${time(r, h, m, Lang.de)}',
          '$n Personen',
          if (r.chance(0.5)) 'Falls du nicht kommen kannst, sag bitte ab.',
        ]
      : <String>[
          'Hi ${first(r)},',
          r.pick([
            'we have reserved a table for you.',
            'thanks for booking a table with us.',
          ]),
          '${date(r, day, Lang.en)} at ${time(r, h, m, Lang.en)}',
          '$n guests',
          if (r.chance(0.5)) 'We hold tables for 15 minutes.',
        ];
  return synth(
    MailClass.restaurant,
    Sender(place, 'reservations@$domain.example', lang: de ? Lang.de : Lang.en),
    subject,
    finish(r, lines),
  );
}

const travelTemplates = <Template>[
  hotelDirect,
  restaurantDirect,
  airlineInline,
  airlineTable,
  awardBooking,
  airlineGerman,
  airlineFrench,
  lowCost,
  flightAgency,
  flightUpdate,
  ukRail,
  oebb,
  deutscheBahn,
  sncf,
  eurostar,
  coach,
  trainUpdate,
  stay,
  rental,
  event,
  attraction,
  restaurant,
  carHire,
];
