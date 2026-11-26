// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'appointment_mail.dart';

/// The code in [seedToday]'s sign-in email.
const todayCode = '482913';

/// Made-up mail about [now]'s day, for the summary line (tests and
/// screenshots): a fresh sign-in code (unread), a parcel out for
/// delivery, a dentist at 3.30pm and a bill due the next day (read).
void seedToday(MailStore store, {required DateTime now}) {
  final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
  var uid = 700;
  MessageSummary mail(
    String address,
    String name,
    String subject,
    DateTime at, {
    required String snippet,
    MessageCategory category = MessageCategory.notifications,
    bool read = true,
    String? code,
  }) {
    final i = address.indexOf('@');
    return MessageSummary(
      uid: uid++,
      receivedAt: at.toUtc(),
      subject: subject,
      from: MailAddress(
        localPart: address.substring(0, i),
        domain: address.substring(i + 1),
        displayName: name,
      ),
      snippet: snippet,
      size: 20000,
      category: category,
      code: code,
      flags: MessageFlags.fromImap([if (read) r'\Seen']),
    );
  }

  store.messages.upsertSummaries(inbox.id, [
    mail(
      'no-reply@northwind.example',
      'Northwind',
      'Your Northwind sign-in code',
      now.subtract(const Duration(minutes: 2)),
      snippet: 'Use $todayCode to sign in. It expires in 10 minutes.',
      category: MessageCategory.codes,
      read: false,
      code: todayCode,
    ),
    mail(
      'info@mail.shopee.sg',
      'Shopee',
      'Your order 241101ABCDEF12 is out for delivery',
      now.subtract(const Duration(hours: 2)),
      snippet:
          'Order 241101ABCDEF12 is out for delivery with Shopee Express. '
          'Tracking number: SPXSG041234567890',
    ),
    mail(
      'appointments@brightsmiledental.co.uk',
      'Bright Smile Dental',
      'Appointment confirmation - Bright Smile Dental',
      now.subtract(const Duration(days: 3)),
      snippet:
          'Dear Alice, this is to confirm your appointment with Dr Patel on '
          '${appointmentDayText(now, 0)} at 3.30pm. Treatment: Scale and '
          'polish. Address: 14 High Street, Oxford OX1 4AA',
      category: MessageCategory.general,
    ),
    mail(
      'hello@myrepublic.com.sg',
      'MyRepublic',
      'Your MyRepublic e-Bill is ready!',
      DateTime(now.year, now.month, now.day - 6, 12),
      snippet:
          'Your e-bill is ready! The outstanding amount for your account '
          'RA2328693 is: \$32.99. Please pay your bill within 7 days of '
          'receiving this email.',
    ),
  ]);
}
