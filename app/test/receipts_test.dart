// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';
import 'dart:typed_data';

import 'package:citusmail/src/compose/compose_page.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

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

  testWidgets('sent mail shows who read it, or that no one answered yet', (
    tester,
  ) async {
    seedSentReport();
    await show(tester);
    await tester.tap(find.text('Sent'));
    await tester.pump();
    await tester.tap(find.text('Final report'));
    await settle(tester);
    expect(find.textContaining('No answer yet'), findsOneWidget);

    app.store.receipts.requested(accountId(), 'alice-report-1@citusmail.test');
    app.store.receipts.record(
      accountId(),
      'alice-report-1@citusmail.test',
      recipient: 'bob@citusmail.test',
      disposition: 'displayed',
      at: DateTime.utc(2026, 10, 19, 8, 45),
    );
    await tester.tap(find.byTooltip('Close (Esc)'));
    await tester.pump();
    await tester.tap(find.text('Final report'));
    await settle(tester);
    expect(find.textContaining('Read by bob@citusmail.test'), findsOneWidget);
    expect(find.textContaining('No answer yet'), findsNothing);
  });

  testWidgets('mail from others never shows receipt status', (tester) async {
    await show(tester);
    await tester.tap(find.text('Hello there'));
    await settle(tester);
    expect(find.textContaining('Read receipt requested'), findsNothing);
  });
}
