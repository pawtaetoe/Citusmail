// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

/// On Gmail, All Mail and Starred hold copies of inbox mail. When mail
/// goes to Trash, Gmail drops those copies itself; the app must drop its
/// local ones too, or the stale copy keeps standing in for the message
/// (in the Clean up page, in search, in Pins) until All Mail is opened.
void main() {
  late Directory directory;
  late MailStore store;
  late StoredMailbox inbox;
  late StoredMailbox allMail;
  late StoredMailbox starred;
  late StoredMailbox trash;
  late StoredMailbox spam;

  final since = DateTime.utc(2026, 9);

  setUp(() {
    directory = Directory.systemTemp.createTempSync('gmail_copies_test');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
    final account = store.accounts.add(
      NewAccount(
        email: 'alice@gmail.test',
        username: 'alice',
        imap: ServerSettings(
          host: 'imap.gmail.test',
          port: 993,
          security: ConnectionSecurity.implicitTls,
        ),
        smtp: ServerSettings(
          host: 'smtp.gmail.test',
          port: 465,
          security: ConnectionSecurity.implicitTls,
        ),
      ),
    );
    ImapMailboxInfo folder(String name, [String? use]) => ImapMailboxInfo(
      encodedName: name,
      delimiter: '/',
      attributes: {if (use != null) '\\$use'},
    );
    final boxes = store.mailboxes.replaceAll(account.id, [
      folder('INBOX'),
      folder('[Gmail]/All Mail', 'All'),
      folder('[Gmail]/Starred', 'Flagged'),
      folder('[Gmail]/Trash', 'Trash'),
      folder('[Gmail]/Spam', 'Junk'),
    ]);
    for (final b in boxes) {
      store.mailboxes.saveSyncState(
        b.id,
        const MailboxSyncState(uidValidity: 1),
      );
    }
    StoredMailbox named(String name) =>
        boxes.firstWhere((b) => b.encodedName == name);
    inbox = named('INBOX');
    allMail = named('[Gmail]/All Mail');
    starred = named('[Gmail]/Starred');
    trash = named('[Gmail]/Trash');
    spam = named('[Gmail]/Spam');
    MessageSummary deal(int uid, String messageId) => MessageSummary(
      uid: uid,
      messageId: messageId,
      subject: 'Weekly deals',
      receivedAt: DateTime.utc(2026, 10, 2),
      from: const MailAddress(
        displayName: 'Shop',
        localPart: 'news',
        domain: 'shop.example',
      ),
    );
    store.messages
      ..upsertSummaries(inbox.id, [deal(7, 'deals@shop')])
      // Stored when All Mail and Starred were last opened.
      ..upsertSummaries(allMail.id, [deal(70, 'deals@shop')])
      ..upsertSummaries(starred.id, [deal(700, 'deals@shop')]);
  });

  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  List<String> senders() => [
    for (final s in store.messages.senderStats(since)) s.from.address,
  ];

  test('trashing inbox mail drops its local copies; Undo brings them back', () {
    expect(senders(), ['news@shop.example']);
    final actions = MailActions(store, undoWindow: const Duration(seconds: 5));

    final receipt = actions.delete([store.messages.byUid(inbox.id, 7)!]);
    expect(store.messages.uids(inbox.id), isEmpty);
    expect(store.messages.uids(allMail.id), isEmpty);
    expect(store.messages.uids(starred.id), isEmpty);
    expect(senders(), isEmpty, reason: 'no stale copy counts in its place');
    // One server change, for the inbox: Gmail drops the copies itself.
    final queued = store.outbox.all(inbox.accountId);
    expect(queued, hasLength(1));
    expect((queued.single.action as DeleteAction).mailboxId, inbox.id);

    expect(actions.undo(receipt), isTrue);
    expect(store.messages.uids(inbox.id), [7]);
    expect(store.messages.uids(allMail.id), [70]);
    expect(store.messages.uids(starred.id), [700]);
    expect(senders(), ['news@shop.example']);
    expect(store.outbox.all(inbox.accountId), isEmpty);
  });

  test('moving to Spam drops the copies; archiving keeps them', () {
    final actions = MailActions(store);
    actions.move([store.messages.byUid(inbox.id, 7)!], allMail);
    expect(store.messages.uids(allMail.id), [70]);
    expect(store.messages.uids(starred.id), [700]);

    store.messages.upsertSummaries(inbox.id, [
      MessageSummary(
        uid: 8,
        messageId: 'deals@shop',
        receivedAt: DateTime.utc(2026, 10, 2),
      ),
    ]);
    actions.move([store.messages.byUid(inbox.id, 8)!], spam);
    expect(store.messages.uids(allMail.id), isEmpty);
    expect(store.messages.uids(starred.id), isEmpty);
    expect(store.messages.uids(trash.id), isEmpty);
  });
}
