// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fmail/src/services/app_services.dart';
import 'package:fmail/src/services/secret_store.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:mail_web/mail_web.dart';

/// No server is reachable: nothing in these tests touches the network.
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

MailConnector _offline(CredentialProvider _) => const _OfflineConnector();

final class _MemorySecrets implements SecretStore {
  final _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

MailAddress _address(String a, [String? name]) => MailAddress(
  displayName: name,
  localPart: a.split('@').first,
  domain: a.split('@').last,
);

const _letter = '''From: Stranger Danger <stranger@x.example>
To: alice@fmail.test
Subject: Hello there
Content-Type: text/html; charset=utf-8

<p>Visible <b>body</b> text.</p>
<p><img src="https://tracker.example/p.gif" width="1" height="1"></p>
<p><a href="https://shop.example/deal">a link</a></p>
''';

/// The app's services over a temporary encrypted store with sample mail
/// and a sync worker that can't reach any server.
final class TestApp {
  TestApp._(this.directory, this.store, this.services);

  final Directory directory;
  final MailStore store;
  final AppServices services;

  /// [web] answers one-click requests; by default every lookup fails, so
  /// nothing can reach the network.
  static Future<TestApp> create({WebClient? web}) async {
    final directory = Directory.systemTemp.createTempSync('fmail_app_test');

    final path = '${directory.path}/mail.db';
    final key = DatabaseKey.generate();
    final store = MailStore.open(path, key);
    final account = store.accounts.add(
      NewAccount(
        email: 'alice@fmail.test',
        username: 'alice@fmail.test',
        imap: ServerSettings(
          host: 'mail.fmail.test',
          port: 993,
          security: ConnectionSecurity.implicitTls,
        ),
        smtp: ServerSettings(
          host: 'mail.fmail.test',
          port: 465,
          security: ConnectionSecurity.implicitTls,
        ),
      ),
    );
    final boxes = store.mailboxes.replaceAll(account.id, [
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
      ImapMailboxInfo(
        encodedName: 'Archive',
        delimiter: '/',
        attributes: const {r'\Archive'},
      ),
      ImapMailboxInfo(
        encodedName: 'Junk',
        delimiter: '/',
        attributes: const {r'\Junk'},
      ),
      ImapMailboxInfo(
        encodedName: 'Projects',
        delimiter: '/',
        attributes: const {},
      ),
    ]);
    StoredMailbox box(String name) =>
        boxes.firstWhere((b) => b.encodedName == name);
    // As after a first sync: messages only exist in synced folders.
    for (final b in boxes) {
      store.mailboxes.saveSyncState(
        b.id,
        const MailboxSyncState(uidValidity: 1, uidNext: 100),
      );
    }
    store.messages.upsertSummaries(box('Sent').id, [
      MessageSummary(
        uid: 1,
        receivedAt: DateTime.utc(2026, 1),
        from: _address('alice@fmail.test'),
        to: [_address('carol@x.example')],
        flags: MessageFlags.fromImap([r'\Seen']),
      ),
    ]);
    DateTime at(int minute) => DateTime.utc(2026, 10, 20, 9, minute);
    store.messages.upsertSummaries(box('INBOX').id, [
      MessageSummary(
        uid: 1,
        receivedAt: at(1),
        subject: 'Hello there',
        from: _address('stranger@x.example', 'Stranger Danger'),
        snippet: 'Visible body text.',
      ),
      MessageSummary(
        uid: 2,
        receivedAt: at(2),
        subject: 'Lunch?',
        from: _address('carol@x.example', 'Carol'),
      ),
      MessageSummary(
        uid: 3,
        receivedAt: at(3),
        subject: 'Weekly deals',
        from: _address('news@shop.example', 'Shop'),
        category: MessageCategory.newsletters,
      ),
      MessageSummary(
        uid: 4,
        receivedAt: at(4),
        subject: 'Your parcel',
        from: _address('noreply@parcel.example', 'Parcel Co'),
        category: MessageCategory.notifications,
      ),
      MessageSummary(
        uid: 5,
        receivedAt: at(5),
        subject: 'Keep this',
        from: _address('dave@x.example', 'Dave'),
        flags: MessageFlags.fromImap([r'\Flagged', r'\Seen']),
      ),
    ]);
    final hello = store.messages.byUid(box('INBOX').id, 1)!;
    store.messages.saveBody(
      hello.id,
      utf8.encode(_letter.replaceAll('\n', '\r\n')),
      searchableText: 'Visible body text.',
    );
    final worker = await SyncWorker.spawn(
      SyncWorkerConfig(databasePath: path, key: key, connector: _offline),
      credentials: const _NoPassword(),
    );
    return TestApp._(
      directory,
      store,
      AppServices(
        store,
        _MemorySecrets(),
        worker,
        web: web ?? offlineWeb,
        databasePath: path,
        // Fast PIN hashing: the real strength is tested in pin_hasher_test.
        pinRounds: 1000,
      ),
    );
  }

  /// A web client whose lookups all fail.
  static final offlineWeb = WebClient(
    resolver: (_) async => throw const SocketException('offline (test)'),
  );

  static const _authResults =
      'mail.fmail.test; spf=pass smtp.mailfrom=x.example; dmarc=pass header.from=x.example';

  /// Adds an inbox message with [fixture] (from test-data/mail) as its
  /// body. Ten older messages carry the server's Authentication-Results,
  /// so most of the inbox has it and the app learns to trust
  /// `mail.fmail.test`.
  StoredMessage seedFixture(
    String fixture, {
    required String subject,
    required int uid,
    DateTime? receivedAt,
  }) {
    final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
    final raw = File('../test-data/mail/$fixture').readAsBytesSync();
    final parsed = const MimeParser().parse(raw);
    store.messages.upsertSummaries(inbox.id, [
      for (var i = 0; i < 10; i++)
        MessageSummary(
          uid: 50 + i,
          receivedAt: DateTime.utc(2026, 9, 1, i),
          subject: 'Older $i',
          from: const MailAddress(localPart: 'old', domain: 'x.example'),
          flags: MessageFlags.fromImap([r'\Seen']),
          headers: const {
            'authentication-results': [_authResults],
          },
        ),
      MessageSummary(
        uid: uid,
        receivedAt: receivedAt ?? DateTime.utc(2026, 10, 21),
        subject: subject,
        from: parsed.from.first,
        listId: ListId.parse(parsed.headers.value('list-id')),
        headers: {
          for (final name in ['authentication-results', 'list-id'])
            if (parsed.headers.contains(name))
              name: [for (final f in parsed.headers.all(name)) f.value],
        },
      ),
    ]);
    final message = store.messages.byUid(inbox.id, uid)!;
    store.messages.saveBody(
      message.id,
      Uint8List.fromList(
        String.fromCharCodes(raw).replaceAll('\n', '\r\n').codeUnits,
      ),
      searchableText: subject,
    );
    return message;
  }

  Future<void> dispose() async {
    await services.dispose();
    directory.deleteSync(recursive: true);
  }
}

final class _NoPassword implements CredentialProvider {
  const _NoPassword();

  @override
  Future<String> passwordFor(Account account) async => 'unused';
}
