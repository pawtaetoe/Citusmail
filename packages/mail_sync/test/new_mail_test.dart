// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late MailStore store;
  late Account account;
  late StoredMailbox inbox;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('new_mail_test');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
    account = store.accounts.add(
      NewAccount(
        email: 'alice@fmail.test',
        username: 'alice',
        imap: ServerSettings(
          host: 'h.example',
          port: 993,
          security: ConnectionSecurity.implicitTls,
        ),
        smtp: ServerSettings(
          host: 'h.example',
          port: 465,
          security: ConnectionSecurity.implicitTls,
        ),
      ),
    );
    inbox = store.mailboxes.replaceAll(account.id, [
      ImapMailboxInfo(
        encodedName: 'INBOX',
        delimiter: '/',
        attributes: const {},
      ),
    ]).single;
    store.mailboxes.saveSyncState(
      inbox.id,
      const MailboxSyncState(uidValidity: 7),
    );
  });

  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  void arrive(
    int uid, {
    MessageCategory category = MessageCategory.general,
    bool seen = false,
  }) => store.messages.upsertSummaries(inbox.id, [
    MessageSummary(
      uid: uid,
      receivedAt: DateTime.utc(2026, 10, 22, 0, uid),
      subject: 'm$uid',
      from: const MailAddress(localPart: 'bob', domain: 'x.example'),
      category: category,
      flags: seen ? MessageFlags.fromImap([r'\Seen']) : MessageFlags.none,
    ),
  ]);

  test('the first claim only sets the mark; later mail is announced once', () {
    final tracker = NewMailTracker(store);
    arrive(1);
    arrive(2);
    expect(tracker.claim(account.id).isEmpty, isTrue, reason: 'existing inbox');

    arrive(3);
    arrive(4, category: MessageCategory.newsletters);
    arrive(5, seen: true); // read on another device already
    arrive(6, category: MessageCategory.notifications);
    arrive(7);
    final first = tracker.claim(account.id);
    expect(first.messages.map((m) => m.subject), ['m3', 'm7']);
    expect(first.total, 2);

    // Another process claiming at the same time gets nothing.
    expect(NewMailTracker(store).claim(account.id).isEmpty, isTrue);
  });

  test('a reset inbox starts over without announcing everything', () {
    final tracker = NewMailTracker(store);
    arrive(1);
    tracker.claim(account.id);
    store.mailboxes.resetForUidValidity(inbox.id, 8);
    arrive(1);
    arrive(2);
    expect(tracker.claim(account.id).isEmpty, isTrue);
    arrive(3);
    expect(tracker.claim(account.id).messages.single.subject, 'm3');
  });

  test('many at once are capped, with the full count', () {
    final tracker = NewMailTracker(store);
    tracker.claim(account.id);
    for (var uid = 1; uid <= 30; uid++) {
      arrive(uid);
    }
    final claimed = tracker.claim(account.id);
    expect(claimed.total, 30);
    expect(claimed.messages, hasLength(NewMailTracker.maxMessages));
    expect(claimed.messages.last.subject, 'm30', reason: 'the newest are kept');
  });
}
