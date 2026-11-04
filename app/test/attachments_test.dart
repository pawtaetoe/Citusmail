// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';
import 'dart:typed_data';

import 'package:citusmail/src/ui/attachments_page.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_trust/mail_trust.dart';
import 'package:mail_view/mail_view.dart';

import 'support/sample_files.dart';
import 'support/test_app.dart';

void main() {
  late TestApp app;
  setUp(() async {
    app = await TestApp.create();
    app.seedFiles();
  });
  tearDown(() => app.dispose());

  /// Lets isolates (reading downloaded messages) finish.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> openPage(
    WidgetTester tester, {
    Size size = const Size(1400, 2000),
  }) async {
    tester.view.physicalSize = size;
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
    if (size.width < 600) {
      await tester.tap(find.byTooltip('Folders'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Attachments'));
    await tester.pump();
    await settle(tester);
    await tester.pumpAndSettle();
  }

  /// File names in the list, top to bottom.
  List<String> listed(WidgetTester tester) => [
    for (final e in tester.widgetList<Text>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Text &&
              w.style?.fontWeight == FontWeight.w600 &&
              w.data != null,
        ),
      ),
    ))
      e.data!,
  ];

  testWidgets('every file people sent, newest first, with filters', (
    tester,
  ) async {
    await openPage(tester);

    expect(listed(tester), [
      'Lease agreement - Flat 4.pdf',
      'Beach.png', // read from the downloaded message
      'Sunset.png',
      'Q3 budget.xlsx',
      'invite.ics',
      'Statement 2026-10.pdf',
      'Contract draft v3.docx',
      'Changes since v2.pdf',
      'Autumn catalogue.pdf',
      'invoice.pdf.exe',
      'Tax return 2025.pdf', // in Archive
      'Receipts 2025.zip',
    ]);
    // Not the signature logos, not Junk.
    expect(find.text('image001.png'), findsNothing);
    expect(find.text('logo.png'), findsNothing);
    expect(find.text('claim form.pdf'), findsNothing);
    // Sender, size and subject.
    expect(find.textContaining('292 KB · Harbour Lettings'), findsOneWidget);
    expect(find.text('Lease for Flat 4, ready to sign'), findsOneWidget);
    // The risky file says so.
    expect(
      find.byTooltip(RiskyFiles.check('invoice.pdf.exe')!.reason),
      findsOneWidget,
    );
    // The email whose files are unknown is offered for a lookup.
    expect(find.textContaining('1 older email has files'), findsOneWidget);

    await tester.tap(find.text('PDFs'));
    await settle(tester);
    expect(listed(tester), [
      'Lease agreement - Flat 4.pdf',
      'Statement 2026-10.pdf',
      'Changes since v2.pdf',
      'Autumn catalogue.pdf',
      'Tax return 2025.pdf',
    ]);

    await tester.tap(find.text('From people'));
    await settle(tester);
    expect(listed(tester), [
      'Lease agreement - Flat 4.pdf',
      'Changes since v2.pdf',
      'Tax return 2025.pdf',
    ]);

    await tester.tap(find.text('Images'));
    await settle(tester);
    expect(listed(tester), ['Beach.png', 'Sunset.png']);
    // Photos on the device show as pictures.
    expect(find.byType(Image), findsNWidgets(2));

    await tester.tap(find.text('Spreadsheets'));
    await settle(tester);
    expect(listed(tester), ['Q3 budget.xlsx']);

    await tester.tap(find.text('Other'));
    await tester.tap(find.text('From people'));
    await settle(tester);
    expect(listed(tester), [
      'invite.ics',
      'invoice.pdf.exe',
      'Receipts 2025.zip',
    ]);

    await tester.tap(find.text('All'));
    await tester.tap(find.text('Documents'));
    await settle(tester);
    expect(listed(tester), ['Contract draft v3.docx']);
    await tester.tap(find.text('All'));
    await settle(tester);

    // Search by file name, sender or subject.
    Future<List<String>> search(String text) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump(const Duration(milliseconds: 300));
      await settle(tester);
      return listed(tester);
    }

    expect(await search('lease'), ['Lease agreement - Flat 4.pdf']);
    expect(await search('northbank'), ['Statement 2026-10.pdf']);
    expect(await search('contract review'), [
      'Contract draft v3.docx',
      'Changes since v2.pdf',
    ]);
    expect(await search('2025'), ['Tax return 2025.pdf', 'Receipts 2025.zip']);
    expect(await search('sunset'), ['Sunset.png']);
    // Junk stays out of search too.
    await search('claim');
    expect(find.text('claim form.pdf'), findsNothing);
    expect(find.text('No matching files'), findsOneWidget);
  });

  testWidgets('a file opens its email in place; it can be left out', (
    tester,
  ) async {
    await openPage(tester);
    await tester.tap(find.text('Beach.png'));
    await settle(tester);
    await tester.pumpAndSettle();

    // The email, with the file on top.
    expect(find.byType(AttachmentsPage), findsNothing);
    expect(find.text('Here are the photos from Saturday!'), findsOneWidget);
    expect(find.text('Beach.png'), findsWidgets);
    expect(find.text('Save'), findsOneWidget);

    await tester.pageBack();
    await settle(tester);
    await tester.pumpAndSettle();
    expect(find.byType(AttachmentsPage), findsOneWidget);

    // "Don't list this file", with Undo.
    await tester.tap(find.text('Q3 budget.xlsx'));
    await settle(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Don\'t list this file'));
    await settle(tester);
    await tester.pumpAndSettle();
    expect(find.text('Q3 budget.xlsx'), findsNothing);
    expect(find.text('Q3 budget.xlsx won\'t be listed'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect(find.text('Q3 budget.xlsx'), findsOneWidget);
  });

  testWidgets('saving: risky files ask first; offline says so', (tester) async {
    // Downloaded before names were kept, with a macro document.
    final inbox = app.store.mailboxes.inbox(
      app.store.accounts.all().single.id,
    )!;
    app.store.messages.upsertSummaries(inbox.id, [
      MessageSummary(
        uid: 500,
        receivedAt: DateTime.utc(2026, 9, 1),
        subject: 'Payment overdue',
        from: const MailAddress(
          localPart: 'billing',
          domain: 'invoices.example',
        ),
        hasAttachments: true,
      ),
    ]);
    final fixture = File('../test-data/mail/security/risky-attachments.eml');
    app.store.messages.saveBody(
      app.store.messages.byUid(inbox.id, 500)!.id,
      Uint8List.fromList(
        fixture.readAsStringSync().replaceAll('\n', '\r\n').codeUnits,
      ),
      searchableText: '',
    );
    await openPage(tester);

    // Not on the device, and the server can't be reached.
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('Lease agreement - Flat 4.pdf'),
          matching: find.byType(InkWell),
        ),
        matching: find.byIcon(Icons.download_outlined),
      ),
    );
    await settle(tester);
    expect(
      find.textContaining('Couldn\'t download this email'),
      findsOneWidget,
    );
    // Saving never marks it read.
    final lease = app.store.messages
        .withAttachments(header: FilePart.storedHeader)
        .firstWhere((r) => r.message.subject!.startsWith('Lease'))
        .message;
    expect(lease.flags.seen, isFalse);

    // On the device but risky: the usual warning, "Don't save" first.
    await tester.enterText(find.byType(TextField), 'docm');
    await tester.pump(const Duration(milliseconds: 300));
    await settle(tester);
    expect(find.text('terms.docm'), findsOneWidget);
    await tester.tap(find.byTooltip('Save to Downloads'));
    await settle(tester);
    await tester.pumpAndSettle();
    expect(find.text('Save this file anyway?'), findsOneWidget);
    expect(
      find.textContaining('This document can contain macros'),
      findsOneWidget,
    );
    await tester.tap(find.text('Don\'t save'));
    await tester.pumpAndSettle();
    expect(find.text('Save this file anyway?'), findsNothing);
    expect(find.textContaining('Saved to'), findsNothing);
  });

  testWidgets('phones reach it from the menu; search sits at the bottom', (
    tester,
  ) async {
    await openPage(tester, size: const Size(390, 844));
    expect(find.text('Lease agreement - Flat 4.pdf'), findsOneWidget);
    final field = tester.getRect(find.byType(TextField));
    expect(field.bottom, greaterThan(844 - 140));
  });

  testWidgets('looking up unknown files: offline keeps the offer', (
    tester,
  ) async {
    await openPage(tester);
    await tester.tap(find.text('List their files'));
    await settle(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('couldn\'t be reached'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
}
