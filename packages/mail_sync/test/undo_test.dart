// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late MailStore store;
  late StoredMailbox inbox;
  late StoredMailbox archive;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('undo_test');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
    final account = store.accounts.add(
      NewAccount(
        email: 'alice@citusmail.test',
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
    final boxes = store.mailboxes.replaceAll(account.id, [
      ImapMailboxInfo(
        encodedName: 'INBOX',
        delimiter: '/',
        attributes: const {},
      ),
      ImapMailboxInfo(
        encodedName: 'Archive',
        delimiter: '/',
        attributes: const {r'\Archive'},
      ),
    ]);
    for (final b in boxes) {
      store.mailboxes.saveSyncState(
        b.id,
        const MailboxSyncState(uidValidity: 1),
      );
    }
    inbox = boxes.firstWhere((b) => b.isInbox);
    archive = boxes.firstWhere((b) => !b.isInbox);
    store.messages.upsertSummaries(inbox.id, [
      MessageSummary(
        uid: 5,
        receivedAt: DateTime.utc(2026),
        subject: 'Keep me',
        from: const MailAddress(
          displayName: 'Bob',
          localPart: 'bob',
          domain: 'x.example',
        ),
        to: const [MailAddress(localPart: 'alice', domain: 'citusmail.test')],
        headers: const {
          'list-id': ['<l.x.example>'],
        },
      ),
    ]);
    final id = store.messages.byUid(inbox.id, 5)!.id;
    store.messages.saveBody(
      id,
      Uint8List.fromList([1, 2, 3]),
      searchableText: 'unique words here',
    );
  });

  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  StoredMessage message() => store.messages.byUid(inbox.id, 5)!;

  test(
    'an archived message comes back exactly, and nothing reaches the server',
    () {
      final actions = MailActions(
        store,
        undoWindow: const Duration(seconds: 5),
      );
      final before = message();
      final receipt = actions.move([before], archive);
      expect(store.messages.byUid(inbox.id, 5), isNull);
      expect(
        store.outbox.due(before.accountId),
        isEmpty,
        reason: 'waits for the undo window',
      );

      expect(actions.undo(receipt), isTrue);
      final back = message();
      expect(back.id, before.id);
      expect(back.subject, 'Keep me');
      expect(
        store.messages.addresses(back.id, 'to').single.address,
        'alice@citusmail.test',
      );
      expect(store.messages.headers(back.id), {
        'list-id': ['<l.x.example>'],
      });
      expect(store.messages.body(back.id), [1, 2, 3]);
      expect(store.messages.search('unique words').single.id, back.id);
      expect(store.outbox.all(back.accountId), isEmpty);
    },
  );

  test('too late to undo once the change may be on its way', () {
    final actions = MailActions(store); // no window: goes with the next sync
    final receipt = actions.delete([message()]);
    expect(actions.undo(receipt), isFalse);
    expect(store.messages.byUid(inbox.id, 5), isNull);
  });

  test('flag changes undo by setting the flag back', () {
    final actions = MailActions(store);
    final receipt = actions.markFlagged([message()]);
    expect(message().flags.flagged, isTrue);
    expect(actions.undo(receipt), isTrue);
    expect(message().flags.flagged, isFalse);
    expect(message().section, SmartSection.general);
  });
}
