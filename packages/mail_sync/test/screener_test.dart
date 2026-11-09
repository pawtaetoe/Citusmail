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
  delimiter: '/',
  attributes: {if (use != null) '\\$use'},
);

void main() {
  late Directory directory;
  late MailStore store;
  late Account account;
  late StoredMailbox inbox;
  late StoredMailbox archive;
  final turnedOn = DateTime.utc(2026, 10, 20, 8);
  final decidedAt = DateTime.utc(2026, 10, 21, 8);

  setUp(() {
    directory = Directory.systemTemp.createTempSync('screener_test');
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
      _folder('INBOX'),
      _folder('Archive', use: 'Archive'),
    ]);
    for (final b in boxes) {
      store.mailboxes.saveSyncState(
        b.id,
        const MailboxSyncState(uidValidity: 7),
      );
    }
    inbox = boxes.firstWhere((b) => b.isInbox);
    archive = boxes.firstWhere((b) => b.specialUse == SpecialUse.archive);
  });

  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  void receive(
    int uid,
    String from, {
    DateTime? at,
    String? subject,
    MessageCategory category = MessageCategory.general,
    String? messageId,
  }) => store.messages.upsertSummaries(inbox.id, [
    MessageSummary(
      uid: uid,
      subject: subject ?? 'm$uid',
      receivedAt: at ?? DateTime.utc(2026, 10, 22, 0, uid),
      messageId: messageId ?? 'm$uid@x.example',
      from: _a(from),
      category: category,
    ),
  ]);

  List<MoveAction> moves() => store.outbox
      .all(account.id)
      .map((e) => e.action)
      .whereType<MoveAction>()
      .toList();

  group('notifications', () {
    test('mail waiting in the Screener is never announced', () {
      receive(1, 'bob@friends.example', at: DateTime.utc(2026, 10, 1));
      final tracker = NewMailTracker(store);
      expect(tracker.claim(account.id).isEmpty, isTrue, reason: 'sets mark');
      store.screener.enable(now: turnedOn);

      receive(2, 'bob@friends.example', subject: 'Dinner on Friday?');
      receive(3, 'ana@studio.example', subject: 'Portfolio review?');
      receive(
        4,
        'no-reply@accounts.example',
        subject: 'Your code is 482913',
        category: MessageCategory.codes,
      );
      final mail = tracker.claim(account.id);
      expect(mail.messages.map((m) => m.subject), [
        'Dinner on Friday?',
        'Your code is 482913',
      ]);
      expect(mail.total, 2);

      // Letting Ana in later doesn't announce her old mail.
      store.screener.decide(
        ScreenerKind.address,
        'ana@studio.example',
        ScreenerDecision.letIn,
      );
      expect(tracker.claim(account.id).isEmpty, isTrue);
      // Her next email is announced like anyone's.
      receive(5, 'ana@studio.example', subject: 'Thanks!');
      expect(tracker.claim(account.id).messages.single.subject, 'Thanks!');
    });

    test('screened-out mail is never announced', () {
      store.screener.enable(now: turnedOn);
      store.screener.decide(
        ScreenerKind.domain,
        'deals.example',
        ScreenerDecision.screenOut,
      );
      final tracker = NewMailTracker(store)..claim(account.id);
      receive(1, 'promo@deals.example', subject: 'Exclusive offer');
      expect(tracker.claim(account.id).isEmpty, isTrue);
    });
  });

  group('Screen out to Archive', () {
    setUp(() {
      store.screener.enable(now: turnedOn);
      store.screener.decide(
        ScreenerKind.address,
        'promo@deals.example',
        ScreenerDecision.screenOut,
        now: decidedAt,
      );
    });

    test('nothing moves unless Archive is chosen', () {
      receive(1, 'promo@deals.example');
      expect(ScreenerArchiver(store).apply(account), 0);
      store.screener.outPlace = ScreenOutPlace.notifications;
      expect(ScreenerArchiver(store).apply(account), 0);
      expect(moves(), isEmpty);
      store.screener.disable();
      store.screener.outPlace = ScreenOutPlace.archive;
      expect(ScreenerArchiver(store).apply(account), 0, reason: 'off');
    });

    test('new mail from screened-out senders moves to Archive', () {
      store.screener.outPlace = ScreenOutPlace.archive;
      receive(1, 'promo@deals.example', subject: 'Last chance');
      receive(2, 'ana@studio.example', subject: 'Portfolio review?');
      receive(
        3,
        'promo@deals.example',
        subject: 'Code 1234',
        category: MessageCategory.codes,
      );
      // From before the decision: stays.
      receive(
        4,
        'promo@deals.example',
        at: decidedAt.subtract(const Duration(days: 1)),
      );

      expect(ScreenerArchiver(store).apply(account), 1);
      expect(store.messages.uids(inbox.id), [2, 3, 4]);
      expect(moves().single.targetMailboxId, archive.id);
      expect(moves().single.uids, [1]);

      // Brought back by the user: stays.
      receive(9, 'promo@deals.example', messageId: 'm1@x.example');
      expect(ScreenerArchiver(store).apply(account), 0);
    });

    test('a pass looks only at mail that arrived since the last one', () {
      store.screener.outPlace = ScreenOutPlace.archive;
      receive(5, 'ana@studio.example');
      expect(ScreenerArchiver(store).apply(account), 0);
      receive(3, 'promo@deals.example'); // older mail, downloaded later
      receive(6, 'promo@deals.example');
      expect(ScreenerArchiver(store).apply(account), 1);
      expect(moves().single.uids, [6]);
      expect(ScreenerArchiver(store).apply(account, everything: true), 1);
      expect(store.messages.uids(inbox.id), [5]);
    });
  });
}
