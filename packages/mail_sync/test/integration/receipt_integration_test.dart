// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Read receipts arriving for carol's sent mail, against the test server.
// (carol: no other test counts her inbox, so test files can run in
// parallel.)

import 'dart:convert';
import 'dart:math';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

import '../support/test_env.dart';

void main() {
  final skip = integrationSkipReason;
  if (skip != null) {
    test('needs the local test servers', () {}, skip: skip);
    return;
  }
  final servers = TestServers.load();

  String receipt(String originalId, {String from = 'bob@citusmail.test'}) =>
      'From: Bob <$from>\r\n'
      'To: carol@citusmail.test\r\n'
      'Subject: Read: Report\r\n'
      'Date: Sat, 24 Oct 2026 10:00:00 +0000\r\n'
      'Message-ID: <mdn-${Random().nextInt(1 << 30)}@citusmail.test>\r\n'
      'MIME-Version: 1.0\r\n'
      'Content-Type: multipart/report; report-type=disposition-notification;\r\n'
      ' boundary="b"\r\n'
      '\r\n'
      '--b\r\nContent-Type: text/plain\r\n\r\nYour message was displayed.\r\n'
      '--b\r\nContent-Type: message/disposition-notification\r\n\r\n'
      'Final-Recipient: rfc822;$from\r\n'
      'Original-Message-ID: <$originalId>\r\n'
      'Disposition: manual-action/MDN-sent-manually; displayed\r\n'
      '--b--\r\n';

  test(
    'receipts are recorded for mail that asked, once, and sorted away',
    () async {
      final device = TestDevice.create(servers, 'carol');
      addTearDown(device.dispose);
      final engine = SyncEngine(
        device.store,
        DefaultMailConnector(
          const TestCredentials(),
          tls: servers.tls,
          endpointFor: servers.endpointFor,
        ),
      );
      addTearDown(engine.dispose);
      await engine.syncAccount(device.account.id);

      final tag = scratchFolder('rcpt').toLowerCase();
      final askedHere = 'asked-$tag@citusmail.test';
      final askedElsewhere = 'other-$tag@citusmail.test';
      final neverAsked = 'never-$tag@citusmail.test';
      device.store.receipts.requested(device.account.id, askedHere);

      final other = await servers.otherDevice('carol');
      addTearDown(() async {
        // Leave carol's mailbox as it was.
        for (final folder in ['INBOX', 'INBOX.Sent']) {
          await other.select(folder);
          final found = (await other.uidSearch(
            SearchCriteria.header('Message-ID', tag),
          )).matches;
          final reports = (await other.uidSearch(
            SearchCriteria.header('Subject', 'Read: Report'),
          )).matches;
          for (final set in [found, reports]) {
            if (set.toList().isNotEmpty) {
              await other.uidStore(set, FlagChange.add, {r'\Deleted'});
              await other.uidExpunge(set);
            }
          }
        }
        await other.logout();
      });
      // A sent copy written on another device, asking for receipts.
      await other.append(
        'INBOX.Sent',
        utf8.encode(
          'From: carol@citusmail.test\r\nTo: bob@citusmail.test\r\nSubject: Report\r\n'
          'Message-ID: <$askedElsewhere>\r\n'
          'Disposition-Notification-To: carol@citusmail.test\r\n\r\nHi\r\n',
        ),
        flags: const {r'\Seen'},
      );
      for (final id in [askedHere, askedElsewhere, neverAsked]) {
        await other.append('INBOX', utf8.encode(receipt(id)));
      }

      final report = await engine.syncAccount(device.account.id);
      expect(report!.receipts, 2);
      for (final id in [askedHere, askedElsewhere]) {
        final got = device.store.receipts
            .forMessage(device.account.id, id)
            .single;
        expect(
          (got.recipient, got.disposition),
          ('bob@citusmail.test', 'displayed'),
        );
      }
      expect(
        device.store.receipts.forMessage(device.account.id, neverAsked),
        isEmpty,
      );

      // Receipts sort as notifications, not as mail from a person.
      final inbox = device.store.mailboxes.inbox(device.account.id)!;
      final reports = device.store.messages
          .list(MessageQuery(mailboxIds: [inbox.id], limit: 500))
          .where((m) => m.subject == 'Read: Report');
      expect(reports, hasLength(3));
      expect(
        reports.every((m) => m.category == MessageCategory.notifications),
        isTrue,
      );

      // Read once only.
      final again = await engine.syncAccount(device.account.id);
      expect(again!.receipts, 0);
    },
  );
}
