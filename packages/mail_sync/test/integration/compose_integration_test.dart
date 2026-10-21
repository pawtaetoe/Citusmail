// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Writing and sending mail end to end, against the local test servers
// (see sync_integration_test.dart). Mail is sent to alice+<folder>, which
// the test server delivers into <folder>, so tests never share a folder.

import 'package:mail_compose/mail_compose.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:mail_view/mail_view.dart';
import 'package:test/test.dart';

import '../support/test_env.dart';

void main() {
  final skip = integrationSkipReason;
  if (skip != null) {
    test('needs the local test servers', () {}, skip: skip);
    return;
  }
  final servers = TestServers.load();
  late TestDevice me;
  setUp(() async {
    me = TestDevice.create(servers, 'alice');
    await me.sync(['INBOX', 'Sent', 'Drafts']);
  });
  tearDown(() => me.dispose());

  /// Messages in [folder] on the server matching [criteria], waiting a few
  /// seconds for delivery.
  Future<List<FetchedMessage>> onServer(
    String folder,
    SearchCriteria criteria, {
    bool expectNone = false,
  }) async {
    final other = await servers.otherDevice('alice');
    try {
      for (var i = 0; i < (expectNone ? 5 : 25); i++) {
        final names = (await other.listMailboxes()).map((f) => f.encodedName);
        if (names.contains(folder)) {
          await other.select(folder, readOnly: true);
          final found = (await other.uidSearch(criteria)).matches;
          if (!found.isEmpty) {
            return (await other.uidFetch(
              found,
              FetchItems(flags: true, fullMessage: true),
            )).messages;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      return const [];
    } finally {
      await other.logout();
    }
  }

  MailAddress to(String folder) =>
      MailAddress(localPart: 'alice+$folder', domain: 'fmail.test');

  test('a reply is delivered once, saved to Sent, threaded, and marks the original answered', () async {
    final folder = scratchFolder('reply');
    final original = me
        .messages('INBOX')
        .firstWhere(
          (m) => m.subject == 'Re: Lunch on Friday?',
        ); // not yet answered
    await me.synchronizer.sync(me.account); // all folders
    final body = await MessageLoader(me.store)
        .load(await me.connector.imap(me.account), original.id);
    final reply = ReplyBuilder(me.store)
        .reply(original, MessageView.parse(body))
        .copyWith(to: [to(folder)], body: 'Yes, Friday works.\n\n');

    final pending = Sender(me.store).send(
      reply,
      now: DateTime.now().subtract(
        const Duration(seconds: 10),
      ), // undo window over
    );
    expect(pending.entryIds, hasLength(2), reason: 'send and answered flag');
    await me.sync(['INBOX']);
    expect(me.store.outbox.all(me.account.id), isEmpty);

    final delivered = await onServer(folder, SearchCriteria.all());
    expect(delivered, hasLength(1));
    final parsed = const MimeParser().parse(delivered.single.sections['']!);
    expect(parsed.subject, 'Re: Lunch on Friday?');
    expect(parsed.inReplyTo, [original.messageId]);
    expect(parsed.from.single.address, 'alice@fmail.test');
    expect(
      parsed.textBody!.decodeText().text,
      startsWith('Yes, Friday works.'),
    );
    expect(parsed.headers.all('bcc'), isEmpty);

    final inSent = await onServer(
      'Sent',
      SearchCriteria.header('Message-ID', parsed.messageId!),
    );
    expect(inSent, hasLength(1));
    final answered = await onServer(
      'INBOX',
      SearchCriteria.header('Message-ID', original.messageId!),
    );
    expect(answered.single.hasFlag(r'\Answered'), isTrue);
  });

  test('an undone send never leaves', () async {
    final folder = scratchFolder('undo');
    final sender = Sender(me.store);
    final pending = sender.send(
      Draft(
        accountId: me.account.id,
        to: [to(folder)],
        subject: 'never',
        body: 'x',
      ),
    );
    expect(sender.undo(pending), isNotNull);
    await me.sync([]);
    expect(
      await onServer(folder, SearchCriteria.all(), expectNone: true),
      isEmpty,
    );
    expect(me.store.drafts.all(), hasLength(1), reason: 'back as a draft');
  });

  test(
    'drafts round-trip through the Drafts folder, one copy at a time',
    () async {
      final drafts = DraftStore(me.store);
      final marker = scratchFolder('draft');
      var draft = drafts.save(
        Draft(
          accountId: me.account.id,
          to: [to(marker)],
          bcc: [MailAddress(localPart: 'bob', domain: 'fmail.test')],
          subject: 'Draft $marker',
          body: 'version 1',
        ),
      );
      expect(drafts.close(draft), DraftOutcome.savedToServer);
      await me.sync(['Drafts']);

      final cached = me
          .messages('Drafts')
          .firstWhere((m) => m.subject == 'Draft $marker');
      expect(cached.flags.draft, isTrue);
      final raw = await MessageLoader(me.store)
          .load(await me.connector.imap(me.account), cached.id);
      draft = drafts.fromDraftsFolder(cached, raw);
      expect(draft.bcc.single.address, 'bob@fmail.test');
      expect(draft.body.trim(), 'version 1');

      drafts.close(draft.copyWith(body: 'version 2'));
      await me.sync(['Drafts']);
      final copies = await onServer(
        'Drafts',
        SearchCriteria.header('Subject', 'Draft $marker'),
      );
      expect(copies, hasLength(1), reason: 'the old copy was removed');
      final latest = const MimeParser().parse(copies.single.sections['']!);
      expect(latest.textBody!.decodeText().text.trim(), 'version 2');
      expect(copies.single.hasFlag(r'\Draft'), isTrue);

      // Sending removes the last copy.
      final reopened = drafts.fromDraftsFolder(
        me.messages('Drafts').firstWhere((m) => m.subject == 'Draft $marker'),
        copies.single.sections['']!,
      );
      Sender(me.store).send(
        reopened,
        now: DateTime.now().subtract(const Duration(seconds: 10)),
      );
      await me.sync(['Drafts']);
      expect(
        await onServer(
          'Drafts',
          SearchCriteria.header('Subject', 'Draft $marker'),
          expectNone: true,
        ),
        isEmpty,
      );
      expect(await onServer(marker, SearchCriteria.all()), hasLength(1));
    },
  );
}
