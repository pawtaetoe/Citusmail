// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

import 'support/mdn_samples.dart';

void main() {
  late Directory directory;
  late MailStore store;
  late Account account;
  late StoredMailbox inbox;
  late StoredMailbox sent;

  ImapMailboxInfo folder(String name, [String? use]) => ImapMailboxInfo(
    encodedName: name,
    delimiter: '/',
    attributes: {if (use != null) '\\$use'},
  );

  setUp(() {
    directory = Directory.systemTemp.createTempSync('receipt_collector_test');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
    account = store.accounts.add(
      NewAccount(
        email: 'maria@citusmail.test',
        username: 'maria',
        imap: ServerSettings(
          host: 'h.example',
          port: 993,
          security: ConnectionSecurity.implicitTls,
        ),
        smtp: ServerSettings(
          host: 'h.example',
          port: 465,
          security: ConnectionSecurity.implicitTls,
        ),
      ),
    );
    final folders = store.mailboxes.replaceAll(account.id, [
      folder('INBOX'),
      folder('Sent', 'Sent'),
    ]);
    inbox = folders.firstWhere((b) => b.encodedName == 'INBOX');
    sent = folders.firstWhere((b) => b.encodedName == 'Sent');

    // "Quarterly plans", written on another device, asked for receipts;
    // its copy in Sent says so.
    store.messages.upsertSummaries(sent.id, [
      MessageSummary(
        uid: 1,
        receivedAt: DateTime.utc(2026, 11, 6, 14, 10),
        messageId: 'plans-1@citusmail.test',
        subject: 'Quarterly plans',
        from: const MailAddress(localPart: 'maria', domain: 'citusmail.test'),
        headers: const {
          'disposition-notification-to': ['<maria@citusmail.test>'],
        },
      ),
      // Didn't ask.
      MessageSummary(
        uid: 2,
        receivedAt: DateTime.utc(2026, 11, 6, 9),
        messageId: 'lunch-3@citusmail.test',
        subject: 'Lunch?',
        from: const MailAddress(localPart: 'maria', domain: 'citusmail.test'),
      ),
    ]);
    // "Trip to Lisbon" was sent from this device; its copy in Sent isn't
    // synced yet.
    store.receipts.requested(account.id, 'trip-2@citusmail.test');
  });

  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  var nextUid = 100;

  /// [text] arrives in the inbox (summary as sync stores it) with its body
  /// on the device.
  StoredMessage arrive(
    String text, {
    DateTime? receivedAt,
    MessageCategory category = MessageCategory.notifications,
  }) {
    final raw = Uint8List.fromList(
      utf8.encode(text.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n')),
    );
    final parsed = const MimeParser().parse(raw);
    final uid = nextUid++;
    store.messages.upsertSummaries(inbox.id, [
      MessageSummary(
        uid: uid,
        receivedAt:
            receivedAt ??
            (parsed.date?.utc ?? DateTime.utc(2026, 11, 6)).add(
              const Duration(seconds: 20),
            ),
        sentAt: parsed.date?.utc,
        messageId: parsed.messageId,
        inReplyTo: parsed.inReplyTo.firstOrNull,
        references: parsed.references,
        subject: parsed.subject,
        from: parsed.from.firstOrNull,
        size: raw.length,
        category: category,
        headers: {
          if (parsed.headers.value('content-type') case final type?)
            'content-type': [type],
        },
      ),
    ]);
    final message = store.messages.byUid(inbox.id, uid)!;
    store.messages.saveBody(message.id, raw, searchableText: '');
    return message;
  }

  int collect() => ReceiptCollector(store).readStored(account);

  List<(String, String)> receipts(String messageId) => [
    for (final r in store.receipts.forMessage(account.id, messageId))
      (r.recipient, r.disposition),
  ];

  test('Gmail: matched by In-Reply-To, read at the receipt\'s date', () {
    final report = arrive(gmailReceipt);
    expect(collect(), 1);
    final r = store.receipts.forMessage(account.id, 'plans-1@citusmail.test');
    expect(r.single.recipient, 'ana@northwind.example');
    expect(r.single.displayed, isTrue);
    expect(r.single.at, DateTime.utc(2026, 11, 6, 15, 42, 10));
    expect(
      store.receipts.reportFor(
        account.id,
        'plans-1@citusmail.test',
        'ana@northwind.example',
      ),
      report.id,
    );
    expect(store.receipts.unreadReports(inbox.id), isEmpty, reason: 'once');
    expect(collect(), 0);
  });

  test('Outlook: no thread headers, matched by Original-Message-ID', () {
    final report = arrive(outlookReceipt);
    expect(report.inReplyTo, isNull);
    expect(report.subject, 'Read: Quarterly plans');
    expect(collect(), 1);
    expect(receipts('plans-1@citusmail.test'), [
      ('ben@contoso.example', 'displayed'),
    ]);
  });

  test('Thunderbird: sent from this device, matched by In-Reply-To', () {
    final report = arrive(thunderbirdReceipt());
    expect(collect(), 1);
    expect(receipts('trip-2@citusmail.test'), [
      ('chloe@fastmail.example', 'displayed'),
    ]);
    expect(
      store.receipts.reportFor(
        account.id,
        'trip-2@citusmail.test',
        'chloe@fastmail.example',
      ),
      report.id,
    );
    // Its References also name an older message; that one didn't ask.
    expect(receipts('earlier-0@citusmail.test'), isEmpty);
  });

  test('without Original-Message-ID, References names the message', () {
    arrive(referencesOnlyReceipt);
    expect(collect(), 1);
    expect(receipts('plans-1@citusmail.test'), [
      ('dev@mobile.example', 'displayed'),
    ]);
  });

  test('several people read it: one receipt each', () {
    arrive(gmailReceipt);
    arrive(outlookReceipt);
    expect(collect(), 2);
    final got = store.receipts.forMessage(account.id, 'plans-1@citusmail.test');
    expect(got.map((r) => r.recipient), [
      'ana@northwind.example',
      'ben@contoso.example',
    ]);
    expect(got.every((r) => r.displayed), isTrue);
  });

  test('deleted unread: recorded, but not as read', () {
    arrive(thunderbirdReceipt(kind: 'deleted'));
    expect(collect(), 1);
    final r = store.receipts.forMessage(account.id, 'trip-2@citusmail.test');
    expect(r.single.disposition, 'deleted');
    expect(r.single.displayed, isFalse);
  });

  test('denied or failed: nothing recorded', () {
    for (final kind in ['denied', 'failed']) {
      arrive(thunderbirdReceipt(kind: kind));
    }
    expect(collect(), 0);
    expect(receipts('trip-2@citusmail.test'), isEmpty);
    expect(store.receipts.unreadReports(inbox.id), isEmpty, reason: 'read');
  });

  test('a receipt for mail that is not the user\'s, or did not ask', () {
    arrive(
      thunderbirdReceipt(
        original: 'newsletter-9@shop.example',
        subject: 'Weekly deals',
      ),
    );
    arrive(
      thunderbirdReceipt(original: 'lunch-3@citusmail.test', subject: 'Lunch?'),
    );
    expect(collect(), 0);
    expect(receipts('newsletter-9@shop.example'), isEmpty);
    expect(receipts('lunch-3@citusmail.test'), isEmpty);
    expect(store.receipts.unreadReports(inbox.id), isEmpty);
  });

  test('an email whose subject starts with "Read:" is not a receipt', () {
    final email = arrive(readColonEmail, category: MessageCategory.general);
    expect(store.receipts.unreadReports(inbox.id), isEmpty);
    expect(collect(), 0);
    expect(
      ReceiptCollector(store)
          .read(account, email, store.messages.body(email.id)!),
      isNull,
    );
    expect(receipts('plans-1@citusmail.test'), isEmpty);
  });

  test('a receipt dated later than it arrived is read when it arrived', () {
    arrive(gmailReceipt, receivedAt: DateTime.utc(2026, 11, 6, 12));
    collect();
    expect(
      store.receipts.forMessage(account.id, 'plans-1@citusmail.test').single.at,
      DateTime.utc(2026, 11, 6, 12),
    );
  });

  test('reports read by the old matcher are read once more', () {
    final report = arrive(referencesOnlyReceipt);
    store.receipts.markReportRead(report.id); // the old one couldn't
    expect(collect(), 1);
    store.receipts.markReportRead(report.id);
    expect(store.receipts.unreadReports(inbox.id), isEmpty);
    expect(collect(), 0, reason: 'only once');
  });

  test('receipts are never announced as new mail', () {
    final tracker = NewMailTracker(store);
    store.mailboxes.saveSyncState(
      inbox.id,
      const MailboxSyncState(uidValidity: 7),
    );
    expect(tracker.claim(account.id).isEmpty, isTrue, reason: 'sets the mark');
    arrive(gmailReceipt);
    arrive(outlookReceipt);
    arrive(readColonEmail, category: MessageCategory.general);
    final announced = tracker.claim(account.id);
    expect(announced.messages.map((m) => m.subject), [
      'Read: The Midnight Library - notes for Thursday',
    ]);
  });
}
