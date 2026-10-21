// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

/// Why integration tests are skipped, or null when they should run.
String? get integrationSkipReason =>
    Platform.environment['FMAIL_INTEGRATION'] == '1'
    ? null
    : 'integration tests: run test-server/fmailtest up, then set FMAIL_INTEGRATION=1';

/// Ports and CA of the local test servers (test-server/).
final class TestServers {
  TestServers._(this.ports, this.tls);

  static TestServers load() {
    final ports = <String, int>{};
    for (final line in File(
      '../../test-server/servers.env',
    ).readAsLinesSync()) {
      final m = RegExp(r'^([A-Z_]+_PORT)=(\d+)$').firstMatch(line.trim());
      if (m != null) ports[m.group(1)!] = int.parse(m.group(2)!);
    }
    final ca = File('../../test-server/.generated/certs/ca.crt')
        .readAsBytesSync();
    return TestServers._(ports, TlsSettings.trustOnly(ca));
  }

  final Map<String, int> ports;
  final TlsSettings tls;

  /// Connects to 127.0.0.1 while checking the certificate for the stored
  /// host name, like a real connection.
  ServerEndpoint endpointFor(ServerSettings s) =>
      ServerEndpoint(s.host, s.port, s.security, connectAddress: '127.0.0.1');

  /// A direct IMAP connection playing "another device".
  Future<ImapClient> otherDevice(
    String user, {
    String imapPort = 'SECURE_IMAPS_PORT',
  }) async {
    final client = await ImapClient.connect(
      ServerEndpoint(
        'mail.fmail.test',
        ports[imapPort]!,
        ConnectionSecurity.implicitTls,
        connectAddress: '127.0.0.1',
      ),
      tls: tls,
    );
    await client.login('$user@fmail.test', '$user-test-password');
    return client;
  }
}

final class TestCredentials implements CredentialProvider {
  const TestCredentials();

  @override
  Future<String> passwordFor(Account account) async =>
      '${account.email.split('@').first}-test-password';
}

/// One simulated device: its own encrypted store, connector and sync parts.
final class TestDevice {
  TestDevice._(
    this.directory,
    this.key,
    this.store,
    this.account,
    this.connector,
    this.synchronizer,
    this.actions,
  );

  static TestDevice create(
    TestServers servers,
    String user, {
    String imapPort = 'SECURE_IMAPS_PORT',
    bool useQresync = true,
    SyncSettings settings = const SyncSettings(),
  }) {
    final directory = Directory.systemTemp.createTempSync('mail_sync_test');
    final key = DatabaseKey.generate();
    final store = MailStore.open('${directory.path}/mail.db', key);
    final account = store.accounts.add(
      NewAccount(
        email: '$user@fmail.test',
        username: '$user@fmail.test',
        imap: ServerSettings(
          host: 'mail.fmail.test',
          port: servers.ports[imapPort]!,
          security: ConnectionSecurity.implicitTls,
        ),
        smtp: ServerSettings(
          host: 'mail.fmail.test',
          port: servers.ports['SECURE_SUBMISSIONS_PORT']!,
          security: ConnectionSecurity.implicitTls,
        ),
      ),
    );
    final connector = DefaultMailConnector(
      const TestCredentials(),
      tls: servers.tls,
      useQresync: useQresync,
      endpointFor: servers.endpointFor,
    );
    final synchronizer = AccountSynchronizer(
      store,
      connector,
      MailboxSynchronizer(
        store,
        const SummaryMapper(HeaderRuleClassifier()),
        settings: settings,
      ),
      OutboxReplayer(store),
    );
    return TestDevice._(
      directory,
      key,
      store,
      account,
      connector,
      synchronizer,
      MailActions(store),
    );
  }

  final Directory directory;
  final DatabaseKey key;
  final MailStore store;
  final Account account;
  final DefaultMailConnector connector;
  final AccountSynchronizer synchronizer;
  final MailActions actions;

  /// Syncs the folder list, the queue, and the named folders only.
  Future<AccountSyncReport> sync(List<String> folderNames) async {
    final known = store.mailboxes
        .forAccount(account.id)
        .map((m) => m.encodedName)
        .toSet();
    AccountSyncReport? listing;
    if (!folderNames.every(known.contains)) {
      // Folder ids are only known after the folder list is stored.
      listing = await synchronizer.sync(account, mailboxIds: const {});
    }
    final ids = {for (final name in folderNames) mailbox(name).id};
    final report = await synchronizer.sync(account, mailboxIds: ids);
    if (listing == null) return report;
    // The queue may have been replayed by the listing sync: count both.
    return AccountSyncReport(
      replay: ReplayResult(
        completed: listing.replay.completed + report.replay.completed,
        failed: listing.replay.failed + report.replay.failed,
        deferred: listing.replay.deferred + report.replay.deferred,
      ),
      mailboxes: report.mailboxes,
    );
  }

  StoredMailbox mailbox(String encodedName) => store.mailboxes
      .forAccount(account.id)
      .firstWhere((m) => m.encodedName == encodedName);

  List<StoredMessage> messages(String encodedName) => store.messages.list(
    MessageQuery(mailboxIds: [mailbox(encodedName).id], limit: 500),
  );

  String get databasePath => '${directory.path}/mail.db';

  void dispose() {
    store.close();
    directory.deleteSync(recursive: true);
  }
}

/// A connector factory the sync worker can run. Top-level, so the closure
/// holds only [servers] (plain data) and can be sent to the worker.
ConnectorFactory testConnector(TestServers servers) =>
    (credentials) => DefaultMailConnector(
      credentials,
      tls: servers.tls,
      endpointFor: servers.endpointFor,
    );

/// A unique folder name for one test run.
String scratchFolder([String prefix = 'Sync']) =>
    '$prefix${Random.secure().nextInt(1 << 32).toRadixString(16)}';

/// A small message with a unique Message-ID.
Uint8List testMessage(String subject, {String to = 'alice@fmail.test'}) {
  final at = to.split('@').last;
  return MessageBuilder()
      .build(
        OutgoingMessage(
          from: MailAddress(localPart: to.split('@').first, domain: at),
          to: [MailAddress(localPart: to.split('@').first, domain: at)],
          subject: subject,
          textBody: 'Body of $subject',
        ),
      )
      .bytes;
}
