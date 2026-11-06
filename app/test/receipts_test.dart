// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';
import 'dart:typed_data';

import 'package:citusmail/src/compose/compose_page.dart';
import 'package:citusmail/src/services/mail_notices.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  int accountId() => app.store.accounts.all().single.id;

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: MailShell(
          notifications: false,
          services: app.services,
          onAddAccount: () {},
          onAccountsChanged: () {},
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }

  /// "Final report", sent by alice asking for a receipt (fixture).
  void seedSentReport() {
    final sent = app.store.mailboxes.bySpecialUse(
      accountId(),
      SpecialUse.sent,
    )!;
    final raw = File('../test-data/mail/sent/report-with-receipt-request.eml')
        .readAsBytesSync();
    final parsed = const MimeParser().parse(raw);
    app.store.messages.upsertSummaries(sent.id, [
      MessageSummary(
        uid: 20,
        receivedAt: DateTime.utc(2026, 10, 19, 8),
        subject: parsed.subject,
        messageId: parsed.messageId,
        from: const MailAddress(localPart: 'alice', domain: 'citusmail.test'),
        flags: MessageFlags.fromImap([r'\Seen']),
        headers: {
          'disposition-notification-to': [
            parsed.headers.value('disposition-notification-to')!,
          ],
        },
      ),
    ]);
    final id = app.store.messages.byUid(sent.id, 20)!.id;
    app.store.messages.saveBody(
      id,
      Uint8List.fromList(
        String.fromCharCodes(raw).replaceAll('\n', '\r\n').codeUnits,
      ),
      searchableText: 'Final report',
    );
  }

  testWidgets('compose: asking for a read receipt is one visible toggle', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.byTooltip('New message (C)'));
    await tester.pumpAndSettle();
    final page = find.byType(ComposePage);
    expect(
      find.descendant(
        of: page,
        matching: find.byTooltip('Ask for a read receipt'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Ask for a read receipt'));
    await tester.pump();
    expect(
      find.byTooltip('Read receipt requested (tap to cancel)'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.mark_email_read), findsOneWidget);
    await tester.tap(find.byTooltip('Read receipt requested (tap to cancel)'));
    await tester.pump();
    expect(find.byTooltip('Ask for a read receipt'), findsOneWidget);
    await tester.tap(find.byTooltip('Close (keeps the draft)'));
    await settle(tester);
    await tester.pump(const Duration(seconds: 5));
  });

  /// Bob's receipt for "Final report" arrives in the inbox (fixture),
  /// read and linked as the receipt collector does.
  StoredMessage receiptArrives({String disposition = 'displayed'}) {
    final inbox = app.store.mailboxes.inbox(accountId())!;
    final raw = File('../test-data/mail/receipts/mdn-displayed.eml')
        .readAsBytesSync();
    app.store.messages.upsertSummaries(inbox.id, [
      MessageSummary(
        uid: 30,
        receivedAt: DateTime.utc(2026, 10, 19, 8, 46),
        subject: 'Read: Final report',
        messageId: 'mdn-1@citusmail.test',
        from: const MailAddress(
          displayName: 'Bob Example',
          localPart: 'bob',
          domain: 'citusmail.test',
        ),
        category: MessageCategory.notifications,
        headers: const {
          'content-type': [
            ('multipart/report; report-type=disposition-notification; '
                'boundary="mdn-boundary"'),
          ],
        },
      ),
    ]);
    final report = app.store.messages.byUid(inbox.id, 30)!;
    app.store.messages.saveBody(
      report.id,
      Uint8List.fromList(
        String.fromCharCodes(raw).replaceAll('\n', '\r\n').codeUnits,
      ),
      searchableText: 'has been displayed',
    );
    app.store.receipts.requested(accountId(), 'alice-report-1@citusmail.test');
    app.store.receipts.record(
      accountId(),
      'alice-report-1@citusmail.test',
      recipient: 'bob@citusmail.test',
      disposition: disposition,
      at: DateTime.utc(2026, 10, 19, 8, 45),
    );
    app.store.receipts.linkReport(
      accountId(),
      'alice-report-1@citusmail.test',
      recipient: 'bob@citusmail.test',
      reportId: report.id,
    );
    return report;
  }

  Future<void> openSent(WidgetTester tester, String subject) async {
    await tester.tap(find.text('Sent'));
    await tester.pump();
    await tester.tap(find.text(subject));
    await settle(tester);
  }

  testWidgets('sent mail: "No answer yet", then "Read on …"', (tester) async {
    seedSentReport();
    await show(tester);
    await openSent(tester, 'Final report');
    expect(find.textContaining('No answer yet'), findsOneWidget);
    expect(find.textContaining('Read on'), findsNothing);
    // Alice asked for the receipt herself: no "the sender asked" notice.
    expect(find.textContaining('The sender asked'), findsNothing);

    receiptArrives();
    await tester.tap(find.byTooltip('Close (Esc)'));
    await tester.pump();
    await tester.tap(find.text('Final report'));
    await settle(tester);
    expect(find.textContaining('No answer yet'), findsNothing);
    // One recipient: no name, just when.
    expect(
      find.textContaining(RegExp(r'^Read on Oct 1[89], ')),
      findsOneWidget,
    );
    expect(find.textContaining('Read by'), findsNothing);
  });

  testWidgets('tapping the line opens the receipt; Back returns', (
    tester,
  ) async {
    seedSentReport();
    receiptArrives();
    await show(tester);
    await openSent(tester, 'Final report');
    await tester.tap(find.textContaining('Read on'));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Read receipt'), findsOneWidget, reason: 'page title');
    expect(find.text('Read: Final report'), findsWidgets);
    expect(
      find.textContaining('has been displayed', findRichText: true),
      findsWidgets,
    );

    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(find.text('Read receipt'), findsNothing);
    expect(find.textContaining('Read on'), findsOneWidget);
  });

  testWidgets('several recipients: who read it, one line each', (tester) async {
    final sent = app.store.mailboxes.bySpecialUse(
      accountId(),
      SpecialUse.sent,
    )!;
    app.store.messages.upsertSummaries(sent.id, [
      MessageSummary(
        uid: 21,
        receivedAt: DateTime.utc(2026, 11, 6, 14, 10),
        subject: 'Quarterly plans',
        messageId: 'plans-1@citusmail.test',
        from: const MailAddress(localPart: 'alice', domain: 'citusmail.test'),
        to: const [
          MailAddress(
            displayName: 'Ana Silva',
            localPart: 'ana',
            domain: 'northwind.example',
          ),
          MailAddress(localPart: 'ben', domain: 'contoso.example'),
        ],
        cc: const [
          MailAddress(
            displayName: 'Chloe Martin',
            localPart: 'chloe',
            domain: 'fastmail.example',
          ),
        ],
        flags: MessageFlags.fromImap([r'\Seen']),
        headers: const {
          'disposition-notification-to': ['<alice@citusmail.test>'],
        },
      ),
    ]);
    const id = 'plans-1@citusmail.test';
    app.store.receipts.requested(accountId(), id);
    for (final (who, kind, minute) in [
      ('ana@northwind.example', 'displayed', 42),
      ('ben@contoso.example', 'displayed', 50),
      ('chloe@fastmail.example', 'deleted', 55),
    ]) {
      app.store.receipts.record(
        accountId(),
        id,
        recipient: who,
        disposition: kind,
        at: DateTime.utc(2026, 11, 6, 15, minute),
      );
    }
    await show(tester);
    await openSent(tester, 'Quarterly plans');
    expect(find.textContaining('Read by Ana Silva on Nov 6, '), findsOneWidget);
    expect(
      find.textContaining('Read by ben@contoso.example on Nov 6, '),
      findsOneWidget,
    );
    // Deleted unread: nothing, and no "no answer" either.
    expect(find.textContaining('Read by Chloe'), findsNothing);
    expect(find.textContaining('No answer yet'), findsNothing);
  });

  testWidgets('a receipt saying it was deleted unread shows nothing', (
    tester,
  ) async {
    seedSentReport();
    receiptArrives(disposition: 'deleted');
    await show(tester);
    await openSent(tester, 'Final report');
    expect(find.textContaining('Read on'), findsNothing);
    expect(find.textContaining('Read by'), findsNothing);
    expect(find.textContaining('No answer yet'), findsNothing);
  });

  testWidgets('receipts are not in the Notifications section', (tester) async {
    seedSentReport();
    receiptArrives();
    await show(tester);
    await tester.tap(find.text('Notifications'));
    await tester.pump();
    expect(find.text('Your parcel'), findsOneWidget);
    expect(find.text('Read: Final report'), findsNothing);
    expect(find.textContaining('Bob Example'), findsNothing);
    final counts = app.store.messages.sectionCounts();
    expect(counts[SmartSection.notifications]!.total, 1);
  });

  test('receipts never become new-mail notifications', () {
    final tracker = NewMailTracker(app.store);
    final account = app.store.accounts.all().single;
    expect(tracker.claim(account.id).isEmpty, isTrue, reason: 'sets the mark');
    seedSentReport();
    receiptArrives();
    final inbox = app.store.mailboxes.inbox(account.id)!;
    app.store.messages.upsertSummaries(inbox.id, [
      MessageSummary(
        uid: 31,
        receivedAt: DateTime.utc(2026, 10, 19, 9),
        subject: 'Your order has shipped',
        from: const MailAddress(localPart: 'noreply', domain: 'shop.example'),
        category: MessageCategory.notifications,
      ),
    ]);
    final mail = tracker.claim(account.id);
    expect(mail.messages.map((m) => m.subject), ['Your order has shipped']);
    final notices = MailNotices.build(
      account,
      mail,
      layout: NoticeLayout.grouped,
    );
    expect(
      notices.map((n) => '${n.title} ${n.body}'),
      everyElement(isNot(contains('Final report'))),
    );
  });

  testWidgets('mail from others never shows receipt status', (tester) async {
    await show(tester);
    await tester.tap(find.text('Hello there'));
    await settle(tester);
    expect(find.textContaining('Read receipt requested'), findsNothing);
  });
}
