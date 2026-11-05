// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

MailAddress _address(String a, [String? name]) => MailAddress(
  displayName: name,
  localPart: a.split('@').first,
  domain: a.split('@').last,
);

/// What came into the test inbox while Alice was away, from [left] (an
/// evening) to [back] (the next morning, at least 13 hours later), and
/// around it: mail from people, her own note, newsletters and a
/// notification, a blocked sender, a sign-in code, a first-time sender
/// the Screener holds back, and mail arriving once she is back.
void seedAwayMail(
  MailStore store, {
  required DateTime left,
  required DateTime back,
}) {
  assert(back.difference(left) >= const Duration(hours: 13));
  final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
  var uid = 30;
  DateTime after(int hours, [int minutes = 0]) =>
      left.add(Duration(hours: hours, minutes: minutes));
  MessageSummary mail(
    DateTime at,
    String from,
    String name,
    String subject, {
    String? snippet,
    MessageCategory category = MessageCategory.general,
    String? code,
    bool seen = false,
  }) => MessageSummary(
    uid: uid++,
    receivedAt: at,
    subject: subject,
    from: _address(from, name),
    snippet: snippet,
    category: category,
    code: code,
    messageId: 'away$uid@x.example',
    flags: MessageFlags.fromImap([if (seen) r'\Seen']),
  );
  store.messages.upsertSummaries(inbox.id, [
    // Exactly when she left: she had seen it come in.
    mail(
      left,
      'carol@x.example',
      'Carol',
      'Before you go',
      snippet: 'Can you send me the slides from today?',
      seen: true,
    ),
    mail(
      after(0, 1),
      'carol@x.example',
      'Carol',
      'Dinner on Friday?',
      snippet: 'We are thinking of the new Thai place at 7. Are you in?',
    ),
    mail(
      after(3, 45),
      'priya@fabrikam.example',
      'Priya Shah',
      'Contract draft, v3',
      snippet: 'I have marked the changes in clause 4. Could you check them?',
      seen: true, // read on her phone
    ),
    // A note she mailed herself from her phone.
    mail(
      after(7, 30),
      'alice@citusmail.test',
      'Alice',
      'Passport number for the booking',
    ),
    mail(
      after(8, 30),
      'digest@medium.example',
      'Medium Daily Digest',
      'Stories picked for you',
      category: MessageCategory.newsletters,
    ),
    mail(
      after(9, 30),
      'news@shop.example',
      'Shop',
      'Last chance: 40% off boots',
      category: MessageCategory.newsletters,
    ),
    mail(
      after(10),
      'shipping@parcel.example',
      'Parcel Co',
      'Your order has shipped',
      category: MessageCategory.notifications,
    ),
    mail(
      after(10, 30),
      'winner@cheap-pills.example',
      'Pharmacy',
      'You have been selected!!!',
    ),
    mail(
      after(11, 30),
      'no-reply@northwind.example',
      'Northwind Bank',
      'Your sign-in code',
      category: MessageCategory.codes,
      code: '482913',
    ),
  ]);
  store.blocks.block(BlockKind.domain, 'cheap-pills.example');
  // The Screener holds back someone writing for the first time.
  store.screener.enable(now: after(12));
  store.messages.upsertSummaries(inbox.id, [
    mail(
      after(12, 30),
      'recruiter@talent.example',
      'Jordan at Talent',
      'Quick question about your next move',
    ),
    // Right as she opened the app.
    mail(
      back,
      'dave@x.example',
      'Dave',
      'Standup moved to 10',
      snippet: 'Room 4B, same link as always.',
    ),
    // While she was reading: goes to General as usual.
    mail(
      back.add(const Duration(minutes: 1)),
      'dave@x.example',
      'Dave',
      'Never mind, 9:30',
      snippet: 'Sorry, 9:30 after all.',
    ),
  ]);
}
