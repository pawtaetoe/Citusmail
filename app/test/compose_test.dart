// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmail/src/compose/compose_page.dart';
import 'package:fmail/src/ui/fmail_theme.dart';
import 'package:fmail/src/ui/mail_shell.dart';
import 'package:mail_compose/mail_compose.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  int accountIdOf() => app.store.accounts.all().single.id;

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

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }

  Finder field(String hint) => find.widgetWithText(TextField, hint);

  /// The first address field of the compose window (not the search box
  /// behind it).
  Finder toField() => find
      .descendant(
        of: find.byType(ComposePage),
        matching: find.byType(TextField),
      )
      .first;

  testWidgets('write and send a new message, then undo it', (tester) async {
    await show(tester);
    await tester.tap(find.byTooltip('New message (C)'));
    await tester.pumpAndSettle();
    expect(find.text('New message'), findsOneWidget);

    // Typing an address and a comma makes a chip.
    await tester.enterText(toField(), 'Bob <bob@x.example>,');
    await tester.pump();
    expect(find.widgetWithText(InputChip, 'Bob'), findsOneWidget);
    await tester.enterText(field('Subject'), 'Plans');
    await tester.enterText(field('Write your message'), 'See you at 7.');
    await tester.tap(find.text('Send'));
    await tester.pump();

    expect(find.text('New message'), findsNothing, reason: 'window closed');
    expect(find.text('Sending…'), findsOneWidget);
    final queued = app.store.outbox.sends().single;
    expect(
      queued.notBefore.isAfter(DateTime.now()),
      isTrue,
      reason: 'undo window',
    );
    final sent = const MimeParser().parse(queued.data!);
    expect(sent.to.single.address, 'bob@x.example');
    expect(sent.subject, 'Plans');

    // Undo brings the message back into a compose window (once the notice
    // has slid in, as for a person).
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(app.store.outbox.sends(), isEmpty);
    expect(find.widgetWithText(InputChip, 'Bob'), findsOneWidget);
    final body = tester.widget<TextField>(field('Write your message'));
    expect(body.controller!.text, 'See you at 7.');
  });

  testWidgets('sending needs a recipient; a bad address is pointed out', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.byTooltip('New message (C)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send'));
    await tester.pump();
    expect(find.text('Add at least one recipient.'), findsOneWidget);

    await tester.enterText(toField(), 'not an address');
    await tester.tap(find.text('Send'));
    await tester.pump();
    expect(find.textContaining('Check the addresses'), findsOneWidget);
    expect(app.store.outbox.sends(), isEmpty);
    await tester.tap(find.byTooltip('Discard'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Discard'));
    await tester.pumpAndSettle();
  });

  testWidgets('closing keeps the draft in the Drafts folder', (tester) async {
    await show(tester);
    await tester.tap(find.byTooltip('New message (C)'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Subject'), 'Unfinished');
    await tester.tap(find.byTooltip('Close (keeps the draft)'));
    await tester.pumpAndSettle();
    expect(find.text('Saved to Drafts.'), findsOneWidget);
    final queued = app.store.outbox.all(accountIdOf()).single;
    expect(queued.action, isA<AppendAction>());
    expect(const MimeParser().parse(queued.data!).subject, 'Unfinished');
  });

  testWidgets('an empty new message is just dropped', (tester) async {
    await show(tester);
    await tester.tap(find.byTooltip('New message (C)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close (keeps the draft)'));
    await tester.pumpAndSettle();
    expect(find.text('Saved to Drafts.'), findsNothing);
    expect(app.store.outbox.all(accountIdOf()), isEmpty);
  });

  testWidgets('reply from the reader quotes and addresses the sender', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.text('Hello there'));
    await settle(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Reply'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, 'Stranger Danger'), findsOneWidget);
    expect(find.text('Re: Hello there'), findsWidgets);
    final body = tester.widget<TextField>(field('Write your message'));
    expect(body.controller!.text, contains('wrote:'));
    expect(body.controller!.text, contains('> Visible'));
  });

  testWidgets('a draft in the Drafts folder opens for editing', (tester) async {
    final drafts = app.store.mailboxes.bySpecialUse(
      accountIdOf(),
      SpecialUse.drafts,
    )!;
    final built = const OutgoingMessages().forDraftsFolder(
      Draft(
        accountId: accountIdOf(),
        to: const [MailAddress(localPart: 'carol', domain: 'x.example')],
        subject: 'Half done',
        body: 'Started this earlier',
      ),
      app.store.accounts.byId(accountIdOf())!,
    );
    app.store.messages.upsertSummaries(drafts.id, [
      MessageSummary(
        uid: 1,
        receivedAt: DateTime.utc(2026),
        subject: 'Half done',
        messageId: built.messageId,
        flags: MessageFlags.fromImap([r'\Draft', r'\Seen']),
      ),
    ]);
    final stored = app.store.messages.byUid(drafts.id, 1)!;
    app.store.messages.saveBody(stored.id, built.bytes, searchableText: '');

    await show(tester);
    await tester.tap(find.text('Drafts'));
    await tester.pump();
    await tester.tap(find.text('Half done'));
    await settle(tester);
    final body = tester.widget<TextField>(field('Write your message'));
    expect(body.controller!.text.trim(), 'Started this earlier');
    expect(find.widgetWithText(InputChip, 'carol@x.example'), findsOneWidget);
  });

  testWidgets('a failed send shows in the Outbox with Try again', (
    tester,
  ) async {
    final entry = app.store.outbox.enqueue(
      accountIdOf(),
      SendAction(from: 'alice@fmail.test', recipients: ['bob@x.example']),
      data: MessageBuilder()
          .build(
            OutgoingMessage(
              from: const MailAddress(localPart: 'alice', domain: 'fmail.test'),
              to: const [MailAddress(localPart: 'bob', domain: 'x.example')],
              subject: 'Refused one',
              textBody: 'x',
            ),
          )
          .bytes,
    );
    app.store.outbox.markFailed(entry.id, '550 mailbox unavailable');
    await show(tester);
    await tester.tap(find.text('Outbox'));
    await tester.pump();
    expect(find.text('Refused one'), findsOneWidget);
    expect(find.textContaining('550 mailbox unavailable'), findsOneWidget);
    await tester.tap(find.byTooltip('Try again'));
    await tester.pump();
    expect(app.store.outbox.byId(entry.id)!.state, OutboxState.pending);
  });
}
