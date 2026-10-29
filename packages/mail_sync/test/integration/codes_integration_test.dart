// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Verification mail is sorted into Codes and its code found, from the
// preview or, past it, from the downloaded body. (carol: other tests do
// not count her inbox.)

import 'dart:convert';

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

  String mail(String subject, String body) =>
      'From: Example <no-reply@example.test>\r\n'
      'To: carol@citusmail.test\r\n'
      'Subject: $subject\r\n'
      'Date: Sun, 25 Oct 2026 10:00:00 +0000\r\n'
      'MIME-Version: 1.0\r\n'
      'Content-Type: text/plain; charset=utf-8\r\n'
      '\r\n'
      '$body\r\n';

  test('codes in the preview and past it; mail stays unread', () async {
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

    final tag = scratchFolder('code').toLowerCase();
    final other = await servers.otherDevice('carol');
    addTearDown(() async {
      await other.select('INBOX');
      final found = (await other.uidSearch(
        SearchCriteria.header('Subject', tag),
      )).matches;
      if (!found.isEmpty) {
        await other.uidStore(found, FlagChange.add, {r'\Deleted'});
        await other.uidExpunge(found);
      }
      await other.logout();
    });
    final filler = 'Thanks for joining Example. ' * 20;
    await other.append(
      'INBOX',
      utf8.encode(mail('Your verification code $tag', 'Your code is 482913.')),
    );
    await other.append(
      'INBOX',
      utf8.encode(
        mail(
          'Sign in to Example $tag',
          '$filler\r\n\r\nYour one-time code: 774102\r\n\r\n$filler',
        ),
      ),
    );
    await other.append(
      'INBOX',
      utf8.encode(mail('Reset your password $tag', '$filler Open the link.')),
    );

    await engine.syncAccount(device.account.id);

    final inbox = device.store.mailboxes.inbox(device.account.id)!;
    final mine = {
      for (final m in device.store.messages.list(
        MessageQuery(mailboxIds: [inbox.id], limit: 500),
      ))
        if (m.subject?.contains(tag) ?? false) m.subject!.split(' ').first: m,
    };
    expect(mine.keys, unorderedEquals(['Your', 'Sign', 'Reset']));
    for (final m in mine.values) {
      expect(m.category, MessageCategory.codes, reason: m.subject);
      expect(m.section, SmartSection.codes, reason: m.subject);
    }
    expect(mine['Your']!.code, '482913');
    expect(mine['Sign']!.code, '774102', reason: 'read from the body');
    expect(mine['Reset']!.code, '', reason: 'looked for, none');
    expect(device.store.messages.body(mine['Sign']!.id), isNotNull);

    // Downloading did not mark anything read on the server.
    await other.select('INBOX', readOnly: true);
    final tagged = (await other.uidSearch(
      SearchCriteria.header('Subject', tag),
    )).matches.toList();
    final unseen = (await other.uidSearch(SearchCriteria.unseen())).matches
        .toList();
    expect(tagged, hasLength(3));
    expect(unseen, containsAll(tagged));
  });
}
