// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Search on the device only sees stored mail. "Search on the server" asks
// the server, and stores the summaries of what it finds, so they open and
// pin like any other mail.

import 'dart:io';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

import 'support/fake_imap.dart';

void main() {
  final skip = FakeImap.skipReason;
  if (skip != null) {
    test('needs the test certificates', () {}, skip: skip);
    return;
  }

  late Directory directory;
  late MailStore store;
  late FakeImap server;
  late Account account;
  late SyncEngine engine;

  final today = DateTime.now().toUtc();
  DateTime daysAgo(int days) => today.subtract(Duration(days: days));

  Future<void> start({required bool gmail}) async {
    server = await FakeImap.start(condstore: true, gmail: gmail)
      ..filterDates = true;
    directory = Directory.systemTemp.createTempSync('server_search_test');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
    account = server.addAccount(store);
    KeepMail.setting.write(store.settings, KeepMail.threeMonths);
    engine = SyncEngine(
      store,
      server.connector(),
      classifier: const HeaderRuleClassifier(),
      settings: const SyncSettings(initialWindow: 5, backfillBatch: 5),
    );
  }

  tearDown(() async {
    await engine.dispose();
    store.close();
    await server.close();
    directory.deleteSync(recursive: true);
  });

  FakeFolder folder(String name) => server.folders[name]!;
  StoredMailbox named(String name) => store.mailboxes
      .forAccount(account.id)
      .firstWhere((m) => m.encodedName == name);
  List<String> subjects(Iterable<MessageId> ids) => [
    for (final id in ids) store.messages.byId(id)!.subject!,
  ];

  group('on Gmail', () {
    setUp(() async {
      await start(gmail: true);
      server.folders
        ..['[Gmail]/All Mail'] = FakeFolder(specialUse: 'All')
        ..['[Gmail]/Trash'] = FakeFolder(specialUse: 'Trash');
      // Archived long ago: older than the device keeps.
      folder('[Gmail]/All Mail').add(
        subject: 'Your redemption booking',
        messageId: 'sq@x.example',
        date: daysAgo(250),
      );
      for (final (i, subject) in ['Lunch', 'Booking a table'].indexed) {
        final id = 'inbox$i@x.example';
        final date = daysAgo(1 + i);
        folder('INBOX').add(subject: subject, messageId: id, date: date);
        folder('[Gmail]/All Mail')
            .add(subject: subject, messageId: id, date: date);
      }
    });

    test('finds archived mail that is not on the device; it opens and '
        'pins', () async {
      await engine.syncAccount(account.id);
      expect(store.messages.search('redemption'), isEmpty);

      final mark = server.commands.length;
      final found = await engine.searchServer(account.id, 'redemption booking');
      expect(subjects(found), ['Your redemption booking']);
      expect(server.since(mark, 'UID SEARCH'), [
        'UID SEARCH X-GM-RAW "redemption booking"',
      ]);
      // Stored in All Mail, once, and now found on the device too.
      final booking = store.messages.byId(found.single)!;
      final allMail = store.mailboxes.bySpecialUse(account.id, SpecialUse.all)!;
      expect(booking.mailboxId, allMail.id);
      expect(store.messages.search('redemption').map((m) => m.id), [
        booking.id,
      ]);
      // Summaries only: the body comes when it is opened.
      for (final f in server.since(mark, 'UID FETCH')) {
        expect(f, isNot(contains('BODY.PEEK[]')));
      }
      expect(store.messages.body(booking.id), isNull);

      final body = await engine.loadBody(booking.id);
      expect(String.fromCharCodes(body), contains('Your redemption booking'));

      MailActions(store).markFlagged([booking]);
      await engine.syncAccount(account.id);
      expect(
        folder('[Gmail]/All Mail').messages.first.flags,
        contains(r'\Flagged'),
      );
      expect(
        store.messages.list(const MessageQuery(flaggedOnly: true)).single.id,
        booking.id,
      );

      // Searching again stores nothing twice.
      final again = await engine.searchServer(account.id, 'redemption booking');
      expect(again, [booking.id]);
      expect(store.messages.uids(allMail.id), [1]);
    });

    test('what is on the device already is found where it is', () async {
      await engine.syncAccount(account.id);
      final found = await engine.searchServer(account.id, 'booking');
      // Newest first.
      expect(subjects(found), ['Booking a table', 'Your redemption booking']);
      expect(
        store.messages.byId(found.first)!.mailboxId,
        named('INBOX').id,
        reason: 'one row, in the inbox',
      );
      final allMail = store.mailboxes.bySpecialUse(account.id, SpecialUse.all)!;
      expect(store.messages.uids(allMail.id), [1]);
    });
  });

  group('elsewhere', () {
    setUp(() async {
      await start(gmail: false);
      server.folders['Archive'] = FakeFolder(specialUse: 'Archive');
    });

    test(
      'the inbox and Archive are searched, at most 50, newest first',
      () async {
        for (var i = 0; i < 60; i++) {
          folder('Archive')
              .add(subject: 'Invoice ${i + 1}', date: daysAgo(400 - i));
        }
        folder('INBOX')
          ..add(subject: 'Invoice from today', date: daysAgo(0))
          ..add(subject: 'Lunch', date: daysAgo(0));
        await engine.syncAccount(account.id);
        expect(store.messages.uids(named('Archive').id), hasLength(5));

        final mark = server.commands.length;
        final found = await engine.searchServer(account.id, 'invoice');
        expect(found, hasLength(ServerSearch.maxResults));
        expect(subjects(found).take(3), [
          'Invoice from today',
          'Invoice 60',
          'Invoice 59',
        ]);
        expect(subjects(found).last, 'Invoice 12');
        expect(server.since(mark, 'UID SEARCH'), [
          'UID SEARCH TEXT "invoice"',
          'UID SEARCH TEXT "invoice"',
        ]);
        expect(server.commands.where((c) => c.contains('X-GM-RAW')), isEmpty);
        // Stored where they are, once.
        expect(store.messages.uids(named('Archive').id), hasLength(49));
        final again = await engine.searchServer(account.id, 'invoice');
        expect(again, found);
        expect(store.messages.uids(named('Archive').id), hasLength(49));
      },
    );
  });

  test('offline, the search fails as a network problem', () async {
    await start(gmail: true);
    final offline = SyncEngine(store, const _Offline());
    addTearDown(offline.dispose);
    await expectLater(
      offline.searchServer(account.id, 'booking'),
      throwsA(isA<MailConnectionException>()),
    );
    expect(
      SyncFailure.from(const MailConnectionException('offline')).kind,
      SyncFailureKind.network,
    );
  });
}

final class _Offline implements MailConnector {
  const _Offline();

  @override
  Future<ImapClient> imap(Account account) async =>
      throw const MailConnectionException('offline (test)');

  @override
  Future<SmtpClient> smtp(Account account) async =>
      throw const MailConnectionException('offline (test)');

  @override
  Future<ManageSieveClient> sieve(Account account) async =>
      throw const MailConnectionException('offline (test)');
}
