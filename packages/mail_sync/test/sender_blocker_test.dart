// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

MailAddress _a(String address) => MailAddress(
  localPart: address.split('@').first,
  domain: address.split('@').last,
);

ImapMailboxInfo _folder(String name, {String? use}) => ImapMailboxInfo(
  encodedName: name,
  delimiter: '.',
  attributes: {if (use != null) '\\$use'},
);

void main() {
  late Directory directory;
  late MailStore store;
  late Account account;
  late StoredMailbox inbox;
  final blockedAt = DateTime.utc(2026, 10, 20);

  Account addAccount(String email) => store.accounts.add(
    NewAccount(
      email: email,
      username: email,
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

  List<StoredMailbox> folders(Account account, List<ImapMailboxInfo> list) {
    final boxes = store.mailboxes.replaceAll(account.id, list);
    for (final b in boxes) {
      store.mailboxes.saveSyncState(
        b.id,
        const MailboxSyncState(uidValidity: 1),
      );
    }
    return boxes;
  }

  setUp(() {
    directory = Directory.systemTemp.createTempSync('sender_blocker_test');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
    account = addAccount('alice@fmail.test');
    // cPanel layout: Junk is INBOX.spam with \Junk; INBOX.Junk is a plain folder.
    inbox = folders(account, [
      _folder('INBOX'),
      _folder('INBOX.spam', use: 'Junk'),
      _folder('INBOX.Junk'),
      _folder('INBOX.Trash', use: 'Trash'),
    ]).firstWhere((b) => b.isInbox);
  });

  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  void receive(int uid, String from, {DateTime? at, String? messageId = ''}) =>
      store.messages.upsertSummaries(inbox.id, [
        MessageSummary(
          uid: uid,
          receivedAt: at ?? DateTime.utc(2026, 10, 21, 0, uid),
          messageId: messageId == '' ? 'm$uid@x.example' : messageId,
          from: _a(from),
        ),
      ]);

  List<MoveAction> moves() => store.outbox
      .all(account.id)
      .map((e) => e.action)
      .whereType<MoveAction>()
      .toList();

  test('new mail from blocked senders goes to Junk (by its flag)', () {
    store.blocks.block(BlockKind.address, 'news@shop.example', now: blockedAt);
    store.blocks.block(BlockKind.domain, 'spam.example', now: blockedAt);
    receive(1, 'news@shop.example');
    receive(2, 'other@shop.example'); // a different address: stays
    receive(3, 'x@mail.spam.example'); // subdomain of a blocked domain
    receive(4, 'x@notspam.example');

    expect(SenderBlocker(store).apply(account), 2);
    expect(store.messages.uids(inbox.id), [2, 4]);
    final junk = store.mailboxes.bySpecialUse(account.id, SpecialUse.junk)!;
    expect(junk.encodedName, 'INBOX.spam');
    expect(moves().single.targetMailboxId, junk.id);
    expect(moves().single.uids.toSet(), {1, 3});
  });

  test('older mail stays, and moved mail brought back stays', () {
    store.blocks.block(BlockKind.address, 'news@shop.example', now: blockedAt);
    receive(
      1,
      'news@shop.example',
      at: blockedAt.subtract(const Duration(days: 2)),
    );
    receive(2, 'news@shop.example');
    expect(SenderBlocker(store).apply(account), 1);
    expect(store.messages.uids(inbox.id), [1]);

    // The user moves it back: the server gives it a new UID in the inbox.
    receive(9, 'news@shop.example', messageId: 'm2@x.example');
    expect(SenderBlocker(store).apply(account), 0);
    expect(store.messages.uids(inbox.id), [1, 9]);
  });

  test('without Junk, blocked mail goes to Trash; without either, nowhere', () {
    folders(account, [_folder('INBOX'), _folder('INBOX.Trash', use: 'Trash')]);
    inbox = store.mailboxes.inbox(account.id)!;
    store.blocks.block(BlockKind.address, 'news@shop.example', now: blockedAt);
    receive(1, 'news@shop.example');
    expect(SenderBlocker(store).apply(account), 1);
    expect(
      moves().single.targetMailboxId,
      store.mailboxes.bySpecialUse(account.id, SpecialUse.trash)!.id,
    );

    final other = addAccount('bob@fmail.test');
    final otherInbox = folders(other, [_folder('INBOX')]).single;
    store.messages.upsertSummaries(otherInbox.id, [
      MessageSummary(
        uid: 1,
        receivedAt: DateTime.utc(2026, 10, 21),
        from: _a('news@shop.example'),
      ),
    ]);
    expect(SenderBlocker(store).apply(other), 0);
    expect(store.messages.uids(otherInbox.id), [1]);
  });

  test('blocked senders are never announced', () {
    final tracker = NewMailTracker(store);
    receive(1, 'carol@x.example');
    tracker.claim(account.id); // sets the mark
    store.blocks.block(BlockKind.domain, 'shop.example', now: blockedAt);
    receive(2, 'news@shop.example');
    receive(3, 'carol@x.example');
    expect(tracker.claim(account.id).messages.map((m) => m.uid), [3]);
  });
}
