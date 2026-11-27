// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Gmail mail archived before a device was added is only in All Mail,
// which is not synced in the background. The full sync fills it in:
// pinned (starred) mail first, then the rest, newest first, a batch a
// sync, back to what the user keeps on the device.

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
  late DateTime now;

  final today = DateTime.now().toUtc();
  DateTime daysAgo(int days) => today.subtract(Duration(days: days));

  Future<void> start({bool gmail = true}) async {
    server = await FakeImap.start(condstore: true, gmail: gmail)
      ..filterDates = true;
    server.folders
      ..['[Gmail]/All Mail'] = FakeFolder(specialUse: 'All')
      ..['[Gmail]/Sent Mail'] = FakeFolder(specialUse: 'Sent')
      ..['[Gmail]/Starred'] = FakeFolder(specialUse: 'Flagged')
      ..['[Gmail]/Spam'] = FakeFolder(specialUse: 'Junk')
      ..['[Gmail]/Trash'] = FakeFolder(specialUse: 'Trash')
      ..['Travel'] = FakeFolder();
    directory = Directory.systemTemp.createTempSync('archived_backfill_test');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
    account = server.addAccount(store);
    now = today;
    // Keep three months on the device.
    KeepMail.setting.write(store.settings, KeepMail.threeMonths);
  }

  tearDown(() async {
    store.close();
    await server.close();
    directory.deleteSync(recursive: true);
  });

  FakeFolder folder(String name) => server.folders[name]!;
  String? subjectOf(FakeMessage m) =>
      RegExp(r'Subject: (.*)\r')
          .firstMatch(String.fromCharCodes(m.raw))
          ?.group(1);

  /// A message in Gmail: always in All Mail, and also in each of [labels]
  /// (INBOX, Travel, Spam...), with the same Message-ID.
  FakeMessage mail(
    String subject, {
    required int daysOld,
    List<String> labels = const [],
    bool starred = false,
  }) {
    final id = '${subject.toLowerCase().replaceAll(' ', '-')}@x.example';
    final flags = {if (starred) r'\Flagged'};
    for (final label in labels) {
      folder(label).add(
        subject: subject,
        messageId: id,
        date: daysAgo(daysOld),
        flags: flags,
      );
    }
    return folder('[Gmail]/All Mail').add(
      subject: subject,
      messageId: id,
      date: daysAgo(daysOld),
      flags: flags,
    );
  }

  AccountSynchronizer synchronizer({int perSync = 2}) => AccountSynchronizer(
    store,
    server.connector(),
    MailboxSynchronizer(
      store,
      const SummaryMapper(HeaderRuleClassifier()),
      settings: SyncSettings(initialWindow: 50, backfillBatch: perSync),
    ),
    OutboxReplayer(store),
    now: () => now,
  );

  StoredMailbox mailbox(SpecialUse use) =>
      store.mailboxes.bySpecialUse(account.id, use)!;
  StoredMailbox named(String name) => store.mailboxes
      .forAccount(account.id)
      .firstWhere((m) => m.encodedName == name);
  List<String> subjectsIn(StoredMailbox m) => [
    for (final s in store.messages.list(
      MessageQuery(mailboxIds: [m.id], limit: 500),
    ))
      s.subject!,
  ];
  List<String> pins() => [
    for (final s in store.messages.list(
      const MessageQuery(flaggedOnly: true, limit: 500),
    ))
      s.subject!,
  ];

  /// How many rows each Message-ID has on the device.
  Map<String, int> rows() {
    final counts = <String, int>{};
    for (final m in store.mailboxes.forAccount(account.id)) {
      for (final s in store.messages.list(
        MessageQuery(mailboxIds: [m.id], limit: 500),
      )) {
        counts[s.messageId!] = (counts[s.messageId!] ?? 0) + 1;
      }
    }
    return counts;
  }

  /// The Gmail mailbox of the bug: a Singapore Airlines booking from
  /// March, archived and starred before this device was set up.
  void seed() {
    mail('Ancient receipt', daysOld: 200); // older than three months
    mail('Your redemption booking', daysOld: 80, starred: true);
    mail('Hotel in Lisbon', daysOld: 70, starred: true);
    mail('Train tickets', daysOld: 60, labels: ['Travel']);
    mail('Old newsletter', daysOld: 50);
    mail('Receipt', daysOld: 40);
    mail('Dinner photos', daysOld: 30);
    mail('Sent reply', daysOld: 20, labels: ['[Gmail]/Sent Mail']);
    mail('Junk offer', daysOld: 15, labels: ['[Gmail]/Spam']);
    mail('Lunch today', daysOld: 1, labels: ['INBOX']);
  }

  test('a new device gets archived mail: pinned first, newest first, '
      'a batch a sync, back to the keep date', () async {
    await start();
    seed();
    final sync = synchronizer();
    StoredMailbox allMail() => mailbox(SpecialUse.all);

    // First sync: the folders, and the pinned archived mail.
    var report = await sync.sync(account);
    expect(subjectsIn(named('INBOX')), ['Lunch today']);
    expect(subjectsIn(allMail()), [
      'Hotel in Lisbon',
      'Your redemption booking',
    ]);
    expect(pins(), ['Hotel in Lisbon', 'Your redemption booking']);
    expect(report.archived?.stored, 2);
    expect(report.archived?.complete, isFalse);
    expect(
      store.messages.search('redemption booking').map((m) => m.mailboxId),
      [allMail().id],
    );

    // Then the rest, newest first: two a sync.
    report = await sync.sync(account);
    expect(subjectsIn(allMail()).take(2), ['Dinner photos', 'Receipt']);
    expect(report.archived?.stored, 2);

    // "Train tickets" is in the Travel folder already: looked at, not
    // stored again.
    report = await sync.sync(account);
    expect(report.archived?.stored, 1);
    expect(report.archived?.complete, isTrue);
    expect(subjectsIn(allMail()), [
      'Dinner photos',
      'Receipt',
      'Old newsletter',
      'Hotel in Lisbon',
      'Your redemption booking',
    ]);

    // Nothing is stored twice, and nothing else is stored: not inbox,
    // sent or spam mail, nor what is older than the keep date.
    expect(rows().values.toSet(), {1});
    expect(rows(), isNot(contains('ancient-receipt@x.example')));
    expect(subjectsIn(named('Travel')), ['Train tickets']);
    expect(subjectsIn(named('[Gmail]/Spam')), ['Junk offer']);

    // Summaries only: no message body was downloaded.
    final fetches = server.since(0, 'UID FETCH');
    expect(fetches, isNotEmpty);
    for (final f in fetches) {
      expect(f, isNot(contains('BODY.PEEK[]')));
      expect(f, isNot(contains('BODY.PEEK[TEXT]')));
    }

    // Complete: a later sync only looks for mail archived since.
    final mark = server.commands.length;
    report = await sync.sync(account);
    expect(report.archived?.stored, 0);
    expect(server.since(mark, 'UID SEARCH'), isEmpty);

    // Keeping a year: the older mail follows.
    KeepMail.setting.write(store.settings, KeepMail.year);
    report = await sync.sync(account);
    expect(report.archived?.stored, 1);
    expect(subjectsIn(allMail()), contains('Ancient receipt'));
    await sync.sync(account);
    expect(rows().values.toSet(), {1});

    // A message filled in opens like any other (All Mail itself was never
    // opened).
    final booking = store.messages.search('redemption booking').single;
    final imap = await server.connector().imap(account);
    final body = await MessageLoader(store).load(imap, booking.id);
    expect(String.fromCharCodes(body), contains('Subject: Your redemption'));
    await imap.logout();
  });

  test('mail that arrives and is archived while the device is away is '
      'filled in too', () async {
    await start();
    seed();
    final sync = synchronizer(perSync: 50);
    var report = await sync.sync(account);
    expect(report.archived?.complete, isTrue);

    // Skips the inbox (a Gmail filter), so this device never sees it
    // leave a folder.
    mail('Boarding pass', daysOld: 0);
    // Arrives in the inbox and stays there.
    mail('Meeting notes', daysOld: 0, labels: ['INBOX']);
    report = await sync.sync(account);
    expect(report.archived?.stored, 1);
    expect(subjectsIn(mailbox(SpecialUse.all)).first, 'Boarding pass');
    expect(subjectsIn(named('INBOX')), ['Meeting notes', 'Lunch today']);
    expect(rows().values.toSet(), {1});
  });

  test('pins and deletions on another device show here', () async {
    await start();
    seed();
    final archivedOnPhone = mail(
      'Visa approval',
      daysOld: 5,
      labels: ['INBOX'],
    );
    final sync = synchronizer(perSync: 50);
    await sync.sync(account);
    expect(subjectsIn(named('INBOX')), ['Lunch today', 'Visa approval']);

    // Archived on the phone: this device saw it leave the inbox.
    final inbox = folder('INBOX');
    inbox.remove(
      inbox.messages.firstWhere((m) => subjectOf(m) == 'Visa approval').uid,
    );
    await sync.sync(account);
    final allMail = mailbox(SpecialUse.all);
    expect(subjectsIn(allMail), contains('Visa approval'));
    expect(pins(), isNot(contains('Visa approval')));

    // Pinned, and another unpinned, on the phone.
    final onServer = folder('[Gmail]/All Mail');
    onServer.setFlags(archivedOnPhone.uid, {r'\Flagged'});
    final booking = onServer.messages.firstWhere(
      (m) => subjectOf(m) == 'Your redemption booking',
    );
    onServer.setFlags(booking.uid, {});
    final report = await sync.sync(account);
    expect(report.archived?.updated, 2);
    expect(pins(), ['Visa approval', 'Hotel in Lisbon']);

    // Deleted on the phone: gone from All Mail, so gone here (looked for
    // at most once an hour).
    onServer.remove(booking.uid);
    await sync.sync(account);
    expect(subjectsIn(allMail), contains('Your redemption booking'));
    now = now.add(const Duration(hours: 2));
    await sync.sync(account);
    expect(subjectsIn(allMail), isNot(contains('Your redemption booking')));
  });

  test('pinning here is not undone before it reaches the server', () async {
    await start();
    seed();
    final sync = synchronizer(perSync: 50);
    await sync.sync(account);
    final dinner = store.messages
        .list(MessageQuery(mailboxIds: [mailbox(SpecialUse.all).id]))
        .firstWhere((m) => m.subject == 'Dinner photos');
    MailActions(store).markFlagged([dinner]);
    expect(pins(), contains('Dinner photos'));
    await sync.sync(account);
    expect(pins(), contains('Dinner photos'));
    expect(
      folder('[Gmail]/All Mail').messages
          .firstWhere((m) => m.uid == dinner.uid)
          .flags,
      contains(r'\Flagged'),
    );
  });

  test('an account added before this version fills in on its next full '
      'sync', () async {
    // The older version did not know Gmail's search: same mailbox, served
    // without X-GM-EXT-1.
    await start(gmail: false);
    seed();
    await synchronizer().sync(account);
    expect(subjectsIn(mailbox(SpecialUse.all)), isEmpty);
    final folders = server.folders;
    await server.close();

    // Updated: the next full sync starts, without adding the account again.
    server = await FakeImap.start(condstore: true, gmail: true)
      ..filterDates = true;
    server.folders
      ..clear()
      ..addAll(folders);
    final report = await synchronizer().sync(account);
    expect(report.archived?.stored, 2);
    expect(pins(), ['Hotel in Lisbon', 'Your redemption booking']);
  });

  test(
    'a server with \\All but without Gmail\'s search is left as it was',
    () async {
      await start(gmail: false);
      seed();
      final sync = synchronizer();
      for (var i = 0; i < 3; i++) {
        final report = await sync.sync(account);
        expect(report.archived, isNull);
      }
      expect(subjectsIn(mailbox(SpecialUse.all)), isEmpty);
      expect(server.commands.where((c) => c.contains('X-GM-RAW')), isEmpty);
      expect(server.since(0, 'EXAMINE "[Gmail]/All Mail"'), isEmpty);
      expect(server.since(0, 'SELECT "[Gmail]/All Mail"'), isEmpty);
    },
  );

  test('when All Mail is reset on the server, it fills in again', () async {
    await start();
    seed();
    final sync = synchronizer(perSync: 50);
    await sync.sync(account);
    expect(subjectsIn(mailbox(SpecialUse.all)), hasLength(5));

    folder('[Gmail]/All Mail').uidValidity = 7;
    final report = await sync.sync(account);
    expect(report.archived?.stored, 5);
    expect(subjectsIn(mailbox(SpecialUse.all)), hasLength(5));
    expect(rows().values.toSet(), {1});
  });
}
