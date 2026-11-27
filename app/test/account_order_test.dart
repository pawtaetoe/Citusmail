// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/core/theme/citusmail_theme.dart';
import 'package:citusmail/src/features/compose/ui/compose_page.dart';
import 'package:citusmail/src/features/inbox/state/mail_controller.dart';
import 'package:citusmail/src/features/inbox/ui/mail_shell.dart';
import 'package:citusmail/src/features/inbox/ui/sidebar.dart';
import 'package:citusmail/src/features/settings/state/setting_id.dart';
import 'package:citusmail/src/features/settings/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

/// The user puts their accounts in an order: the sidebar, the From choice
/// and new messages (from the top account) follow it.
void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  Account addBob() {
    final bob = app.store.accounts.add(
      NewAccount(
        email: 'bob@citusmail.test',
        username: 'bob@citusmail.test',
        imap: ServerSettings(
          host: 'mail.citusmail.test',
          port: 993,
          security: ConnectionSecurity.implicitTls,
        ),
        smtp: ServerSettings(
          host: 'mail.citusmail.test',
          port: 465,
          security: ConnectionSecurity.implicitTls,
        ),
      ),
    );
    app.store.mailboxes.replaceAll(bob.id, [
      ImapMailboxInfo(
        encodedName: 'INBOX',
        delimiter: '/',
        attributes: const {},
      ),
    ]);
    return bob;
  }

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

  double topInSidebar(WidgetTester tester, String text) => tester
      .getTopLeft(
        find
            .descendant(of: find.byType(Sidebar), matching: find.text(text))
            .first,
      )
      .dy;

  testWidgets('the sidebar and a new message follow the order', (tester) async {
    final alice = app.store.accounts.all().single;
    final bob = addBob();
    app.store.accounts.reorder([bob.id, alice.id]);
    await show(tester);

    expect(
      topInSidebar(tester, 'bob@citusmail.test'),
      lessThan(topInSidebar(tester, 'alice@citusmail.test')),
    );

    // From the Smart Inbox (all accounts), a new message is from the top
    // account, and the From choice lists them in the same order.
    await tester.tap(find.byTooltip('New message (C)'));
    await tester.pumpAndSettle();
    final from = tester.widget<DropdownButton<AccountId>>(
      find.descendant(
        of: find.byType(ComposePage),
        matching: find.byType(DropdownButton<AccountId>),
      ),
    );
    expect(from.value, bob.id);
    expect([for (final item in from.items!) item.value], [bob.id, alice.id]);
    // Lets the draft's autosave run.
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('Settings: drag an account to the top', (tester) async {
    final alice = app.store.accounts.all().single;
    final bob = addBob();
    final controller = MailController(app.services);
    addTearDown(controller.dispose);
    var changes = 0;
    controller.accountsChanged.addListener(() => changes++);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: SettingsPage(
          services: app.services,
          controller: controller,
          isAndroid: false,
          show: SettingId.accounts,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Top account: new messages are sent from it'),
      findsOneWidget,
    );

    // Bob's handle, dragged above Alice.
    final handle = find.byTooltip('Drag to reorder bob@citusmail.test');
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(0, -150));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      [for (final a in app.store.accounts.all()) a.id],
      [bob.id, alice.id],
    );
    expect(changes, 1, reason: 'the sidebar is told');
  });
}
