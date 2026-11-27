// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Hand-written, made-up emails that [MailModel] is evaluated on and
/// never trained on (the trainer reads only tool/mail_model/). Written
/// apart from the generator's templates, in other words and layouts, to
/// see what carries over: UK and Austrian rail tickets, airline tables
/// with the codes in their own cells, award bookings, and the hard
/// negatives around them. Nobody's real mail.
library;

import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';

/// One labelled email: what it truly is ([kind]; null: none of them).
final class Labelled {
  Labelled(
    this.kind,
    this.from,
    this.name,
    this.subject,
    this.text, {
    this.type,
    this.bulk = false,
    DateTime? at,
    String? company,
    this.reservations = const [],
    this.source = 'held-out',
  }) : at = at ?? DateTime.utc(2026, 10, 1 + (from.length * 7) % 27, 9),
       company = company ?? registrable(from);

  final MailKind? kind;

  /// For a booking, its type.
  final BookingType? type;
  final String from;
  final String name;
  final String subject;
  final String text;
  final bool bulk;
  final DateTime at;
  final String company;
  final List<ReservationInfo> reservations;

  /// Which set it is from.
  final String source;

  MailSample get sample => MailSample(
    address: from,
    domain: company,
    senderName: name.isEmpty ? null : name,
    subject: subject,
    text: text,
    bulk: bulk,
  );

  /// The registrable domain of [address], roughly.
  static String registrable(String address) {
    final parts = address.substring(address.indexOf('@') + 1).split('.');
    if (parts.length >= 3 &&
        const {
          'co',
          'com',
          'org',
          'gv',
          'ac',
          'gov',
        }.contains(parts[parts.length - 2])) {
      return parts.sublist(parts.length - 3).join('.');
    }
    return parts.sublist(parts.length - 2).join('.');
  }
}

const _s = MailKind.subscription;
const _d = MailKind.delivery;
const _b = MailKind.booking;
const _a = MailKind.account;
const _p = MailKind.appointment;

final heldOut = <Labelled>[
  // ------------------------------------------------------------- trains
  Labelled(
    _b,
    'tickets@avantiwestcoast.co.uk',
    'Avanti West Coast',
    'Your Avanti West Coast e-tickets',
    'Thanks for travelling with Avanti West Coast\n\n'
        'Your tickets are ready to download in the app or from the link '
        'below.\n\nBooking ref: 9QX4TR2M\n\nLondon Euston → Lancaster\n'
        'Fri 18 Dec 2026\n10:30 – 13:05\nAdvance Single, Standard\n'
        'Reserved seat: Coach U, Seat 31 (window)\n\n'
        'Amount: £48.90 (Visa debit)\n\nPlease have your ticket ready for '
        'inspection.',
    type: BookingType.train,
  ),
  Labelled(
    _b,
    'noreply@lner.co.uk',
    'LNER',
    'Booking confirmed - 14 February',
    'Hi Sam, thanks for booking with LNER.\n'
        'Ticket collection reference KT8Z4PWQ\n'
        'Out: York 07:12 to London Kings Cross 09:05, Sat 14 Feb 2027\n'
        'Back: London Kings Cross 18:30 to York 20:24, Sun 15 Feb 2027\n'
        'Off-Peak Return x 2 (Two Together Railcard)\nTotal £97.40',
    type: BookingType.train,
  ),
  Labelled(
    _b,
    'auto-confirm@info.thetrainline.com',
    'Trainline',
    'Your eTickets: Brighton to London Victoria',
    'Your eTickets are ready\nAdd them to your wallet before you travel.\n'
        'Brighton > London Victoria\nTuesday 3 November\nLeave 08:14\n'
        'Anytime Day Single\n1 adult\nTransaction ID 2604-1187-7731\n'
        'Price £29.80',
    type: BookingType.train,
  ),
  Labelled(
    _b,
    'tickets@oebb.at',
    'ÖBB',
    'Ihr Ticket für Ihre Reise von Wien Hbf nach Graz Hbf',
    'Danke, dass Sie mit den ÖBB reisen!\n\nTicket\nGültig am 05.12.2026\n'
        'Wien Hbf 09:28 → Graz Hbf 12:02\nRJX 553\n2. Klasse, 1 Person\n'
        'Sitzplatz: Wagen 27, Platz 45\nTicketnummer 7731 9902 1184\n'
        'Gesamtpreis EUR 19,90\n\nDas Ticket ist personalisiert. Bitte '
        'Lichtbildausweis mitführen.',
    type: BookingType.train,
  ),
  Labelled(
    _b,
    'ticketshop@oebb.at',
    'ÖBB',
    'Your ÖBB ticket: Salzburg Hbf – Zürich HB',
    'Thank you for your purchase.\nYour ticket\nTravel date: 22.01.2027\n'
        'Salzburg Hbf dep 06:12\nZürich HB arr 11:20\nRJX 160\n'
        'Sparschiene, 2nd class\nBooking code: 4K7XQ2\nTotal: EUR 49.90\n'
        'Show the ticket on your phone or printed.',
    type: BookingType.train,
  ),
  Labelled(
    _b,
    'noreply@oebb.at',
    'ÖBB Nightjet',
    'Buchungsbestätigung Nightjet Wien – Hamburg',
    'Ihre Buchung ist abgeschlossen.\nNJ 490\nAbfahrt Wien Hbf, '
        'Fr. 11.12.2026, 19:56 Uhr\nAnkunft Hamburg-Altona, Sa. 12.12.2026, '
        '09:52 Uhr\nLiegewagen, 4er-Abteil, Wagen 263, Platz 85\n'
        'Buchungsnummer 1203 4485 9921',
    type: BookingType.train,
  ),
  Labelled(
    _b,
    'noreply@bahn.de',
    'Deutsche Bahn',
    'Your ticket for your journey on 9 Jan',
    'Thank you for booking with Deutsche Bahn.\nOrder 7724 1190 3318\n'
        'Outward: Frankfurt(Main)Hbf 08:20 → Köln Hbf 09:24, ICE 514, '
        'platform 7\nSaver Fare, 2nd class, 1 adult, EUR 27.99\n'
        'Your ticket is valid only on the train shown.',
    type: BookingType.train,
  ),
  Labelled(
    _b,
    'confirmation@sncf.fr',
    'SNCF Connect',
    'Votre e-billet TGV INOUI Paris → Bordeaux',
    'Bon voyage !\nAller le sam. 6 févr. 2027\nParis Montparnasse 07h52\n'
        'Bordeaux Saint-Jean 10h01\nTGV INOUI 8411 - voiture 14 - place 62\n'
        'Référence de votre voyage : QZRTBK\nPrix total 54,00 €',
    type: BookingType.train,
  ),
  Labelled(
    _b,
    'tickets@eurostar.com',
    'Eurostar',
    'Booking confirmed - London to Brussels',
    'Booking reference HQPLZD\n\nLondon St Pancras Intl → Brussels-Midi\n'
        'Thu 3 Dec 2026, depart 08:16, arrive 11:20 local time\n'
        'Eurostar 9116, coach 12, seat 44, Eurostar Standard\n'
        'Please arrive at least 60 minutes before departure for security '
        'and passport checks.',
    type: BookingType.train,
  ),
  Labelled(
    _b,
    'buchung@flixbus.de',
    'FlixBus',
    'Deine Reise nach Prag ist gebucht',
    'Buchungsnummer 3031 9487 72\nMünchen ZOB → Praha ÚAN Florenc\n'
        'Mi., 25.11.2026 · 07:30 – 12:15\nLinie N840 · 1 Erwachsener\n'
        'Bezahlt: 19,99 €\nZeig einfach den QR-Code beim Einsteigen.',
    type: BookingType.train,
  ),
  // ------------------------------------------------------------ flights
  Labelled(
    _b,
    'booking@qatarairways.com',
    'Qatar Airways',
    'Booking Confirmed',
    'Booking Confirmed\nBooking reference\nR7KQ2D\n\nItinerary\n'
        'QR 017\nDOH\n08:05\nHamad International\n|\nLHR\n13:20\n'
        'London Heathrow\nTerminal 4\nSun, 06 Dec 2026\nEconomy Classic\n\n'
        'QR 016\nLHR\n15:40\n|\nDOH\n00:55 +1\nSun, 20 Dec 2026\n\n'
        'Passengers\nMS PRIYA KAUR\nE-ticket 157 2419983310',
    type: BookingType.flight,
  ),
  Labelled(
    _b,
    'krisflyer@singaporeair.com',
    'KrisFlyer',
    'Your award ticket - 70,000 miles + taxes',
    'Dear Mr Lim,\nYour KrisFlyer award booking has been ticketed.\n'
        'Saver award, Business\nMiles redeemed: 70,000\nTaxes and fees: '
        'SGD 112.40\nSIN–NRT SQ 638 Mon 12 Apr 2027 08:45 – 16:55\n'
        'Booking reference 6PQ9ZT',
    type: BookingType.flight,
  ),
  Labelled(
    _b,
    'online@booking-lufthansa.com',
    'Lufthansa',
    'Ihr Lufthansa Flug nach Wien',
    'Ihre Reiseübersicht\nBuchungscode: K2L9QW\n'
        'Frankfurt (FRA) → Wien (VIE)\nLH 1236 · Do., 07.01.2027\n'
        '13:05 – 14:25\nEconomy Light\nPassagier: Anna Huber',
    type: BookingType.flight,
  ),
  Labelled(
    _b,
    'noreply@jetblue.example',
    'Jet Blue Sky',
    'You are booked! Confirmation #XQMRTA',
    "Get ready to fly. Here's your itinerary.\n"
        'BOS > SFO\nFri, Jan 15\n7:00 AM - 10:41 AM\nNonstop\n'
        'Confirmation code XQMRTA. Total charged \$412.30 to Mastercard '
        'ending 0074.',
    type: BookingType.flight,
  ),
  Labelled(
    _b,
    'noreply@wizzair.com',
    'Wizz Air',
    'Your flight confirmation W6 1385',
    'Confirmation code: QL4NZ7\nVienna (VIE) - London Luton (LTN)\n'
        '14 Mar 2027, 06:20 - 07:55\nWIZZ Basic, 1 passenger\n'
        'Total EUR 39.99',
    type: BookingType.flight,
  ),
  Labelled(
    _b,
    'travel@expedia.com',
    'Expedia',
    'Your trip to Lisbon is booked',
    'Thanks for booking. Expedia itinerary 7311 0485 2271.\n'
        'Flight: Paris (CDG) to Lisbon (LIS), Air France AF 1024, Sat 20 Mar '
        '2027, departs 9:35am arrives 11:05am\nTraveler: Chloé Martin',
    type: BookingType.flight,
  ),
  // -------------------------------------------------------------- stays
  Labelled(
    _b,
    'reservations@lindner.example',
    'Lindner Hotels',
    'Lindner Hotel Am Belvedere has been booked',
    'Dear Mr Novak,\nwe are delighted to confirm your stay.\n'
        'Arrival: 03.12.2026\nDeparture: 06.12.2026\nSuperior Double Room, '
        'breakfast included\nRate: EUR 168.00 per night\n'
        'Reservation no. 88412093',
    type: BookingType.stay,
  ),
  Labelled(
    _b,
    'noreply@booking.com',
    'Booking.com',
    'Your booking at Casa do Rio has changed',
    'Your booking has been modified by the property.\n'
        'Casa do Rio, Porto\nNew check-in: Fri 9 Apr 2027\nCheck-out: '
        'Mon 12 Apr 2027\nBooking number 3388.120.447\nPIN 7731',
    type: BookingType.stay,
  ),
  Labelled(
    _b,
    'automated@airbnb.com',
    'Airbnb',
    'Your stay in Kyoto is confirmed',
    'Confirmation code HMQ4ZTP8KX\nMachiya with garden, hosted by Hana\n'
        'Arrive Tue, Mar 30 · 3:00 PM\nLeave Sat, Apr 3 · 11:00 AM\n'
        '2 guests · JPY 118,400 total',
    type: BookingType.stay,
  ),
  Labelled(
    _b,
    'reservation@hotel-sonne.example',
    'Hotel Sonne',
    'Reservierungsbestätigung',
    'Sehr geehrte Frau Wagner,\nwir freuen uns, Ihre Zimmerreservierung '
        'zu bestätigen:\nAnreise Freitag, 18. Dezember 2026\nAbreise '
        'Sonntag, 20. Dezember 2026\n1 Doppelzimmer, 2 Personen, inkl. '
        'Frühstück\nReservierungsnummer 44817',
    type: BookingType.stay,
  ),
  // ------------------------------------------- events, tables, cars
  Labelled(
    _b,
    'orders@eventbrite.com',
    'Eventbrite',
    'Your tickets for Winter Jazz Night',
    'Order #2219048831\nWinter Jazz Night\nSat, December 12, 2026 '
        '7:30 PM\nThe Jazz Cellar, 14 Frith Street\n2 x General Admission\n'
        'View tickets in the app.',
    type: BookingType.event,
  ),
  Labelled(
    _b,
    'boxoffice@nationaltheatre.example',
    'National Theatre',
    'Booking confirmation: The Seagull',
    'Thank you for booking.\nThe Seagull\nOlivier Theatre\nWed 20 Jan '
        '2027 at 19:30\nStalls, Row H, seats 12-13\nBooking ref 66718842\n'
        'Your e-tickets are attached.',
    type: BookingType.event,
  ),
  Labelled(
    _b,
    'member_services@opentable.com',
    'OpenTable',
    'Reservation confirmed at Trattoria Lucca',
    'You are all set.\nTrattoria Lucca\nFriday, November 27, 2026 at '
        '8:00 PM\n4 people\nConfirmation #118843\nNeed to make a change? '
        'Modify or cancel.',
    type: BookingType.restaurant,
  ),
  Labelled(
    _b,
    'reservierung@quandoo.at',
    'Quandoo',
    'Deine Reservierung im Figlmüller',
    'Hallo Lukas,\ndeine Tischreservierung ist bestätigt.\nFiglmüller '
        'Wollzeile\nSamstag, 5. Dezember 2026, 19:00 Uhr\n2 Personen',
    type: BookingType.restaurant,
  ),
  Labelled(
    _b,
    'reservations@europcar.com',
    'Europcar',
    'Reservation confirmed: 1144882910',
    'Thank you for choosing Europcar.\nPick up: Nice Airport T2, 02/04/2027 '
        '10:00\nReturn: Nice Airport T2, 09/04/2027 10:00\nPeugeot 208 or '
        'similar, manual\nEstimated total EUR 261.15',
    type: BookingType.car,
  ),
  // ------------------------------------------------------ subscriptions
  Labelled(
    _s,
    'billing@plusnet.example',
    'Plusnet',
    'Your Plusnet bill for November',
    'Hi Tom, your new bill is ready. Unlimited Fibre, monthly. Total to '
        'pay £27.99 by Direct Debit on 15 November. Account 7713-0022.',
  ),
  Labelled(
    _s,
    'kundenservice@drei.at',
    'Drei',
    'Ihre Rechnung Oktober 2026',
    'Ihre Rechnung steht online bereit. Tarif: Drei Unlimited. '
        'Rechnungsbetrag: 24,90 €. Abbuchung am 12.11.2026.',
  ),
  Labelled(
    _s,
    'no_reply@email.apple.com',
    'Apple',
    'Your subscription has been renewed',
    'Apple One Individual, monthly. Renewal price \$19.95. Your '
        'subscription renews on 4 December unless you cancel at least '
        '24 hours before.',
  ),
  Labelled(
    _s,
    'invoice+statements@stripe.com',
    'Fieldnotes',
    'Your receipt from Fieldnotes #1077-2201',
    'Receipt from Fieldnotes Ltd. Amount paid £6.00. Fieldnotes Team '
        '(monthly), 1 Nov – 1 Dec 2026. Paid with Amex 3005.',
  ),
  Labelled(
    _s,
    'payments-noreply@google.com',
    'Google One',
    'Google One: payment received',
    'Thanks! Your payment of SGD 2.98 for 100 GB of Google One storage '
        'went through. Next charge: 9 Dec 2026.',
  ),
  Labelled(
    _s,
    'service@ewe.example',
    'EWE',
    'Ihre Stromrechnung',
    'Ihre Abschlagsrechnung für Strom liegt vor. Monatlicher Abschlag '
        '84,00 EUR, fällig am 01.12.2026.',
  ),
  Labelled(
    _s,
    'membership@fitlab.example',
    'FitLab',
    'Your FitLab membership has renewed',
    'Your monthly membership renewed today. We charged €39.00 to your '
        'card. Freeze or cancel any time in the app.',
  ),
  // --------------------------------------------------------- deliveries
  Labelled(
    _d,
    'versandbestaetigung@amazon.de',
    'Amazon.de',
    'Versandt: „Wasserkocher Edelstahl“',
    'Dein Paket ist unterwegs! Lieferung voraussichtlich Donnerstag, 3. '
        'Dezember. Bestellnr. 302-7748812-1203345. Sendungsverfolgung bei '
        'DHL.',
  ),
  Labelled(
    _d,
    'noreply@dhl.de',
    'DHL Paket',
    'Ihr DHL Paket kommt heute',
    'Ihre Sendung 00340434161094015820 wird heute zwischen 10:30 und '
        '13:30 Uhr zugestellt.',
  ),
  Labelled(
    _d,
    'no-reply@royalmail.com',
    'Royal Mail',
    "We've got your parcel ready for collection",
    'Sorry we missed you. Your item QF123456785GB is waiting at your '
        'local Delivery Office. Bring ID to collect it.',
  ),
  Labelled(
    _d,
    'auto-reply@usps.example',
    'USPS',
    'USPS Expected Delivery on Saturday',
    'Your item is out for delivery. Tracking 9400 1000 0000 0000 0000 '
        '00. Expected by 8:00 pm.',
  ),
  Labelled(
    _d,
    'orders@etsy.example',
    'Etsy',
    'Your Etsy order has shipped',
    'Good news! Your order #2801175 from WoolAndWillow is on its way. '
        'Tracking: Evri H01HYA0012345678. Estimated arrival Nov 30.',
  ),
  // ------------------------------------------------------ appointments
  Labelled(
    _p,
    'reception@kensingtondental.example',
    'Kensington Dental',
    'Appointment confirmed for Tue 8 Dec',
    'Dear Grace, your hygienist appointment with Sarah is confirmed for '
        'Tuesday 8 December at 2:40pm at 12 Church Street. Please let us '
        'know 48 hours ahead if you cannot make it.',
  ),
  Labelled(
    _p,
    'no-reply@doctolib.de',
    'Doctolib',
    'Ihr Termin bei Dr. med. Weber',
    'Terminbestätigung: Montag, 30.11.2026 um 08:45 Uhr, Hausarztpraxis '
        'Dr. Weber, Lindenstraße 4, Berlin. Bitte bringen Sie Ihre '
        'Versichertenkarte mit.',
  ),
  Labelled(
    _p,
    'bookings@halfords.example',
    'Halfords Autocentre',
    'Your MOT is booked',
    'Your MOT test is booked for Fri 4 Dec at 9:00am at Halfords '
        'Autocentre Leeds. Vehicle: AB12 CDE.',
  ),
  Labelled(
    _p,
    'no-reply@fresha.com',
    'Fresha',
    'Booking confirmed with Studio Nine',
    'Your appointment is confirmed. Wash, cut & style with Leo, Sat 12 Dec '
        'at 11:00. Studio Nine, 3 Mill Lane. Cancel up to 24h before for '
        'free.',
  ),
  // ---------------------------------------------------------- accounts
  Labelled(
    _a,
    'hello@notion.example',
    'Notion',
    'Welcome to Notion, Felix',
    'Thanks for signing up. Please confirm your email address to finish '
        'creating your account.',
  ),
  Labelled(
    _a,
    'no-reply@accounts.example.com',
    'Example ID',
    'Your sign-in code',
    'Use 482 913 to sign in to Example ID. The code expires in 15 '
        'minutes. If you did not try to sign in, you can ignore this email.',
  ),
  Labelled(
    _a,
    'security@paypal.example',
    'PayPal',
    'New login to your account',
    'We noticed a login to your account from a new device: Firefox on '
        'Windows, Vienna, Austria. If this was you, no action is needed.',
  ),
  Labelled(
    _a,
    'noreply@zalando.de',
    'Zalando',
    'Passwort zurücksetzen',
    'Du hast ein neues Passwort angefordert. Klicke auf den Link, um es '
        'zurückzusetzen. Der Link ist 24 Stunden gültig.',
  ),
  // ------------------------------------- hard negatives (none of them)
  Labelled(
    null,
    'news@info.thetrainline.com',
    'Trainline',
    'Save 30% on trains with a Railcard',
    'Travelling more this winter? Save a third on off-peak fares with a '
        'Railcard. London to Manchester from £14.50. Book by 30 Nov. '
        'Unsubscribe | Preferences',
    bulk: true,
  ),
  Labelled(
    null,
    'deals@flightdeals.example',
    'Fare Alerts',
    'SIN → LHR from S\$899 return',
    'Fares just dropped!\nSIN\n→\nLHR\nDepart 12 Jan, return 26 Jan\n'
        'S\$899 return on Singapore Airlines\nBook now before they are gone. '
        'Manage alerts.',
    bulk: true,
  ),
  Labelled(
    null,
    'newsletter@oebb.at',
    'ÖBB',
    'Nightjet: Neue Verbindungen ab Dezember',
    'Ab dem Fahrplanwechsel fährt der Nightjet täglich von Wien nach '
        'Paris. Jetzt Tickets ab 39,90 € sichern! Newsletter abbestellen.',
    bulk: true,
  ),
  Labelled(
    null,
    'promo@hotelchain.example',
    'Stay Rewards',
    'Up to 40% off weekend stays',
    'Escape for the weekend. Members save up to 40% at over 300 hotels. '
        'Stay by 28 Feb 2027. Terms apply.',
    bulk: true,
  ),
  Labelled(
    null,
    'no-reply@notifications.service.gov.uk',
    'UK Visas and Immigration',
    'Your electronic travel authorisation (ETA) application',
    'Your application for an ETA to travel to the UK has been granted. '
        'Reference 4410-2281-9937-1120. You can travel to the UK as many '
        'times as you like for 2 years.',
  ),
  Labelled(
    null,
    'esta@cbp.example',
    'ESTA',
    'ESTA application status: Authorization Approved',
    'Application number Y4L8K21Q0Z. Your travel authorization has been '
        'approved and is valid until 03 Oct 2028. This does not guarantee '
        'admission to the United States.',
  ),
  Labelled(
    null,
    'executiveclub@email.ba.com',
    'British Airways Executive Club',
    'Your Avios statement',
    'Your Avios balance: 48,210. Tier points: 260. Avios expire if your '
        'account is inactive for 36 months.',
  ),
  Labelled(
    null,
    'seasons@southernrailway.example',
    'Southern',
    'Your season ticket expires in 7 days',
    'Your annual season ticket Brighton – London Terminals expires on 2 '
        'December. Renew online now so you can keep travelling.',
  ),
  Labelled(
    null,
    'service@erstebank.at',
    'Erste Bank',
    'Ihr Kontoauszug ist da',
    'Der Kontoauszug für Oktober steht in George für Sie bereit.',
  ),
  Labelled(
    null,
    'reviews@booking.com',
    'Booking.com',
    'How was Hotel Sacher Wien?',
    'Thanks for staying at Hotel Sacher Wien. Rate your stay and help '
        'other travellers.',
  ),
  Labelled(
    null,
    'noreply@uber.com',
    'Uber',
    'Your Thursday evening trip with Uber',
    'Thanks for riding, Daniel. Total €18.40. Pick-up 21:14 Hauptbahnhof, '
        'drop-off 21:36 Neubaugasse.',
  ),
  Labelled(
    null,
    'marco.rossi@gmail.com',
    'Marco Rossi',
    'Train to Salzburg on Saturday?',
    'Hey, there is a railjet at 9:30 from Wien Hbf, gets in at 11:52. '
        'Should I book two tickets? Sparschiene is 19.90 each.',
  ),
  Labelled(
    null,
    'notifications@github.com',
    'Wei Chen',
    '[acme/rail] Ticket PDF shows wrong platform (#88)',
    'The e-ticket PDF shows platform 7 instead of 9 for ICE trains. '
        'Reply to this email directly or view it on GitHub.',
    bulk: true,
  ),
  Labelled(
    null,
    'policy@insurer.example',
    'Safe Travels Insurance',
    'Your travel insurance documents',
    'Your annual multi-trip policy is now active. Policy number 1188-2203. '
        'Keep this email with you when you travel.',
  ),
  Labelled(
    null,
    'news@lonelyplanet.example',
    'Lonely Planet',
    'The best Christmas markets in Europe',
    'From Vienna to Strasbourg, our editors pick the markets worth the '
        'trip, and how to get there by train. Read more. Unsubscribe.',
    bulk: true,
  ),
  Labelled(
    null,
    'no-reply@grab.com',
    'GrabFood',
    'Your GrabFood order is on its way',
    'Your driver has picked up your order from Nasi Lemak Corner. '
        'Estimated arrival 7:45 PM. Total S\$24.80.',
  ),
  Labelled(
    null,
    'deals@expedia.com',
    'Expedia',
    'Still thinking about Paris?',
    'Hotels in Paris from €89 a night. Prices for your dates may go up. '
        'Complete your booking today.',
    bulk: true,
  ),
  Labelled(
    null,
    'alerts@monzo.example',
    'Monzo',
    'You spent £48.90 at Avanti West Coast',
    'Card payment of £48.90 to AVANTI WEST COAST. Your balance is '
        '£1,203.17.',
  ),
  Labelled(
    null,
    'calendar-notification@google.com',
    'Google Calendar',
    'Invitation: Travel policy review @ Wed 2 Dec 2026 10am',
    'Agenda: booking rules for trains and flights, hotel limits, invoices. '
        'Join with Google Meet.',
  ),
  Labelled(
    null,
    'news@uniqlo.example',
    'UNIQLO',
    'Black Friday: 30% off HEATTECH',
    'This weekend only. Free delivery over £50. Shop now. Unsubscribe.',
    bulk: true,
  ),
];
