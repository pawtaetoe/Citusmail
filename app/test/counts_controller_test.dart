// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The sidebar and section counts on their own, without the mail screen.

import 'package:citusmail/src/features/inbox/state/mail_counts.dart';
import 'package:citusmail/src/features/inbox/state/message_list_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  late MessageListModel list;
  late CountsController counts;
  setUp(() async {
    app = await TestApp.create();
    list = MessageListModel(app.store);
    counts = CountsController(app.store, list, FollowUpReminders(app.store));
  });
  tearDown(() {
    counts.dispose();
    list.dispose();
    return app.dispose();
  });

  AccountId accountId() => app.store.accounts.all().single.id;

  test('empty until counted, then the inbox unread', () {
    expect(counts.counts.value, same(MailCounts.empty));
    counts.refresh();
    final value = counts.counts.value;
    // Four of the five sample messages are unread.
    expect(value.inboxUnread, 4);
    expect(value.perAccountUnread[accountId()], 4);
    expect(value.outbox, 0);
    expect(value.snoozed, 0);
    expect(value.followUps, 0);
  });

  test('counted again only when the store changed', () {
    counts.refresh();
    final first = counts.counts.value;
    counts.refresh();
    expect(counts.counts.value, same(first));

    final inbox = app.store.mailboxes.inbox(accountId())!;
    final unread = app.store.messages
        .list(MessageQuery(mailboxIds: [inbox.id], unreadOnly: true))
        .first;
    app.store.messages.updateFlags(inbox.id, [
      (
        uid: unread.uid,
        flags: MessageFlags(unread.flags.bits | 1),
        modSeq: null,
      ),
    ]);
    counts.refresh();
    expect(counts.counts.value, isNot(same(first)));
    expect(counts.counts.value.inboxUnread, 3);
  });

  test('MailCounts leaves the Screener and snoozed out of the inbox', () {
    const sections = {
      SmartSection.screener: SectionCount(3, 3),
      SmartSection.snoozed: SectionCount(2, 2),
      SmartSection.general: SectionCount(4, 1),
    };
    expect(MailCounts.unreadIn(sections), 1);
  });
}
