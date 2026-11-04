// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mail_compose/mail_compose.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_view/mail_view.dart';
import 'package:test/test.dart';

MailAddress a(String address, [String? name]) => MailAddress(
  displayName: name,
  localPart: address.split('@').first,
  domain: address.split('@').last,
);

void main() {
  late Directory directory;
  late MailStore store;
  late Account alice;
  late StoredMailbox inbox;
  late StoredMailbox drafts;

  Account addAccount(String email, {String? name}) => store.accounts.add(
    NewAccount(
      email: email,
      displayName: name,
      username: email,
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

  setUp(() {
    directory = Directory.systemTemp.createTempSync('mail_compose_test');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
    alice = addAccount('alice@citusmail.test', name: 'Alice');
    final boxes = store.mailboxes.replaceAll(alice.id, [
      ImapMailboxInfo(
        encodedName: 'INBOX',
        delimiter: '/',
        attributes: const {},
      ),
      ImapMailboxInfo(
        encodedName: 'Drafts',
        delimiter: '/',
        attributes: const {r'\Drafts'},
      ),
      ImapMailboxInfo(
        encodedName: 'Sent',
        delimiter: '/',
        attributes: const {r'\Sent'},
      ),
    ]);
    for (final b in boxes) {
      store.mailboxes.saveSyncState(
        b.id,
        const MailboxSyncState(uidValidity: 1),
      );
    }
    inbox = boxes.firstWhere((b) => b.isInbox);
    drafts = boxes.firstWhere((b) => b.specialUse == SpecialUse.drafts);
  });

  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  /// A received message, stored and parsed as the reader would have it.
  (StoredMessage, MessageView) received({
    List<OutgoingAttachment> attachments = const [],
  }) {
    final built = MessageBuilder().build(
      OutgoingMessage(
        from: a('bob@x.example', 'Bob'),
        to: [a('alice@citusmail.test', 'Alice'), a('carol@x.example', 'Carol')],
        cc: [a('dave@x.example'), a('ALICE@citusmail.test')],
        replyTo: a('bob-replies@x.example'),
        subject: 'Re: Plans',
        textBody: 'First line\n\nSecond line',
        references: const ['root@x.example'],
        inReplyTo: 'root@x.example',
        attachments: attachments,
      ),
    );
    final parsed = const MimeParser().parse(built.bytes);
    store.messages.upsertSummaries(inbox.id, [
      MessageSummary(
        uid: 7,
        receivedAt: DateTime.utc(2026, 10, 20, 9, 1),
        sentAt: DateTime.utc(2026, 10, 20, 9, 1),
        messageId: parsed.messageId,
        inReplyTo: 'root@x.example',
        references: const ['root@x.example'],
        subject: parsed.subject,
        from: parsed.from.single,
        to: parsed.to,
        cc: parsed.cc,
        replyTo: parsed.replyTo,
      ),
    ]);
    return (store.messages.byUid(inbox.id, 7)!, MessageView.parse(built.bytes));
  }

  group('replies and forwards', () {
    test('reply goes to Reply-To, threads, and quotes', () {
      final (message, view) = received();
      final draft = ReplyBuilder(store).reply(message, view);
      expect(draft.to.map((x) => x.address), ['bob-replies@x.example']);
      expect(draft.cc, isEmpty);
      expect(draft.subject, 'Re: Plans', reason: 'no Re: Re:');
      expect(draft.inReplyTo, message.messageId);
      expect(draft.references, ['root@x.example', message.messageId]);
      expect(draft.answeredMessageId, message.id);
      expect(draft.body, contains('Bob <bob@x.example> wrote:'));
      expect(draft.body, contains('> First line\n>\n> Second line'));
    });

    test('reply all includes everyone except the user, once each', () {
      final (message, view) = received();
      final draft = ReplyBuilder(store).replyAll(message, view);
      expect(draft.to.map((x) => x.address), [
        'bob-replies@x.example',
        'carol@x.example',
      ]);
      expect(draft.cc.map((x) => x.address), ['dave@x.example']);
    });

    test('forward carries attachments and no threading', () {
      final (message, view) = received(
        attachments: [
          OutgoingAttachment(
            filename: 'plan.txt',
            mimeType: 'text/plain',
            bytes: Uint8List.fromList(utf8.encode('the plan')),
          ),
        ],
      );
      final draft = ReplyBuilder(store).forward(message, view);
      expect(draft.subject, 'Fwd: Re: Plans');
      expect(draft.to, isEmpty);
      expect(draft.inReplyTo, isNull);
      expect(draft.body, contains('Forwarded message'));
      expect(draft.body, contains('First line'));
      expect(draft.attachments.single.fileName, 'plan.txt');
      expect(utf8.decode(draft.attachments.single.bytes), 'the plan');
    });
  });

  group('forward as attachment', () {
    test('the original whole, as an attached email', () {
      final (message, _) = received();
      final raw = Uint8List.fromList(
        latin1.encode('Subject: Re: Plans\r\n\r\nFirst line\r\n'),
      );
      final draft = ReplyBuilder(store).forwardAsAttachment(message, raw);
      expect(draft.subject, 'Fwd: Re: Plans');
      expect(draft.body, isEmpty);
      expect(draft.to, isEmpty);
      final attachment = draft.attachments.single;
      expect(attachment.mimeType, 'message/rfc822');
      expect(attachment.fileName, 'Re_ Plans.eml');
      expect(attachment.bytes, raw);
    });

    test('.eml names are safe and end in .eml', () {
      expect(ReplyBuilder.emlName('Invoice 42'), 'Invoice 42.eml');
      expect(ReplyBuilder.emlName('../../etc/passwd'), 'passwd.eml');
      expect(ReplyBuilder.emlName(null), 'message.eml');
      expect(ReplyBuilder.emlName('saved.EML'), 'saved.EML');
    });
  });

  group('drafts', () {
    late DraftStore store_;
    setUp(() => store_ = DraftStore(store));

    test('save and load keep every field', () {
      final saved = store_.save(
        Draft(
          accountId: alice.id,
          to: [a('bob@x.example', 'Bob')],
          bcc: [a('secret@x.example')],
          subject: 'Hi',
          body: 'Hello',
          inReplyTo: 'p@x',
          references: const ['p@x'],
          answeredMessageId: 3,
          attachments: [
            DraftAttachment(
              fileName: 'a.bin',
              mimeType: 'application/octet-stream',
              bytes: Uint8List.fromList([1, 2, 3]),
            ),
          ],
        ),
      );
      final loaded = store_.load(saved.id!)!;
      expect(loaded.to.single.displayName, 'Bob');
      expect(loaded.bcc.single.address, 'secret@x.example');
      expect(loaded.subject, 'Hi');
      expect(loaded.references, ['p@x']);
      expect(loaded.answeredMessageId, 3);
      expect(loaded.attachments.single.bytes, [1, 2, 3]);
    });

    test('damaged content gives an empty draft, not an error', () {
      final id = store.drafts.save(
        accountId: alice.id,
        content: 'not json',
        attachments: const [],
      );
      expect(store_.load(id)!.isEmpty, isTrue);
    });

    test('closing moves the draft to the Drafts folder, new copy first', () {
      final first = store_.save(
        Draft(accountId: alice.id, subject: 'v1', body: 'one'),
      );
      expect(
        store_.close(first.copyWith(savedMessageId: 'old-copy@citusmail.test')),
        DraftOutcome.savedToServer,
      );
      final queued = store.outbox.all(alice.id).map((e) => e.action).toList();
      expect(
        queued[0],
        isA<AppendAction>().having(
          (x) => x.flags,
          'flags',
          contains(r'\Draft'),
        ),
      );
      expect(
        queued[1],
        isA<RemoveDraftAction>().having(
          (x) => x.messageId,
          'id',
          'old-copy@citusmail.test',
        ),
      );
      expect(
        store.drafts.all(),
        isEmpty,
        reason: 'no longer only on the device',
      );
    });

    test('an empty draft is dropped, with its old server copy', () {
      final draft = store_.save(
        Draft(accountId: alice.id, savedMessageId: 'old@citusmail.test'),
      );
      expect(store_.close(draft), DraftOutcome.discarded);
      expect(store.drafts.all(), isEmpty);
      expect(
        store.outbox.all(alice.id).single.action,
        isA<RemoveDraftAction>(),
      );
    });

    test('without a Drafts folder the draft stays on the device', () {
      final bob = addAccount('bob@citusmail.test');
      expect(
        store_.close(Draft(accountId: bob.id, body: 'x')),
        DraftOutcome.keptOnDevice,
      );
      expect(store_.onDevice().single.body, 'x');
    });

    test('a saved draft opens again with all fields, Bcc included', () {
      const messages = OutgoingMessages();
      final draft = Draft(
        accountId: alice.id,
        to: [a('bob@x.example', 'Bob')],
        bcc: [a('secret@x.example')],
        subject: 'Hi',
        body: 'Hello there',
        inReplyTo: 'p@x.example',
        references: const ['p@x.example'],
      );
      final built = messages.forDraftsFolder(draft, alice);
      store.messages.upsertSummaries(drafts.id, [
        MessageSummary(
          uid: 1,
          receivedAt: DateTime.utc(2026),
          messageId: built.messageId,
          flags: MessageFlags.fromImap([r'\Draft']),
        ),
      ]);
      final stored = store.messages.byUid(drafts.id, 1)!;
      final reopened = store_.fromDraftsFolder(stored, built.bytes);
      expect(reopened.to.single.address, 'bob@x.example');
      expect(reopened.bcc.single.address, 'secret@x.example');
      expect(reopened.subject, 'Hi');
      expect(reopened.body.trim(), 'Hello there');
      expect(reopened.inReplyTo, 'p@x.example');
      expect(reopened.savedMessageId, built.messageId);

      // Closing it again replaces that copy and hides it at once.
      store_.close(reopened);
      expect(store.messages.byUid(drafts.id, 1), isNull);
    });
  });

  group('sending', () {
    late Sender sender;
    setUp(() => sender = Sender(store));

    test('problems are caught before anything is queued', () {
      expect(
        () => sender.send(Draft(accountId: alice.id, body: 'x')),
        throwsA(
          isA<ComposeException>().having((e) => e.problems, 'problems', {
            ComposeProblem.noRecipients,
          }),
        ),
      );
      expect(
        () => sender.send(Draft(accountId: alice.id, to: [a('bob@nodot')])),
        throwsA(
          isA<ComposeException>().having((e) => e.problems, 'problems', {
            ComposeProblem.invalidRecipient,
          }),
        ),
      );
      final big = Draft(
        accountId: alice.id,
        to: [a('bob@x.example')],
        attachments: [
          DraftAttachment(
            fileName: 'big',
            mimeType: 'application/octet-stream',
            bytes: Uint8List(20 * 1024 * 1024),
          ),
        ],
      );
      expect(
        () => sender.send(big),
        throwsA(
          isA<ComposeException>().having((e) => e.problems, 'problems', {
            ComposeProblem.attachmentsTooLarge,
          }),
        ),
      );
      expect(store.outbox.all(alice.id), isEmpty);
    });

    test('send waits for the undo window, marks the original answered', () {
      final (message, view) = received();
      final reply = DraftStore(store).save(
        ReplyBuilder(store)
            .reply(message, view)
            .copyWith(savedMessageId: 'v1@citusmail.test'),
      );
      final now = DateTime.now();
      final pending = sender.send(reply, now: now);

      expect(pending.undoUntil, now.add(const Duration(seconds: 5)));
      expect(store.outbox.due(alice.id, now: now), isEmpty);
      final queued = store.outbox.due(alice.id, now: pending.undoUntil);
      expect(queued.map((e) => e.action.runtimeType), [
        SendAction,
        RemoveDraftAction,
        SetFlagsAction,
      ]);
      final sent = const MimeParser().parse(queued.first.data!);
      expect(sent.from.single.displayName, 'Alice');
      expect(sent.inReplyTo, [message.messageId]);
      expect(store.messages.byId(message.id)!.flags.answered, isTrue);
      expect(store.drafts.all(), isEmpty);
    });

    test('asking for a read receipt: the standard header, and remembered', () {
      final draft = Draft(
        accountId: alice.id,
        to: [a('bob@x.example')],
        subject: 'Report',
        body: 'Here it is.',
        requestReceipt: true,
      );
      // Kept when the draft is saved and opened again.
      final saved = DraftStore(store).save(draft);
      expect(store.drafts.byId(saved.id!), isNotNull);
      final reopened = Draft.decodeContent(
        saved.encodeContent(),
        id: saved.id!,
        accountId: alice.id,
        attachments: const [],
      );
      expect(reopened.requestReceipt, isTrue);

      final now = DateTime.now();
      final pending = sender.send(reopened, now: now);
      final queued = store.outbox.due(alice.id, now: pending.undoUntil).first;
      final sent = const MimeParser().parse(queued.data!);
      expect(
        sent.headers.value('disposition-notification-to'),
        contains('alice@citusmail.test'),
      );
      expect(store.receipts.wasRequested(alice.id, sent.messageId!), isTrue);

      // Without the option: no header, nothing remembered.
      final plain = sender.send(
        Draft(accountId: alice.id, to: [a('bob@x.example')], body: 'x'),
        now: now,
      );
      final plainSent = const MimeParser().parse(
        store.outbox
            .due(alice.id, now: plain.undoUntil)
            .firstWhere((e) => e.id == plain.entryIds.first)
            .data!,
      );
      expect(plainSent.headers.value('disposition-notification-to'), isNull);
      expect(
        store.receipts.wasRequested(alice.id, plainSent.messageId!),
        isFalse,
      );
    });

    test('undo takes everything back and restores the draft', () {
      final (message, view) = received();
      final now = DateTime.now();
      final pending = sender.send(
        ReplyBuilder(store).reply(message, view),
        now: now,
      );
      final restored = sender.undo(
        pending,
        now: now.add(const Duration(seconds: 1)),
      );
      expect(restored, isNotNull);
      expect(restored!.id, isNotNull, reason: 'saved on the device again');
      expect(restored.subject, 'Re: Plans');
      expect(store.outbox.all(alice.id), isEmpty);
      expect(store.messages.byId(message.id)!.flags.answered, isFalse);
    });

    test('undo is refused once the message may be going out', () {
      final now = DateTime.now();
      final pending = sender.send(
        Draft(accountId: alice.id, to: [a('bob@x.example')], body: 'x'),
        now: now,
      );
      expect(
        sender.undo(pending, now: now.add(const Duration(seconds: 5))),
        isNull,
      );
      expect(store.outbox.all(alice.id), hasLength(1));
    });
  });

  group('send later', () {
    late Sender sender;
    late ScheduledSends scheduled;
    setUp(() {
      sender = Sender(store);
      scheduled = ScheduledSends(store, sender);
    });

    // Wednesday morning; the message is due Thursday at 8.
    final now = DateTime(2026, 11, 4, 9, 10);
    final thursday = DateTime(2026, 11, 5, 8);

    /// A reply with a Bcc and a file, written in the Drafts folder before.
    Draft reply(StoredMessage message, MessageView view) => ReplyBuilder(store)
        .reply(message, view)
        .copyWith(
          body: 'The numbers are attached.\n\n',
          bcc: [a('me+archive@citusmail.test')],
          attachments: [
            DraftAttachment(
              fileName: 'q3.csv',
              mimeType: 'text/csv',
              bytes: Uint8List.fromList(utf8.encode('month,total\nJul,12\n')),
            ),
          ],
          savedMessageId: 'v1@citusmail.test',
        );

    ScheduledSend only() => scheduled.all().single;

    test('waits in the outbox until its time, dated then', () {
      final (message, view) = received();
      final pending = sender.schedule(reply(message, view), thursday, now: now);
      expect(pending.scheduledFor, thursday);
      // The Message-ID it goes out with, for "Remind me if no reply".
      expect(
        const MimeParser().parse(only().entry.data!).messageId,
        pending.messageId,
      );

      // The undo delay over: only the old Drafts copy goes.
      expect(
        store.outbox
            .due(alice.id, now: pending.undoUntil)
            .map((e) => e.action.runtimeType),
        [RemoveDraftAction],
      );
      final justBefore = thursday.subtract(const Duration(seconds: 1));
      expect(
        store.outbox
            .due(alice.id, now: justBefore)
            .whereType<OutboxEntry>()
            .where((e) => e.action is! RemoveDraftAction),
        isEmpty,
        reason: 'never early',
      );
      final due = store.outbox.due(alice.id, now: thursday);
      expect(due.map((e) => e.action.runtimeType), [
        SendAction,
        RemoveDraftAction,
        SetFlagsAction,
      ]);
      final send = due.first.action as SendAction;
      expect(send.schedule!.at, thursday.toUtc());
      expect(send.schedule!.followUps, [due.last.id]);
      expect(send.recipients, contains('me+archive@citusmail.test'));
      final parsed = const MimeParser().parse(due.first.data!);
      expect(parsed.date!.utc, thursday.toUtc());
      expect(parsed.headers.all('bcc'), isEmpty);
      expect(store.messages.byId(message.id)!.flags.answered, isTrue);
      expect(store.drafts.all(), isEmpty);
      expect(scheduled.nextDue(now: now), thursday.toUtc());
      expect(only().waitingAt(now), isTrue);
      expect(only().waitingAt(thursday), isFalse);
    });

    test('a time within the undo delay is refused', () {
      final draft = Draft(accountId: alice.id, to: [a('bob@x.example')]);
      expect(
        () => sender.schedule(
          draft,
          now.add(const Duration(seconds: 3)),
          now: now,
        ),
        throwsArgumentError,
      );
      expect(store.outbox.all(alice.id), isEmpty);
    });

    test('Change time: one message, at the new time', () {
      final (message, view) = received();
      sender.schedule(reply(message, view), thursday, now: now);
      final friday = DateTime(2026, 11, 6, 13);
      final pending = scheduled.reschedule(only(), friday, now: now);
      expect(pending, isNotNull);
      final s = only();
      expect(s.at, friday.toUtc());
      expect(s.entry.notBefore, friday.toUtc());
      expect(const MimeParser().parse(s.entry.data!).date!.utc, friday.toUtc());
      expect(
        store.outbox.due(alice.id, now: thursday).map((e) => e.action),
        everyElement(isA<RemoveDraftAction>()),
      );
      expect(
        store.outbox
            .all(alice.id)
            .where((e) => e.action is SetFlagsAction)
            .single
            .notBefore,
        friday.toUtc(),
        reason: 'answered when it goes out, once',
      );
      expect(store.messages.byId(message.id)!.flags.answered, isTrue);
      expect(
        () => scheduled.reschedule(only(), now, now: now),
        throwsArgumentError,
      );
    });

    test('Send now: an ordinary send, with the usual undo delay', () {
      final (message, view) = received();
      sender.schedule(reply(message, view), thursday, now: now);
      final pending = scheduled.sendNow(only(), now: now)!;
      expect(pending.scheduledFor, isNull);
      expect(scheduled.all(), isEmpty);
      final send = store.outbox.sends().single;
      expect(send.notBefore, pending.undoUntil.toUtc());
      expect(
        store.outbox
            .due(alice.id, now: pending.undoUntil)
            .map((e) => e.action.runtimeType),
        containsAll([SendAction, SetFlagsAction]),
      );
      expect(const MimeParser().parse(send.data!).subject, 'Re: Plans');
    });

    test('Edit: back to a draft, everything kept, the schedule ends', () {
      final (message, view) = received();
      sender.schedule(reply(message, view), thursday, now: now);
      final draft = scheduled.edit(only(), now: now)!;
      expect(draft.id, isNotNull, reason: 'saved on the device');
      expect(draft.subject, 'Re: Plans');
      expect(draft.body, 'The numbers are attached.\n\n');
      expect(draft.bcc.single.address, 'me+archive@citusmail.test');
      expect(draft.answeredMessageId, message.id);
      expect(draft.attachments.single.fileName, 'q3.csv');
      expect(
        utf8.decode(draft.attachments.single.bytes),
        'month,total\nJul,12\n',
      );
      expect(scheduled.all(), isEmpty);
      expect(
        store.outbox.all(alice.id).map((e) => e.action),
        everyElement(isA<RemoveDraftAction>()),
      );
      expect(store.messages.byId(message.id)!.flags.answered, isFalse);
    });

    test('Cancel: goes to Drafts instead, never sent', () {
      final (message, view) = received();
      sender.schedule(reply(message, view), thursday, now: now);
      expect(scheduled.cancel(only(), now: now), DraftOutcome.savedToServer);
      expect(store.outbox.sends(), isEmpty);
      final append = store.outbox
          .all(alice.id)
          .firstWhere((e) => e.action is AppendAction);
      expect((append.action as AppendAction).mailboxId, drafts.id);
      final copy = const MimeParser().parse(append.data!);
      expect(copy.subject, 'Re: Plans');
      expect(store.messages.byId(message.id)!.flags.answered, isFalse);
    });

    test('too late once its time came: nothing changes', () {
      sender.schedule(
        Draft(accountId: alice.id, to: [a('bob@x.example')], body: 'x'),
        thursday,
        now: now,
      );
      final s = only();
      expect(scheduled.edit(s, now: thursday), isNull);
      expect(scheduled.cancel(s, now: thursday), isNull);
      expect(scheduled.sendNow(s, now: thursday), isNull);
      expect(
        scheduled.reschedule(
          s,
          thursday.add(const Duration(days: 1)),
          now: thursday,
        ),
        isNull,
      );
      expect(only().entry.id, s.entry.id);

      // Also once a try has been made (the server was unreachable).
      store.outbox.retryLater(s.entry.id, 'offline', thursday);
      expect(scheduled.edit(only(), now: now), isNull);
      expect(scheduled.nextDue(now: now), isNull);
    });

    test('a failure is reported once', () {
      sender.schedule(
        Draft(accountId: alice.id, to: [a('bob@x.example')], body: 'x'),
        thursday,
        now: now,
      );
      sender.send(
        Draft(accountId: alice.id, to: [a('carol@x.example')], body: 'y'),
        now: now,
      );
      expect(scheduled.claimFailures(), isEmpty);
      for (final e in store.outbox.sends()) {
        store.outbox.markFailed(e.id, '550 mailbox unavailable');
      }
      final claimed = scheduled.claimFailures();
      expect(claimed, hasLength(1), reason: 'only the scheduled one');
      expect(claimed.single.entry.lastError, '550 mailbox unavailable');
      expect(scheduled.claimFailures(), isEmpty);
    });
  });

  group('answering invitations', () {
    late Sender sender;
    setUp(() => sender = Sender(store));

    (StoredMessage, CalendarInvite) invitation(String fixture) {
      final raw = File('../../test-data/invites/$fixture').readAsBytesSync();
      final parsed = const MimeParser().parse(raw);
      store.messages.upsertSummaries(inbox.id, [
        MessageSummary(
          uid: 9,
          receivedAt: DateTime.utc(2026, 11, 3, 9),
          messageId: parsed.messageId,
          subject: parsed.subject,
          from: parsed.from.single,
        ),
      ]);
      return (
        store.messages.byUid(inbox.id, 9)!,
        MessageView.parse(raw).invite!,
      );
    }

    test('accepting goes to the organizer only, through the outbox', () {
      final (message, invite) = invitation('outlook-teams-request.eml');
      final now = DateTime.now();
      final draft = InvitationReplies.draft(
        message: message,
        account: alice,
        invite: invite,
        attendee: invite.attendeeFor([alice.email])!,
        answer: CalendarAnswer.accepted,
        now: DateTime.utc(2026, 11, 4, 10),
      )!;
      final pending = sender.send(draft, now: now);
      expect(store.outbox.due(alice.id, now: now), isEmpty, reason: 'undo');
      final queued = store.outbox.due(alice.id, now: pending.undoUntil).single;
      final action = queued.action as SendAction;
      expect(action.recipients, ['ana.lima@contoso.example']);

      final sent = const MimeParser().parse(queued.data!);
      expect(sent.to.single.address, 'ana.lima@contoso.example');
      expect(sent.to.single.displayName, 'Ana Lima');
      expect(sent.cc, isEmpty);
      expect(sent.subject, 'Accepted: Q4 roadmap review');
      expect(sent.inReplyTo, [message.messageId]);
      expect(sent.root.contentType.mimeType, 'multipart/alternative');
      expect(
        sent.textBody!.decodeText().text.trim(),
        'Alice has accepted this invitation.',
      );
      final part = sent.root.children.last;
      expect(part.contentType.mimeType, 'text/calendar');
      expect(part.contentType.parameters['method'], 'REPLY');
      final reply = CalendarInvite.parse(part.decodeText().text)!;
      expect(reply.method, CalendarMethod.reply);
      expect(reply.uid, invite.uid);
      expect(reply.sequence, 2);
      expect(reply.attendees.single.email, 'alice@citusmail.test');
      expect(reply.attendees.single.answer, CalendarAnswer.accepted);
      expect(sent.allDefects, isEmpty);
    });

    test('declining with a note; cancelling keeps no draft', () {
      final (message, invite) = invitation('all-day-request.eml');
      final now = DateTime.now();
      final pending = sender.send(
        InvitationReplies.draft(
          message: message,
          account: alice,
          invite: invite,
          attendee: invite.attendeeFor([alice.email])!,
          answer: CalendarAnswer.declined,
          note: 'Sorry, I\'m away that week.',
        )!,
        now: now,
      );
      final sent = const MimeParser().parse(
        store.outbox.due(alice.id, now: pending.undoUntil).single.data!,
      );
      expect(sent.subject, 'Declined: Team offsite – Sintra');
      expect(
        sent.textBody!.decodeText().text,
        contains('Sorry, I\'m away that week.'),
      );
      final reply = CalendarInvite.parse(
        sent.root.children.last.decodeText().text,
      )!;
      expect(
        reply.event.property('COMMENT')!.text,
        'Sorry, I\'m away that week.',
      );

      expect(sender.cancel(pending, now: now), isTrue);
      expect(store.outbox.all(alice.id), isEmpty);
      expect(store.drafts.all(), isEmpty);
    });

    test('cancelled events and publications have nothing to answer', () {
      for (final fixture in ['outlook-cancel.eml', 'zoom-webinar.eml']) {
        final (message, invite) = invitation(fixture);
        expect(
          InvitationReplies.draft(
            message: message,
            account: alice,
            invite: invite,
            attendee:
                invite.attendeeFor([alice.email]) ??
                CalendarPerson.read(
                  ICalProperty('ATTENDEE', 'mailto:alice@citusmail.test'),
                )!,
            answer: CalendarAnswer.accepted,
          ),
          isNull,
          reason: fixture,
        );
      }
    });
  });
}
