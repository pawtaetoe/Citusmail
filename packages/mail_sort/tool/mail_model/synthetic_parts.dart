// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Building blocks of the synthetic mail: dates, times, money, names,
/// places and the noise real mail carries, in English, German and
/// French. All made up.
library;

import 'rng.dart';

enum Lang { en, de, fr }

final class Sender {
  const Sender(this.name, this.address, {this.lang = Lang.en});

  final String name;
  final String address;
  final Lang lang;

  String get domain {
    final host = address.substring(address.indexOf('@') + 1);
    final parts = host.split('.');
    const twoPart = {'co.uk', 'com.sg', 'com.au', 'co.jp', 'co.at', 'com.br'};
    final last2 = parts.length >= 2
        ? parts.sublist(parts.length - 2).join('.')
        : host;
    if (twoPart.contains(last2) && parts.length >= 3) {
      return parts.sublist(parts.length - 3).join('.');
    }
    return last2;
  }
}

// ----------------------------------------------------------------- dates

const _monthsEn = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', //
  'August', 'September', 'October', 'November', 'December', //
];
const _monthsDe = [
  'Januar', 'Februar', 'März', 'April', 'Mai', 'Juni', 'Juli', //
  'August', 'September', 'Oktober', 'November', 'Dezember', //
];
const _monthsFr = [
  'janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', //
  'août', 'septembre', 'octobre', 'novembre', 'décembre', //
];
const _daysEn = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', //
  'Sunday', //
];
const _daysDe = [
  'Montag', 'Dienstag', 'Mittwoch', 'Donnerstag', 'Freitag', 'Samstag', //
  'Sonntag', //
];
const _daysFr = [
  'lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', //
  'dimanche', //
];

/// A day in the coming year or so.
DateTime someDay(Rng r) =>
    DateTime.utc(2026, 1, 1).add(Duration(days: r.below(540)));

String two(int n) => n.toString().padLeft(2, '0');

/// [d] written the way mail in [lang] writes dates, in one of several
/// styles.
String date(Rng r, DateTime d, Lang lang) {
  final wd = d.weekday - 1;
  final m = d.month - 1;
  switch (lang) {
    case Lang.en:
      return switch (r.below(8)) {
        0 => '${d.day} ${_monthsEn[m]} ${d.year}',
        1 =>
          '${_daysEn[wd].substring(0, 3)}, ${d.day} '
              '${_monthsEn[m].substring(0, 3)} ${d.year}',
        2 => '${_monthsEn[m]} ${d.day}, ${d.year}',
        3 => '${_daysEn[wd]} ${d.day} ${_monthsEn[m]}',
        4 => '${two(d.day)}/${two(d.month)}/${d.year}',
        5 => '${d.year}-${two(d.month)}-${two(d.day)}',
        6 =>
          '${_daysEn[wd].substring(0, 3)} ${d.day} '
              '${_monthsEn[m].substring(0, 3)}',
        _ => '${_monthsEn[m].substring(0, 3)} ${d.day}, ${d.year}',
      };
    case Lang.de:
      return switch (r.below(5)) {
        0 => '${two(d.day)}.${two(d.month)}.${d.year}',
        1 =>
          '${_daysDe[wd].substring(0, 2)}., ${two(d.day)}.${two(d.month)}.'
              '${d.year}',
        2 => '${d.day}. ${_monthsDe[m]} ${d.year}',
        3 => '${_daysDe[wd]}, ${d.day}. ${_monthsDe[m]}',
        _ => '${two(d.day)}.${two(d.month)}.${d.year % 100}',
      };
    case Lang.fr:
      return switch (r.below(4)) {
        0 => '${d.day} ${_monthsFr[m]} ${d.year}',
        1 => '${_daysFr[wd]} ${d.day} ${_monthsFr[m]} ${d.year}',
        2 => '${two(d.day)}/${two(d.month)}/${d.year}',
        _ =>
          '${_daysFr[wd].substring(0, 3)}. ${d.day} '
              '${_monthsFr[m].substring(0, 3)}.',
      };
  }
}

String time(Rng r, int h, int min, Lang lang) {
  switch (lang) {
    case Lang.en:
      if (r.chance(0.6)) return '${two(h)}:${two(min)}';
      final h12 = h % 12 == 0 ? 12 : h % 12;
      final ampm = h < 12 ? 'am' : 'pm';
      return r.chance(0.5)
          ? '$h12:${two(min)} ${ampm.toUpperCase()}'
          : '$h12:${two(min)}$ampm';
    case Lang.de:
      return r.chance(0.5)
          ? '${two(h)}:${two(min)} Uhr'
          : '${two(h)}:${two(min)}';
    case Lang.fr:
      return r.chance(0.5) ? '${two(h)}h${two(min)}' : '${two(h)}:${two(min)}';
  }
}

/// A random time of day, as hours and minutes.
(int, int) someTime(Rng r) =>
    (r.between(5, 22), r.pick([0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55]));

// ----------------------------------------------------------------- money

/// [amount] in [currency] as mail in [lang] writes it.
String money(Rng r, double amount, String currency, Lang lang) {
  final whole = amount.floor();
  final cents = ((amount - whole) * 100).round().clamp(0, 99);
  String grouped(String sep) {
    final s = whole.toString();
    final out = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) out.write(sep);
      out.write(s[i]);
    }
    return out.toString();
  }

  if (lang == Lang.en) {
    final n = '${grouped(',')}.${two(cents)}';
    final symbol = const {
      'GBP': '£',
      'EUR': '€',
      'USD': r'$',
      'SGD': r'S$',
      'AUD': r'A$',
    }[currency];
    if (symbol != null && r.chance(0.8)) return '$symbol$n';
    return '$currency $n';
  }
  final n = '${grouped('.')},${two(cents)}';
  final symbol = const {
    'EUR': '€',
    'GBP': '£',
    'CHF': 'CHF',
    'USD': r'$',
  }[currency];
  return r.chance(0.7) ? '$n ${symbol ?? currency}' : '$currency $n';
}

double price(Rng r, double lo, double hi) =>
    ((lo + r.unit() * (hi - lo)) * 100).roundToDouble() / 100;

// ------------------------------------------------------------ references

const _letters = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
const _digits = '0123456789';

String code(Rng r, int length, {bool letters = true, bool digits = true}) {
  final alphabet = '${letters ? _letters : ''}${digits ? _digits : ''}';
  return String.fromCharCodes([
    for (var i = 0; i < length; i++)
      alphabet.codeUnitAt(r.below(alphabet.length)),
  ]);
}

String digits(Rng r, int length) => code(r, length, letters: false);

/// An airline-style record locator: six letters and digits.
String pnr(Rng r) => r.chance(0.5) ? code(r, 6, digits: false) : code(r, 6);

// ----------------------------------------------------------------- people

const firstNames = [
  'Alex', 'Sam', 'Jordan', 'Mei', 'Priya', 'Lukas', 'Anna', 'Sophie', //
  'Thomas', 'Emma', 'Noah', 'Lea', 'Jonas', 'Chloé', 'Lucas', 'Hana', //
  'Rahul', 'Fatima', 'Oliver', 'Isabel', 'Marco', 'Elif', 'Daniel', //
  'Grace', 'Felix', 'Clara', 'Wei', 'Aisha', 'Tom', 'Ines', //
];
const lastNames = [
  'Tan', 'Smith', 'Müller', 'Martin', 'Lim', 'Schmidt', 'Dubois', //
  'Wong', 'Huber', 'Novak', 'Brown', 'Bernard', 'Gruber', 'Patel', //
  'Taylor', 'Wagner', 'Laurent', 'Chen', 'Fischer', 'Moreau', 'Kaur', //
];

String person(Rng r) => '${r.pick(firstNames)} ${r.pick(lastNames)}';
String first(Rng r) => r.pick(firstNames);

// ----------------------------------------------------------------- places

/// Airports: code, city, airport name.
const airports = [
  ('SIN', 'Singapore', 'Singapore Changi'),
  ('HND', 'Tokyo', 'Tokyo Haneda'),
  ('NRT', 'Tokyo', 'Tokyo Narita'),
  ('LHR', 'London', 'London Heathrow'),
  ('LGW', 'London', 'London Gatwick'),
  ('STN', 'London', 'London Stansted'),
  ('JFK', 'New York', 'New York JFK'),
  ('EWR', 'New York', 'Newark Liberty'),
  ('CDG', 'Paris', 'Paris Charles de Gaulle'),
  ('ORY', 'Paris', 'Paris Orly'),
  ('FRA', 'Frankfurt', 'Frankfurt am Main'),
  ('MUC', 'Munich', 'Munich'),
  ('VIE', 'Vienna', 'Vienna International'),
  ('ZRH', 'Zurich', 'Zurich'),
  ('AMS', 'Amsterdam', 'Amsterdam Schiphol'),
  ('DXB', 'Dubai', 'Dubai International'),
  ('SYD', 'Sydney', 'Sydney Kingsford Smith'),
  ('BKK', 'Bangkok', 'Bangkok Suvarnabhumi'),
  ('HKG', 'Hong Kong', 'Hong Kong International'),
  ('LAX', 'Los Angeles', 'Los Angeles International'),
  ('SFO', 'San Francisco', 'San Francisco International'),
  ('MAD', 'Madrid', 'Madrid Barajas'),
  ('BCN', 'Barcelona', 'Barcelona El Prat'),
  ('FCO', 'Rome', 'Rome Fiumicino'),
  ('LIS', 'Lisbon', 'Lisbon Humberto Delgado'),
  ('DUB', 'Dublin', 'Dublin'),
  ('EDI', 'Edinburgh', 'Edinburgh'),
  ('MAN', 'Manchester', 'Manchester'),
  ('CPH', 'Copenhagen', 'Copenhagen Kastrup'),
  ('KUL', 'Kuala Lumpur', 'Kuala Lumpur International'),
  ('ICN', 'Seoul', 'Seoul Incheon'),
  ('MEL', 'Melbourne', 'Melbourne Tullamarine'),
  ('DPS', 'Bali', 'Bali Ngurah Rai'),
  ('BER', 'Berlin', 'Berlin Brandenburg'),
  ('HAM', 'Hamburg', 'Hamburg'),
  ('GVA', 'Geneva', 'Geneva'),
  ('IST', 'Istanbul', 'Istanbul'),
  ('DOH', 'Doha', 'Doha Hamad'),
  ('ORD', 'Chicago', "Chicago O'Hare"),
  ('BOS', 'Boston', 'Boston Logan'),
  ('NCE', 'Nice', "Nice Côte d'Azur"),
  ('ATH', 'Athens', 'Athens'),
  ('PRG', 'Prague', 'Prague'),
  ('OSL', 'Oslo', 'Oslo Gardermoen'),
  ('KIX', 'Osaka', 'Osaka Kansai'),
  ('TPE', 'Taipei', 'Taipei Taoyuan'),
  ('GLA', 'Glasgow', 'Glasgow'),
];

/// Two different airports.
((String, String, String), (String, String, String)) route(Rng r) {
  final from = r.pick(airports);
  var to = r.pick(airports);
  while (to.$2 == from.$2) {
    to = r.pick(airports);
  }
  return (from, to);
}

const ukStations = [
  'London Euston', 'Manchester Piccadilly', 'Birmingham New Street', //
  'Glasgow Central', 'London Kings Cross', 'Edinburgh Waverley', 'York', //
  'Newcastle', 'Leeds', 'London Paddington', 'Bristol Temple Meads', //
  'Brighton', 'Liverpool Lime Street', 'Preston', 'Lancaster', //
  'Milton Keynes Central', 'Coventry', 'Durham', 'Peterborough', //
  'Oxford', 'Cardiff Central', 'Reading', 'Sheffield', 'Nottingham', //
];
const atStations = [
  'Wien Hbf', 'Salzburg Hbf', 'Innsbruck Hbf', 'Graz Hbf', 'Linz Hbf', //
  'Villach Hbf', 'Wien Meidling', 'Klagenfurt Hbf', 'St. Pölten Hbf', //
  'Bregenz', 'Wien Westbahnhof', 'Kitzbühel', //
];
const deStations = [
  'Berlin Hbf', 'München Hbf', 'Hamburg Hbf', 'Frankfurt(Main)Hbf', //
  'Köln Hbf', 'Stuttgart Hbf', 'Leipzig Hbf', 'Düsseldorf Hbf', //
  'Hannover Hbf', 'Nürnberg Hbf', 'Dresden Hbf', 'Bremen Hbf', //
  'Berlin Südkreuz', 'Mannheim Hbf', //
];
const frStations = [
  'Paris Gare de Lyon', 'Lyon Part-Dieu', 'Marseille Saint-Charles', //
  'Paris Montparnasse', 'Bordeaux Saint-Jean', 'Lille Europe', //
  'Nice Ville', 'Strasbourg', 'Paris Gare du Nord', 'Rennes', //
  'Nantes', 'Toulouse Matabiau', 'Avignon TGV', 'Montpellier Saint-Roch', //
];
const eurostarStations = [
  'London St Pancras International', 'Paris Gare du Nord', //
  'Brussels Midi', 'Amsterdam Centraal', 'Rotterdam Centraal', //
  'Lille Europe', //
];
const busStops = [
  'Berlin ZOB', 'Prague Florenc', 'Munich ZOB', 'Vienna Erdberg', //
  'London Victoria Coach Station', 'Amsterdam Sloterdijk', //
  'Paris Bercy Seine', 'Hamburg ZOB', 'Budapest Népliget', //
  'Manchester Shudehill', 'Birmingham Coach Station', //
];

/// Two different items.
(T, T) pair<T>(Rng r, List<T> items) {
  final from = r.pick(items);
  var to = r.pick(items);
  while (to == from) {
    to = r.pick(items);
  }
  return (from, to);
}

const cities = [
  'Lisbon', 'Paris', 'Vienna', 'Tokyo', 'Barcelona', 'Berlin', 'Rome', //
  'Prague', 'Edinburgh', 'Copenhagen', 'Kyoto', 'Bangkok', 'Sydney', //
  'New York', 'Amsterdam', 'Munich', 'Salzburg', 'Nice', 'Seville', //
  'Singapore', 'Hong Kong', 'Seoul', 'Porto', 'Florence', 'Zurich', //
];

const hotelWords = [
  'Grand Hotel', 'Hotel', 'Park Hotel', 'Residence', 'Suites', 'Inn', //
  'Boutique Hotel', 'Apartments', 'Hostel', 'Palace', 'Lodge', //
];
const hotelNames = [
  'Bellevue', 'Central', 'Riverside', 'Sacher', 'Royal', 'Astoria', //
  'Mirador', 'Alma', 'Lindenhof', 'Le Marais', 'Sakura', 'Harbour', //
  'Oak', 'Old Town', 'Belvedere', 'Corso', 'Aurora', 'Kranich', //
];

String hotel(Rng r, String city) => r.chance(0.5)
    ? '${r.pick(hotelWords)} ${r.pick(hotelNames)}'
    : '${r.pick(hotelNames)} ${r.pick(hotelWords)} $city';

const restaurants = [
  'Burnt Oak', 'La Petite Cuisine', 'Trattoria Sole', 'Sushi Kaze', //
  'The Green Fig', 'Brasserie Lumière', 'Gasthaus Linde', 'Casa Lola', //
  'Noodle Bar 21', 'The Copper Pot', 'Bistro Margaux', 'Ember & Ash', //
  'Le Comptoir', 'Wirtshaus zur Post', 'Osteria Nonna', 'Spice Route', //
];

const venues = [
  'O2 Arena', 'Royal Albert Hall', 'Wiener Stadthalle', 'Accor Arena', //
  'Olympiastadion', 'Barbican Centre', 'Konzerthaus', 'Wembley Stadium', //
  'Zénith Paris', 'Mercedes-Benz Arena', 'Sydney Opera House', //
  'Esplanade Concert Hall', 'Brixton Academy', 'Volksoper', //
];
const acts = [
  'The Midnight Owls', 'Clara Voss', 'Northern Lights Orchestra', //
  'Echo Valley', 'Les Étoiles', 'The Paper Kites Tribute', 'DJ Solaris', //
  'Hamlet', 'The Nutcracker', 'Comedy Night with Sam Ray', //
  'Arsenal v Chelsea', 'Rapid Wien v Sturm Graz', 'Swan Lake', //
  'Jazz at Dusk', 'The Lion King', 'Indie Fest 2026', //
];

const streets = [
  'High Street', 'Market Square', 'Station Road', 'Mariahilfer Straße', //
  'Rue de Rivoli', 'Church Lane', 'Kärntner Ring', 'Orchard Road', //
  'Baker Street', 'Hauptstraße', 'Avenue Foch', 'King Street', //
];

String address(Rng r) =>
    '${r.between(1, 220)} ${r.pick(streets)}, ${r.pick(cities)}';

// ------------------------------------------------------------------ noise

/// Lines that real mail carries around what matters.
const _transactionalFooters = [
  'This is an automated message. Please do not reply to this email.',
  'Questions? Visit our Help Centre or contact customer service.',
  'Privacy Policy | Terms and Conditions | Contact us',
  'You received this email because you made a purchase with us.',
  '© 2026 All rights reserved.',
  'Download our app for the fastest way to manage your booking.',
  'Follow us on Facebook, Instagram and X.',
  'Registered office: 1 Example Place, London. Registered in England.',
  'Bitte antworten Sie nicht auf diese E-Mail.',
  'Ceci est un message automatique, merci de ne pas y répondre.',
  'Datenschutz | Impressum | AGB',
  'Mentions légales | Confidentialité',
];

const _marketingFooters = [
  'Unsubscribe | Manage email preferences',
  'You are receiving this email because you signed up for our newsletter.',
  'View this email in your browser',
  "Don't want these emails? Unsubscribe here.",
  'Newsletter abbestellen | Im Browser ansehen',
  'Se désabonner | Voir la version en ligne',
  'Prices correct at time of sending. Subject to availability. T&Cs apply.',
  '*Terms and conditions apply. Offer ends Sunday.',
];

/// [lines] with what real mail adds: headers, footers, table bars, blank
/// lines, or only a preview of it.
String finish(Rng r, List<String> lines, {bool marketing = false}) {
  final out = <String>[];
  if (marketing ? r.chance(0.5) : r.chance(0.1)) {
    out.add(r.pick(['View in browser', 'View this email online', '[Logo]']));
  }
  final bars = r.chance(0.15);
  for (final line in lines) {
    if (line.isEmpty) {
      if (r.chance(0.7)) out.add('');
      continue;
    }
    out.add(
      bars && line.contains(': ') ? line.replaceFirst(': ', ' | ') : line,
    );
    if (r.chance(0.06)) out.add('');
  }
  final footers = marketing ? _marketingFooters : _transactionalFooters;
  for (var i = r.below(3); i > 0; i--) {
    out
      ..add('')
      ..add(r.pick(footers));
  }
  if (!marketing && r.chance(0.12)) {
    out
      ..add('')
      ..add(r.pick(_marketingFooters));
  }
  var text = out.join('\n');
  if (r.chance(0.1)) text = text.replaceAll('\n', ' ');
  if (r.chance(0.12)) {
    // Only the preview is on the device.
    final n = r.between(80, 260);
    if (text.length > n) text = text.substring(0, n);
  }
  return text;
}
