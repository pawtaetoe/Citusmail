// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/compose/compose_controller.dart';
import 'package:citusmail/src/compose/compose_page.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/settings_page.dart';
import 'package:citusmail/src/ui/sign_offs_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_compose/mail_compose.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_view/mail_view.dart';

import 'support/test_app.dart';

const _bob = MailAddress(
  displayName: 'Bob Lee',
  localPart: 'bob',
  domain: 'harbour.example',
);

void main() {
  late TestApp app;
  late Account alice;
  late Account tommy;
  late SignOff work;
  late SignOff casual;
  late SignOff short;

  SignOffRepository signOffs() => app.store.signOffs;

  setUp(() async {
    app = await TestApp.create();
    alice = app.store.accounts.all().single;
    tommy = app.store.accounts.add(
      NewAccount(
        email: 'tommy@fluminaris.example',
        displayName: 'Tommy Kung',
        username: 'tommy',
        imap: ServerSettings(
          host: 'mail.fluminaris.example',
          port: 993,
          security: ConnectionSecurity.implicitTls,
        ),
        smtp: ServerSettings(
          host: 'mail.fluminaris.example',
          port: 465,
          security: ConnectionSecurity.implicitTls,
        ),
      ),
    );
    work = signOffs().add(
      name: 'Work',
      text: 'Best regards,\nTommy Kung\nFluminaris',
    );
    casual = signOffs().add(name: 'Casual', text: 'Cheers,\nTommy');
    short = signOffs().add(name: 'Short', text: '– T');
    signOffs().setDefaults(
      tommy.email,
      SignOffDefaults(
        newMail: work.id,
        repliesSameAsNew: false,
        replies: short.id,
        changedAt: DateTime.utc(2026, 11, 10),
      ),
    );
    signOffs().setDefaults(
      alice.email,
      SignOffDefaults(newMail: casual.id, changedAt: DateTime.utc(2026, 11)),
    );
  });
  tearDown(() => app.dispose());

  Draft reply() => Draft(
    accountId: tommy.id,
    to: const [_bob],
    subject: 'Re: Dock schedule',
    inReplyTo: 'dock-1@harbour.example',
    quote:
        'On Mon, 9 Nov 2026 at 10:02, Bob Lee <bob@harbour.example> wrote:\n'
        '> Can we move the delivery to Thursday?',
  );

  /// The text part of the message waiting in the Outbox.
  String sentText() {
    final view = MessageView.parse(app.store.outbox.sends().single.data!);
    expect(view.isHtml, isFalse, reason: 'plain text only, no HTML part');
    return view.message.textBody!.decodeText().text.trimRight();
  }

  group('while writing', () {
    test('a new message starts with the account\'s sign-off', () {
      final c = ComposeController(app.services, Draft(accountId: tommy.id));
      addTearDown(c.dispose);
      expect(c.signOff, work);
      expect(c.signOffChosen, isFalse);
      c.setBody('Hi Bob,\n\nThe invoice is attached.');
      expect(
        c.draft.text,
        'Hi Bob,\n\nThe invoice is attached.\n\n'
        'Best regards,\nTommy Kung\nFluminaris',
      );
    });

    test('a reply starts with the reply sign-off, above the quote', () {
      final c = ComposeController(app.services, reply());
      addTearDown(c.dispose);
      expect(c.signOff, short);
      c.setBody('Thursday works.');
      expect(
        c.draft.text,
        'Thursday works.\n\n– T\n\n'
        'On Mon, 9 Nov 2026 at 10:02, Bob Lee <bob@harbour.example> wrote:\n'
        '> Can we move the delivery to Thursday?',
      );
    });

    test('"same as new mail" replies with the new mail sign-off', () {
      final c = ComposeController(
        app.services,
        reply().copyWith(accountId: alice.id),
      );
      addTearDown(c.dispose);
      expect(c.signOff, casual);
    });

    test('choosing another replaces only the sign-off', () {
      final c = ComposeController(app.services, reply());
      addTearDown(c.dispose);
      c.setBody('Thursday works.\n\nBest regards,\nTommy Kung\nFluminaris');
      c.chooseSignOff(casual);
      expect(c.signOffChosen, isTrue);
      expect(
        c.draft.body,
        'Thursday works.\n\nBest regards,\nTommy Kung\nFluminaris',
        reason: 'what was typed is never touched, even when it looks alike',
      );
      expect(c.draft.text, contains('Fluminaris\n\nCheers,\nTommy\n\nOn Mon'));
      c.chooseSignOff(null);
      expect(c.signOff, isNull);
      expect(c.draft.text, isNot(contains('Cheers')));
      expect(c.draft.text, contains('Fluminaris\n\nOn Mon'));
    });

    test('another From account brings its sign-off, unless one was chosen', () {
      final c = ComposeController(app.services, Draft(accountId: tommy.id));
      addTearDown(c.dispose);
      expect(c.signOff, work);
      c.setAccount(alice.id);
      expect(c.signOff, casual);
      c.chooseSignOff(short);
      c.setAccount(tommy.id);
      expect(c.signOff, short, reason: 'chosen by hand');
    });

    test('an account without a default starts with none', () {
      signOffs().setDefaults(
        alice.email,
        SignOffDefaults(changedAt: DateTime.utc(2026, 11, 10)),
      );
      final c = ComposeController(app.services, Draft(accountId: alice.id));
      addTearDown(c.dispose);
      expect(c.signOff, isNull);
      expect(c.draft.text, isEmpty);
    });

    test('a new sign-off is saved for later, or used once', () {
      final c = ComposeController(app.services, Draft(accountId: tommy.id));
      addTearDown(c.dispose);
      final saved = c.writeSignOff(
        text: 'Warmly,\nTommy',
        name: 'Warm',
        separator: true,
      );
      expect(saved.isSaved, isTrue);
      expect(signOffs().all().map((s) => s.name), [
        'Work',
        'Casual',
        'Short',
        'Warm',
      ]);
      expect(c.draft.text, '-- \nWarmly,\nTommy');

      final once = c.writeSignOff(
        text: 'Thanks for the quick fix!\nT',
        save: false,
      );
      expect(once.isSaved, isFalse);
      expect(signOffs().all(), hasLength(4), reason: 'not kept');
      expect(c.signOff, once);
      expect(c.draft.text, 'Thanks for the quick fix!\nT');
    });

    test('a saved sign-off without a name is named by its first line', () {
      expect(
        ComposeController.defaultName('Kind regards,\nT'),
        'Kind regards,',
      );
      expect(ComposeController.defaultName('  '), 'Sign-off');
    });

    test('the sent message carries it', () {
      final c = ComposeController(app.services, Draft(accountId: tommy.id));
      addTearDown(c.dispose);
      c.to.add(_bob);
      c.setSubject('Invoice');
      c.setBody('Attached.');
      expect(c.send(), isA<ComposeSent>());
      expect(sentText(), 'Attached.\n\nBest regards,\nTommy Kung\nFluminaris');
    });

    test('Send later keeps it, also when taken back to edit', () {
      final c = ComposeController(app.services, reply());
      addTearDown(c.dispose);
      c.setBody('Thursday works.');
      c.chooseSignOff(casual);
      final now = DateTime.now();
      final sent = c.send(at: now.add(const Duration(days: 1)))! as ComposeSent;
      expect(sent.pending.scheduledFor, isNotNull);
      expect(sentText(), startsWith('Thursday works.\n\nCheers,\nTommy\n\nOn'));
      final scheduled = ScheduledSends(app.store, app.services.sender);
      final back = scheduled.edit(scheduled.all().single)!;
      final again = ComposeController(app.services, back);
      addTearDown(again.dispose);
      expect(again.signOff, casual);
      expect(again.signOffChosen, isTrue, reason: 'no default over it');
      expect(again.draft.body, 'Thursday works.');
    });

    test('a draft keeps its sign-off through the Drafts folder', () {
      final c = ComposeController(
        app.services,
        reply().copyWith(accountId: alice.id),
      );
      addTearDown(c.dispose);
      c.setBody('Thursday works.');
      c.chooseSignOff(work);
      expect(
        c.close(),
        isA<ComposeClosed>().having(
          (r) => r.outcome,
          'outcome',
          DraftOutcome.savedToServer,
        ),
      );
      // What went to the Drafts folder, as it comes back from there.
      final append = app.store.outbox
          .all(alice.id)
          .firstWhere((e) => e.action is AppendAction);
      final drafts = app.store.mailboxes.bySpecialUse(
        alice.id,
        SpecialUse.drafts,
      )!;
      final parsed = const MimeParser().parse(append.data!);
      app.store.messages.upsertSummaries(drafts.id, [
        MessageSummary(
          uid: 50,
          receivedAt: DateTime.utc(2026),
          messageId: parsed.messageId,
          flags: MessageFlags.fromImap([r'\Draft']),
        ),
      ]);
      final reopened = app.services.drafts.fromDraftsFolder(
        app.store.messages.byUid(drafts.id, 50)!,
        append.data!,
      );
      final again = ComposeController(app.services, reopened);
      addTearDown(again.dispose);
      expect(again.signOff, work, reason: 'not the account default');
      expect(again.draft.body, 'Thursday works.');
      expect(again.draft.quote, reply().quote);
    });

    test('after managing, the sign-off in use follows its edits', () {
      final c = ComposeController(app.services, Draft(accountId: tommy.id));
      addTearDown(c.dispose);
      signOffs().update(work.copyWith(text: 'Kind regards,\nTommy'));
      c.signOffsChanged();
      expect(c.signOff!.text, 'Kind regards,\nTommy');
      // Deleted: stays in this message as it was.
      signOffs().remove(work.id);
      c.signOffsChanged();
      expect(c.signOff!.isSaved, isFalse);
      expect(c.draft.text, 'Kind regards,\nTommy');
    });
  });

  group('compose window', () {
    Future<ComposeController> open(WidgetTester tester, Draft draft) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = ComposeController(app.services, draft);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: CitusmailTheme.light(),
          home: Scaffold(body: ComposePage(controller: c)),
        ),
      );
      await tester.pump();
      return c;
    }

    final chip = find.byKey(const ValueKey('compose-sign-off'));

    testWidgets('the sign-off is marked, and switched from its button', (
      tester,
    ) async {
      final c = await open(tester, reply());
      expect(find.text('Sign-off: Short'), findsOneWidget);
      expect(find.text('– T'), findsOneWidget);
      // Above the quote.
      expect(
        tester.getTopLeft(find.text('– T')).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('compose-quote'))).dy,
        ),
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Write your message'),
        'Thursday works.',
      );

      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(find.text('Write a new sign-off…'), findsOneWidget);
      expect(find.text('Manage sign-offs…'), findsOneWidget);
      await tester.tap(find.text('Work').last);
      await tester.pumpAndSettle();
      expect(find.text('Sign-off: Work'), findsOneWidget);
      expect(
        find.text('Best regards,\nTommy Kung\nFluminaris'),
        findsOneWidget,
      );
      expect(c.draft.body, 'Thursday works.');

      await tester.tap(chip);
      await tester.pumpAndSettle();
      await tester.tap(find.text('None').last);
      await tester.pumpAndSettle();
      expect(find.text('No sign-off'), findsOneWidget);
      expect(c.signOff, isNull);
      await tester.pump(const Duration(seconds: 3)); // autosave
    });

    testWidgets('"Write a new sign-off" for this email only', (tester) async {
      final c = await open(tester, Draft(accountId: tommy.id));
      await tester.tap(chip);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Write a new sign-off…'));
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('sign-off-save'));
      expect(tester.widget<CheckboxListTile>(save).value, isTrue);
      await tester.tap(save);
      await tester.pump();
      expect(find.byKey(const ValueKey('sign-off-name')), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('sign-off-text')),
        'Talk soon,\nTommy',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Use'));
      await tester.pumpAndSettle();
      expect(find.text('Sign-off: this email only'), findsOneWidget);
      expect(c.draft.text, 'Talk soon,\nTommy');
      expect(signOffs().all(), hasLength(3));

      // Saved for later: in the list, with its name.
      await tester.tap(chip);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Write a new sign-off…'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('sign-off-name')),
        'Friends',
      );
      await tester.enterText(
        find.byKey(const ValueKey('sign-off-text')),
        'Hugs,\nTommy',
      );
      await tester.tap(find.byKey(const ValueKey('sign-off-separator')));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Use'));
      await tester.pumpAndSettle();
      expect(find.text('Sign-off: Friends'), findsOneWidget);
      expect(signOffs().all().last.name, 'Friends');
      expect(c.draft.text, '-- \nHugs,\nTommy');
      await tester.pump(const Duration(seconds: 3)); // autosave
    });
  });

  group('Sign-offs page', () {
    Future<void> show(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: CitusmailTheme.light(),
          home: SignOffsPage(services: app.services),
        ),
      );
      await tester.pump();
    }

    testWidgets('reached from Settings, under Writing', (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: CitusmailTheme.light(),
          home: SettingsPage(services: app.services, isAndroid: false),
        ),
      );
      await tester.pump();
      final tile = find.text('Sign-offs');
      await tester.scrollUntilVisible(tile, 200);
      // The Writing group: in the list of groups and as its heading.
      expect(find.text('Writing'), findsWidgets);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(find.byType(SignOffsPage), findsOneWidget);
    });

    testWidgets('the first one, from an example with the user\'s name', (
      tester,
    ) async {
      for (final s in signOffs().all()) {
        signOffs().remove(s.id);
      }
      signOffs().setDefaults(
        alice.email,
        SignOffDefaults(changedAt: DateTime.utc(2026, 11, 10)),
      );
      signOffs().setDefaults(
        tommy.email,
        SignOffDefaults(changedAt: DateTime.utc(2026, 11, 10)),
      );
      await show(tester);
      expect(find.text('No sign-offs yet'), findsOneWidget);
      await tester.tap(find.text('Add your first sign-off'));
      await tester.pumpAndSettle();
      final text = tester.widget<TextField>(
        find.byKey(const ValueKey('sign-off-text')),
      );
      expect(text.controller!.text, 'Best regards,\nTommy Kung');
      await tester.enterText(
        find.byKey(const ValueKey('sign-off-name')),
        'Work',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      final added = signOffs().all().single;
      expect(added.name, 'Work');
      expect(find.text('Work'), findsWidgets);
      // The first one is every account's default.
      expect(signOffs().defaultFor(alice.email, reply: false), added);
      expect(signOffs().defaultFor(tommy.email, reply: true), added);
    });

    testWidgets('edit, delete with Undo, and each account\'s defaults', (
      tester,
    ) async {
      await show(tester);
      expect(
        find.text('Best regards,\nTommy Kung\nFluminaris'),
        findsOneWidget,
      );
      expect(find.text('Cheers,\nTommy'), findsOneWidget);

      // Edit.
      await tester.tap(find.text('Cheers,\nTommy'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('sign-off-text')),
        'Cheers!\nTommy',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(signOffs().byId(casual.id)!.text, 'Cheers!\nTommy');

      // Delete, then Undo.
      await tester.tap(find.byTooltip('More for Short'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(signOffs().byId(short.id), isNull);
      expect(find.text('Short'), findsNothing);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(signOffs().byId(short.id), isNotNull);

      // Tommy's replies: same as new mail.
      await tester.tap(
        find.byKey(const ValueKey('sign-off-replies-tommy@fluminaris.example')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Same as new mail').last);
      await tester.pumpAndSettle();
      expect(signOffs().defaultFor(tommy.email, reply: true), work);

      // Alice's new mail: none.
      await tester.tap(
        find.byKey(const ValueKey('sign-off-new-alice@citusmail.test')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('None').last);
      await tester.pumpAndSettle();
      expect(signOffs().defaultFor(alice.email, reply: false), isNull);
    });
  });
}
