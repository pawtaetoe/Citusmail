// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Runs against the local test servers:
//   test-server/citusmailtest up
//   CITUSMAIL_INTEGRATION=1 dart test test/integration
//
// Tests that change mail work only in folders they create with a random
// name, so the seeded folders stay as they are.

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:test/test.dart';

import '../support/test_servers.dart';

Uint8List sampleMessage(String subject) => MessageBuilder()
    .build(
      OutgoingMessage(
        from: const MailAddress(localPart: 'alice', domain: 'citusmail.test'),
        to: [const MailAddress(localPart: 'alice', domain: 'citusmail.test')],
        subject: subject,
        textBody: 'Test body for $subject',
      ),
    )
    .bytes;

String scratchName() =>
    'CitusmailTest-${Random.secure().nextInt(1 << 32).toRadixString(16)}';

void main() {
  final skip = TestServers.skipReason;
  if (skip != null) {
    test('needs the local test servers', () {}, skip: skip);
    return;
  }
  final servers = TestServers.load();

  group('connecting', () {
    test('implicit TLS, capabilities and login', () async {
      final client = await ImapClient.connect(
        servers.secureImaps,
        tls: servers.tls,
      );
      expect(client.capabilities.has('IMAP4REV1'), isTrue);
      await client.login(
        TestServers.address('alice'),
        TestServers.password('alice'),
      );
      expect(client.isAuthenticated, isTrue);
      for (final cap in [
        'IDLE',
        'CONDSTORE',
        'QRESYNC',
        'MOVE',
        'UIDPLUS',
        'SPECIAL-USE',
      ]) {
        expect(client.capabilities.has(cap), isTrue, reason: cap);
      }
      await client.logout();
    });

    test(
      'STARTTLS upgrades before login, and capabilities are re-read',
      () async {
        final client = await ImapClient.connect(
          servers.secureImapStartTls,
          tls: servers.tls,
        );
        expect(
          client.capabilities.has('LOGINDISABLED'),
          isFalse,
          reason: 'must be the post-TLS list',
        );
        await client.login(
          TestServers.address('bob'),
          TestServers.password('bob'),
        );
        await client.logout();
      },
    );

    test(
      'wrong password is an authentication error and keeps the connection',
      () async {
        final client = await ImapClient.connect(
          servers.secureImaps,
          tls: servers.tls,
        );
        await expectLater(
          client.login(TestServers.address('alice'), 'wrong'),
          throwsA(isA<ImapAuthenticationException>()),
        );
        expect(client.isUsable, isTrue);
        await client.login(
          TestServers.address('alice'),
          TestServers.password('alice'),
        );
        await client.logout();
      },
    );

    test('a server without encryption is refused', () async {
      await expectLater(
        ImapClient.connect(servers.plainImap, tls: servers.tls),
        throwsA(isA<MailSecurityException>()),
      );
    });

    final certificateCases = {
      'expired.citusmail.test': TlsFailure.expired,
      'untrusted.citusmail.test': TlsFailure.untrusted,
      'wrong-name.citusmail.test': TlsFailure.hostnameMismatch,
    };
    for (final MapEntry(key: name, value: failure)
        in certificateCases.entries) {
      test('certificate for $name is refused ($failure)', () async {
        final endpoint = servers.endpoint(
          'SECURE_IMAPS_PORT',
          ConnectionSecurity.implicitTls,
          tlsName: name,
        );
        await expectLater(
          ImapClient.connect(endpoint, tls: servers.tls),
          throwsA(
            isA<MailTlsException>().having(
              (e) => e.failure,
              'failure',
              failure,
            ),
          ),
        );
      });
    }

    test(
      'the test CA is not trusted by default (system trust store only)',
      () async {
        await expectLater(
          ImapClient.connect(servers.secureImaps),
          throwsA(isA<MailTlsException>()),
        );
      },
    );
  });

  group('reading', () {
    late ImapClient client;
    setUp(() async => client = await servers.imap('alice'));
    tearDown(() => client.logout());

    test('folders with special use, nesting and non-ASCII names', () async {
      final folders = await client.listMailboxes();
      final byUse = {
        for (final f in folders)
          if (f.specialUse != null) f.specialUse!: f.name,
      };
      expect(byUse, containsPair(SpecialUse.sent, 'Sent'));
      expect(byUse, containsPair(SpecialUse.junk, 'Junk'));
      expect(byUse, containsPair(SpecialUse.drafts, 'Drafts'));
      expect(
        folders.map((f) => f.name),
        containsAll(['INBOX', 'Projects/2026', '日本語']),
      );
    });

    test('select reports UIDVALIDITY, counts and a mod-sequence', () async {
      final inbox = await client.select('INBOX');
      expect(inbox.exists, 22);
      expect(inbox.uidValidity, greaterThan(0));
      expect(inbox.highestModSeq, isNotNull);
      expect(inbox.readOnly, isFalse);
      final status = await client.status('INBOX', highestModSeq: true);
      expect(status.messages, 22);
      expect(status.uidValidity, inbox.uidValidity);
    });

    test('summary fetch of every message', () async {
      await client.select('INBOX', readOnly: true);
      final result = await client.uidFetch(
        SequenceSet.all(),
        FetchItems.summary(modSeq: true),
      );
      expect(result.messages, hasLength(22));
      final lunch = result.messages.firstWhere(
        (m) => m.envelope?.messageId == 'lunch-1@citusmail.test',
      );
      expect(lunch.envelope!.subject, 'Lunch on Friday?');
      expect(lunch.hasFlag(r'\Seen'), isTrue);
      expect(lunch.internalDate, DateTime.utc(2026, 10, 12, 1, 15));
      expect(lunch.modSeq, isNotNull);
      final japanese = result.messages.where(
        (m) => m.envelope?.messageId == 'kaigi@kaisha.example',
      );
      expect(japanese, isEmpty, reason: 'that one is in the 日本語 folder');
    });

    test(
      'BODYSTRUCTURE sections match the MIME parser, and parts download alone',
      () async {
        await client.select(
          MailboxNameCodec.encode('Projects/2026'),
          readOnly: true,
        );
        final summary = await client.uidFetch(
          SequenceSet.all(),
          FetchItems.summary(),
        );
        final message = summary.messages.single;
        final pdf = message.bodyStructure!.allParts.firstWhere(
          (p) => p.contentType.mimeType == 'application/pdf',
        );
        expect(pdf.section, '2');
        expect(pdf.filename, 'invoice-2026-10.pdf');

        final part = await client.uidFetch(
          SequenceSet.of([message.uid!]),
          FetchItems(sections: [pdf.section]),
        );
        final decoded = const Base64Decoder().decode(
          part.messages.single.sections['2']!,
        );
        expect(utf8.decode(decoded.bytes.sublist(0, 8)), '%PDF-1.4');

        final full = await client.uidFetch(
          SequenceSet.of([message.uid!]),
          FetchItems(fullMessage: true),
        );
        final parsed = const MimeParser().parse(
          full.messages.single.sections['']!,
        );
        expect(parsed.attachments.single.section, pdf.section);
      },
    );

    test('reading a message never marks it seen (BODY.PEEK)', () async {
      await client.select('INBOX');
      final unseen = await client.uidSearch(SearchCriteria.unseen());
      final uid = unseen.matches.toList().first;
      await client.uidFetch(
        SequenceSet.of([uid]),
        FetchItems(fullMessage: true),
      );
      final again = await client.uidSearch(SearchCriteria.unseen());
      expect(again.matches.contains(uid), isTrue);
    });

    test('carol (Namecheap layout): the \\Junk folder is INBOX.spam, not INBOX.Junk', () async {
      final carol = await servers.imap('carol');
      final folders = await carol.listMailboxes();
      expect(
        folders.firstWhere((f) => f.specialUse == SpecialUse.junk).name,
        'INBOX.spam',
      );
      expect(
        folders.firstWhere((f) => f.name == 'INBOX.Junk').specialUse,
        isNull,
      );
      await carol.logout();
    });
  });

  group('writing (in scratch folders)', () {
    late ImapClient client;
    late String folder;
    setUp(() async {
      client = await servers.imap('alice');
      folder = scratchName();
      await client.create(folder);
    });
    tearDown(() => client.logout());

    test('append, search, store with UNCHANGEDSINCE, move', () async {
      final mapping = await client.append(
        folder,
        sampleMessage('one'),
        flags: {r'\Seen'},
        internalDate: DateTime.utc(2026, 10, 1, 8),
      );
      expect(mapping, isNotNull);
      final uid = mapping!.destinationUids.toList().single;

      final selected = await client.select(folder);
      expect(selected.uidValidity, mapping.uidValidity);
      final found = await client.uidSearch(
        SearchCriteria.header('Subject', 'one'),
      );
      expect(found.matches.toList(), [uid]);

      final fetched = await client.uidFetch(
        SequenceSet.of([uid]),
        FetchItems(flags: true, modSeq: true, internalDate: true),
      );
      final modSeq = fetched.messages.single.modSeq!;
      expect(
        fetched.messages.single.internalDate,
        DateTime.utc(2026, 10, 1, 8),
      );

      final store = await client.uidStore(
        SequenceSet.of([uid]),
        FlagChange.add,
        {r'\Flagged'},
        unchangedSince: modSeq,
      );
      expect(store.notModified, isNull);
      // A second change based on the old mod-sequence is refused, which is
      // how a device avoids overwriting another device's newer change.
      final stale = await client.uidStore(
        SequenceSet.of([uid]),
        FlagChange.remove,
        {r'\Seen'},
        unchangedSince: modSeq,
      );
      expect(stale.notModified?.contains(uid), isTrue);

      final target = scratchName();
      await client.create(target);
      final moved = await client.uidMove(SequenceSet.of([uid]), target);
      expect(moved.mapping!.sourceUids!.toList(), [uid]);
      expect((await client.status(folder)).messages, 0);
      expect((await client.status(target)).messages, 1);
    });

    test('creating an existing folder is fine', () async {
      await client.create(folder);
    });

    test('limited server: move without MOVE uses COPY + UID EXPUNGE', () async {
      final limited = await servers.imap(
        'alice',
        endpoint: servers.limitedImaps,
      );
      expect(limited.capabilities.has('MOVE'), isFalse);
      final source = scratchName(), target = scratchName();
      await limited.create(source);
      await limited.create(target);
      final uid = (await limited.append(
        source,
        sampleMessage('limited'),
      ))!.destinationUids.toList().single;
      final selected = await limited.select(source);
      expect(
        selected.highestModSeq,
        isNull,
        reason: 'no CONDSTORE on the limited server',
      );
      final result = await limited.uidMove(SequenceSet.of([uid]), target);
      expect(result.originalsMarkedDeleted, isFalse);
      expect((await limited.status(source)).messages, 0);
      expect((await limited.status(target)).messages, 1);
      await limited.logout();
    });
  });

  group('change tracking', () {
    test('IDLE reports new mail within seconds', () async {
      final watcher = await servers.imap('alice');
      final writer = await servers.imap('alice');
      final folder = scratchName();
      await writer.create(folder);
      await watcher.select(folder);

      final gotExists = Completer<int>();
      final subscription = watcher.events.listen((event) {
        if (event is ImapExistsEvent && !gotExists.isCompleted) {
          gotExists.complete(event.count);
        }
      });
      final idling = watcher.idle(
        until: gotExists.future.timeout(const Duration(seconds: 15)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await writer.append(folder, sampleMessage('idle'));

      expect(await gotExists.future.timeout(const Duration(seconds: 15)), 1);
      await idling;
      await subscription.cancel();
      await watcher.logout();
      await writer.logout();
    });

    test(
      'QRESYNC reports flag changes and removals since the cached state',
      () async {
        final device = await servers.imap('alice');
        expect(await device.enable(['QRESYNC']), contains('QRESYNC'));
        final folder = scratchName();
        await device.create(folder);
        final a = (await device.append(
          folder,
          sampleMessage('a'),
        ))!.destinationUids.toList().single;
        final b = (await device.append(
          folder,
          sampleMessage('b'),
        ))!.destinationUids.toList().single;
        final cached = await device.select(folder);
        await device.logout();

        // Another device changes a flag and removes a message.
        final other = await servers.imap('alice');
        await other.select(folder);
        await other.uidStore(SequenceSet.of([a]), FlagChange.add, {r'\Seen'});
        await other.uidStore(SequenceSet.of([b]), FlagChange.add, {
          r'\Deleted',
        });
        await other.uidExpunge(SequenceSet.of([b]));
        await other.logout();

        final again = await servers.imap('alice');
        await again.enable(['QRESYNC']);
        final resync = await again.select(
          folder,
          qresync: QresyncParameters(
            uidValidity: cached.uidValidity,
            highestModSeq: cached.highestModSeq!,
            knownUids: SequenceSet.of([a, b]),
          ),
        );
        expect(resync.vanished?.toList(), [b]);
        expect(resync.changedMessages.single.uid, a);
        expect(resync.changedMessages.single.hasFlag(r'\Seen'), isTrue);
        await again.logout();
      },
    );
  });
}
