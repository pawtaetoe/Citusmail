// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The Smart Inbox's counts, read after every sync: the same numbers as
// counting every row, from indexes alone.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

import 'support/temp_store.dart';

void main() {
  late TempStore temp;
  setUp(() => temp = TempStore.create());
  tearDown(() => temp.dispose());

  /// Inboxes of two accounts with every kind of mail, read and unread,
  /// read receipts among them (also pinned ones, which keep their
  /// section) and other reports.
  List<MailboxId> seed() {
    final store = temp.store;
    final inboxes = <MailboxId>[];
    for (final (a, email) in ['alice@a.example', 'bob@b.example'].indexed) {
      final account = temp.addAccount(email);
      final inbox = store.mailboxes.replaceAll(account.id, [
        ImapMailboxInfo(
          encodedName: 'INBOX',
          delimiter: '/',
          attributes: const {},
        ),
      ]).single;
      inboxes.add(inbox.id);
      store.messages.upsertSummaries(inbox.id, [
        for (var i = 1; i <= 120; i++)
          MessageSummary(
            uid: i,
            receivedAt: DateTime.utc(2026, 1, 1).add(Duration(hours: i)),
            messageId: 'm$i.$a@x.example',
            from: MailAddress(localPart: 's${i % 7}', domain: 'x.example'),
            subject: 'Message $i',
            category: MessageCategory.values[i % MessageCategory.values.length],
            flags: MessageFlags.fromImap([
              if (i % 3 == 0) r'\Seen',
              if (i % 17 == 0) r'\Flagged',
            ]),
            headers: {
              'content-type': [
                if (i % 5 == 0)
                  'multipart/report; report-type=disposition-notification'
                else if (i % 11 == 0)
                  'multipart/report; report-type=delivery-status'
                else
                  'text/plain',
              ],
            },
          ),
      ]);
    }
    return inboxes;
  }

  /// The counts as 0.6.3 read them: every row of the inboxes.
  Map<SmartSection, SectionCount> everyRow(List<MailboxId> inboxes) {
    final where =
        'mailbox_id IN (${inboxes.map((i) => i.value).join(', ')}) '
        "AND NOT (section IN ('notifications', 'screener') "
        "AND messages.category = 'notifications' AND EXISTS (SELECT 1 "
        'FROM message_headers rh WHERE rh.message_id = messages.id '
        "AND rh.name = 'content-type' "
        "AND lower(rh.value) LIKE '%multipart/report%' "
        "AND lower(rh.value) LIKE '%disposition-notification%'))";
    final rows = temp.store.database.select(
      'SELECT section, count(*) AS n, sum((flags & 1) = 0) AS u '
      'FROM messages WHERE $where GROUP BY section',
    );
    return {
      for (final s in SmartSection.values) s: SectionCount.empty,
      for (final row in rows)
        SmartSection.values.byName(row['section'] as String): SectionCount(
          row['n'] as int,
          row['u'] as int,
        ),
    };
  }

  Map<SmartSection, (int, int)> plain(Map<SmartSection, SectionCount> c) => {
    for (final MapEntry(:key, :value) in c.entries)
      key: (value.total, value.unread),
  };

  test('the same counts as counting every row, per inbox and together', () {
    final inboxes = seed();
    final byInbox = temp.store.messages.sectionCountsByInbox();
    expect(byInbox.keys, inboxes);
    for (final id in inboxes) {
      expect(plain(byInbox[id]!), plain(everyRow([id])));
    }
    expect(
      plain(temp.store.messages.sectionCounts()),
      plain(everyRow(inboxes)),
    );
    // Receipts are there to be left out.
    expect(
      everyRow(inboxes)[SmartSection.notifications]!.total,
      lessThan(
        temp.store.database
                .select(
                  "SELECT count(*) FROM messages WHERE section = 'notifications'",
                )
                .first
                .columnAt(0)
            as int,
      ),
    );
  });

  test('counting reads indexes, not every row', () {
    seed();
    final plan = temp.store.messages.debugSectionCountPlan();
    // The index of report headers holds only reports: it may be read
    // whole.
    expect(
      plan.where((p) => p.startsWith('SCAN')),
      everyElement(contains('USING INDEX message_headers_reports')),
    );
    expect(
      plan.where((p) => p.contains('COVERING INDEX messages_by_section')),
      hasLength(1),
    );
    expect(
      plan.where((p) => p.contains('INDEX messages_unread')),
      hasLength(1),
    );
    expect(
      plan.where((p) => p.contains('message_headers_reports')),
      isNotEmpty,
    );
  });
}
