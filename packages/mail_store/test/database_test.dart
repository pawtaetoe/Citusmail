// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

import 'support/temp_store.dart';

const secretSubject = 'TOP-SECRET-SUBJECT-4f8a2c';
const secretBody = 'confidential-body-text-91be7d';

bool fileContains(String path, String text) {
  final file = File(path);
  if (!file.existsSync()) return false;
  return latin1.decode(file.readAsBytesSync()).contains(text) ||
      utf8.decode(file.readAsBytesSync(), allowMalformed: true).contains(text);
}

void main() {
  late TempStore temp;
  setUp(() => temp = TempStore.create());
  tearDown(() => temp.dispose());

  void storeSecrets() {
    final account = temp.addAccount();
    final mailbox =
        temp.store.mailboxes.replaceAll(account.id, []).firstOrNull ??
        (() {
          temp.store.database.execute(
            "INSERT INTO mailboxes (account_id, encoded_name, name) VALUES (?, 'INBOX', 'INBOX')",
            [account.id],
          );
          return temp.store.mailboxes.inbox(account.id)!;
        })();
    temp.store.messages.upsertSummaries(mailbox.id, [
      MessageSummary(
        uid: 1,
        receivedAt: DateTime.utc(2026),
        subject: secretSubject,
      ),
    ]);
    final id = temp.store.messages.byUid(mailbox.id, 1)!.id;
    temp.store.messages.saveBody(
      id,
      Uint8List.fromList(utf8.encode('Subject: x\r\n\r\n$secretBody')),
      searchableText: secretBody,
    );
  }

  group('encryption on disk', () {
    test('no plaintext in the database or its WAL file, open or closed', () {
      storeSecrets();
      for (final suffix in ['', '-wal']) {
        expect(
          fileContains('${temp.path}$suffix', secretSubject),
          isFalse,
          reason: 'subject in $suffix',
        );
        expect(
          fileContains('${temp.path}$suffix', secretBody),
          isFalse,
          reason: 'body in $suffix',
        );
        expect(
          fileContains('${temp.path}$suffix', 'CREATE TABLE'),
          isFalse,
          reason: 'schema in $suffix',
        );
      }
      temp.store.close();
      final header = File(temp.path).readAsBytesSync().sublist(0, 16);
      expect(latin1.decode(header), isNot('SQLite format 3\u0000'));
      expect(fileContains(temp.path, secretSubject), isFalse);
      temp.store = MailStore.open(
        temp.path,
        temp.key,
      ); // so dispose() can close it
    });

    test('the right key reopens the data; a wrong key is refused', () {
      storeSecrets();
      temp.reopen();
      expect(temp.store.messages.search(secretSubject), hasLength(1));
      temp.store.close();
      expect(
        () => MailStore.open(temp.path, DatabaseKey.generate()),
        throwsA(isA<WrongKeyException>()),
      );
      temp.store = MailStore.open(temp.path, temp.key);
    });

    test('safe settings are active', () {
      final db = temp.store.database;
      int pragma(String name) =>
          db.select('PRAGMA $name').first.columnAt(0) as int;
      expect(pragma('temp_store'), 2, reason: 'temporary data stays in memory');
      expect(pragma('secure_delete'), 1);
      expect(pragma('foreign_keys'), 1);
      expect(db.select('PRAGMA journal_mode').first.columnAt(0), 'wal');
      expect(db.select('PRAGMA cipher').first.columnAt(0), 'chacha20');
    });

    test('destroy removes the database and its side files', () {
      storeSecrets();
      temp.store.close();
      MailDatabase.destroy(temp.path);
      for (final suffix in ['', '-wal', '-shm']) {
        expect(File('${temp.path}$suffix').existsSync(), isFalse);
      }
      temp.store = MailStore.open(temp.path, temp.key); // fresh, empty
      expect(temp.store.accounts.all(), isEmpty);
    });
  });

  group('DatabaseKey', () {
    test('is 32 random bytes and never printed', () {
      final a = DatabaseKey.generate(), b = DatabaseKey.generate();
      expect(a.bytes, hasLength(32));
      expect(a.hex, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(a.hex, isNot(b.hex));
      expect(a.toString(), isNot(contains(a.hex)));
      expect(DatabaseKey.fromBytes(a.bytes).hex, a.hex);
    });

    test('rejects wrong sizes', () {
      expect(
        () => DatabaseKey.fromBytes(List.filled(31, 0)),
        throwsArgumentError,
      );
      expect(
        () => DatabaseKey.fromBytes(List.filled(33, 0)),
        throwsArgumentError,
      );
    });
  });

  test('database files and folder are private to the user', () {
    temp.store.database.execute('CREATE TABLE t (x)'); // creates the WAL
    temp.reopen();
    String mode(String path) =>
        (FileStat.statSync(path).mode & 0x1FF).toRadixString(8);
    expect(mode(temp.path), '600');
    expect(mode('${temp.path}-wal'), '600');
    expect(mode(temp.directory.path), '700');
  }, testOn: 'linux || mac-os');

  group('schema migrations', () {
    test('a new database is at the latest schema', () {
      expect(temp.store.database.schemaVersion, schemaMigrations.last.version);
    });

    test('a database from a newer app version is refused, not damaged', () {
      temp.store.database.execute('PRAGMA user_version = 999');
      temp.store.close();
      expect(
        () => MailStore.open(temp.path, temp.key),
        throwsA(isA<DatabaseTooNewException>()),
      );
      final db = MailDatabase.open(
        temp.path,
        temp.key,
        migrations: [
          ...schemaMigrations,
          for (var v = schemaMigrations.last.version + 1; v <= 999; v++)
            Migration(v, const []),
        ],
      );
      expect(db.schemaVersion, 999);
      db.execute('PRAGMA user_version = ${schemaMigrations.last.version}');
      db.close();
      temp.store = MailStore.open(temp.path, temp.key);
    });

    MailDatabase openAt(int version) {
      temp.store.close();
      MailDatabase.destroy(temp.path);
      final db = MailDatabase.open(
        temp.path,
        temp.key,
        migrations: schemaMigrations.sublist(0, version),
      );
      db
        ..execute(
          'INSERT INTO accounts (id, email, username, imap_host, imap_port, imap_security, smtp_host, smtp_port, smtp_security, created_at) '
          "VALUES (1, 'a@fmail.test', 'a', 'h', 993, 'implicitTls', 'h', 465, 'implicitTls', 0)",
        )
        ..execute(
          "INSERT INTO mailboxes (id, account_id, encoded_name, name) VALUES (1, 1, 'INBOX', 'INBOX')",
        );
      return db;
    }

    List<List<Object?>> categories() => temp.store.database
        .select(
          'SELECT uid, category, category_source FROM messages ORDER BY uid',
        )
        .map((r) => [for (final v in r.values) v])
        .toList();

    test('version 1 categories carry over to the latest schema', () {
      openAt(1)
        ..execute(
          'INSERT INTO messages (mailbox_id, uid, received_at, category, category_source) VALUES '
          "(1, 1, 0, 'newsletters', 'rule'), (1, 2, 0, 'notifications', 'manual')",
        )
        ..close();
      temp.store = MailStore.open(temp.path, temp.key);
      expect(categories(), [
        [1, 'newsletters', 'rule'],
        [2, 'notifications', 'rule'],
      ]);
      expect(
        temp.store.messages.byUid(1, 1)!.category,
        MessageCategory.newsletters,
      );
    });

    test('version 2 "Move to" choices are dropped; rules decide again', () {
      openAt(2)
        ..execute(
          'INSERT INTO messages (mailbox_id, uid, received_at, from_address, category, category_source, auto_category, auto_source) '
          "VALUES (1, 1, 0, 'news@shop.example', 'people', 'manual', 'newsletters', 'rule')",
        )
        ..execute(
          'INSERT INTO category_choices (scope, key, category, updated_at) '
          "VALUES ('sender', 'news@shop.example', 'people', 0)",
        )
        ..close();
      temp.store = MailStore.open(temp.path, temp.key);
      expect(categories(), [
        [1, 'newsletters', 'rule'],
      ]);
      expect(
        temp.store.database.select(
          "SELECT name FROM sqlite_master WHERE name IN ('category_choices', 'messages_by_list_id')",
        ),
        isEmpty,
      );
      expect(temp.store.settings.read('anything'), isNull);
    });

    test('version 5 mail gets its Smart Inbox section', () {
      openAt(5)
        ..execute(
          "INSERT INTO mailboxes (id, account_id, encoded_name, name, special_use) VALUES (2, 1, 'Sent', 'Sent', 'sent')",
        )
        ..execute(
          'INSERT INTO messages (id, mailbox_id, uid, received_at, from_address, category, flags) VALUES '
          "(1, 1, 1, 0, 'a@x', 'newsletters', 0), (2, 1, 2, 0, 'b@x', 'people', 4), "
          "(3, 1, 3, 0, 'friend@x', 'people', 0), (4, 1, 4, 0, 'stranger@x', 'people', 0), "
          "(5, 2, 1, 0, 'me@x', 'people', 1)",
        )
        ..execute(
          "INSERT INTO message_addresses (message_id, kind, position, address) VALUES (5, 'to', 0, 'Friend@x')",
        )
        ..close();
      temp.store = MailStore.open(temp.path, temp.key);
      expect(
        temp.store.database
            .select(
              'SELECT id, section FROM messages WHERE mailbox_id = 1 ORDER BY id',
            )
            .map((r) => r['section']),
        ['newsletters', 'pinned', 'important', 'general'],
      );
    });

    test('version 12 mail keeps its category and section; codes fit', () {
      openAt(12)
        ..execute(
          'INSERT INTO messages (id, mailbox_id, uid, received_at, category, section, flags) VALUES '
          "(1, 1, 1, 0, 'newsletters', 'newsletters', 0), (2, 1, 2, 0, 'people', 'pinned', 4)",
        )
        ..close();
      temp.store = MailStore.open(temp.path, temp.key);
      final db = temp.store.database;
      expect(
        db
            .select('SELECT category, section, code FROM messages ORDER BY id')
            .map((r) => (r['category'], r['section'], r['code'])),
        [('newsletters', 'newsletters', null), ('people', 'pinned', null)],
      );
      db.execute(
        "UPDATE messages SET category = 'codes', section = 'codes', code = '123456' WHERE id = 1",
      );
      expect(
        () => db.execute("UPDATE messages SET category = 'other' WHERE id = 1"),
        throwsA(anything),
      );
      expect(
        db.select(
          "SELECT name FROM sqlite_master WHERE name IN ('messages_by_section', 'messages_unread', 'messages_by_category_date')",
        ),
        hasLength(3),
      );
    });

    test('a failing migration rolls back completely', () {
      temp.store.close();
      final broken = [
        ...schemaMigrations,
        Migration(schemaMigrations.last.version + 1, const [
          'CREATE TABLE half_done (x INTEGER)',
          'THIS IS NOT SQL',
        ]),
      ];
      expect(
        () => MailDatabase.open(temp.path, temp.key, migrations: broken),
        throwsA(isA<MigrationException>()),
      );
      temp.store = MailStore.open(temp.path, temp.key);
      expect(temp.store.database.schemaVersion, schemaMigrations.last.version);
      expect(
        temp.store.database.select(
          "SELECT name FROM sqlite_master WHERE name = 'half_done'",
        ),
        isEmpty,
      );
    });
  });

  group('transactions', () {
    test('an exception rolls everything back', () {
      expect(
        () => temp.store.transaction(() {
          temp.addAccount('a@x.example');
          throw StateError('boom');
        }),
        throwsStateError,
      );
      expect(temp.store.accounts.all(), isEmpty);
    });

    test('an inner failure rolls back only the inner part', () {
      temp.store.transaction(() {
        temp.addAccount('outer@x.example');
        try {
          temp.store.transaction(() {
            temp.addAccount('inner@x.example');
            throw StateError('inner');
          });
        } on StateError {
          // handled
        }
      });
      expect(temp.store.accounts.all().map((a) => a.email), [
        'outer@x.example',
      ]);
    });

    test('async work inside a transaction is refused', () {
      expect(
        () => temp.store.transaction(() => Future.value(1)),
        throwsStateError,
      );
    });
  });
}
