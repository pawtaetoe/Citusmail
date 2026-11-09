// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The mail screen refreshes after every sync and action; it counts
// again only when something in the store changed (here, or written by
// the sync worker's own connection).

import 'dart:io';

import 'package:citusmail/src/mail/mail_controller.dart';
import 'package:citusmail/src/mail/store_changes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

void main() {
  test('a write here or by another connection changes the stamp', () {
    final directory = Directory.systemTemp.createTempSync('stamp_test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/mail.db';
    final key = DatabaseKey.generate();
    final ui = MailStore.open(path, key);
    final worker = MailStore.open(path, key);
    addTearDown(ui.close);
    addTearDown(worker.close);
    final changes = StoreChanges(ui);

    final start = changes.stamp;
    ui.settings.read('anything');
    ui.accounts.all();
    expect(changes.stamp, start, reason: 'reading changes nothing');

    ui.settings.write('ui.test', 'one');
    final afterOwn = changes.stamp;
    expect(afterOwn, isNot(start));

    worker.settings.write('sync.test', 'two');
    expect(changes.stamp, isNot(afterOwn), reason: 'the worker wrote');
  });

  group('refresh', () {
    late TestApp app;
    late MailController controller;
    setUp(() async {
      app = await TestApp.create();
      controller = MailController(app.services);
    });
    tearDown(() {
      controller.dispose();
      return app.dispose();
    });

    test('nothing changed: the counts are kept', () {
      final counts = controller.counts.value;
      final sections = controller.list.sectionCounts();
      controller.refresh();
      controller.refresh();
      expect(controller.counts.value, same(counts));
      expect(controller.list.sectionCounts(), same(sections));
    });

    test('a message read: counted again', () {
      final before = controller.counts.value;
      final inbox = app.store.mailboxes.inbox(
        app.store.accounts.all().single.id,
      )!;
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
      controller.refresh();
      expect(controller.counts.value, isNot(same(before)));
      expect(
        controller.counts.value.folderUnread[inbox.id],
        before.folderUnread[inbox.id]! - 1,
      );
    });
  });
}
