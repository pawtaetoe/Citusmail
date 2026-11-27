// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'test_app.dart';

/// A store the size of a busy user's: five accounts and tens of thousands
/// of emails over two years, spread over the inbox, Archive, Sent, Junk,
/// Trash and a folder of their own, with the bodies of a few hundred
/// downloaded (one of them a very large HTML newsletter). Made-up mail
/// only, the same every time ([seed]).
///
/// The inboxes have mail from people (some the user wrote to, so the
/// Important section has mail), newsletters with a List-Id, notifications
/// (shipping, receipts, bookings, renewals: what the "Found in your mail"
/// pages look for), verification codes, a few read receipts, pins and
/// unread mail, mostly recent.
final class BigMailbox {
  BigMailbox._(this.store, this.now);

  final MailStore store;
  final DateTime now;

  /// Stored messages, by folder kind, over every account.
  int stored = 0;

  /// The downloaded bodies.
  int bodies = 0;

  /// A very large HTML newsletter (downloaded), in the first inbox.
  late final StoredMessage largeHtml;

  /// The accounts, the test app's own first.
  late final List<Account> accounts;

  static const _people = [
    'John Smith', 'Mary Müller', 'Ahmed Garcia', 'Sofia Nowak', //
    'Lukas Rossi', 'Chen Dubois', 'Priya Kowalski', 'Olga Johansson',
    'Pierre Silva', 'Fatima Novak', 'Kenji Haddad', 'Maria Tanaka',
    'David Okafor', 'Anna Murphy', 'Jürgen Jensen', 'Zoë Kim',
    'Mateo Patel', 'Emma Ivanova', 'Noah Costa', 'Ingrid Fischer',
    'Rahul Brown', 'Ewa Lopez', 'Tomás Smith', 'Leila Müller',
  ];

  static const _companies = [
    'amazon', 'paypal', 'github', 'airbnb', 'spotify', 'netflix', //
    'dropbox', 'linkedin', 'zalando', 'ikea', 'lufthansa', 'deutschebahn',
    'shopee', 'ebay', 'booking', 'uber', 'apple', 'google', 'adobe',
    'notion', 'figma', 'slack', 'zoom', 'etsy',
  ];

  static const _words =
      'your order invoice receive delivery update meeting project report '
      'account payment receipt welcome reminder weekly newsletter schedule '
      'shipping confirmed password security request review question holiday '
      'flight booking ticket dinner tomorrow monday friday notes budget '
      'contract quarterly results team office parcel tracking statement '
      'subscription renewal offer discount photos family birthday party '
      'agenda minutes draft proposal feedback interview application support '
      'issue release version launch summer winter school garden kitchen '
      'travel museum concert library bicycle mountain river coffee';

  static const _notices = [
    'Your order #{n} has shipped',
    'Your parcel is out for delivery',
    'Your receipt from {c}',
    'Your invoice for {m}',
    'Booking confirmation: {w} trip',
    'Your appointment reminder for {m}',
    'Your subscription renews soon',
    'Payment received, thank you',
    'Security alert for your account',
    'Your weekly {w} report',
    'New sign-in to your account',
    'Your {c} statement is ready',
  ];

  /// Adds [perAccount] messages to each of [accountCount] accounts (the
  /// test app's own first): about 32,000 by default.
  static BigMailbox seed(
    TestApp app, {
    required DateTime now,
    int accountCount = 5,
    int perAccount = 6400,
    int bodyCount = 300,
    int seed = 1,
  }) {
    final big = BigMailbox._(app.store, now);
    big._seed(accountCount, perAccount, bodyCount, Random(seed));
    return big;
  }

  void _seed(int accountCount, int perAccount, int bodyCount, Random random) {
    final first = store.accounts.all().single;
    const names = ['bob', 'carol', 'dave', 'erin', 'frank', 'grace'];
    accounts = [
      first,
      for (var i = 0; i < accountCount - 1; i++)
        _addAccount('${names[i]}@${names[i]}.example'),
    ];
    String word() {
      final words = _words.split(' ');
      return words[(pow(random.nextDouble(), 2) * words.length).floor()];
    }

    String words(int n) => [for (var i = 0; i < n; i++) word()].join(' ');
    T pick<T>(List<T> list) => list[random.nextInt(list.length)];
    MailAddress person(String name) => MailAddress(
      displayName: name,
      localPart: name.toLowerCase().replaceAll(' ', '.'),
      domain: '${name.split(' ').last.toLowerCase()}.example',
    );
    MailAddress company(String c, String local) => MailAddress(
      displayName: c[0].toUpperCase() + c.substring(1),
      localPart: local,
      domain: '$c.example',
    );

    final withBodies = <(MessageId, String, MailAddress)>[];
    for (final (a, account) in accounts.indexed) {
      final boxes = store.mailboxes.forAccount(account.id);
      StoredMailbox? box(String name) =>
          boxes.where((b) => b.encodedName == name).firstOrNull;
      final own = MailAddress(
        localPart: account.email.split('@').first,
        domain: account.email.split('@').last,
      );
      // Share of each folder, in thousandths of the account's mail.
      final folders = <(StoredMailbox, int)>[
        (box('INBOX')!, 560),
        (box('Archive')!, 280),
        (box('Sent')!, 95),
        (box('Junk')!, 25),
        (box('Trash') ?? box('Projects')!, 25),
        (box('Projects')!, 15),
      ];
      final written = {for (var i = 0; i < 8; i++) _people[(a * 5 + i) % 24]};
      var uid = 1000;
      for (final (folder, share) in folders) {
        final count = perAccount * share ~/ 1000;
        final isInbox = folder.encodedName == 'INBOX';
        final isSent = folder.specialUse == SpecialUse.sent;
        final summaries = <MessageSummary>[];
        for (var i = 0; i < count; i++) {
          // Newest last; more mail lately than two years ago.
          final age = Duration(
            minutes: (pow((count - i) / count, 1.6) * 2 * 365 * 24 * 60)
                .round(),
          );
          final at = now.subtract(age);
          final recent = age < const Duration(days: 3);
          final roll = random.nextInt(100);
          final kind = isSent
              ? 'sent'
              : roll < 35
              ? 'person'
              : roll < 65
              ? 'newsletter'
              : roll < 95
              ? 'notice'
              : 'code';
          final c = pick(_companies);
          final n = 100000 + random.nextInt(900000);
          final from = switch (kind) {
            'sent' => own,
            'person' => person(pick(_people)),
            'newsletter' => company(c, 'news'),
            _ => company(c, 'noreply'),
          };
          final subject = switch (kind) {
            'sent' || 'person' => words(3 + random.nextInt(6)),
            'newsletter' => '${from.displayName} weekly: ${words(4)}',
            'code' => 'Your verification code is $n',
            _ =>
              pick(_notices)
                  .replaceAll('{n}', '$n')
                  .replaceAll('{c}', from.displayName!)
                  .replaceAll('{m}', pick(['May', 'June', 'July', 'March']))
                  .replaceAll('{w}', word()),
          };
          final seen =
              isSent || !isInbox || random.nextInt(100) < (recent ? 40 : 96);
          final pinned = random.nextInt(100) < 2;
          final receipt = isInbox && kind == 'notice' && i % 400 == 7;
          summaries.add(
            MessageSummary(
              uid: uid++,
              receivedAt: at,
              messageId: 'g$uid.$a@gen.example',
              subject: subject,
              from: from,
              to: [if (isSent) person(pick(written.toList())) else own],
              snippet: words(12 + random.nextInt(10)),
              size: 2000 + random.nextInt(80000),
              listId: kind == 'newsletter' ? 'news.$c.example' : null,
              category: switch (kind) {
                'newsletter' => MessageCategory.newsletters,
                'notice' => MessageCategory.notifications,
                'code' => MessageCategory.codes,
                _ => MessageCategory.general,
              },
              code: kind == 'code' ? '$n' : null,
              hasAttachments: random.nextInt(100) < 8,
              flags: MessageFlags.fromImap([
                if (seen) r'\Seen',
                if (pinned) r'\Flagged',
              ]),
              headers: {
                if (isInbox && i > count - 300)
                  'authentication-results': [
                    _authResults(account.email.split('@').last, from.domain),
                  ],
                if (kind == 'newsletter')
                  'list-unsubscribe': ['<https://${from.domain}/unsub/$n>'],
                if (receipt)
                  'content-type': [
                    'multipart/report; report-type=disposition-notification',
                  ],
              },
            ),
          );
        }
        for (var start = 0; start < summaries.length; start += 500) {
          store.messages.upsertSummaries(
            folder.id,
            summaries.sublist(start, min(start + 500, summaries.length)),
          );
        }
        stored += summaries.length;
        if (isInbox) {
          // The newest mail of each kind has been opened or read ahead.
          final share = bodyCount ~/ accounts.length;
          final listed = store.messages.list(
            MessageQuery(mailboxIds: [folder.id], limit: share * 3),
          );
          for (final m in listed.where((m) => m.uid % 3 == 0).take(share)) {
            withBodies.add((m.id, m.subject ?? '', m.from!));
          }
        }
      }
    }
    store.transaction(() {
      for (final (i, (id, subject, from)) in withBodies.indexed) {
        final html = _html(subject, random, paragraphs: 8 + i % 40);
        store.messages.saveBody(
          id,
          _raw(from, subject, html),
          searchableText: words(80),
        );
        bodies++;
      }
    });
    // A very large newsletter, newest in the first inbox.
    final inbox = store.mailboxes.inbox(accounts.first.id)!;
    final from = company('zalando', 'news');
    store.messages.upsertSummaries(inbox.id, [
      MessageSummary(
        uid: 99999,
        receivedAt: now.subtract(const Duration(minutes: 5)),
        messageId: 'large@gen.example',
        subject: 'Zalando weekly: the big summer sale',
        from: from,
        listId: 'news.zalando.example',
        category: MessageCategory.newsletters,
        size: 1500000,
        snippet: 'Up to 70% off',
      ),
    ]);
    largeHtml = store.messages.byUid(inbox.id, 99999)!;
    store.messages.saveBody(
      largeHtml.id,
      _raw(from, largeHtml.subject!, _html('Sale', random, paragraphs: 2500)),
      searchableText: 'summer sale',
    );
    bodies++;
    stored++;
  }

  static String _authResults(String server, String domain) =>
      'mx.$server; spf=pass smtp.mailfrom=$domain; dkim=pass '
      'header.d=$domain; dmarc=pass header.from=$domain';

  Account _addAccount(String email) {
    final host = 'mail.${email.split('@').last}';
    final account = store.accounts.add(
      NewAccount(
        email: email,
        username: email,
        imap: ServerSettings(
          host: host,
          port: 993,
          security: ConnectionSecurity.implicitTls,
        ),
        smtp: ServerSettings(
          host: host,
          port: 465,
          security: ConnectionSecurity.implicitTls,
        ),
      ),
    );
    final boxes = store.mailboxes.replaceAll(account.id, [
      for (final (name, use) in const [
        ('INBOX', null),
        ('Drafts', r'\Drafts'),
        ('Sent', r'\Sent'),
        ('Archive', r'\Archive'),
        ('Junk', r'\Junk'),
        ('Trash', r'\Trash'),
        ('Projects', null),
      ])
        ImapMailboxInfo(encodedName: name, delimiter: '/', attributes: {?use}),
    ]);
    for (final b in boxes) {
      store.mailboxes.saveSyncState(
        b.id,
        const MailboxSyncState(uidValidity: 1, uidNext: 100000),
      );
    }
    return account;
  }

  /// A newsletter-like HTML body: tables, styled text, images and links.
  static String _html(String title, Random random, {required int paragraphs}) {
    final b = StringBuffer(
      '<!DOCTYPE html><html><head><style>td{padding:4px}'
      '.x{color:#333}</style></head><body><table width="600">',
    );
    b.write(
      '<tr><td><h1 class="x">${htmlEscape.convert(title)}</h1></td></tr>',
    );
    for (var i = 0; i < paragraphs; i++) {
      b
        ..write('<tr><td style="font-family:Arial;font-size:14px">')
        ..write('<img src="https://img.example/p$i.jpg" width="560" ')
        ..write('height="200" alt="Picture $i">')
        ..write('<p>Paragraph $i: ')
        ..write(
          List.generate(
            30 + random.nextInt(30),
            (j) => j.isEven ? 'lorem' : 'ipsum dolor',
          ).join(' '),
        )
        ..write(' <a href="https://shop.example/item/$i?utm_source=mail">')
        ..write('See item $i</a></p>')
        ..write('<img src="https://track.example/o/$i.gif" width="1" ')
        ..write('height="1"></td></tr>');
    }
    b.write('</table></body></html>');
    return b.toString();
  }

  static Uint8List _raw(MailAddress from, String subject, String html) =>
      Uint8List.fromList(
        utf8.encode(
          'From: ${from.displayName} <${from.address}>\r\n'
          'To: someone@citusmail.test\r\n'
          'Subject: $subject\r\n'
          'MIME-Version: 1.0\r\n'
          'Content-Type: text/html; charset=utf-8\r\n'
          '\r\n'
          '${html.replaceAll('\n', '\r\n')}\r\n',
        ),
      );
}
