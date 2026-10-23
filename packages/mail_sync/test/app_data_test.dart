// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:mail_appsync/mail_appsync.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

/// A device: its own store with the same account and folders.
final class _Device {
  _Device(String name) {
    directory = Directory.systemTemp.createTempSync('app_data_$name');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
    account = store.accounts.add(
      NewAccount(
        email: 'Carol@fmail.test',
        username: 'carol',
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
    store.mailboxes.replaceAll(account.id, [
      ImapMailboxInfo(
        encodedName: 'INBOX',
        delimiter: '.',
        attributes: const {},
      ),
      ImapMailboxInfo(
        encodedName: 'INBOX.Receipts',
        delimiter: '.',
        attributes: const {},
      ),
    ]);
    snapshotter = AppDataSnapshotter(store);
  }

  late final Directory directory;
  late final MailStore store;
  late final Account account;
  late final AppDataSnapshotter snapshotter;

  StoredMailbox get receipts => store.mailboxes
      .forAccount(account.id)
      .firstWhere((m) => m.encodedName == 'INBOX.Receipts');

  void close() {
    store.close();
    directory.deleteSync(recursive: true);
  }
}

/// What a real exchange does, without the server: merge both devices'
/// records and apply the result to each.
void _exchange(_Device a, _Device b) {
  final merged = SyncSnapshot.merge([
    SyncSnapshot(
      device: a.snapshotter.device,
      createdAt: 0,
      records: a.snapshotter.localRecords().values.toList(),
    ),
    SyncSnapshot(
      device: b.snapshotter.device,
      createdAt: 0,
      records: b.snapshotter.localRecords().values.toList(),
    ),
  ]);
  a.snapshotter.apply(merged);
  b.snapshotter.apply(merged);
}

void main() {
  late _Device phone;
  late _Device laptop;
  setUp(() {
    phone = _Device('phone');
    laptop = _Device('laptop');
  });
  tearDown(() {
    phone.close();
    laptop.close();
  });

  test('every kind of data reaches the other device, times kept', () {
    final at = DateTime.utc(2026, 10, 20, 9);
    phone.store.blocks.block(BlockKind.domain, 'spam.example', now: at);
    phone.store.imageSenders.allow('news@shop.example', now: at);
    phone.store.unsubscriptions.record(
      accountId: phone.account.id,
      listKey: 'list:weekly.shop.example',
      listName: 'Shop Weekly',
      kind: UnsubscribeKind.oneClick,
      now: at,
    );
    phone.store.folderRules.add(
      accountId: phone.account.id,
      mailboxId: phone.receipts.id,
      field: RuleField.fromDomain,
      value: 'shop.example',
      now: at,
    );

    _exchange(phone, laptop);

    final block = laptop.store.blocks.all().single;
    expect(
      (block.kind, block.value, block.since),
      (BlockKind.domain, 'spam.example', at),
    );
    expect(laptop.store.imageSenders.isAllowed('news@shop.example'), isTrue);
    final unsub = laptop.store.unsubscriptions.find(
      laptop.account.id,
      'list:weekly.shop.example',
    )!;
    expect(
      (unsub.listName, unsub.kind, unsub.at),
      ('Shop Weekly', UnsubscribeKind.oneClick, at),
    );
    final rule = laptop.store.folderRules.forMailbox(laptop.receipts.id).single;
    expect(
      (rule.field, rule.value, rule.appliesFrom),
      (RuleField.fromDomain, 'shop.example', at),
    );

    // A second exchange changes nothing.
    final before = laptop.snapshotter.localRecords().length;
    _exchange(phone, laptop);
    expect(laptop.snapshotter.localRecords().length, before);
    expect(laptop.store.blocks.all(), hasLength(1));
  });

  test('removals reach the other device and are not undone', () {
    phone.store.blocks.block(
      BlockKind.address,
      'a@x.example',
      now: DateTime.utc(2026, 10, 1),
    );
    _exchange(phone, laptop);
    expect(laptop.store.blocks.all(), hasLength(1));

    final block = laptop.store.blocks.all().single;
    laptop.store.blocks.unblock(block.id, at: DateTime.utc(2026, 10, 2));
    _exchange(phone, laptop);
    expect(phone.store.blocks.all(), isEmpty, reason: 'removed on the laptop');
    expect(laptop.store.blocks.all(), isEmpty);

    // Blocking again later wins over the old removal.
    phone.store.blocks.block(
      BlockKind.address,
      'a@x.example',
      now: DateTime.utc(2026, 10, 3),
    );
    _exchange(phone, laptop);
    expect(laptop.store.blocks.all(), hasLength(1));
  });

  test(
    'data for an account or folder this device lacks is kept and passed on',
    () {
      phone.store.mailboxes.replaceAll(phone.account.id, [
        ImapMailboxInfo(
          encodedName: 'INBOX',
          delimiter: '.',
          attributes: const {},
        ),
        ImapMailboxInfo(
          encodedName: 'INBOX.Receipts',
          delimiter: '.',
          attributes: const {},
        ),
        ImapMailboxInfo(
          encodedName: 'INBOX.Travel',
          delimiter: '.',
          attributes: const {},
        ),
      ]);
      final travel = phone.store.mailboxes
          .forAccount(phone.account.id)
          .firstWhere((m) => m.encodedName == 'INBOX.Travel');
      phone.store.folderRules.add(
        accountId: phone.account.id,
        mailboxId: travel.id,
        field: RuleField.fromAddress,
        value: 'trips@air.example',
      );
      _exchange(phone, laptop);
      expect(laptop.store.folderRules.forAccount(laptop.account.id), isEmpty);

      // The laptop still carries it: a third device gets it from the laptop.
      final tablet = _Device('tablet');
      addTearDown(tablet.close);
      tablet.store.mailboxes.replaceAll(tablet.account.id, [
        ImapMailboxInfo(
          encodedName: 'INBOX',
          delimiter: '.',
          attributes: const {},
        ),
        ImapMailboxInfo(
          encodedName: 'INBOX.Travel',
          delimiter: '.',
          attributes: const {},
        ),
      ]);
      _exchange(laptop, tablet);
      expect(
        tablet.store.folderRules.forAccount(tablet.account.id).single.value,
        'trips@air.example',
      );
    },
  );

  test('deleting a rule on one device removes it on the other', () {
    final rule = phone.store.folderRules.add(
      accountId: phone.account.id,
      mailboxId: phone.receipts.id,
      field: RuleField.subject,
      value: 'receipt',
      now: DateTime.utc(2026, 10, 1),
    );
    _exchange(phone, laptop);
    expect(
      laptop.store.folderRules.forMailbox(laptop.receipts.id),
      hasLength(1),
    );
    phone.store.folderRules.remove(rule.id, at: DateTime.utc(2026, 10, 5));
    _exchange(phone, laptop);
    expect(laptop.store.folderRules.forMailbox(laptop.receipts.id), isEmpty);
  });

  test('each device has its own id', () {
    expect(phone.snapshotter.device, hasLength(32));
    expect(
      phone.snapshotter.device,
      phone.snapshotter.device,
      reason: 'stable',
    );
    expect(phone.snapshotter.device, isNot(laptop.snapshotter.device));
  });

  test('the sync folder is recognised under any layout', () {
    StoredMailbox box(String name, String? delimiter) => StoredMailbox(
      id: 1,
      accountId: 1,
      encodedName: name,
      name: name,
      selectable: true,
      syncState: const MailboxSyncState(),
      delimiter: delimiter,
    );
    expect(box('Citusmail Sync', '/').isAppData, isTrue);
    expect(box('INBOX.Citusmail Sync', '.').isAppData, isTrue);
    expect(box('INBOX.Citusmail', '.').isAppData, isFalse);
    expect(box('Projects', '/').isAppData, isFalse);
  });
}
