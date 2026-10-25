// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

final _certs = Directory('../../test-server/.generated/certs');
final _haveCerts = File('${_certs.path}/mail.crt').existsSync();

ImapMailboxInfo _folder(String name, {String? use}) => ImapMailboxInfo(
  encodedName: name,
  delimiter: '/',
  attributes: {if (use != null) '\\$use'},
);

StoredMailbox _box(int id, String name, {bool selectable = true}) =>
    StoredMailbox(
      id: id,
      accountId: 1,
      encodedName: name,
      name: name,
      selectable: selectable,
      syncState: MailboxSyncState.empty,
      delimiter: '/',
    );

FolderRule _rule(int id, int mailboxId, RuleField field, String value) =>
    FolderRule(
      id: id,
      accountId: 1,
      mailboxId: mailboxId,
      field: field,
      value: value,
      appliesFrom: DateTime.utc(2026),
      createdAt: DateTime.utc(2026),
    );

/// A ManageSieve server over implicit TLS that keeps scripts in memory.
final class _SieveServer {
  _SieveServer._(this._server);

  static Future<_SieveServer> start({String sieve = 'fileinto'}) async {
    final context = SecurityContext()
      ..useCertificateChain('${_certs.path}/mail.crt')
      ..usePrivateKey('${_certs.path}/mail.key');
    final server = _SieveServer._(
      await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, context),
    );
    server._sieve = sieve;
    server._listen();
    return server;
  }

  final SecureServerSocket _server;
  late String _sieve;
  final scripts = <String, String>{};
  String? active;
  int sessions = 0;

  int get port => _server.port;

  void _listen() => _server.listen((socket) {
    sessions++;
    socket.add(
      utf8.encode(
        '"IMPLEMENTATION" "Fake"\r\n"SIEVE" "$_sieve"\r\n'
        '"SASL" "PLAIN"\r\n"VERSION" "1.0"\r\nOK\r\n',
      ),
    );
    var buffer = Uint8List(0);
    String? pending;
    socket.listen(
      (data) {
        buffer = Uint8List.fromList([...buffer, ...data]);
        while (true) {
          if (pending != null) {
            final n = int.parse(
              RegExp(r'\{(\d+)\+\}$').firstMatch(pending!)!.group(1)!,
            );
            if (buffer.length < n + 2) return;
            final script = utf8.decode(buffer.sublist(0, n));
            buffer = buffer.sublist(n + 2);
            final name = RegExp(r'"([^"]*)"').firstMatch(pending!)!.group(1)!;
            scripts[name] = script;
            pending = null;
            socket.add(utf8.encode('OK\r\n'));
            continue;
          }
          final end = buffer.indexOf(0x0A);
          if (end < 0) return;
          final line = utf8.decode(buffer.sublist(0, end)).trimRight();
          buffer = buffer.sublist(end + 1);
          if (RegExp(r'\{\d+\+\}$').hasMatch(line)) {
            pending = line;
            continue;
          }
          final arg = RegExp(r'"([^"]*)"').firstMatch(line)?.group(1);
          final reply = switch (line.split(' ').first) {
            'AUTHENTICATE' => 'OK\r\n',
            'LISTSCRIPTS' => [
              for (final name in scripts.keys)
                '"$name"${name == active ? ' ACTIVE' : ''}\r\n',
              'OK\r\n',
            ].join(),
            'SETACTIVE' => () {
              active = arg!.isEmpty ? null : arg;
              return 'OK\r\n';
            }(),
            'DELETESCRIPT' => () {
              if (arg == active) return 'NO (ACTIVE) "active"\r\n';
              scripts.remove(arg);
              return 'OK\r\n';
            }(),
            'LOGOUT' => 'OK\r\n',
            _ => 'NO "unknown"\r\n',
          };
          socket.add(utf8.encode(reply));
        }
      },
      onError: (_) {},
      onDone: socket.destroy,
    );
  }, onError: (Object _) {});

  Future<void> close() => _server.close();
}

void main() {
  group('SieveRules.script', () {
    final junk = _box(2, 'Junk');
    final receipts = _box(3, 'Receipts');
    final work = _box(4, 'Work/Ärger');

    test('nothing to run', () {
      expect(
        SieveRules.script(
          blocks: const [],
          blockTarget: junk,
          rules: const [],
          folders: const {},
          extensions: const {'fileinto'},
        ),
        isNull,
      );
    });

    test('blocks first (addresses, then domains), then rules in order', () {
      final script = SieveRules.script(
        blocks: [
          BlockedSender(
            id: 1,
            kind: BlockKind.domain,
            value: 'spam.example',
            since: DateTime.utc(2026),
          ),
          BlockedSender(
            id: 2,
            kind: BlockKind.address,
            value: 'pest@x.example',
            since: DateTime.utc(2026),
          ),
        ],
        blockTarget: junk,
        rules: [
          _rule(1, 3, RuleField.fromDomain, 'shop.example'),
          _rule(2, 4, RuleField.subject, 'Prüfung "Q3"'),
          _rule(3, 4, RuleField.toAddress, 'alias@me.example'),
          _rule(4, 3, RuleField.fromAddress, 'bills@power.example'),
          _rule(5, 99, RuleField.fromAddress, 'gone@x.example'),
        ],
        folders: {3: receipts, 4: work},
        extensions: const {'fileinto', 'comparator-i;unicode-casemap'},
      )!;
      expect(
        script,
        '# Citusmail: your blocked senders and folder rules, kept up to date\r\n'
        '# by the app. Changes made here are replaced.\r\n'
        'require ["fileinto", "comparator-i;unicode-casemap"];\r\n'
        'if address :is "from" "pest@x.example" {\r\n  fileinto "Junk";\r\n  stop;\r\n}\r\n'
        'if anyof (address :domain :is "from" "spam.example", '
        'address :domain :matches "from" "*.spam.example") {\r\n  fileinto "Junk";\r\n  stop;\r\n}\r\n'
        'if anyof (address :domain :is "from" "shop.example", '
        'address :domain :matches "from" "*.shop.example") {\r\n  fileinto "Receipts";\r\n  stop;\r\n}\r\n'
        'if header :contains :comparator "i;unicode-casemap" "subject" "Prüfung \\"Q3\\"" '
        '{\r\n  fileinto "Work/Ärger";\r\n  stop;\r\n}\r\n'
        'if address :is ["to", "cc"] "alias@me.example" {\r\n  fileinto "Work/Ärger";\r\n  stop;\r\n}\r\n'
        'if address :is "from" "bills@power.example" {\r\n  fileinto "Receipts";\r\n  stop;\r\n}\r\n',
      );
    });

    test('values can never break out of their string', () {
      final script = SieveRules.script(
        blocks: const [],
        blockTarget: null,
        rules: [
          _rule(1, 3, RuleField.subject, 'a"; discard; #\\'),
          _rule(2, 3, RuleField.subject, 'line\r\nbreak'),
        ],
        folders: {3: receipts},
        extensions: const {'fileinto'},
      )!;
      expect(script, contains(r'"a\"; discard; #\\"'));
      expect(script, contains('"line  break"'));
      expect(script, isNot(contains('unicode-casemap')));
      expect(script, contains('require "fileinto";'));
    });

    test('rules into the inbox or a folder that is gone are left out', () {
      expect(
        SieveRules.script(
          blocks: const [],
          blockTarget: null,
          rules: [_rule(1, 5, RuleField.subject, 'x')],
          folders: {5: _box(5, 'INBOX'), 6: _box(6, 'Old', selectable: false)},
          extensions: const {'fileinto'},
        ),
        isNull,
      );
    });
  });

  group('ServerRules', () {
    late Directory directory;
    late MailStore store;
    late Account account;
    late _SieveServer server;
    late DateTime now;
    late Map<String, StoredMailbox> boxes;

    ServerRules rules() => ServerRules(store, (account) async {
      final client = await ManageSieveClient.connect(
        ServerEndpoint(
          'mail.fmail.test',
          server.port,
          ConnectionSecurity.implicitTls,
          connectAddress: '127.0.0.1',
        ),
        tls: TlsSettings.trustOnly(
          File('${_certs.path}/ca.crt').readAsBytesSync(),
        ),
      );
      await client.authenticate(account.username, 'pw');
      return client;
    }, now: () => now);

    setUp(() async {
      directory = Directory.systemTemp.createTempSync('server_rules_test');
      store = MailStore.open('${directory.path}/m.db', DatabaseKey.generate());
      account = store.accounts.add(
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
      boxes = {
        for (final b in store.mailboxes.replaceAll(account.id, [
          _folder('INBOX'),
          _folder('Junk', use: 'Junk'),
          _folder('Receipts'),
        ]))
          b.name: b,
      };
      server = await _SieveServer.start();
      now = DateTime.utc(2026, 10, 25, 12);
    });

    tearDown(() async {
      store.close();
      directory.deleteSync(recursive: true);
      await server.close();
    });

    test('off: nothing is touched', () async {
      store.blocks.block(BlockKind.address, 'pest@x.example');
      expect(await rules().run(account), isNull);
      expect(server.sessions, 0);
    });

    test('on: stored and activated once; again only after a change', () async {
      store.settings.write(ServerRules.settingKey, 'on');
      store.blocks.block(BlockKind.address, 'pest@x.example');
      final first = await rules().run(account);
      expect(first!.state, ServerRulesState.active);
      expect(server.active, ServerRules.scriptName);
      expect(
        server.scripts[ServerRules.scriptName],
        contains('pest@x.example'),
      );
      expect(server.sessions, 1);

      // Nothing changed: no connection.
      now = now.add(const Duration(hours: 1));
      expect((await rules().run(account))!.state, ServerRulesState.active);
      expect(server.sessions, 1);

      store.folderRules.add(
        accountId: account.id,
        mailboxId: boxes['Receipts']!.id,
        field: RuleField.fromDomain,
        value: 'shop.example',
      );
      await rules().run(account);
      expect(server.sessions, 2);
      expect(server.scripts[ServerRules.scriptName], contains('Receipts'));
      expect(rules().status(account.id)!.state, ServerRulesState.active);
    });

    test('another active script is left alone', () async {
      store.settings.write(ServerRules.settingKey, 'on');
      store.blocks.block(BlockKind.address, 'pest@x.example');
      server
        ..scripts['roundcube'] = 'keep;'
        ..active = 'roundcube';
      final status = await rules().run(account);
      expect(status!.state, ServerRulesState.otherScriptActive);
      expect(status.detail, 'roundcube');
      expect(server.scripts.keys, ['roundcube']);
      expect(server.active, 'roundcube');
    });

    test('turned off, or nothing left: the script is removed', () async {
      store.settings.write(ServerRules.settingKey, 'on');
      final block = store.blocks.block(BlockKind.address, 'pest@x.example');
      await rules().run(account);
      expect(server.active, ServerRules.scriptName);

      store.blocks.unblock(block.id);
      expect(
        (await rules().run(account))!.state,
        ServerRulesState.nothingToRun,
      );
      expect(server.scripts, isEmpty);
      expect(server.active, isNull);

      store.blocks.block(BlockKind.address, 'pest@x.example');
      await rules().run(account);
      expect(server.active, ServerRules.scriptName);
      store.settings.write(ServerRules.settingKey, 'off');
      expect(await rules().run(account), isNull);
      expect(server.scripts, isEmpty);
      expect(rules().status(account.id), isNull);
    });

    test('a server without ManageSieve is asked again after a day', () async {
      store.settings.write(ServerRules.settingKey, 'on');
      store.blocks.block(BlockKind.address, 'pest@x.example');
      var attempts = 0;
      final unsupported = ServerRules(store, (account) async {
        attempts++;
        throw const MailConnectionException('connection refused');
      }, now: () => now);
      expect(
        (await unsupported.run(account))!.state,
        ServerRulesState.notSupported,
      );
      await unsupported.run(account);
      expect(attempts, 1);
      now = now.add(const Duration(days: 2));
      await unsupported.run(account);
      expect(attempts, 2);
    });
  }, skip: _haveCerts ? null : 'needs test-server certificates');
}
