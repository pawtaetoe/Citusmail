// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'mail_types.dart';

/// One made-up example email and what it is.
final class MailTypeSeed {
  const MailTypeSeed(this.kinds, this.sample);

  /// What it is (empty: none of them).
  final Set<MailKind> kinds;
  final MailSample sample;
}

/// A small hand-written set of made-up emails (invented companies and
/// people), which gives [MailTypeClassifier] sensible priors before the
/// user corrects anything. Nobody's real mail.
abstract final class MailTypeSeeds {
  static const _s = {MailKind.subscription};
  static const _d = {MailKind.delivery};
  static const _b = {MailKind.booking};
  static const _a = {MailKind.account};
  static const _p = {MailKind.appointment};
  static const _none = <MailKind>{};

  static const all = [
    // Subscriptions: receipts and renewals that speak of a plan.
    MailTypeSeed(
      _s,
      MailSample(
        address: 'billing@streamly.example',
        senderName: 'Streamly',
        subject: 'Your Streamly receipt',
        text:
            'Thanks for your payment. Premium plan, monthly. Amount paid '
            r'$15.99. Your subscription renews on 3 March. Manage your plan '
            'in Account settings.',
      ),
    ),
    MailTypeSeed(
      _s,
      MailSample(
        address: 'invoice+statements@mail.paystripe.example',
        senderName: 'Notewise',
        subject: 'Your receipt from Notewise #2291-4410',
        text:
            r'Receipt from Notewise. Amount paid US$20.00. Date paid '
            'Oct 2. Notewise Pro subscription, 1 month. Payment method Visa '
            'ending 4242. Questions? Contact us.',
      ),
    ),
    MailTypeSeed(
      _s,
      MailSample(
        address: 'no-reply@cloudbox.example',
        senderName: 'CloudBox',
        subject: 'Your CloudBox plan has renewed',
        text:
            'Your 2 TB plan renewed for another year. We charged '
            r'S$139.00 to your card. Next billing date 12 Jan. '
            'Turn off auto-renew any time.',
      ),
    ),
    MailTypeSeed(
      _s,
      MailSample(
        address: 'ebill@fibrenet.example',
        senderName: 'FibreNet',
        subject: 'Your FibreNet e-bill for October is ready',
        text:
            'Your monthly bill is ready. Amount due S\$49.90, due by 21 '
            'Oct. Broadband 1Gbps plan. Pay with GIRO or card.',
      ),
    ),
    MailTypeSeed(
      _s,
      MailSample(
        address: 'support@namehost.example',
        senderName: 'NameHost',
        subject: 'NameHost Order Confirmation - Domain renewal',
        text:
            r'Thank you for your order. example.net domain renewal, 1 year, '
            r'$11.06. Auto-renew is on. Expires 2027-08-01.',
      ),
    ),
    MailTypeSeed(
      _s,
      MailSample(
        address: 'hello@fitclub.example',
        senderName: 'FitClub',
        subject: 'Your free trial ends in 3 days',
        text:
            'Your FitClub free trial ends on 14 May. After that your '
            'membership renews at \$29 per month unless you cancel.',
      ),
    ),
    MailTypeSeed(
      _s,
      MailSample(
        address: 'billing@power.example',
        senderName: 'City Power',
        subject: 'Your utilities bill for September',
        text:
            'Your bill for electricity and water is ready. Total amount '
            r'payable $132.40. Payment due date 28 Sep. Account no 8812 004.',
      ),
    ),
    // Deliveries: shipping and carrier mail.
    MailTypeSeed(
      _d,
      MailSample(
        address: 'shipping@gadgetshop.example',
        senderName: 'GadgetShop',
        subject: 'Your order #48213 has shipped',
        text:
            'Good news! Your order is on its way. Tracking number '
            '1Z999AA10123456784. Estimated delivery Thursday, 4 June. '
            'Track your package.',
      ),
    ),
    MailTypeSeed(
      _d,
      MailSample(
        address: 'noreply@parcelpost.example',
        senderName: 'ParcelPost',
        subject: 'Your parcel is out for delivery',
        text:
            'Your parcel RR123456785SG is out for delivery today between '
            '9am and 1pm. The courier will leave it at your door.',
      ),
    ),
    MailTypeSeed(
      _d,
      MailSample(
        address: 'orders@bookhaven.example',
        senderName: 'BookHaven',
        subject: 'Delivered: 2 items from your order',
        text:
            'Your package was delivered. Left with: front door. Order '
            '113-55210-88. Return or replace items in Your Orders.',
      ),
    ),
    MailTypeSeed(
      _d,
      MailSample(
        address: 'notify@quickship.example',
        senderName: 'QuickShip',
        subject: 'Your shipment is ready for collection',
        text:
            'Your shipment 7781 2299 3310 is ready to collect at the '
            'pickup point. Bring your ID. It will be kept for 7 days.',
      ),
    ),
    // Bookings: flights, stays, tables, tickets.
    MailTypeSeed(
      _b,
      MailSample(
        address: 'booking@skyway.example',
        senderName: 'SkyWay Airlines',
        subject: 'Booking confirmation - Singapore to Tokyo',
        text:
            'Your flight is confirmed. Booking reference K7QP2M. SW 638 '
            'departs Singapore 23:55 on 12 Dec, arrives Tokyo Haneda 08:05. '
            'Check in online 48 hours before departure.',
      ),
    ),
    MailTypeSeed(
      _b,
      MailSample(
        address: 'reservations@harbourinn.example',
        senderName: 'Harbour Inn',
        subject: 'Your reservation at Harbour Inn is confirmed',
        text:
            'Check-in Fri 5 Apr from 3pm, check-out Sun 7 Apr by 11am. '
            '1 room, 2 guests. Confirmation number 553201. We look forward '
            'to your stay.',
      ),
    ),
    MailTypeSeed(
      _b,
      MailSample(
        address: 'tickets@railgo.example',
        senderName: 'RailGo',
        subject: 'Your train tickets: Paris to Lyon',
        text:
            'Departure 9 Jun 07:56 from Paris Gare de Lyon, coach 12 seat '
            '44. Your e-ticket is attached. Booking ref QX5512.',
      ),
    ),
    MailTypeSeed(
      _b,
      MailSample(
        address: 'noreply@tablenow.example',
        senderName: 'TableNow',
        subject: 'Your table is booked for Saturday',
        text:
            'Table for 4 at Olive & Vine on Sat 18 May at 7:30pm. '
            'Reservation number 99812. Need to change? Manage booking.',
      ),
    ),
    // Appointments: a dentist, a salon, a car service.
    MailTypeSeed(
      _p,
      MailSample(
        address: 'appointments@brightsmile.example',
        senderName: 'Bright Smile Dental',
        subject: 'Your appointment is confirmed',
        text:
            'This is to confirm your appointment with Dr Lim on Tue 12 Nov '
            'at 3:30 PM. Treatment: scale and polish. To reschedule or '
            'cancel, call us at least 24 hours before.',
      ),
    ),
    MailTypeSeed(
      _p,
      MailSample(
        address: 'no-reply@salonbook.example',
        senderName: 'SalonBook',
        subject: 'Booking confirmed: Haircut at Studio Nine',
        text:
            'You are booked! Sat 16 Nov at 11:00, Haircut and blow dry '
            'with Mia. Booking ref A7K2Q9. Manage appointment.',
      ),
    ),
    MailTypeSeed(
      _p,
      MailSample(
        address: 'service@northgarage.example',
        senderName: 'North Garage',
        subject: 'Reminder: your car service is tomorrow',
        text:
            'Your vehicle is booked in for a full service tomorrow at '
            '08:30. Please drop off your keys at reception.',
      ),
    ),
    // Accounts: welcome, sign-in and password mail.
    MailTypeSeed(
      _a,
      MailSample(
        address: 'welcome@taskboard.example',
        senderName: 'Taskboard',
        subject: 'Welcome to Taskboard! Confirm your email',
        text:
            'Thanks for signing up. Confirm your email address to finish '
            'creating your account. Your username is alex.',
      ),
    ),
    MailTypeSeed(
      _a,
      MailSample(
        address: 'security@photohub.example',
        senderName: 'PhotoHub',
        subject: 'New sign-in to your PhotoHub account',
        text:
            'We noticed a new sign-in to your account from Chrome on '
            'Windows. If this was you, you can ignore this email. If not, '
            'reset your password.',
      ),
    ),
    MailTypeSeed(
      _a,
      MailSample(
        address: 'no-reply@forumly.example',
        senderName: 'Forumly',
        subject: 'Your password was changed',
        text:
            'The password for your Forumly account was changed. If you '
            'did not do this, secure your account now.',
      ),
    ),
    // None of them: people, discussions, newsletters, statements, ads.
    MailTypeSeed(
      _none,
      MailSample(
        address: 'notifications@codeforge.example',
        senderName: 'Sam Lee',
        subject: 'Re: [acme/shop] Fix invoice totals (#212)',
        text:
            '@alex I pushed a fix for the rounding in the invoice view. '
            'Reply to this email directly or view it on CodeForge. You are '
            'receiving this because you were mentioned.',
      ),
    ),
    MailTypeSeed(
      _none,
      MailSample(
        address: 'notifications@codeforge.example',
        senderName: 'Priya N',
        subject: '[acme/billing] Subscription renewal job fails on retry (#88)',
        text:
            'The renewal worker crashes when the payment provider times '
            'out. Steps to reproduce attached. Reply to this email directly, '
            'view it on CodeForge, or unsubscribe.',
        bulk: true,
      ),
    ),
    MailTypeSeed(
      _none,
      MailSample(
        address: 'jamie.tan@freemail.example',
        senderName: 'Jamie Tan',
        subject: 'Dinner on Friday?',
        text:
            'Hey! Are you free on Friday? Thinking of trying that new '
            'ramen place near the office. Let me know.',
      ),
    ),
    MailTypeSeed(
      _none,
      MailSample(
        address: 'news@gearstore.example',
        senderName: 'GearStore',
        subject: 'Weekend sale: 30% off everything',
        text:
            'Our biggest sale of the season. Free shipping on orders over '
            r'$50. Shop now. Unsubscribe or update your preferences.',
        bulk: true,
      ),
    ),
    MailTypeSeed(
      _none,
      MailSample(
        address: 'estatements@bigbank.example',
        senderName: 'BigBank',
        subject: 'Your account statement is ready',
        text:
            'Your monthly account statement for September is now '
            'available in online banking. This is an automated message.',
      ),
    ),
    MailTypeSeed(
      _none,
      MailSample(
        address: 'digest@weeklyreads.example',
        senderName: 'Weekly Reads',
        subject: 'This week: five stories worth your time',
        text:
            'Hand-picked long reads on science, travel and food. Read in '
            'browser. You are receiving this because you subscribed.',
        bulk: true,
      ),
    ),
    MailTypeSeed(
      _none,
      MailSample(
        address: 'receipts@rideshare.example',
        senderName: 'RideShare',
        subject: 'Your Sunday evening trip with RideShare',
        text:
            r'Thanks for riding, Alex. Total $14.20. Pickup Orchard Rd '
            '7:12pm, drop-off Tiong Bahru 7:31pm. Driver Ahmad. Rate your '
            'trip.',
      ),
    ),
    MailTypeSeed(
      _none,
      MailSample(
        address: 'no-reply@foodfast.example',
        senderName: 'FoodFast',
        subject: 'Your FoodFast order receipt',
        text:
            r'Order from Noodle House. Subtotal $18.50, delivery fee $2.99, '
            r'total $21.49. Paid with Visa. Hope you enjoyed your meal!',
      ),
    ),
    MailTypeSeed(
      _none,
      MailSample(
        address: 'team@calendarly.example',
        senderName: 'Calendarly',
        subject: 'Meeting confirmed: Project sync with Dana',
        text:
            'Your meeting is scheduled for Tue 4 Mar 10:00. Join with the '
            'video link. Reschedule or cancel from your calendar.',
      ),
    ),
  ];
}
