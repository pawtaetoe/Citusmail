// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmail/src/services/app_services.dart';
import 'package:fmail/src/services/secret_store.dart';
import 'package:fmail/src/ui/fmail_theme.dart';
import 'package:fmail/src/ui/mail_shell.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

/// No server is reachable: nothing in these tests touches the network.
final class _OfflineConnector implements MailConnector {
  const _OfflineConnector();

  @override
  Future<ImapClient> imap(Account account) async =>
      throw const MailConnectionException('offline (test)');

  @override
  Future<SmtpClient> smtp(Account account) async =>
      throw const MailConnectionException('offline (test)');
}

MailConnector _offline(CredentialProvider _) => const _OfflineConnector();

final class _MemorySecrets implements SecretStore {
  final _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

MailAddress _address(String a, [String? name]) => MailAddress(
  displayName: name,
  localPart: a.split('@').first,
  domain: a.split('@').last,
);

const _letter = '''From: Stranger Danger <stranger@x.example>
To: alice@fmail.test
Subject: Hello there
Content-Type: text/html; charset=utf-8

<p>Visible <b>body</b> text.</p>
<p><img src="https://tracker.example/p.gif" width="1" height="1"></p>
<p><a href="https://shop.example/deal">a link</a></p>
''';

void main() {
  late Directory directory;
  late AppServices services;
  late MailStore store;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('fmail_app_test');
    final path = '${directory.path}/mail.db';
    final key = DatabaseKey.generate();
    store = MailStore.open(path, key);
    final account = store.accounts.add(
      NewAccount(
        email: 'alice@fmail.test',
        username: 'alice@fmail.test',
        imap: ServerSettings(
          host: 'mail.fmail.test',
          port: 993,
          security: ConnectionSecurity.implicitTls,
        ),
        smtp: ServerSettings(
          host: 'mail.fmail.test',
          port: 465,
          security: ConnectionSecurity.implicitTls,
        ),
      ),
    );
    final boxes = store.mailboxes.replaceAll(account.id, [
      ImapMailboxInfo(
        encodedName: 'INBOX',
        delimiter: '/',
        attributes: const {},
      ),
      ImapMailboxInfo(
        encodedName: 'Sent',
        delimiter: '/',
        attributes: const {r'\Sent'},
      ),
      ImapMailboxInfo(
        encodedName: 'Archive',
        delimiter: '/',
        attributes: const {r'\Archive'},
      ),
      ImapMailboxInfo(
        encodedName: 'Projects',
        delimiter: '/',
        attributes: const {},
      ),
    ]);
    StoredMailbox box(String name) =>
        boxes.firstWhere((b) => b.encodedName == name);
    // As after a first sync: messages only exist in synced folders.
    for (final b in boxes) {
      store.mailboxes.saveSyncState(
        b.id,
        const MailboxSyncState(uidValidity: 1, uidNext: 100),
      );
    }
    store.messages.upsertSummaries(box('Sent').id, [
      MessageSummary(
        uid: 1,
        receivedAt: DateTime.utc(2026, 1),
        from: _address('alice@fmail.test'),
        to: [_address('carol@x.example')],
        flags: MessageFlags.fromImap([r'\Seen']),
      ),
    ]);
    DateTime at(int minute) => DateTime.utc(2026, 10, 20, 9, minute);
    store.messages.upsertSummaries(box('INBOX').id, [
      MessageSummary(
        uid: 1,
        receivedAt: at(1),
        subject: 'Hello there',
        from: _address('stranger@x.example', 'Stranger Danger'),
        snippet: 'Visible body text.',
      ),
      MessageSummary(
        uid: 2,
        receivedAt: at(2),
        subject: 'Lunch?',
        from: _address('carol@x.example', 'Carol'),
      ),
      MessageSummary(
        uid: 3,
        receivedAt: at(3),
        subject: 'Weekly deals',
        from: _address('news@shop.example', 'Shop'),
        category: MessageCategory.newsletters,
      ),
      MessageSummary(
        uid: 4,
        receivedAt: at(4),
        subject: 'Your parcel',
        from: _address('noreply@parcel.example', 'Parcel Co'),
        category: MessageCategory.notifications,
      ),
      MessageSummary(
        uid: 5,
        receivedAt: at(5),
        subject: 'Keep this',
        from: _address('dave@x.example', 'Dave'),
        flags: MessageFlags.fromImap([r'\Flagged', r'\Seen']),
      ),
    ]);
    final hello = store.messages.byUid(box('INBOX').id, 1)!;
    store.messages.saveBody(
      hello.id,
      utf8.encode(_letter.replaceAll('\n', '\r\n')),
      searchableText: 'Visible body text.',
    );
    final worker = await SyncWorker.spawn(
      SyncWorkerConfig(databasePath: path, key: key, connector: _offline),
      credentials: const _NoPassword(),
    );
    services = AppServices(store, _MemorySecrets(), worker);
  });

  tearDown(() async {
    await services.dispose();
    directory.deleteSync(recursive: true);
  });

  Future<void> show(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: FmailTheme.light(),
        home: MailShell(
          services: services,
          onAddAccount: () {},
          onAccountsChanged: () {},
        ),
      ),
    );
    await tester.pump();
  }

  /// Lets real isolates (worker, message parsing) finish.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('wide: sidebar, Smart Inbox sections, reader', (tester) async {
    await show(tester, const Size(1400, 900));

    // Sidebar.
    expect(find.text('Pins'), findsOneWidget);
    expect(find.text('Sent'), findsOneWidget);
    expect(find.text('Archive'), findsOneWidget);
    expect(find.text('Projects'), findsOneWidget);

    // Every section, in order, each message once.
    for (final title in [
      'Pinned',
      'Important',
      'General',
      'Notifications',
      'Newsletters',
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    double top(String text) => tester.getTopLeft(find.text(text).first).dy;
    expect(top('Pinned') < top('Important'), isTrue);
    expect(top('Important') < top('General'), isTrue);
    expect(top('Keep this') < top('Lunch?'), isTrue, reason: 'pinned first');
    expect(
      top('Lunch?') < top('Hello there'),
      isTrue,
      reason: 'Carol is important',
    );

    // Open a message: safe body, blocked tracker, unread dot gone.
    await tester.tap(find.text('Hello there'));
    await settle(tester);
    expect(find.textContaining('Visible', findRichText: true), findsWidgets);
    expect(find.textContaining('remote image was blocked'), findsOneWidget);
    expect(
      store.messages
          .list(const MessageQuery.inbox())
          .firstWhere((m) => m.subject == 'Hello there')
          .flags
          .seen,
      isTrue,
    );

    // A link asks before opening anything.
    // Tap on the words (the paragraph itself is as wide as the pane).
    final link = find.textContaining('a link', findRichText: true).last;
    await tester.tapAt(tester.getTopLeft(link) + const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.text('Open this link?'), findsOneWidget);
    expect(find.text('shop.example'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Pin from the reader moves it to Pinned.
    await tester.tap(find.byTooltip('Pin'));
    await tester.pump();
    expect(top('Hello there') < top('Important'), isTrue);
  });

  testWidgets('Classic shows one list; Show all opens a section', (
    tester,
  ) async {
    await show(tester, const Size(1400, 900));
    await tester.tap(find.text('Classic'));
    await tester.pump();
    expect(find.text('Pinned'), findsNothing);
    for (final subject in [
      'Hello there',
      'Lunch?',
      'Weekly deals',
      'Your parcel',
      'Keep this',
    ]) {
      expect(find.text(subject), findsOneWidget);
    }
    await tester.tap(find.text('Smart'));
    await tester.pump();
    await tester.tap(find.text('Newsletters'));
    await tester.pump();
    expect(find.byTooltip('Back to inbox'), findsOneWidget);
    expect(find.text('Weekly deals'), findsOneWidget);
    expect(find.text('Lunch?'), findsNothing);
  });

  testWidgets('narrow: one pane at a time, back returns to the list', (
    tester,
  ) async {
    await show(tester, const Size(400, 800));
    expect(find.text('Pins'), findsNothing, reason: 'sidebar is in the drawer');
    await tester.tap(find.text('Hello there'));
    await settle(tester);
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.text('Weekly deals'), findsNothing);
    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    expect(find.text('Weekly deals'), findsOneWidget);

    await tester.tap(find.byTooltip('Folders'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pins'));
    await tester.pumpAndSettle();
    expect(find.text('Keep this'), findsOneWidget);
    expect(find.text('Weekly deals'), findsNothing);
  });

  testWidgets('search finds stored mail', (tester) async {
    await show(tester, const Size(1400, 900));
    await tester.enterText(find.byType(TextField), 'parcel');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(find.text('Results for "parcel"'), findsOneWidget);
    expect(find.text('Your parcel'), findsOneWidget);
    expect(find.text('Lunch?'), findsNothing);
  });
}

final class _NoPassword implements CredentialProvider {
  const _NoPassword();

  @override
  Future<String> passwordFor(Account account) async => 'unused';
}
