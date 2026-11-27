// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Synthetic mail that is not a booking: receipts and bills, deliveries,
/// appointments, account mail, and the hard negatives (promotions,
/// newsletters, visas, statements, season-ticket renewals, mail from
/// people). All made up.
library;

import 'package:mail_sort/mail_sort.dart';

import 'rng.dart';
import 'synthetic_mail.dart';
import 'synthetic_parts.dart';

String _month(Rng r, Lang lang) {
  final d = someDay(r);
  return switch (lang) {
    Lang.en => const [
      'January', 'February', 'March', 'April', 'May', 'June', 'July', //
      'August', 'September', 'October', 'November', 'December', //
    ][d.month - 1],
    Lang.de => const [
      'Januar', 'Februar', 'März', 'April', 'Mai', 'Juni', 'Juli', //
      'August', 'September', 'Oktober', 'November', 'Dezember', //
    ][d.month - 1],
    Lang.fr => const [
      'janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', //
      'août', 'septembre', 'octobre', 'novembre', 'décembre', //
    ][d.month - 1],
  };
}

// --------------------------------------------------------- subscriptions

/// ISP, telco and utility e-bills.
SynthMail eBill(Rng r) {
  final senders = [
    ('BT', 'billing@bt.com', Lang.en, 'GBP', 'Broadband'),
    ('Vodafone', 'ebill@vodafone.co.uk', Lang.en, 'GBP', 'Mobile'),
    (
      'Virgin Media',
      'billing@virginmedia.co.uk',
      Lang.en,
      'GBP',
      'Broadband & TV',
    ),
    ('Telekom', 'rechnung@telekom.de', Lang.de, 'EUR', 'MagentaZuhause'),
    ('A1', 'rechnung@a1.at', Lang.de, 'EUR', 'Internet'),
    ('Magenta', 'service@magenta.at', Lang.de, 'EUR', 'Mobilfunk'),
    ('Orange', 'facture@orange.fr', Lang.fr, 'EUR', 'Livebox'),
    ('Free', 'facture@free.fr', Lang.fr, 'EUR', 'Freebox'),
    ('Singtel', 'ebill@singtel.com', Lang.en, 'SGD', 'Fibre'),
    (
      'MyRepublic',
      'billing@myrepublic.com.sg',
      Lang.en,
      'SGD',
      'Fibre broadband',
    ),
    ('Octopus Energy', 'hello@octopus.energy', Lang.en, 'GBP', 'Electricity'),
    ('Wien Energie', 'rechnung@wienenergie.at', Lang.de, 'EUR', 'Strom'),
    ('Xfinity', 'billing@xfinity.com', Lang.en, 'USD', 'Internet'),
  ];
  final (name, from, lang, cur, plan) = r.pick(senders);
  final month = _month(r, lang);
  final amount = money(r, price(r, 15, 140), cur, lang);
  final due = date(r, someDay(r), lang);
  final account = digits(r, r.between(8, 12));
  final subject = switch (lang) {
    Lang.en => r.pick([
      'Your $name bill is ready',
      'Your $month bill',
      'Your $name e-bill for $month',
      'Your latest bill from $name',
      'Your statement is ready to view',
      'Your monthly bill: $amount',
    ]),
    Lang.de => r.pick([
      'Ihre Rechnung für $month',
      'Ihre $name Rechnung ist da',
      'Neue Rechnung verfügbar',
    ]),
    Lang.fr => r.pick([
      'Votre facture $name est disponible',
      'Votre facture de $month',
      'Nouvelle facture disponible',
    ]),
  };
  final lines = switch (lang) {
    Lang.en => <String>[
      r.pick(['Hi ${first(r)},', 'Dear customer,']),
      r.pick([
        'Your bill is ready.',
        'Your latest bill is now available online.',
        'Here is your monthly bill.',
      ]),
      'Account number: $account',
      '$plan monthly plan',
      'Amount due: $amount',
      r.pick([
        'Due date: $due',
        'We will collect this by Direct Debit on or after $due.',
        'Pay by $due.',
      ]),
      if (r.chance(0.4)) 'Your plan renews automatically each month.',
    ],
    Lang.de => <String>[
      'Guten Tag ${person(r)},',
      'Ihre aktuelle Rechnung steht für Sie bereit.',
      'Kundennummer: $account',
      'Tarif: $plan',
      'Rechnungsbetrag: $amount',
      'Der Betrag wird am $due von Ihrem Konto abgebucht.',
    ],
    Lang.fr => <String>[
      'Bonjour,',
      'Votre facture est disponible dans votre espace client.',
      'Numéro client : $account',
      'Offre : $plan',
      'Montant : $amount',
      'Prélèvement le $due.',
    ],
  };
  return synth(
    MailClass.subscription,
    Sender(name, from, lang: lang),
    subject,
    finish(r, lines),
  );
}

/// App store and Stripe receipts for subscriptions.
SynthMail subscriptionReceipt(Rng r) {
  final products = [
    'Notewise Pro', 'Kitepad Plus', 'CloudBox 2 TB', 'Streamly Premium', //
    'iCloud+ 200 GB', 'YouTube Premium', 'Duolingo Super', 'Headspace', //
    'Claude Pro', 'Spotify Premium', 'Microsoft 365 Personal', '1Password', //
  ];
  final product = r.pick(products);
  final senders = [
    ('Apple', 'no_reply@email.apple.com'),
    ('Google Play', 'googleplay-noreply@google.com'),
    (product.split(' ').first, 'invoice+statements@stripe.com'),
    (product.split(' ').first, 'receipts@paddle.com'),
    (
      product.split(' ').first,
      'billing@${product.split(' ').first.toLowerCase()}.example',
    ),
  ];
  final (name, from) = r.pick(senders);
  final cur = r.pick(['USD', 'GBP', 'EUR', 'SGD', 'AUD']);
  final amount = money(r, price(r, 2.99, 30), cur, Lang.en);
  final period = r.pick(['monthly', 'yearly', '1 month', 'annual']);
  final next = date(r, someDay(r), Lang.en);
  final subject = r.pick([
    'Your receipt from $name',
    'Your receipt from $name #${digits(r, 4)}-${digits(r, 4)}',
    'Your $name subscription has renewed',
    'Receipt for your $product subscription',
    'Your Google Play Order Receipt from ${date(r, someDay(r), Lang.en)}',
    'Payment received - $product',
    'Your subscription to $product',
    'Thanks for your payment',
  ]);
  final lines = <String>[
    r.pick([
      'Receipt from $name',
      'Thanks for your purchase.',
      'Your payment was successful.',
    ]),
    'Amount paid: $amount',
    'Date paid: ${date(r, someDay(r), Lang.en)}',
    '$product ($period)',
    r.pick([
      'Renews $next',
      'Next billing date: $next',
      'Your subscription renews automatically unless cancelled.',
      'You can manage or cancel your subscription in Settings.',
    ]),
    'Payment method: ${r.pick(['Visa', 'Mastercard', 'Amex', 'PayPal'])} ${r.chance(0.6) ? '•••• ${digits(r, 4)}' : ''}',
    if (r.chance(0.4)) 'Order ID: ${code(r, 10)}',
    if (r.chance(0.4)) 'Invoice number: ${code(r, 4)}-${digits(r, 4)}',
  ];
  return synth(
    MailClass.subscription,
    Sender(name, from),
    subject,
    finish(r, lines),
  );
}

/// Renewal notices: domains, memberships, insurance, software.
SynthMail renewalNotice(Rng r) {
  final senders = [
    (
      'Porkbun',
      'support@porkbun.com',
      'Domain renewal: ${r.pick(['example-family.net', 'mysite.dev', 'tanlab.io'])}',
    ),
    ('Namecheap', 'support@namecheap.com', 'Domain auto-renewal'),
    ('PureGym', 'membership@puregym.com', 'Gym membership'),
    ('The Economist', 'subscriptions@economist.com', 'Digital subscription'),
    ('NordVPN', 'billing@nordvpn.com', 'VPN plan'),
    ('Adobe', 'mail@mail.adobe.com', 'Creative Cloud Photography plan'),
    ('Der Standard', 'abo@derstandard.at', 'Digital-Abo'),
  ];
  final (name, from, what) = r.pick(senders);
  final when = date(r, someDay(r), Lang.en);
  final amount = money(
    r,
    price(r, 9, 240),
    r.pick(['USD', 'GBP', 'EUR']),
    Lang.en,
  );
  final subject = r.pick([
    'Your subscription will renew on $when',
    'Upcoming renewal: $what',
    '$name | Order Confirmation',
    'Your membership has been renewed',
    'Renewal reminder',
    'Your plan renews soon',
  ]);
  final lines = <String>[
    r.pick(['Thank you for your order!', 'Just a reminder,', 'Hello,']),
    what,
    r.pick([
      'Your plan will automatically renew on $when for $amount.',
      'We charged $amount to your card. Auto-renew is ON.',
      'Your subscription renews yearly. Next payment $when.',
    ]),
    if (r.chance(0.5)) 'Manage auto-renew in your account settings.',
  ];
  return synth(
    MailClass.subscription,
    Sender(name, from),
    subject,
    finish(r, lines),
  );
}

/// Streaming and membership payments.
SynthMail membershipPayment(Rng r) {
  final senders = [
    ('Netflix', 'info@account.netflix.com'),
    ('Disney+', 'disneyplus@mail.disneyplus.com'),
    ('Spotify', 'no-reply@spotify.com'),
    ('Amazon Prime', 'prime@amazon.co.uk'),
    ('Patreon', 'no-reply@patreon.com'),
    ('Deezer', 'noreply@deezer.com'),
  ];
  final (name, from) = r.pick(senders);
  final amount = money(
    r,
    price(r, 4.99, 22),
    r.pick(['GBP', 'EUR', 'USD', 'SGD']),
    Lang.en,
  );
  final subject = r.pick([
    'Your $name membership payment',
    'Your payment was successful',
    'Thanks for your payment of $amount',
    'Your $name receipt',
    'We received your payment',
  ]);
  final lines = <String>[
    'Thanks for your payment of $amount for your ${r.pick(['Standard', 'Premium', 'Basic with ads', 'Family', 'Individual'])} plan.',
    'Your membership renews on ${date(r, someDay(r), Lang.en)}.',
    if (r.chance(0.5)) 'View billing details',
    if (r.chance(0.4)) 'Billed monthly. Cancel anytime.',
  ];
  return synth(
    MailClass.subscription,
    Sender(name, from),
    subject,
    finish(r, lines),
  );
}

// ------------------------------------------------------------ deliveries

SynthMail delivery(Rng r) {
  final senders = [
    ('Amazon', 'shipment-tracking@amazon.co.uk', Lang.en),
    ('Amazon.de', 'versandbestaetigung@amazon.de', Lang.de),
    ('DHL', 'noreply@dhl.de', Lang.de),
    ('DHL Express', 'noreply@dhl.com', Lang.en),
    ('UPS', 'mcinfo@ups.com', Lang.en),
    ('FedEx', 'trackingupdates@fedex.com', Lang.en),
    ('Royal Mail', 'no-reply@royalmail.com', Lang.en),
    ('Evri', 'noreply@evri.com', Lang.en),
    ('DPD', 'noreply@dpd.co.uk', Lang.en),
    ('Österreichische Post', 'noreply@post.at', Lang.de),
    ('Colissimo', 'noreply@colissimo.fr', Lang.fr),
    ('Shopee', 'info@mail.shopee.sg', Lang.en),
    ('Zalando', 'service@zalando.de', Lang.de),
    ('IKEA', 'noreply@ikea.com', Lang.en),
  ];
  final (name, from, lang) = r.pick(senders);
  final tracking = r.pick([
    '1Z${code(r, 16)}',
    '${code(r, 2, digits: false)}${digits(r, 9)}${r.pick(['GB', 'DE', 'AT', 'FR'])}',
    digits(r, r.between(12, 20)),
    'H${digits(r, 15)}',
  ]);
  final order = r.chance(0.5)
      ? '${digits(r, 3)}-${digits(r, 7)}-${digits(r, 7)}'
      : digits(r, 10);
  final item = r.pick([
    'USB-C Hub',
    'Running shoes',
    'Coffee grinder',
    'Paperback book',
    'Desk lamp',
    'Phone case',
    'Winter jacket',
  ]);
  final stage = r.below(5);
  final when = date(r, someDay(r), lang);
  final subject = switch (lang) {
    Lang.de => const [
      'Ihre Sendung ist unterwegs',
      'Ihr Paket kommt heute',
      'Ihre Bestellung wurde versandt',
      'Ihr Paket wurde zugestellt',
      'Ihre Sendung liegt zur Abholung bereit',
    ][stage],
    Lang.fr => const [
      'Votre colis est en route',
      'Votre colis sera livré aujourd\'hui',
      'Votre commande a été expédiée',
      'Votre colis a été livré',
      'Votre colis est disponible en point retrait',
    ][stage],
    Lang.en => [
      r.pick([
        'Your parcel is on its way',
        'Your order has shipped',
        'Shipped: "$item"',
        'Your $name order has been dispatched',
      ]),
      r.pick([
        'Your parcel is out for delivery',
        'Arriving today: $item',
        'Out for delivery',
      ]),
      r.pick([
        'Your package is in transit',
        'Your delivery is scheduled for $when',
        'Your parcel is arriving soon',
      ]),
      r.pick([
        'Delivered: your package',
        'Your parcel has been delivered',
        'Delivered: $item',
      ]),
      r.pick([
        'Your item is ready for collection',
        'We missed you',
        'Your parcel is waiting at the Post Office',
      ]),
    ][stage],
  };
  final lines = switch (lang) {
    Lang.de => <String>[
      'Hallo ${first(r)},',
      'Sendungsnummer: $tracking',
      if (r.chance(0.5)) 'Bestellnummer: $order',
      'Voraussichtliche Zustellung: $when',
      if (r.chance(0.5)) 'Artikel: $item',
      'Sendung verfolgen',
    ],
    Lang.fr => <String>[
      'Bonjour,',
      'Numéro de suivi : $tracking',
      'Livraison prévue le $when',
      'Suivre mon colis',
    ],
    Lang.en => <String>[
      r.pick(['Hi ${first(r)},', 'Good news!', 'Hello,']),
      r.pick([
        'Your package is on the way.',
        'Your parcel has been handed to the courier.',
        'Your order is on its way to you.',
        'Your parcel was delivered.',
      ]),
      if (r.chance(0.6)) 'Order #$order',
      '${r.pick(['Tracking number', 'Tracking ID', 'Parcel number'])}: $tracking',
      r.pick([
        'Estimated delivery: $when',
        'Arriving $when',
        'Delivered $when, handed to resident',
        'Expected $when between 9am and 1pm',
      ]),
      if (r.chance(0.5))
        'Carrier: ${r.pick(['Royal Mail', 'DPD', 'Evri', 'UPS', 'DHL', 'Ninja Van'])}',
      if (r.chance(0.4)) item,
      'Track your parcel',
    ],
  };
  return synth(
    MailClass.delivery,
    Sender(name, from, lang: lang),
    subject,
    finish(r, lines),
  );
}

// ---------------------------------------------------------- appointments

SynthMail appointment(Rng r) {
  final services = [
    (
      'Bright Smile Dental',
      'reception@brightsmile.co.uk',
      'Check-up and clean',
      Lang.en,
    ),
    (
      'Zahnarztpraxis Dr. Huber',
      'praxis@zahnarzt-huber.at',
      'Kontrolle',
      Lang.de,
    ),
    (
      'Cabinet Dentaire Moreau',
      'rdv@dentiste-moreau.fr',
      'Détartrage',
      Lang.fr,
    ),
    ('MoveWell Physio', 'appointments@movewell.com', 'Physio session', Lang.en),
    ('Snip Studio', 'hello@snipstudio.com', 'Cut and blow dry', Lang.en),
    ('Fresha', 'no-reply@fresha.com', 'Haircut with Mel', Lang.en),
    ('Treatwell', 'noreply@treatwell.co.uk', 'Gel manicure', Lang.en),
    (
      'Doctolib',
      'no-reply@doctolib.fr',
      'Consultation médecine générale',
      Lang.fr,
    ),
    ('Doctolib', 'no-reply@doctolib.de', 'Hausarzt-Termin', Lang.de),
    (
      'Riverside Surgery',
      'noreply@riversidesurgery.nhs.uk',
      'GP appointment',
      Lang.en,
    ),
    ('Kwik Fit', 'bookings@kwik-fit.com', 'MOT and service', Lang.en),
    ('Happy Paws Vet', 'reception@happypawsvet.com', 'Vaccination', Lang.en),
    ('Apple Store', 'genius@apple.com', 'Genius Bar appointment', Lang.en),
    ('Optiker Fischer', 'termine@optik-fischer.de', 'Sehtest', Lang.de),
  ];
  final (name, from, what, lang) = r.pick(services);
  final day = someDay(r);
  final (h, m) = (r.between(8, 18), r.pick([0, 15, 30, 45]));
  final when =
      '${date(r, day, lang)} ${lang == Lang.fr
          ? 'à'
          : lang == Lang.de
          ? 'um'
          : 'at'} ${time(r, h, m, lang)}';
  final reminder = r.chance(0.3);
  final subject = switch (lang) {
    Lang.de =>
      reminder
          ? 'Erinnerung an Ihren Termin am ${date(r, day, lang)}'
          : r.pick([
              'Terminbestätigung',
              'Ihr Termin bei $name',
              'Bestätigung Ihres Termins: $what',
            ]),
    Lang.fr =>
      reminder
          ? 'Rappel : votre rendez-vous du ${date(r, day, lang)}'
          : r.pick([
              'Confirmation de votre rendez-vous',
              'Votre rendez-vous chez $name est confirmé',
            ]),
    Lang.en =>
      reminder
          ? r.pick([
              'Reminder: your appointment tomorrow',
              'Appointment reminder - $name',
              'See you soon: $what',
            ])
          : r.pick([
              'Booking confirmed: $what on ${date(r, day, lang)}',
              'Your appointment is confirmed',
              'Appointment confirmation - $name',
              'Your $what appointment',
              'Your booking at $name',
            ]),
  };
  final lines = switch (lang) {
    Lang.de => <String>[
      'Guten Tag ${person(r)},',
      'hiermit bestätigen wir Ihren Termin.',
      what,
      when,
      name,
      address(r),
      'Bitte sagen Sie den Termin mindestens 24 Stunden vorher ab, falls Sie verhindert sind.',
    ],
    Lang.fr => <String>[
      'Bonjour,',
      'Votre rendez-vous est confirmé.',
      what,
      when,
      name,
      address(r),
      'En cas d\'empêchement, merci d\'annuler au moins 24h avant.',
    ],
    Lang.en => <String>[
      r.pick(['Hi ${first(r)},', 'Dear ${person(r)},']),
      r.pick([
        'Your appointment is confirmed.',
        'Your booking is confirmed.',
        'This is a reminder of your upcoming appointment.',
      ]),
      what,
      when,
      if (r.chance(0.5))
        'With ${r.pick(['Dr ${r.pick(lastNames)}', first(r), 'your stylist', 'our technician'])}',
      if (r.chance(0.6)) address(r),
      if (r.chance(0.4)) 'Booking reference: BK-${digits(r, 4)}',
      r.pick([
        'Need to reschedule? Reply or call us.',
        'Please arrive 10 minutes early.',
        'To cancel or change, use the link below at least 24 hours before.',
      ]),
    ],
  };
  return synth(
    MailClass.appointment,
    Sender(name, from, lang: lang),
    subject,
    finish(r, lines),
  );
}

// --------------------------------------------------------------- accounts

SynthMail accountMail(Rng r) {
  final services = [
    ('Google', 'no-reply@accounts.google.com'),
    (
      'Microsoft account team',
      'account-security-noreply@accountprotection.microsoft.com',
    ),
    ('Dropbox', 'no-reply@dropbox.com'),
    ('Slack', 'feedback@slack.com'),
    ('Strava', 'no-reply@strava.com'),
    ('Kitepad', 'hello@kitepad.io'),
    ('Instagram', 'security@mail.instagram.com'),
    ('Booking.com', 'noreply@booking.com'),
    ('Trainline', 'service@info.thetrainline.com'),
    ('ÖBB', 'noreply@oebb.at'),
    ('Some Service', 'do-not-reply@service.example'),
  ];
  final (name, from) = r.pick(services);
  final lang = r.chance(0.15)
      ? Lang.de
      : r.chance(0.1)
      ? Lang.fr
      : Lang.en;
  final kind = r.below(6);
  final codeValue = digits(r, 6);
  final (subject, lines) = switch ((lang, kind)) {
    (Lang.de, _) => (
      r.pick([
        'Bestätigen Sie Ihre E-Mail-Adresse',
        'Passwort zurücksetzen',
        'Neue Anmeldung bei $name',
        'Ihr Sicherheitscode: $codeValue',
        'Bestätige deine E-Mail-Adresse',
        'Neues Passwort angefordert',
        'Willkommen bei $name',
      ]),
      <String>[
        'Hallo,',
        r.pick([
          'bitte bestätigen Sie Ihre E-Mail-Adresse, um Ihr Konto zu aktivieren.',
          'Sie haben angefordert, Ihr Passwort zurückzusetzen.',
          'Wir haben eine neue Anmeldung in Ihrem Konto festgestellt.',
          'Ihr Code lautet $codeValue. Er ist 10 Minuten gültig.',
          'du hast ein neues Passwort angefordert. Klicke auf den Link, um es zurückzusetzen.',
          'bitte bestätige deine E-Mail-Adresse, um dein Konto zu aktivieren.',
        ]),
        'Falls Sie das nicht waren, ändern Sie bitte Ihr Passwort.',
      ],
    ),
    (Lang.fr, _) => (
      r.pick([
        'Confirmez votre adresse e-mail',
        'Réinitialisation de votre mot de passe',
        'Nouvelle connexion à votre compte',
      ]),
      <String>[
        'Bonjour,',
        r.pick([
          'Merci de confirmer votre adresse e-mail pour activer votre compte.',
          'Vous avez demandé à réinitialiser votre mot de passe.',
          'Une nouvelle connexion à votre compte a été détectée.',
        ]),
        "Si ce n'était pas vous, sécurisez votre compte.",
      ],
    ),
    (_, 0) => (
      r.pick([
        'Welcome to $name',
        'Welcome to $name, ${first(r)}!',
        'Thanks for signing up',
        'Your $name account is ready',
      ]),
      <String>[
        'Thanks for creating a $name account.',
        r.pick([
          'Confirm your email address to get started.',
          'Verify your email to finish setting up.',
          'Your account is ready to use.',
        ]),
        'Verify email',
      ],
    ),
    (_, 1) => (
      r.pick([
        'Reset your password',
        'Password reset request',
        'Your $name password reset link',
      ]),
      <String>[
        'Someone asked to reset the password for your $name account.',
        'Click the link below to choose a new password. It expires in 1 hour.',
        'If it was not you, ignore this email.',
      ],
    ),
    (_, 2) => (
      r.pick([
        'Security alert',
        'New sign-in to your account',
        'New login from ${r.pick(['Chrome on Windows', 'Safari on iPhone', 'Firefox on Linux'])}',
        'Unusual sign-in activity',
      ]),
      <String>[
        'We noticed a new sign-in to your $name account.',
        'Device: ${r.pick(['iPhone', 'Windows PC', 'Mac', 'Android phone'])}',
        'Location: ${r.pick(cities)}',
        'Time: ${date(r, someDay(r), Lang.en)} ${time(r, r.between(0, 23), r.between(0, 59), Lang.en)}',
        "If this was you, you don't need to do anything. If not, secure your account.",
      ],
    ),
    (_, 3) => (
      r.pick([
        'Your verification code',
        '$codeValue is your $name code',
        'Your one-time code',
        'Sign in to $name',
      ]),
      <String>[
        'Your verification code is $codeValue.',
        'Enter it to sign in. It expires in 10 minutes.',
        "Don't share this code with anyone.",
      ],
    ),
    (_, 4) => (
      r.pick([
        'Your email address was changed',
        'Your password was changed',
        'Your phone number was updated',
      ]),
      <String>[
        'The ${r.pick(['email address', 'password', 'phone number'])} for your $name account was changed on ${date(r, someDay(r), Lang.en)}.',
        'If you made this change, no action is needed.',
        'If not, contact us right away.',
      ],
    ),
    _ => (
      r.pick([
        'Your account has been deleted',
        'Your $name account is closed',
        'Confirm your account deletion',
      ]),
      <String>[
        'Your $name account and its data have been deleted.',
        "We're sorry to see you go.",
      ],
    ),
  };
  return synth(
    MailClass.account,
    Sender(name, from, lang: lang),
    subject,
    finish(r, lines),
  );
}

// -------------------------------------------------------------- marketing

/// Promotions, many of them about travel: the hardest negatives.
SynthMail travelPromo(Rng r) {
  final senders = [
    ('Trainline', 'news@info.thetrainline.com'),
    ('LNER', 'offers@lner.co.uk'),
    ('Avanti West Coast', 'news@avantiwestcoast.co.uk'),
    ('ÖBB', 'newsletter@oebb.at'),
    ('Eurostar', 'news@eurostar.com'),
    ('British Airways', 'ba@email.ba.com'),
    ('Singapore Airlines', 'promotions@singaporeair.com'),
    ('easyJet', 'news@easyjet.com'),
    ('Booking.com', 'email.campaign@sg.booking.com'),
    ('Expedia', 'deals@expedia.com'),
    ('Skyscanner', 'news@skyscanner.net'),
    ('Airbnb', 'discover@airbnb.com'),
    ('Ticketmaster', 'news@email.ticketmaster.com'),
  ];
  final (name, from) = r.pick(senders);
  final ((fc, fcity, _), (tc, tcity, _)) = route(r);
  final pct = r.pick([10, 15, 20, 25, 30, 40, 50]);
  final cur = r.pick(['GBP', 'EUR', 'SGD', 'USD']);
  final lang = name == 'ÖBB' && r.chance(0.7) ? Lang.de : Lang.en;
  final subject = lang == Lang.de
      ? r.pick([
          'Sparschiene ab ${money(r, 9.9, 'EUR', lang)}',
          'Jetzt buchen: $pct % Rabatt auf Ihre nächste Reise',
          'Unsere Angebote für den Winter',
        ])
      : r.pick([
          'Save $pct% on trains',
          'Save up to $pct% on your next trip',
          'Fly to $tcity from ${money(r, price(r, 49, 900), cur, lang)}',
          'Flash sale: $fcity to $tcity',
          'Last-minute deals in $tcity',
          'Your next adventure awaits',
          'Earn double ${r.pick(['Avios', 'miles', 'points'])} this month',
          'Prices dropped for $fc → $tc',
          'Black Friday: $pct% off hotels',
          'Weekend getaways from ${money(r, price(r, 39, 200), cur, lang)}',
          'Still thinking about $tcity?',
          'Complete your booking',
          'Book now, travel later',
          'Tickets on sale now: ${r.pick(acts)}',
        ]);
  final day = someDay(r);
  final lines = lang == Lang.de
      ? <String>[
          'Entdecken Sie Österreich mit der Sparschiene.',
          'Wien – Salzburg ab ${money(r, 9.9, 'EUR', lang)}',
          'Nur für kurze Zeit. Jetzt buchen!',
          'Reisezeitraum bis ${date(r, day, lang)}.',
        ]
      : <String>[
          r.pick([
            'Hi ${first(r)},',
            'Dreaming of a getaway?',
            'Limited time only!',
            'Hello traveller,',
          ]),
          r.pick([
            'Book by ${date(r, day, Lang.en)} and save $pct% on selected routes.',
            '$fcity ($fc) to $tcity ($tc) from ${money(r, price(r, 49, 900), cur, Lang.en)} return.',
            'Our biggest sale of the year is here: up to $pct% off.',
            'Travel between ${date(r, day, Lang.en)} and ${date(r, day.add(const Duration(days: 60)), Lang.en)}.',
            "Prices for your search $fc → $tc have dropped. Don't miss out.",
            'You left something behind. Complete your booking before prices go up.',
          ]),
          if (r.chance(0.6))
            r.pick([
              'Departing ${date(r, day, Lang.en)} ${time(r, r.between(6, 22), 0, Lang.en)}',
              'Fares from ${money(r, price(r, 9, 99), cur, Lang.en)} each way',
            ]),
          if (r.chance(0.5))
            r.pick([
              'London to Manchester from £12',
              'Vienna to Munich from €29.90',
              'Paris Gare du Nord from €39',
              'Hotels in $tcity from ${money(r, 59, cur, Lang.en)} a night',
            ]),
          r.pick([
            'Book now',
            'Find deals',
            'Search fares',
            'Explore offers',
            'Shop now',
          ]),
          if (r.chance(0.5))
            '*Selected routes. Subject to availability. Terms apply.',
        ];
  return synth(
    MailClass.marketing,
    Sender(name, from, lang: lang),
    subject,
    finish(r, lines, marketing: true),
    bulk: r.chance(0.8),
  );
}

/// Shop and service promotions.
SynthMail shopPromo(Rng r) {
  final senders = [
    ('UNIQLO', 'news@uniqlo.com'),
    ('Zalando', 'newsletter@zalando.de'),
    ('IKEA', 'news@ikea.com'),
    ('Amazon', 'store-news@amazon.co.uk'),
    ('ASOS', 'asos@info.asos.com'),
    ('Spotify', 'no-reply@spotify.com'),
    ('Uber Eats', 'uber@uber.com'),
    ('Deliveroo', 'news@deliveroo.co.uk'),
  ];
  final (name, from) = r.pick(senders);
  final pct = r.pick([10, 20, 30, 40, 50, 70]);
  final subject = r.pick([
    '$pct% off everything this weekend',
    'Free delivery on orders over ${money(r, 50, r.pick(['GBP', 'EUR', 'SGD']), Lang.en)}',
    'New arrivals you will love',
    'Your exclusive code inside',
    'Try Premium free for 3 months',
    'Last chance: sale ends tonight',
    'Your weekend treat: ${money(r, 5, 'GBP', Lang.en)} off',
    "Don't miss out, ${first(r)}",
  ]);
  final lines = <String>[
    r.pick([
      'Shop the sale.',
      'Up to $pct% off selected lines.',
      'Use code SAVE$pct at checkout.',
      'Get it delivered free.',
    ]),
    r.pick([
      'Offer ends ${date(r, someDay(r), Lang.en)}.',
      'While stocks last.',
      'Free delivery and returns.',
    ]),
    'Shop now',
  ];
  return synth(
    MailClass.marketing,
    Sender(name, from),
    subject,
    finish(r, lines, marketing: true),
    bulk: r.chance(0.85),
  );
}

// ---------------------------------------------- none: the hard negatives

/// Newsletters: editorial content, often about travel.
SynthMail newsletter(Rng r) {
  final senders = [
    ('The Points Guy', 'newsletter@thepointsguy.com'),
    ('Lonely Planet', 'news@lonelyplanet.com'),
    ('Seat61 updates', 'news@seat61.example'),
    ('Monocle', 'newsletter@monocle.com'),
    ('Der Standard Reisen', 'newsletter@derstandard.at'),
    ('Tech Weekly', 'hello@techweekly.substack.com'),
    ('Morning Brew', 'crew@morningbrew.com'),
  ];
  final (name, from) = r.pick(senders);
  final city = r.pick(cities);
  final subject = r.pick([
    '10 things to do in $city this winter',
    'The best night trains in Europe',
    'Weekly digest: ${r.pick(['travel', 'tech', 'food', 'design'])} news',
    'How to use your miles for business class',
    'Issue #${r.between(10, 400)}: ${r.pick(['Slow travel', 'Rail passes explained', 'Why fares go up', 'The new airport lounges'])}',
    'Our guide to $city',
    'This week: ${r.pick(['airline news', 'hotel openings', 'a 48-hour itinerary'])}',
  ]);
  final lines = <String>[
    r.pick(['In this issue:', 'Good morning!', 'Hello readers,']),
    r.pick([
      'We rode the new night train from Vienna to Paris and here is what we found.',
      'Award seats on long-haul routes are easier to find than you think.',
      'A guide to booking rail tickets in Europe: when to buy, and which passes pay off.',
      'The hotel everyone is talking about in $city, and three cheaper alternatives.',
      'Airlines change schedules every season. Here is how to read the timetable.',
    ]),
    r.pick(['Read more', 'Continue reading', 'Read the full story']),
    if (r.chance(0.5))
      'Plus: ${r.pick(['the best travel credit cards', 'readers\' letters', 'our podcast'])}',
  ];
  return synth(
    MailClass.none,
    Sender(name, from),
    subject,
    finish(r, lines, marketing: true),
    bulk: true,
  );
}

/// Visas, ETAs and other travel permits: about travel, not a booking.
SynthMail travelPermit(Rng r) {
  final senders = [
    (
      'UK Visas and Immigration',
      'no-reply@notifications.service.gov.uk',
      'UK ETA',
    ),
    ('ESTA', 'esta@cbp.dhs.gov', 'ESTA'),
    ('Australian Government', 'noreply@homeaffairs.gov.au', 'eVisitor visa'),
    ('ETIAS', 'no-reply@etias.europa.eu', 'ETIAS travel authorisation'),
    ('New Zealand Immigration', 'noreply@immigration.govt.nz', 'NZeTA'),
    ('Immigration Office', 'evisa@immigration.example', 'eVisa'),
  ];
  final (name, from, what) = r.pick(senders);
  final ref = digits(r, r.between(10, 16));
  final subject = r.pick([
    'Your $what has been approved',
    '$what application approved',
    'Your application for a $what: decision',
    'We have received your $what application',
    'Your $what is valid',
  ]);
  final lines = <String>[
    'Dear applicant,',
    r.pick([
      'Your application for a $what has been approved.',
      'We have received your application and payment.',
      'Your travel authorisation is now valid.',
    ]),
    'Application number: $ref',
    if (r.chance(0.5)) 'Passport number ending: ${digits(r, 3)}',
    'Valid until ${date(r, someDay(r), Lang.en)}',
    r.pick([
      'You do not need to print this email. Your authorisation is linked to your passport.',
      'An approved authorisation does not guarantee entry.',
      'Carry the passport you used to apply when you travel.',
    ]),
  ];
  return synth(MailClass.none, Sender(name, from), subject, finish(r, lines));
}

/// Bank and card statements, loyalty statements.
SynthMail statement(Rng r) {
  final senders = [
    ('DBS', 'alerts@dbs.com', Lang.en),
    ('Monzo', 'help@monzo.com', Lang.en),
    ('Erste Bank', 'service@erstebank.at', Lang.de),
    ('Commerzbank', 'kontoauszug@commerzbank.de', Lang.de),
    ('BNP Paribas', 'releves@bnpparibas.fr', Lang.fr),
    ('Executive Club', 'executiveclub@email.ba.com', Lang.en),
    ('KrisFlyer', 'krisflyer@singaporeair.com', Lang.en),
    ('CDP', 'cdp-estatement@sgx.com', Lang.en),
  ];
  final (name, from, lang) = r.pick(senders);
  final month = _month(r, lang);
  final subject = switch (lang) {
    Lang.de => r.pick([
      'Ihr Kontoauszug für $month',
      'Neuer Kontoauszug verfügbar',
    ]),
    Lang.fr => r.pick([
      'Votre relevé de compte de $month',
      'Nouveau relevé disponible',
    ]),
    Lang.en => r.pick([
      'Your $month statement is ready',
      'Your credit card e-Statement is ready',
      'Your ${r.pick(['Avios', 'miles', 'points'])} statement',
      'Your monthly account summary',
      'Your balance and recent activity',
    ]),
  };
  final lines = switch (lang) {
    Lang.de => <String>[
      'Ihr Kontoauszug für $month steht im Online-Banking bereit.',
      'Kontostand: ${money(r, price(r, 100, 9000), 'EUR', lang)}',
    ],
    Lang.fr => <String>[
      'Votre relevé de $month est disponible dans votre espace.',
      'Solde : ${money(r, price(r, 100, 9000), 'EUR', lang)}',
    ],
    Lang.en => <String>[
      r.pick([
        'Your statement for $month is now available in online banking.',
        'Your ${r.pick(['Avios', 'miles'])} balance is ${r.between(1, 300)},${digits(r, 3)}.',
        'Here is a summary of your account activity.',
      ]),
      if (r.chance(0.5)) 'Minimum payment due ${date(r, someDay(r), Lang.en)}.',
      if (r.chance(0.5))
        'Balance: ${money(r, price(r, 10, 9000), r.pick(['GBP', 'SGD', 'USD']), Lang.en)}',
      if (r.chance(0.4))
        'Recent activity: ${r.pick(['flight', 'hotel', 'partner'])} miles credited on ${date(r, someDay(r), Lang.en)}.',
    ],
  };
  return synth(
    MailClass.none,
    Sender(name, from, lang: lang),
    subject,
    finish(r, lines),
  );
}

/// Season tickets and travel cards renewing: rail words, but no journey.
SynthMail seasonTicket(Rng r) {
  final senders = [
    ('Avanti West Coast', 'seasons@avantiwestcoast.co.uk', Lang.en),
    ('Southern', 'seasontickets@southernrailway.com', Lang.en),
    ('Wiener Linien', 'jahreskarte@wienerlinien.at', Lang.de),
    ('ÖBB', 'oebb-vorteilscard@oebb.at', Lang.de),
    ('Deutsche Bahn', 'bahncard@bahn.de', Lang.de),
    ('Transport for London', 'oyster@tfl.gov.uk', Lang.en),
    ('SNCF Connect', 'abonnement@sncf-connect.com', Lang.fr),
  ];
  final (name, from, lang) = r.pick(senders);
  final (a, b) = pair(
    r,
    lang == Lang.en
        ? ukStations
        : lang == Lang.de
        ? atStations
        : frStations,
  );
  final expires = date(r, someDay(r), lang);
  final subject = switch (lang) {
    Lang.de => r.pick([
      'Ihre Jahreskarte läuft bald ab',
      'Verlängerung Ihrer BahnCard',
      'Ihre Vorteilscard wird verlängert',
    ]),
    Lang.fr => r.pick([
      'Votre abonnement arrive à échéance',
      'Renouvelez votre abonnement',
    ]),
    Lang.en => r.pick([
      'Your season ticket is due for renewal',
      'Time to renew your annual season ticket',
      'Your season ticket expires on $expires',
      'Your Oyster card auto top-up',
      'Renew your railcard',
    ]),
  };
  final lines = switch (lang) {
    Lang.de => <String>[
      'Ihre Karte ist gültig bis $expires.',
      'Verlängern Sie jetzt online.',
      'Kundennummer: ${digits(r, 9)}',
    ],
    Lang.fr => <String>[
      'Votre abonnement est valable jusqu\'au $expires.',
      'Renouvelez-le en ligne.',
    ],
    Lang.en => <String>[
      r.pick([
        'Your season ticket between $a and $b expires on $expires.',
        'Your railcard expires on $expires.',
      ]),
      'Renew online in a few minutes and keep travelling.',
      if (r.chance(0.5))
        'Annual season ticket $a - $b: ${money(r, price(r, 900, 6000), 'GBP', lang)}',
      if (r.chance(0.4)) 'Pay monthly with our season ticket loan.',
    ],
  };
  return synth(
    MailClass.none,
    Sender(name, from, lang: lang),
    subject,
    finish(r, lines),
  );
}

/// After a trip: reviews, receipts for rides, trip summaries.
SynthMail afterTrip(Rng r) {
  final senders = [
    ('Booking.com', 'noreply@booking.com'),
    ('Airbnb', 'automated@airbnb.com'),
    ('Uber', 'noreply@uber.com'),
    ('Grab', 'no-reply@grab.com'),
    ('Bolt', 'receipts@bolt.eu'),
    ('Trainline', 'service@info.thetrainline.com'),
    ('Hotels.com', 'reviews@mail.hotels.com'),
  ];
  final (name, from) = r.pick(senders);
  final city = r.pick(cities);
  final subject = r.pick([
    'How was your stay in $city?',
    'Rate your stay at ${hotel(r, city)}',
    'Your trip with $name',
    'Your ${r.pick(['Uber', 'Grab', 'Bolt'])} receipt',
    'Thanks for riding, ${first(r)}',
    'How was your journey?',
    'Your E-Receipt',
    'Tell us about your trip',
  ]);
  final lines = <String>[
    r.pick([
      'Thanks for staying with us. Share your experience with other travellers.',
      'Hope you enjoyed your ride!',
      'Your trip on ${date(r, someDay(r), Lang.en)}',
      'Tell us how it went and help other guests.',
    ]),
    if (r.chance(0.6))
      'Pick-up ${time(r, r.between(6, 23), r.between(0, 59), Lang.en)} ${r.pick(streets)}, drop-off ${r.pick(streets)}',
    if (r.chance(0.6))
      'Total ${money(r, price(r, 6, 60), r.pick(['GBP', 'EUR', 'SGD']), Lang.en)}',
    r.pick(['Leave a review', 'Rate your trip', 'View receipt']),
  ];
  return synth(MailClass.none, Sender(name, from), subject, finish(r, lines));
}

/// Mail from people, which talks about trips, tickets and bills.
SynthMail personal(Rng r) {
  final who = person(r);
  final domain = r.pick([
    'gmail.com',
    'outlook.com',
    'gmx.at',
    'web.de',
    'orange.fr',
    'company.com',
    'icloud.com',
  ]);
  final city = r.pick(cities);
  final subject = r.pick([
    'Re: trip to $city',
    'Train times for Saturday?',
    'Hotel options',
    'Re: splitting the bill',
    'Fwd: Booking confirmation',
    'Dinner on ${date(r, someDay(r), Lang.en)}',
    'Photos from $city',
    'Quick question',
    'Re: tickets',
    'Wochenende in $city',
    'Our flights',
    'Notes from the offsite',
  ]);
  final lines = <String>[
    r.pick(['Hi ${first(r)},', 'Hey!', 'Hallo ${first(r)},', 'Salut,']),
    r.pick([
      'I looked at trains to $city, there is one at ${time(r, r.between(7, 20), 0, Lang.en)} that gets in before lunch. Shall we book?',
      'The hotel near the station looks nice but it is a bit expensive. What do you think?',
      "I'll transfer you my share of the tickets tonight.",
      'Can you forward me the booking reference? I lost the email.',
      'We land at ${time(r, r.between(7, 22), 30, Lang.en)} on ${date(r, someDay(r), Lang.en)}, can you pick us up?',
      'Here are my notes from the meeting. Next year we should book the venue earlier.',
      'Hast du schon die Zugtickets gekauft? Ich wäre für den Zug um 9.',
      'The photos from $city are in the shared album.',
    ]),
    if (r.chance(0.5)) r.pick(['Cheers,', 'Best,', 'Thanks!', 'LG']),
    who.split(' ').first,
    if (r.chance(0.3))
      '> On ${date(r, someDay(r), Lang.en)}, ${person(r)} wrote:',
  ];
  return synth(
    MailClass.none,
    Sender(who, '${who.split(' ').first.toLowerCase()}@$domain'),
    subject,
    lines.join('\n'),
  );
}

/// Notifications from services: GitHub, calendars, school, work tools.
SynthMail notification(Rng r) {
  final senders = [
    ('GitHub', 'notifications@github.com'),
    ('Jira', 'jira@company.atlassian.net'),
    ('Google Calendar', 'calendar-notification@google.com'),
    ('Nextdoor', 'no-reply@rs.email.nextdoor.com'),
    ('LinkedIn', 'messages-noreply@linkedin.com'),
    ('School newsletter', 'office@school.example'),
    ('HMRC', 'noreply@tax.service.gov.uk'),
  ];
  final (name, from) = r.pick(senders);
  final subject = r.pick([
    '[acme/web] ${r.pick(['Booking page shows the wrong date', 'Invoice export times out', 'Fix ticket rendering', 'Delivery tracker crashes'])} (#${r.between(10, 999)})',
    'Updated invitation: Team sync @ ${r.pick(['Mon', 'Tue', 'Wed'])} ${time(r, r.between(9, 17), 0, Lang.en)}',
    'You have ${r.between(2, 9)} new messages',
    'Your tax return reminder',
    'Parents evening on ${date(r, someDay(r), Lang.en)}',
    '${person(r)} mentioned you in a comment',
  ]);
  final lines = <String>[
    r.pick([
      'The booking confirmation page renders the departure time in UTC. Steps to reproduce attached.',
      'Please review the pull request: tickets now show the coach and seat.',
      'Reminder: the deadline for your tax return is ${date(r, someDay(r), Lang.en)}.',
      'Agenda: travel policy, invoices, Q3 planning.',
      'New posts in your neighbourhood: lost cat, bike for sale.',
    ]),
    r.pick([
      'Reply to this email directly or view it on GitHub.',
      'View in calendar',
      'Open the app to reply.',
      'You are receiving this because you are subscribed.',
    ]),
  ];
  return synth(
    MailClass.none,
    Sender(name, from),
    subject,
    finish(r, lines),
    bulk: r.chance(0.6),
  );
}

/// One-off receipts and orders: paid, but neither a subscription nor
/// shipped (takeaways, rides, shop purchases, refunds).
SynthMail oneOffReceipt(Rng r) {
  final senders = [
    ('GrabFood', 'no-reply@grab.com'),
    ('foodpanda', 'noreply@foodpanda.sg'),
    ('Deliveroo', 'noreply@deliveroo.co.uk'),
    ('Apple', 'no_reply@email.apple.com'),
    ('Steam', 'noreply@steampowered.com'),
    ('PayPal', 'service@paypal.co.uk'),
    ('Lieferando', 'info@lieferando.at'),
  ];
  final (name, from) = r.pick(senders);
  final amount = money(
    r,
    price(r, 4, 80),
    r.pick(['GBP', 'SGD', 'EUR', 'USD']),
    Lang.en,
  );
  final subject = r.pick([
    'Your order from ${r.pick(restaurants)} is on its way',
    'Your receipt for $amount',
    'You sent a payment of $amount',
    'Refund processed: $amount',
    'Thank you for your purchase',
    'Your order has been accepted',
  ]);
  final lines = <String>[
    r.pick([
      'Your rider has picked up your order and is on the way. Estimated arrival ${time(r, r.between(11, 22), r.between(0, 59), Lang.en)}.',
      'Thanks for your purchase of ${r.pick(['Monument Valley', 'a gift card', 'Stardew Valley', 'an album'])}.',
      'You sent $amount to ${person(r)}.',
      'We have refunded $amount to your card.',
    ]),
    'Total $amount',
    if (r.chance(0.5)) 'Order ${code(r, 8)}',
  ];
  return synth(MailClass.none, Sender(name, from), subject, finish(r, lines));
}

/// Travel insurance, check-in reminders for loyalty, cancellations of
/// newsletters... mail that names travel but books nothing.
SynthMail travelAdmin(Rng r) {
  final senders = [
    ('Allianz Travel', 'policy@allianz-travel.example'),
    ('Revolut', 'no-reply@revolut.com'),
    ('Wise', 'noreply@wise.com'),
    ('TripIt', 'noreply@tripit.com'),
    ('Seat Guru', 'news@seatguru.example'),
  ];
  final (name, from) = r.pick(senders);
  final city = r.pick(cities);
  final subject = r.pick([
    'Your travel insurance policy documents',
    'Travelling soon? Let us know',
    'Your annual multi-trip cover renews',
    'Tips for your trip to $city',
    'Currency for your trip to $city',
  ]);
  final lines = <String>[
    r.pick([
      'Your policy covers trips of up to 31 days worldwide. Policy number ${digits(r, 10)}.',
      'Using your card abroad? Turn on travel notifications in the app.',
      'Pack light: here is what you can take in your cabin bag.',
      'Exchange rates for your next trip are now available.',
    ]),
    r.pick(['Read more', 'Open the app', 'View policy']),
  ];
  return synth(MailClass.none, Sender(name, from), subject, finish(r, lines));
}

/// Shorter carrier notices: missed deliveries, collections, expected
/// days.
SynthMail deliveryNotice(Rng r) {
  final senders = [
    ('USPS', 'auto-reply@usps.example', Lang.en),
    ('Royal Mail', 'no-reply@royalmail.com', Lang.en),
    ('PostNL', 'noreply@postnl.nl', Lang.en),
    ('GLS', 'noreply@gls-group.eu', Lang.de),
    ('Hermes', 'noreply@myhermes.de', Lang.de),
    ('Canada Post', 'noreply@canadapost.example', Lang.en),
    ('Australia Post', 'noreply@auspost.com.au', Lang.en),
  ];
  final (name, from, lang) = r.pick(senders);
  final tracking = r.pick([
    '${digits(r, 4)} ${digits(r, 4)} ${digits(r, 4)} ${digits(r, 4)} ${digits(r, 4)} ${digits(r, 2)}',
    '${code(r, 2, digits: false)}${digits(r, 9)}GB',
    digits(r, 14),
    '3S${code(r, 11)}',
  ]);
  final day = r.pick([
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
  ]);
  final subject = lang == Lang.de
      ? r.pick([
          'Dein Paket kommt morgen',
          'Wir haben dich nicht angetroffen',
          'Paket liegt im Paketshop bereit',
          'Zustellung heute',
        ])
      : r.pick([
          '$name Expected Delivery on $day',
          "We've got your parcel ready for collection",
          'Sorry we missed you',
          'Your item will be delivered today',
          'Delivery attempted',
          'Your parcel has arrived at the pickup point',
          'Your package will arrive $day',
        ]);
  final lines = lang == Lang.de
      ? <String>[
          'Sendung $tracking',
          r.pick([
            'Leider haben wir dich nicht angetroffen. Dein Paket liegt im Paketshop zur Abholung bereit.',
            'Dein Paket wird morgen zwischen 9 und 13 Uhr zugestellt.',
            'Bitte bring einen Ausweis zur Abholung mit.',
          ]),
        ]
      : <String>[
          r.pick([
            'Your item is out for delivery.',
            'We tried to deliver your item today but nobody was in.',
            'Your item is waiting at your local Delivery Office. Bring ID to collect it.',
            'Your package is expected by 8:00 pm.',
            'Your parcel is ready to pick up.',
          ]),
          '${r.pick(['Tracking', 'Tracking number', 'Item', 'Reference'])} $tracking',
          if (r.chance(0.5))
            'Expected by ${time(r, r.between(17, 21), 0, Lang.en)}.',
        ];
  return synth(
    MailClass.delivery,
    Sender(name, from, lang: lang),
    subject,
    finish(r, lines),
  );
}

/// Trials, instalments and other bills in other words.
SynthMail trialsAndInstalments(Rng r) {
  final lang = r.pick([Lang.en, Lang.en, Lang.de]);
  final company = r.pick([
    'Kitepad',
    'Notewise',
    'Lumen',
    'Readly',
    'Calmly',
    'FitLab',
    'EWE',
    'Vattenfall',
    'E.ON',
  ]);
  final from = 'billing@${company.toLowerCase().replaceAll('.', '')}.example';
  final amount = money(
    r,
    price(r, 4, 120),
    lang == Lang.de ? 'EUR' : r.pick(['USD', 'GBP', 'EUR']),
    lang,
  );
  final when = date(r, someDay(r), lang);
  final (subject, lines) = lang == Lang.de
      ? (
          r.pick([
            'Ihre Abschlagsrechnung',
            'Ihre Stromrechnung',
            'Neuer Abschlag ab $when',
            'Ihr Abo wurde verlängert',
            'Ihre Mitgliedschaft',
          ]),
          <String>[
            r.pick([
              'Ihre Abschlagsrechnung für Strom liegt vor.',
              'Ihr monatlicher Abschlag beträgt $amount.',
              'Ihr Abonnement verlängert sich automatisch um einen Monat.',
            ]),
            'Betrag: $amount, fällig am $when.',
            if (r.chance(0.5)) 'Vertragsnummer ${digits(r, 9)}',
          ],
        )
      : (
          r.pick([
            'Your free trial of $company has started',
            'Your $company trial ends in 3 days',
            'Your $company plan is now active',
            'Your monthly payment to $company',
            'Your direct debit amount is changing',
          ]),
          <String>[
            r.pick([
              'Welcome to $company! Your 14-day free trial ends on $when. After that it is $amount per month.',
              'Your trial ends on $when and your card will be charged $amount.',
              'Your monthly payment of $amount will be collected on $when.',
              'You are now on the $company Plus plan, billed monthly at $amount.',
            ]),
            r.pick([
              'Cancel any time in Settings.',
              'Manage your subscription.',
              'No action needed.',
            ]),
          ],
        );
  return synth(
    MailClass.subscription,
    Sender(company, from, lang: lang),
    subject,
    finish(r, lines),
  );
}

/// Car services, MOTs, vets, opticians: appointments in other words.
SynthMail serviceAppointment(Rng r) {
  final services = [
    ('Halfords Autocentre', 'bookings@halfords.example', 'MOT', Lang.en),
    ('Kwik Fit', 'bookings@kwik-fit.com', 'tyre fitting', Lang.en),
    ('ÖAMTC', 'termin@oeamtc.at', 'Pickerl-Überprüfung', Lang.de),
    ('ATU', 'termin@atu.de', 'Reifenwechsel', Lang.de),
    ('Specsavers', 'appointments@specsavers.example', 'eye test', Lang.en),
    ('City Vets', 'reception@cityvets.example', 'booster vaccination', Lang.en),
    (
      'Bürgeramt',
      'termin@buergeramt.example',
      'Personalausweis beantragen',
      Lang.de,
    ),
  ];
  final (name, from, what, lang) = r.pick(services);
  final day = someDay(r);
  final (h, m) = (r.between(8, 17), r.pick([0, 15, 30, 45]));
  final subject = lang == Lang.de
      ? r.pick([
          'Ihr Termin: $what',
          'Terminbestätigung $name',
          'Ihr Termin am ${date(r, day, lang)}',
        ])
      : r.pick([
          'Your $what is booked',
          'Your $what appointment on ${date(r, day, lang)}',
          'Booking confirmed: $what',
          'Reminder: $what tomorrow',
        ]);
  final lines = lang == Lang.de
      ? <String>[
          'Guten Tag,',
          'Ihr Termin für $what ist bestätigt.',
          '${date(r, day, lang)} um ${time(r, h, m, lang)}',
          '$name, ${address(r)}',
          if (r.chance(0.5)) 'Bitte kommen Sie 5 Minuten früher.',
        ]
      : <String>[
          r.pick(['Hi ${first(r)},', 'Hello,']),
          'Your $what is booked for ${date(r, day, lang)} at ${time(r, h, m, lang)} at $name ${r.pick(cities)}.',
          if (r.chance(0.5))
            'Vehicle: ${code(r, 4)} ${code(r, 3, digits: false)}',
          if (r.chance(0.5)) 'Need to change it? Call us or use the link.',
        ];
  return synth(
    MailClass.appointment,
    Sender(name, from, lang: lang),
    subject,
    finish(r, lines),
  );
}

/// All the templates that are not bookings.
const otherTemplates = <Template>[
  deliveryNotice,
  trialsAndInstalments,
  serviceAppointment,
  eBill,
  subscriptionReceipt,
  renewalNotice,
  membershipPayment,
  delivery,
  appointment,
  accountMail,
  travelPromo,
  shopPromo,
  newsletter,
  travelPermit,
  statement,
  seasonTicket,
  afterTrip,
  personal,
  notification,
  oneOffReceipt,
  travelAdmin,
];
