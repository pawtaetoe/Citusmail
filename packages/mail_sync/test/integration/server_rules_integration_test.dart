// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Server rules against the real Dovecot + Pigeonhole test server: the app
// stores its Sieve script over ManageSieve, and mail delivered afterwards
// is filed by the server itself, with no device syncing.
//   test-server/fmailtest up
//   FMAIL_INTEGRATION=1 dart test test/integration

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:test/test.dart';

import '../support/test_env.dart';

void main() {
  final skip = integrationSkipReason;
  if (skip != null) {
    test('needs the local test servers', () {}, skip: skip);
    return;
  }
  late TestServers servers;
  late TestDevice device;
  late DefaultMailConnector connector;
  late AccountSynchronizer synchronizer;
  late String folder;
  late String tag;

  setUpAll(() => servers = TestServers.load());

  setUp(() async {
    device = TestDevice.create(servers, 'alice');
    tag = scratchFolder('t').toLowerCase();
    folder = scratchFolder('Rules');
    final other = await servers.otherDevice('alice');
    await other.create(folder);
    await other.logout();
    connector = DefaultMailConnector(
      const TestCredentials(),
      tls: servers.tls,
      // The test server publishes ManageSieve on its own port.
      endpointFor: (s) => servers.endpointFor(
        s.port == ManageSieveClient.port
            ? ServerSettings(
                host: s.host,
                port: servers.ports['SECURE_SIEVE_PORT']!,
                security: s.security,
              )
            : s,
      ),
    );
    synchronizer = AccountSynchronizer(
      device.store,
      connector,
      MailboxSynchronizer(
        device.store,
        const SummaryMapper(HeaderRuleClassifier()),
      ),
      OutboxReplayer(device.store),
      serverRules: ServerRules(device.store, connector.sieve),
    );
  });

  tearDown(() async {
    // Take the script away again, whatever happened.
    device.store.settings.write(ServerRules.settingKey, 'off');
    await ServerRules(device.store, connector.sieve).run(device.account);
    final other = await servers.otherDevice('alice');
    for (final box in ['INBOX', 'Junk']) {
      await other.select(box);
      final found = (await other.uidSearch(
        SearchCriteria.header('Subject', tag),
      )).matches;
      if (!found.isEmpty) {
        await other.uidStore(found, FlagChange.add, {r'\Deleted'});
        await other.uidExpunge(found);
      }
    }
    await other.deleteMailbox(folder);
    await other.logout();
    device.dispose();
  });

  /// Sends as bob (the server checks only the envelope sender), with
  /// [from] in the From header.
  Future<void> deliver(String from, String subject) async {
    final smtp = await SmtpClient.connect(
      ServerEndpoint(
        'mail.fmail.test',
        servers.ports['SECURE_SUBMISSIONS_PORT']!,
        ConnectionSecurity.implicitTls,
        connectAddress: '127.0.0.1',
      ),
      tls: servers.tls,
    );
    await smtp.authenticate('bob@fmail.test', 'bob-test-password');
    final at = from.lastIndexOf('@');
    await smtp.send(
      MessageBuilder().build(
        OutgoingMessage(
          from: MailAddress(
            localPart: from.substring(0, at),
            domain: from.substring(at + 1),
          ),
          to: const [MailAddress(localPart: 'alice', domain: 'fmail.test')],
          subject: subject,
          textBody: 'Server rules test.',
        ),
      ),
      from: const MailAddress(localPart: 'bob', domain: 'fmail.test'),
    );
    await smtp.quit();
  }

  /// UIDs of messages with [subject] in [box], waiting up to 10 s.
  Future<int> countIn(String box, String subject) async {
    final other = await servers.otherDevice('alice');
    try {
      for (var i = 0; i < 20; i++) {
        await other.select(box, readOnly: true);
        final found = (await other.uidSearch(
          SearchCriteria.header('Subject', subject),
        )).matches.length;
        if (found > 0 || i == 19) return found;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      return 0;
    } finally {
      await other.logout();
    }
  }

  test('the server files blocked and ruled mail by itself', () async {
    // The folder list, so rules can name the folder.
    await synchronizer.sync(device.account, mailboxIds: const {});
    final target = device.mailbox(folder);
    device.store.folderRules.add(
      accountId: device.account.id,
      mailboxId: target.id,
      field: RuleField.subject,
      value: 'rule-$tag',
    );
    device.store.blocks.block(BlockKind.address, 'pest-$tag@x.example');
    device.store.blocks.block(BlockKind.domain, 'spam-$tag.example');
    device.store.settings.write(ServerRules.settingKey, 'on');

    final report = await synchronizer.sync(
      device.account,
      mailboxIds: const {},
    );
    expect(
      report.serverRules?.state,
      ServerRulesState.active,
      reason: report.serverRules?.detail,
    );

    // Nothing syncs from here on: only the server acts. (Nothing is sent
    // that would stay in INBOX: other tests count its messages.)
    await deliver('bob@fmail.test', 'rule-$tag Rechnung Übersicht');
    await deliver('pest-$tag@x.example', 'blocked address $tag');
    await deliver('news@mail.spam-$tag.example', 'blocked subdomain $tag');

    expect(await countIn(folder, 'rule-$tag'), 1);
    expect(await countIn('Junk', 'blocked address $tag'), 1);
    expect(await countIn('Junk', 'blocked subdomain $tag'), 1);
    expect(await countIn('INBOX', 'rule-$tag'), 0);
  });

  test('the server checks the script; turning off removes it', () async {
    await synchronizer.sync(device.account, mailboxIds: const {});
    device.store.blocks.block(BlockKind.address, 'pest-$tag@x.example');
    device.store.settings.write(ServerRules.settingKey, 'on');
    await synchronizer.sync(device.account, mailboxIds: const {});

    final sieve = await connector.sieve(device.account);
    expect(
      (await sieve.listScripts()).where((s) => s.active).map((s) => s.name),
      [ServerRules.scriptName],
    );
    final script = await sieve.getScript(ServerRules.scriptName);
    expect(script, contains('pest-$tag@x.example'));
    expect(await sieve.checkScript(script), isNull, reason: 'valid as stored');
    await sieve.logout();

    device.store.settings.write(ServerRules.settingKey, 'off');
    await ServerRules(device.store, connector.sieve).run(device.account);
    final after = await connector.sieve(device.account);
    expect(await after.listScripts(), isEmpty);
    await after.logout();
  });
}
