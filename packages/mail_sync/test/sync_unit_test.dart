// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:mail_view/mail_view.dart';
import 'package:test/test.dart';

void main() {
  test(
    'background syncs skip views like Gmail Starred; opening syncs them',
    () {
      var id = 0;
      StoredMailbox box(
        String name, {
        SpecialUse? use,
        bool selectable = true,
      }) => StoredMailbox(
        id: ++id,
        accountId: 1,
        encodedName: name,
        name: name,
        selectable: selectable,
        syncState: MailboxSyncState.empty,
        delimiter: '/',
        specialUse: use,
      );
      final inbox = box('INBOX');
      final all = box('[Gmail]/All Mail', use: SpecialUse.all);
      final starred = box('[Gmail]/Starred', use: SpecialUse.flagged);
      final important = box('[Gmail]/Important', use: SpecialUse.important);
      final parent = box('[Gmail]', selectable: false);
      final appData = box(StoredMailbox.appDataName);
      final folders = [inbox, all, starred, important, parent, appData];

      expect(AccountSynchronizer.foldersToSync(folders, null), [inbox, all]);
      expect(AccountSynchronizer.foldersToSync(folders, {starred.id}), [
        starred,
      ]);
      expect(
        AccountSynchronizer.foldersToSync(folders, {parent.id, appData.id}),
        isEmpty,
      );
    },
  );

  group('Backoff', () {
    test('doubles from 30 s, capped at 1 h, with at most 10% jitter', () {
      final backoff = Backoff(random: Random(1));
      expect(backoff.after(0).inSeconds, inInclusiveRange(30, 33));
      expect(backoff.after(1).inSeconds, inInclusiveRange(60, 66));
      expect(backoff.after(5).inSeconds, inInclusiveRange(960, 1056));
      expect(backoff.after(50).inMinutes, inInclusiveRange(60, 66));
    });
  });

  group('SyncFailure', () {
    test('classifies errors into what the app should do', () {
      expect(
        SyncFailure.from(ImapAuthenticationException('no')).kind,
        SyncFailureKind.authentication,
      );
      expect(
        SyncFailure.from(const MailTlsException(TlsFailure.expired, 'x')).kind,
        SyncFailureKind.security,
      );
      expect(
        SyncFailure.from(const MailSecurityException('x')).kind,
        SyncFailureKind.security,
      );
      expect(
        SyncFailure.from(const MailConnectionException('x')).kind,
        SyncFailureKind.network,
      );
      expect(
        SyncFailure.from(const MailTimeoutException('x')).kind,
        SyncFailureKind.network,
      );
      expect(
        SyncFailure.from(const MailProtocolException('x')).kind,
        SyncFailureKind.server,
      );
      expect(SyncFailure.from(StateError('bug')).kind, SyncFailureKind.server);
    });
  });

  group('SummaryMapper', () {
    const mapper = SummaryMapper(HeaderRuleClassifier());

    FetchedMessage fetched({
      int? uid = 7,
      String? preview,
      List<int>? headers,
      ImapBodyPart? structure,
    }) => FetchedMessage(
      sequence: 1,
      uid: uid,
      flags: {r'\Seen', r'$Forwarded'},
      internalDate: DateTime.utc(2026, 10, 1),
      size: 1234,
      envelope: ImapEnvelope(
        subject: 'Hello',
        messageId: 'm1@x.example',
        from: const [
          MailAddress(
            displayName: 'Ana',
            localPart: 'ana',
            domain: 'x.example',
          ),
        ],
      ),
      preview: preview,
      bodyStructure: structure,
      sections: {
        if (headers != null)
          'HEADER.FIELDS (LIST-ID)': Uint8List.fromList(headers),
      },
    );

    test('maps envelope, flags, size and headers', () {
      final s = mapper.map(
        fetched(
          headers: utf8.encode(
            'List-Id: <l.x.example>\r\nList-Unsubscribe:\r\n <https://x.example/u>\r\n\r\n',
          ),
        ),
      )!;
      expect(s.uid, 7);
      expect(s.subject, 'Hello');
      expect(s.from!.displayName, 'Ana');
      expect(s.flags.seen, isTrue);
      expect(s.flags.keywords, {r'$Forwarded'});
      expect(s.size, 1234);
      expect(s.headers, {
        'list-id': ['<l.x.example>'],
        'list-unsubscribe': ['<https://x.example/u>'],
      });
    });

    test('previews become one clean line, at most 200 characters', () {
      expect(
        mapper
            .map(fetched(preview: 'Hi\r\n\tthere\u0000 ${'x' * 300}'))!
            .snippet,
        hasLength(200),
      );
      expect(
        mapper.map(fetched(preview: 'Hi\r\n\tthere'))!.snippet,
        'Hi there',
      );
      expect(mapper.map(fetched(preview: '   '))!.snippet, isNull);
    });

    test('attachments are kept by name, type and size, not downloaded', () {
      ImapBodyPart leaf(
        String section,
        String type,
        String subtype, {
        String? name,
        String? disposition,
        int size = 0,
      }) => ImapBodyPart(
        section: section,
        contentType: ContentType(
          type,
          subtype,
          MimeParameters({'name': ?name}),
        ),
        encoding: 'BASE64',
        size: size,
        disposition: disposition == null
            ? null
            : ContentDisposition(disposition),
      );
      final s = mapper.map(
        fetched(
          // A server must not be able to plant the app's own header.
          headers: utf8.encode('X-Citusmail-File: {"name":"x.exe"}\r\n\r\n'),
          structure: ImapBodyPart(
            section: '',
            contentType: ContentType('multipart', 'mixed'),
            children: [
              leaf('1', 'text', 'plain', size: 300),
              leaf(
                '2',
                'application',
                'pdf',
                name: 'Invoice 1042.pdf',
                disposition: 'attachment',
                size: 40000,
              ),
            ],
          ),
        ),
      )!;
      expect(s.hasAttachments, isTrue);
      expect(s.headers.keys, [FilePart.storedHeader]);
      expect(
        FilePart.decode(s.headers[FilePart.storedHeader]!.single),
        const FilePart(
          name: 'Invoice 1042.pdf',
          mimeType: 'application/pdf',
          size: 30000,
        ),
      );
      // Without attachments, nothing is kept.
      expect(mapper.map(fetched())!.headers, isEmpty);
    });

    test('messages without a UID are skipped', () {
      expect(mapper.map(fetched(uid: null)), isNull);
    });

    test('asks only for what is needed', () {
      final syntax = SummaryMapper.fetchItems(
        ImapCapabilities(['IMAP4rev1', 'PREVIEW']),
        modSeq: true,
      ).toSyntax();
      expect(syntax, contains('PREVIEW'));
      expect(
        syntax,
        contains('BODY.PEEK[HEADER.FIELDS (List-Id List-Unsubscribe'),
      );
      expect(
        syntax,
        isNot(contains('BODY.PEEK[]')),
        reason: 'never the whole message for a summary',
      );
      expect(
        SummaryMapper.fetchItems(
          ImapCapabilities(['IMAP4rev1']),
          modSeq: false,
        ).toSyntax(),
        isNot(contains('PREVIEW')),
      );
    });
  });

  group('MailActions (local side)', () {
    late Directory dir;
    late MailStore store;
    late Account account;
    late StoredMailbox inbox, archive;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('mail_actions');
      store = MailStore.open('${dir.path}/m.db', DatabaseKey.generate());
      account = store.accounts.add(
        NewAccount(
          email: 'a@x.example',
          username: 'a@x.example',
          imap: ServerSettings(
            host: 'x.example',
            port: 993,
            security: ConnectionSecurity.implicitTls,
          ),
          smtp: ServerSettings(
            host: 'x.example',
            port: 465,
            security: ConnectionSecurity.implicitTls,
          ),
        ),
      );
      final folders = store.mailboxes.replaceAll(account.id, [
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
      inbox = folders.firstWhere((f) => f.isInbox);
      archive = folders.firstWhere((f) => !f.isInbox);
      for (final f in folders) {
        store.mailboxes.saveSyncState(
          f.id,
          const MailboxSyncState(uidValidity: 5),
        );
      }
      store.messages.upsertSummaries(inbox.id, [
        for (var uid = 1; uid <= 3; uid++)
          MessageSummary(uid: uid, receivedAt: DateTime.utc(2026, 1, uid)),
      ]);
    });

    tearDown(() {
      store.close();
      dir.deleteSync(recursive: true);
    });

    List<StoredMessage> all() =>
        store.messages.list(MessageQuery(mailboxIds: [inbox.id]));

    test(
      'mark read changes the store and queues one action with UIDVALIDITY',
      () {
        MailActions(store).markRead(all());
        expect(all().every((m) => m.flags.seen), isTrue);
        final action =
            store.outbox.all(account.id).single.action as SetFlagsAction;
        expect(action.uids.toSet(), {1, 2, 3});
        expect(action.uidValidity, 5);
        expect(action.add, [r'\Seen']);
      },
    );

    test('nothing is queued when nothing changes', () {
      MailActions(store).markRead(all(), read: false);
      expect(store.outbox.all(account.id), isEmpty);
    });

    test('move and delete remove locally and queue', () {
      final actions = MailActions(store);
      final messages = all();
      actions.move([messages[0]], archive);
      actions.delete([messages[1]]);
      expect(all().map((m) => m.uid), [messages[2].uid]);
      final queued = store.outbox.all(account.id).map((e) => e.action).toList();
      expect(
        queued[0],
        isA<MoveAction>().having(
          (a) => a.targetMailboxId,
          'target',
          archive.id,
        ),
      );
      expect(queued[1], isA<DeleteAction>());
    });

    test('sending queues the message with its envelope', () {
      final built = MessageBuilder().build(
        OutgoingMessage(
          from: const MailAddress(localPart: 'a', domain: 'x.example'),
          to: const [MailAddress(localPart: 'b', domain: 'x.example')],
          bcc: const [MailAddress(localPart: 'c', domain: 'x.example')],
          textBody: 'hi',
        ),
      );
      final entry = MailActions(store).send(account, built);
      final action = entry.action as SendAction;
      expect(action.recipients, ['b@x.example', 'c@x.example']);
      expect(action.smtpAccepted, isFalse);
      expect(entry.data, built.bytes);
    });
  });

  test('after a start, a sync runs when a scheduled send is due', () async {
    final directory = Directory.systemTemp.createTempSync('engine_due_test');
    final store = MailStore.open(
      '${directory.path}/mail.db',
      DatabaseKey.generate(),
    );
    addTearDown(() {
      store.close();
      directory.deleteSync(recursive: true);
    });
    final account = store.accounts.add(
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
    // Queued before the app started (no folders yet, so no inbox watch).
    store.outbox.enqueue(
      account.id,
      SendAction(from: 'alice@citusmail.test', recipients: ['b@x.example']),
      data: Uint8List.fromList(utf8.encode('Subject: x\r\n\r\nx\r\n')),
      notBefore: DateTime.now().add(const Duration(milliseconds: 600)),
    );
    final engine = SyncEngine(
      store,
      const _OfflineConnector(),
      fullSyncInterval: const Duration(hours: 1),
    );
    var started = 0;
    engine.events.listen((e) {
      if (e is AccountSyncStarted) started++;
    });
    engine.start();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(started, 1, reason: 'the first sync');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(started, 2, reason: 'one more when it was due');
    await engine.dispose();
  });
}

/// No server is reachable.
final class _OfflineConnector implements MailConnector {
  const _OfflineConnector();

  @override
  Future<ImapClient> imap(Account account) async =>
      throw const MailConnectionException('offline (test)');

  @override
  Future<SmtpClient> smtp(Account account) async =>
      throw const MailConnectionException('offline (test)');

  @override
  Future<ManageSieveClient> sieve(Account account) async =>
      throw const MailConnectionException('offline (test)');
}
