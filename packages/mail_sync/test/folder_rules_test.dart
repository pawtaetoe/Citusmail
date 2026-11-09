// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

MailAddress a(String address) => MailAddress(
  localPart: address.split('@').first,
  domain: address.split('@').last,
);

ImapMailboxInfo folder(String name, {String delimiter = '/', String? use}) =>
    ImapMailboxInfo(
      encodedName: name,
      delimiter: delimiter,
      attributes: {if (use != null) '\\$use'},
    );

void main() {
  late Directory directory;
  late MailStore store;
  late Account account;
  late StoredMailbox inbox;
  late StoredMailbox receipts;
  late StoredMailbox lists;
  final ruleStart = DateTime.utc(2026, 10, 20);

  setUp(() {
    directory = Directory.systemTemp.createTempSync('folder_rules_test');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
    account = store.accounts.add(
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
      folder('INBOX'),
      folder('Receipts'),
      folder('Lists'),
    ]);
    for (final b in boxes) {
      store.mailboxes.saveSyncState(
        b.id,
        const MailboxSyncState(uidValidity: 1),
      );
    }
    inbox = boxes.firstWhere((b) => b.isInbox);
    receipts = boxes.firstWhere((b) => b.encodedName == 'Receipts');
    lists = boxes.firstWhere((b) => b.encodedName == 'Lists');
  });

  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  void receive(
    int uid,
    String from, {
    String subject = 'Hello',
    List<String> to = const ['alice@citusmail.test'],
    DateTime? at,
    String? messageId = '',
  }) => store.messages.upsertSummaries(inbox.id, [
    MessageSummary(
      uid: uid,
      receivedAt: at ?? DateTime.utc(2026, 10, 21, 0, uid),
      messageId: messageId == '' ? 'm$uid@x.example' : messageId,
      from: a(from),
      to: [for (final t in to) a(t)],
      subject: subject,
    ),
  ]);

  FolderRule rule(
    StoredMailbox target,
    RuleField field,
    String value, {
    bool existing = false,
  }) => store.folderRules.add(
    accountId: account.id,
    mailboxId: target.id,
    field: field,
    value: value,
    includeExisting: existing,
    now: ruleStart,
  );

  List<int> inInbox() => store.messages.uids(inbox.id);

  test('matching new inbox mail is moved and queued for the server', () {
    rule(receipts, RuleField.fromDomain, 'shop.example');
    rule(lists, RuleField.toAddress, 'alice+lists@citusmail.test');
    rule(receipts, RuleField.subject, 'RECEIPT');
    receive(1, 'orders@shop.example');
    receive(2, 'news@mail.shop.example'); // subdomain
    receive(3, 'bob@evilshop.example'); // look-alike: no
    receive(4, 'bob@x.example', to: ['alice+lists@citusmail.test']);
    receive(5, 'bob@x.example', subject: 'Your receipt #12');
    receive(6, 'carol@x.example');

    expect(FolderRuleApplier(store).apply(account), 4);
    expect(inInbox(), [3, 6]);
    final moves = store.outbox
        .all(account.id)
        .map((e) => e.action)
        .cast<MoveAction>();
    expect(
      {for (final m in moves) m.targetMailboxId: m.uids.toSet()},
      {
        receipts.id: {1, 2, 5},
        lists.id: {4},
      },
    );
  });

  test(
    'only mail from the rule\'s start, unless existing mail was included',
    () {
      rule(receipts, RuleField.fromAddress, 'orders@shop.example');
      receive(
        1,
        'orders@shop.example',
        at: ruleStart.subtract(const Duration(days: 1)),
      );
      receive(
        2,
        'orders@shop.example',
        at: ruleStart.add(const Duration(hours: 1)),
      );
      expect(FolderRuleApplier(store).apply(account), 1);
      expect(inInbox(), [1]);

      rule(
        receipts,
        RuleField.fromAddress,
        'orders@shop.example',
        existing: true,
      );
      expect(FolderRuleApplier(store).apply(account), 1);
      expect(inInbox(), isEmpty);
    },
  );

  test('a message a rule moved once stays where the user puts it', () {
    rule(receipts, RuleField.fromDomain, 'shop.example');
    receive(1, 'orders@shop.example');
    expect(FolderRuleApplier(store).apply(account), 1);
    // The user moves it back: it arrives in the inbox again (a new UID).
    receive(2, 'orders@shop.example', messageId: 'm1@x.example');
    expect(FolderRuleApplier(store).apply(account), 0);
    expect(inInbox(), [2]);
  });

  test('no rules, no Message-ID, or the first rule wins', () {
    receive(1, 'orders@shop.example');
    expect(FolderRuleApplier(store).apply(account), 0, reason: 'no rules');
    rule(lists, RuleField.fromDomain, 'shop.example');
    rule(receipts, RuleField.fromDomain, 'shop.example');
    receive(2, 'orders@shop.example', messageId: null);
    expect(FolderRuleApplier(store).apply(account), 1);
    expect(inInbox(), [2], reason: 'without a Message-ID it is left alone');
    final move = store.outbox.all(account.id).single.action as MoveAction;
    expect(move.targetMailboxId, lists.id, reason: 'the oldest rule wins');
  });

  group('new folder names', () {
    List<StoredMailbox> layout(List<ImapMailboxInfo> folders) {
      final other = store.accounts.add(
        NewAccount(
          email: 'x${folders.length}${folders.first.delimiter}@citusmail.test',
          username: 'x',
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
      return store.mailboxes.replaceAll(other.id, folders);
    }

    test('follow the server layout', () {
      final dovecot = layout([
        folder('INBOX'),
        folder('Sent', use: 'Sent'),
        folder('Archive'),
      ]);
      expect(FolderNames.newFolder(dovecot, 'Receipts'), 'Receipts');
      expect(
        FolderNames.newFolder(dovecot, 'Projects / 2026'),
        'Projects/2026',
      );
      expect(FolderNames.newFolder(dovecot, 'Café'), 'Caf&AOk-');

      final cpanel = layout([
        folder('INBOX', delimiter: '.'),
        folder('INBOX.Sent', delimiter: '.', use: 'Sent'),
        folder('INBOX.Archive', delimiter: '.'),
      ]);
      expect(FolderNames.newFolder(cpanel, 'Receipts'), 'INBOX.Receipts');
      expect(
        FolderNames.newFolder(cpanel, 'Projects/2026'),
        'INBOX.Projects.2026',
      );
    });

    test('unusable names are refused', () {
      final cpanel = layout([
        folder('INBOX', delimiter: '.'),
        folder('INBOX.Sent', delimiter: '.'),
      ]);
      for (final bad in [
        '',
        '  ',
        'a//b',
        'inbox',
        'with.dot',
        'star*',
        'per%cent',
        'tab\there',
        'x' * 101,
      ]) {
        expect(
          () => FolderNames.newFolder(cpanel, bad),
          throwsArgumentError,
          reason: bad,
        );
      }
    });
  });

  test('a pass looks only at mail that arrived since the last one', () {
    rule(receipts, RuleField.fromDomain, 'shop.example');
    receive(5, 'carol@x.example');
    expect(FolderRuleApplier(store).apply(account), 0);
    // Older mail downloaded later (a lower UID) waits for a pass over
    // everything, which the sync asks for after downloading older mail.
    receive(3, 'orders@shop.example');
    receive(6, 'orders@shop.example');
    expect(FolderRuleApplier(store).apply(account), 1);
    expect(inInbox(), [3, 5]);
    expect(FolderRuleApplier(store).apply(account, everything: true), 1);
    expect(inInbox(), [5]);
  });

  test('a changed rule looks at all mail since its start again', () {
    receive(1, 'orders@shop.example');
    rule(lists, RuleField.fromDomain, 'other.example');
    expect(FolderRuleApplier(store).apply(account), 0);
    rule(receipts, RuleField.fromDomain, 'shop.example');
    expect(FolderRuleApplier(store).apply(account), 1);
    expect(inInbox(), isEmpty);
  });

  group('InboxPass', () {
    final since = DateTime.utc(2026);
    List<int> uids(InboxPass pass) => [
      for (final m in pass.messages(since)) m.uid,
    ];

    test('everything first, then only new mail', () {
      receive(1, 'a@x.example');
      receive(2, 'b@x.example');
      final first = InboxPass.start(store, 'test', inbox, 'v1');
      expect(first.everything, isTrue);
      expect(uids(first), [2, 1]);
      first.finish();

      final second = InboxPass.start(store, 'test', inbox, 'v1');
      expect(second.everything, isFalse);
      expect(uids(second), isEmpty);
      second.finish();

      receive(3, 'c@x.example');
      receive(4, 'd@x.example', at: DateTime.utc(2025, 12, 31));
      final third = InboxPass.start(store, 'test', inbox, 'v1');
      expect(uids(third), [3], reason: 'received before the start: no');
      third.finish();
      expect(uids(InboxPass.start(store, 'test', inbox, 'v1')), isEmpty);
    });

    test('everything again when what it applies or the inbox changed', () {
      receive(1, 'a@x.example');
      InboxPass.start(store, 'test', inbox, 'v1').finish();
      expect(InboxPass.start(store, 'test', inbox, 'v2').everything, isTrue);
      expect(
        InboxPass.start(store, 'other', inbox, 'v1').everything,
        isTrue,
        reason: 'each kind of pass on its own',
      );
      expect(
        InboxPass.start(
          store,
          'test',
          inbox,
          'v1',
          everything: true,
        ).everything,
        isTrue,
      );
      store.mailboxes.saveSyncState(
        inbox.id,
        const MailboxSyncState(uidValidity: 2),
      );
      inbox = store.mailboxes.byId(inbox.id)!;
      expect(InboxPass.start(store, 'test', inbox, 'v1').everything, isTrue);
    });
  });
}
