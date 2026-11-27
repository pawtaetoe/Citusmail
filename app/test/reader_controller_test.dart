// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Opening mail and starting messages, on their own: the reader and the
// compose starter without the mail screen.

import 'package:citusmail/src/features/compose/state/compose_starter.dart';
import 'package:citusmail/src/features/inbox/state/mail_counts.dart';
import 'package:citusmail/src/features/inbox/state/mail_location.dart';
import 'package:citusmail/src/features/inbox/state/message_list_model.dart';
import 'package:citusmail/src/features/reader/state/reader_controller.dart';
import 'package:citusmail/src/features/reader/state/reader_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_compose/mail_compose.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  late MessageListModel list;
  late CountsController counts;
  late ComposeStarter compose;
  late ReaderController reader;
  late List<String> notices;
  late List<Draft> drafts;
  late int refreshes;
  int? viewed;

  setUp(() async {
    app = await TestApp.create();
    notices = [];
    drafts = [];
    refreshes = 0;
    viewed = null;
    list = MessageListModel(app.store)..show(const InboxLocation());
    counts = CountsController(app.store, list, FollowUpReminders(app.store));
    compose = ComposeStarter(
      app.services,
      accountInView: () => viewed,
      notify: (message, {undo}) => notices.add(message),
    )..onCompose = drafts.add;
    reader = ReaderController(
      app.services,
      list,
      counts,
      compose,
      refresh: () => refreshes++,
    );
  });
  tearDown(() {
    reader.dispose();
    compose.dispose();
    counts.dispose();
    list.dispose();
    return app.dispose();
  });

  int accountId() => app.store.accounts.all().single.id;
  StoredMailbox box(String name) => app.store.mailboxes
      .forAccount(accountId())
      .firstWhere((b) => b.encodedName == name);
  StoredMessage inboxMessage(String subject) => app.store.messages
      .list(MessageQuery(mailboxIds: [box('INBOX').id]))
      .firstWhere((m) => m.subject == subject);

  group('ReaderController', () {
    test('opening marks read, counts again, and shows the message', () async {
      final hello = inboxMessage('Hello there');
      expect(hello.flags.seen, isFalse);
      final states = <ReaderState>[];
      reader.reader.addListener(() => states.add(reader.reader.value));

      await reader.open(hello);

      expect(states.first, isA<ReaderLoading>());
      final ready = reader.reader.value as ReaderReady;
      expect(ready.message.id, hello.id);
      expect(ready.message.flags.seen, isTrue);
      expect(reader.selected?.id, hello.id);
      expect(ready.view.body.plainText, contains('Visible body text.'));
      expect(ready.imagesShown, isFalse);
      expect(counts.counts.value.inboxUnread, 3, reason: 'counted again');
    });

    test('a message that can\'t be downloaded says why', () async {
      final lunch = inboxMessage('Lunch?');
      await reader.open(lunch);
      final failed = reader.reader.value as ReaderFailed;
      expect(failed.message.id, lunch.id);
      expect(failed.reason, contains('Can\'t reach the server'));
    });

    test('readerFor leaves the message unread', () async {
      final hello = inboxMessage('Hello there');
      final ready = await reader.readerFor(hello);
      expect(ready.message.flags.seen, isFalse);
      expect(reader.reader.value, isA<ReaderEmpty>());
    });

    test('images load when asked, only for the open message', () async {
      await reader.open(inboxMessage('Hello there'));
      final ready = reader.reader.value as ReaderReady;
      reader.showImages(ready);
      expect((reader.reader.value as ReaderReady).imagesShown, isTrue);
    });

    test('next and previous follow the list', () async {
      final visible = list.visible;
      expect(visible.length, greaterThan(2));
      reader.openNext();
      await Future<void>.delayed(Duration.zero);
      expect(reader.selected?.id, visible.first.id, reason: 'none open');
      reader.openNext();
      await Future<void>.delayed(Duration.zero);
      expect(reader.selected?.id, visible[1].id);
      reader.openNext(previous: true);
      await Future<void>.delayed(Duration.zero);
      expect(reader.selected?.id, visible.first.id);
    });

    test('refreshOpen reads the open message again; close empties', () async {
      final hello = inboxMessage('Hello there');
      await reader.open(hello);
      final inbox = box('INBOX');
      app.store.messages.updateFlags(inbox.id, [
        (
          uid: hello.uid,
          flags: MessageFlags.fromImap([r'\Flagged']),
          modSeq: null,
        ),
      ]);
      reader.refreshOpen();
      expect(reader.selected?.flags.flagged, isTrue);
      expect(reader.reader.value, isA<ReaderReady>());
      reader.close();
      expect(reader.reader.value, isA<ReaderEmpty>());
      expect(reader.selected, isNull);
    });

    test('read receipts only for the user\'s own mail', () {
      expect(reader.receiptsFor(inboxMessage('Lunch?')), isNull);
    });
  });

  group('ComposeStarter', () {
    test('a new message from the viewed account, else the first', () {
      compose.compose();
      expect(drafts.single.accountId, accountId());
      viewed = 4242;
      compose.compose();
      expect(drafts.last.accountId, 4242);
    });

    test('replies and forwards open in the compose window', () async {
      final hello = inboxMessage('Hello there');
      final ready = await reader.readerFor(hello);
      compose.reply(ready);
      expect(drafts.last.subject, 'Re: Hello there');
      expect(drafts.last.to.single.address, 'stranger@x.example');
      compose.forward(ready);
      expect(drafts.last.subject, startsWith('Fwd'));
      compose.forwardAsAttachment(ready);
      expect(drafts.last.attachments, hasLength(1));
      expect(compose.rawMessage(hello), isNotNull);
    });

    test('a draft opens in the compose window; offline it says so', () async {
      final folder = box('Drafts');
      app.store.messages.upsertSummaries(folder.id, [
        MessageSummary(
          uid: 9,
          receivedAt: DateTime.utc(2026, 10, 22),
          subject: 'Half written',
          flags: MessageFlags.fromImap([r'\Draft', r'\Seen']),
        ),
      ]);
      final draft = app.store.messages.byUid(folder.id, 9)!;
      expect(compose.isDraft(draft), isTrue);
      expect(compose.isDraft(inboxMessage('Lunch?')), isFalse);

      await reader.open(draft);
      expect(reader.reader.value, isA<ReaderEmpty>(), reason: 'not read');
      expect(notices, ['Can\'t open the draft while offline.']);
    });
  });
}
