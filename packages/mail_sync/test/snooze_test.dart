// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:mail_appsync/mail_appsync.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

final now = DateTime.utc(2026, 11, 4, 9);

/// A device with one account (the same address on every device).
final class _Device {
  _Device(String name, {DateTime Function()? clock}) {
    directory = Directory.systemTemp.createTempSync('snooze_$name');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
    account = store.accounts.add(
      NewAccount(
        email: 'carol@citusmail.test',
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
        const MailboxSyncState(uidValidity: 7),
      );
    }
    inbox = boxes.firstWhere((b) => b.isInbox);
    archive = boxes.firstWhere((b) => !b.isInbox);
    snapshotter = AppDataSnapshotter(store, clock: clock ?? () => now);
  }

  late final Directory directory;
  late final MailStore store;
  late final Account account;
  late final StoredMailbox inbox, archive;
  late final AppDataSnapshotter snapshotter;

  StoredMessage receive(
    int uid,
    String subject, {
    required String messageId,
    bool seen = false,
  }) {
    store.messages.upsertSummaries(inbox.id, [
      MessageSummary(
        uid: uid,
        subject: subject,
        receivedAt: now.subtract(Duration(hours: uid)),
        from: const MailAddress(
          displayName: 'Ana Silva',
          localPart: 'ana',
          domain: 'studio.example',
        ),
        messageId: messageId,
        flags: seen ? MessageFlags.fromImap([r'\Seen']) : MessageFlags.none,
      ),
    ]);
    return store.messages.byUid(inbox.id, uid)!;
  }

  void close() {
    store.close();
    directory.deleteSync(recursive: true);
  }
}

void _exchange(_Device a, _Device b) {
  final merged = SyncSnapshot.merge([
    for (final d in [a, b])
      SyncSnapshot(
        device: d.snapshotter.device,
        createdAt: 0,
        records: d.snapshotter.localRecords().values.toList(),
      ),
  ]);
  a.snapshotter.apply(merged);
  b.snapshotter.apply(merged);
}

void main() {
  late _Device phone;
  late _Device laptop;
  var laptopNow = now;

  setUp(() {
    phone = _Device('phone');
    laptopNow = now;
    laptop = _Device('laptop', clock: () => laptopNow);
  });
  tearDown(() {
    phone.close();
    laptop.close();
  });

  group('waking', () {
    test('marks the message unread, also on the server', () {
      final m = phone.receive(
        1,
        'Proposal draft',
        messageId: 'p1@x',
        seen: true,
      );
      phone.store.snoozes.snooze(m.messageId!, now.add(Duration(hours: 1)));
      final waker = SnoozeWaker(phone.store, MailActions(phone.store));
      expect(waker.nextDue, now.add(const Duration(hours: 1)));
      expect(waker.wake(now: now).isEmpty, isTrue);

      final back = waker.wake(now: now.add(const Duration(hours: 2)));
      expect(back.messages.single.message.subject, 'Proposal draft');
      expect(back.messages.single.message.flags.seen, isFalse);
      expect(back.messages.single.message.backFromSnooze, isTrue);
      expect(back.accountIds, {phone.account.id});
      final queued = phone.store.outbox.all(phone.account.id).single.action;
      expect(queued, isA<SetFlagsAction>());
      expect((queued as SetFlagsAction).remove, [r'\Seen']);
      // Exactly once.
      expect(waker.wake(now: now.add(const Duration(hours: 3))).isEmpty, true);
      expect(waker.nextDue, isNull);
    });
  });

  group('moving and deleting', () {
    test('archiving a snoozed message ends the snooze; Undo snoozes it '
        'again', () {
      final m = phone.receive(1, 'Lease renewal', messageId: 'lease@x');
      phone.store.snoozes.snooze(m.messageId!, now.add(Duration(days: 1)));
      final actions = MailActions(
        phone.store,
        undoWindow: const Duration(seconds: 5),
      );
      final snoozed = phone.store.messages.byId(m.id)!;
      expect(snoozed.section, SmartSection.snoozed);

      final receipt = actions.move([snoozed], phone.archive);
      expect(phone.store.snoozes.all(), isEmpty);
      expect(receipt.snoozes.single.messageId, 'lease@x');

      expect(actions.undo(receipt), isTrue);
      expect(
        phone.store.snoozes.find('lease@x')!.until,
        now.add(Duration(days: 1)),
      );
      expect(
        phone.store.messages.byUid(phone.inbox.id, 1)!.section,
        SmartSection.snoozed,
      );
    });

    test('deleting ends it too; other mail is untouched', () {
      final a = phone.receive(1, 'Snoozed one', messageId: 'a@x');
      phone.receive(2, 'Another snoozed', messageId: 'b@x');
      phone.store.snoozes.snooze('a@x', now.add(const Duration(days: 1)));
      phone.store.snoozes.snooze('b@x', now.add(const Duration(days: 1)));
      MailActions(phone.store).delete([phone.store.messages.byId(a.id)!]);
      expect(phone.store.snoozes.all().map((s) => s.messageId), ['b@x']);
    });
  });

  group('between devices', () {
    test('a snooze, its new time and Unsnooze reach the other device', () {
      phone.receive(1, 'Quarterly report', messageId: 'q3@x');
      final l = laptop.receive(1, 'Quarterly report', messageId: 'q3@x');
      phone.store.snoozes.snooze(
        'q3@x',
        now.add(const Duration(days: 1)),
        now: now,
      );
      _exchange(phone, laptop);
      expect(
        laptop.store.snoozes.find('q3@x')!.until,
        now.add(Duration(days: 1)),
      );
      expect(laptop.store.messages.byId(l.id)!.section, SmartSection.snoozed);

      // Changed on the laptop later: the phone follows.
      laptop.store.snoozes.snooze(
        'q3@x',
        now.add(const Duration(days: 3)),
        now: now.add(const Duration(minutes: 5)),
      );
      _exchange(phone, laptop);
      expect(
        phone.store.snoozes.find('q3@x')!.until,
        now.add(Duration(days: 3)),
      );

      // Unsnoozed on the phone: back where it was on both.
      phone.store.snoozes.cancel(
        'q3@x',
        at: now.add(const Duration(minutes: 10)),
      );
      _exchange(phone, laptop);
      expect(laptop.store.snoozes.all(), isEmpty);
      final back = laptop.store.messages.byId(l.id)!;
      expect(back.section, SmartSection.general);
      expect(back.backFromSnooze, isFalse);
    });

    test('a snooze that came back on one device comes back on the other '
        '(listed at its time), without coming back twice', () {
      phone.receive(1, 'Concert tickets', messageId: 'tix@x');
      final l = laptop.receive(1, 'Concert tickets', messageId: 'tix@x');
      final until = now.add(const Duration(hours: 1));
      phone.store.snoozes.snooze('tix@x', until, now: now);
      _exchange(phone, laptop);

      phone.store.snoozes.wake(now: now.add(const Duration(hours: 2)));
      laptopNow = now.add(const Duration(hours: 2));
      _exchange(phone, laptop);

      expect(laptop.store.snoozes.all(), isEmpty);
      final back = laptop.store.messages.byId(l.id)!;
      expect(back.section, SmartSection.general);
      expect(back.listedAt, until);
      expect(laptop.store.snoozes.wake(now: laptopNow), isEmpty);
    });

    test('a record survives sealing and opening', () {
      phone.store.snoozes.snooze('<odd id>@x', now.add(Duration(hours: 9)));
      final record = phone.snapshotter.localRecords().values.single;
      expect(record.kind, RecordKind.snooze);
      final copy = SyncRecord.fromJson(record.toJson());
      expect(copy.key, AppDataKeys.snooze('<odd id>@x'));
      expect(
        copy.data['until'],
        now.add(Duration(hours: 9)).millisecondsSinceEpoch,
      );
      laptop.snapshotter.apply({copy.key: copy});
      expect(
        laptop.store.snoozes.find('<odd id>@x')!.until,
        now.add(Duration(hours: 9)),
      );
    });
  });
}
