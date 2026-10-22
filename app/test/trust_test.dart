// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmail/src/ui/fmail_theme.dart';
import 'package:fmail/src/ui/mail_shell.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

const _authResults =
    'mail.fmail.test; spf=pass smtp.mailfrom=x.example; dmarc=pass header.from=x.example';

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  /// Adds a message to the inbox with [fixture] as its body. Ten older
  /// messages carry the server's Authentication-Results, so most of the
  /// inbox has it and the app learns to trust `mail.fmail.test`.
  void seed(String fixture, {required String subject, required int uid}) {
    final store = app.store;
    final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
    final raw = File('../test-data/mail/$fixture').readAsBytesSync();
    final parsed = const MimeParser().parse(raw);
    store.messages.upsertSummaries(inbox.id, [
      for (var i = 0; i < 10; i++)
        MessageSummary(
          uid: 50 + i,
          receivedAt: DateTime.utc(2026, 9, 1, i),
          subject: 'Older $i',
          from: const MailAddress(localPart: 'old', domain: 'x.example'),
          flags: MessageFlags.fromImap([r'\Seen']),
          headers: const {
            'authentication-results': [_authResults],
          },
        ),
      MessageSummary(
        uid: uid,
        receivedAt: DateTime.utc(2026, 10, 21),
        subject: subject,
        from: parsed.from.first,
        headers: {
          'authentication-results': [
            for (final f in parsed.headers.all('authentication-results'))
              f.value,
          ],
        },
      ),
    ]);
    final id = store.messages.byUid(inbox.id, uid)!.id;
    store.messages.saveBody(
      id,
      Uint8List.fromList(
        String.fromCharCodes(raw).replaceAll('\n', '\r\n').codeUnits,
      ),
      searchableText: subject,
    );
  }

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: FmailTheme.light(),
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

  Future<void> open(WidgetTester tester, String subject) async {
    await tester.tap(find.text(subject));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('a phishing message gets a red warning and guarded links', (
    tester,
  ) async {
    seed(
      'security/phishing-link-mismatch.eml',
      subject: 'Your account has been limited',
      uid: 70,
    );
    await show(tester);
    await open(tester, 'Your account has been limited');

    expect(find.text('This message may be a scam'), findsOneWidget);
    expect(
      find.textContaining('couldn\'t confirm this came from mailbox.example'),
      findsOneWidget,
    );
    expect(find.textContaining('calls itself PayPal'), findsOneWidget);

    final link = find
        .textContaining('https://www.paypal.com/signin', findRichText: true)
        .last;
    await tester.tapAt(tester.getTopLeft(link) + const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.text('Open this link anyway?'), findsOneWidget);
    expect(
      find.textContaining(
        'shows www.paypal.com but goes to paypa1-login.example',
      ),
      findsOneWidget,
    );
    expect(find.text('Open anyway'), findsOneWidget);
    await tester.tap(find.text('Don\'t open'));
    await tester.pumpAndSettle();
    expect(find.text('Open this link anyway?'), findsNothing);
  });

  testWidgets('a risky attachment asks before saving', (tester) async {
    seed('security/risky-attachments.eml', subject: 'Overdue invoice', uid: 71);
    await show(tester);
    await open(tester, 'Overdue invoice');

    expect(find.text('This message may be a scam'), findsOneWidget);
    await tester.tap(find.textContaining('invoice.pdf.exe ·'));
    await tester.pumpAndSettle();
    expect(find.text('Save this file anyway?'), findsOneWidget);
    expect(find.textContaining('Pretends to be a .pdf'), findsWidgets);
    await tester.tap(find.text('Don\'t save'));
    await tester.pumpAndSettle();
    expect(find.text('Save this file anyway?'), findsNothing);
    expect(find.textContaining('Saved to'), findsNothing);
  });

  testWidgets('ordinary mail shows no warning', (tester) async {
    await show(tester);
    await open(tester, 'Hello there');
    expect(find.text('This message may be a scam'), findsNothing);
    expect(find.text('Be careful with this message'), findsNothing);
  });
}
