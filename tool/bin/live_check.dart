// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Read-only check of the app's own IMAP and SMTP code against the real
/// account in live-test.env (password from the system keychain).
///
///   dart run repo_tools:live_check
///
/// Changes nothing: the inbox is opened with EXAMINE (read-only), only
/// summaries are fetched, and SMTP logs in and quits without sending.
/// Prints counts and capabilities only, never subjects or addresses.
library;

import 'dart:io';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_setup/mail_setup.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

Future<void> main() async {
  try {
    final settings = LiveSettings.load(File('live-test.env'));
    final password = await Keychain.lookup(settings.email);
    await _checkDiscovery(settings, password);
    await _checkImap(settings, password);
    await _checkSmtp(settings, password);
    await _checkSync(settings, password);
    stdout.writeln('\nAll live checks passed.');
  } on Object catch (e) {
    stderr.writeln('\nLive check failed: $e');
    exitCode = 1;
  }
}

Future<void> _checkImap(LiveSettings s, String password) async {
  stdout.writeln('IMAP ${s.imapHost}:${s.imapPort}');
  final watch = Stopwatch()..start();
  final client = await ImapClient.connect(
    ServerEndpoint(s.imapHost, s.imapPort, ConnectionSecurity.implicitTls),
  );
  _ok('TLS connection and greeting (${watch.elapsedMilliseconds} ms)');
  try {
    await client.login(s.email, password);
    _ok('login');
    final wanted = [
      'IDLE',
      'CONDSTORE',
      'QRESYNC',
      'MOVE',
      'UIDPLUS',
      'SPECIAL-USE',
    ];
    _ok(
      'capabilities: ${wanted.map((c) => '$c ${client.capabilities.has(c) ? 'yes' : 'no'}').join(', ')}',
    );

    final enabled = await client.enable(['QRESYNC']);
    _ok('enabled: ${enabled.isEmpty ? 'none' : enabled.join(' ')}');

    final folders = await client.listMailboxes();
    final special = {
      for (final f in folders)
        if (f.specialUse != null) f.specialUse!.name: f.name,
    };
    _ok('${folders.length} folders; special use: $special');

    final inbox = await client.select('INBOX', readOnly: true);
    _ok(
      'INBOX (read-only): ${inbox.exists} messages, UIDVALIDITY ${inbox.uidValidity}, '
      'mod-sequence ${inbox.highestModSeq ?? 'not tracked'}',
    );

    if (inbox.exists > 0) {
      final search = await client.uidSearch(SearchCriteria.all());
      final uids = search.matches.toList();
      final latest = uids.sublist(uids.length > 5 ? uids.length - 5 : 0);
      final fetched = await client.uidFetch(
        SequenceSet.of(latest),
        FetchItems.summary(modSeq: true),
      );
      final envelopes = fetched.messages
          .where((m) => m.envelope != null)
          .length;
      final structures = fetched.messages
          .where((m) => m.bodyStructure != null)
          .length;
      _ok(
        'fetched ${fetched.messages.length} summaries: $envelopes envelopes and '
        '$structures body structures parsed',
      );
    }

    final idleWatch = Stopwatch()..start();
    await client.idle(until: Future<void>.delayed(const Duration(seconds: 3)));
    _ok('IDLE entered and left cleanly (${idleWatch.elapsed.inSeconds} s)');
  } finally {
    await client.logout();
  }
}

/// Discovery as the setup screen runs it (without asking Mozilla), then a
/// real login with the found settings. Nothing is saved or sent.
Future<void> _checkDiscovery(LiveSettings s, String password) async {
  stdout.writeln('Account discovery for ${s.email}');
  final watch = Stopwatch()..start();
  final result = await AccountDiscovery().discover(s.email);
  final found = result.settings;
  if (found == null) throw StateError('discovery found nothing');
  _ok(
    'found via ${found.source.name} in ${watch.elapsedMilliseconds} ms: IMAP ${found.imap}, SMTP ${found.smtp}',
  );
  _ok(
    'warnings: ${found.warnings.isEmpty ? 'none' : found.warnings.map((w) => w.name).join(', ')}',
  );
  final verified = await const AccountVerifier().verify(found, password);
  if (!verified.succeeded) {
    throw StateError(
      'verification failed: ${verified.problem} ${verified.message}',
    );
  }
  _ok('verified with a real IMAP login and SMTP authentication');
}

Future<void> _checkSmtp(LiveSettings s, String password) async {
  stdout.writeln('SMTP ${s.smtpHost}:${s.smtpPort}');
  final client = await SmtpClient.connect(
    ServerEndpoint(s.smtpHost, s.smtpPort, ConnectionSecurity.implicitTls),
  );
  try {
    _ok('TLS connection; extensions: ${client.extensions.keys.join(' ')}');
    _ok('size limit: ${client.maxMessageSize ?? 'not announced'} bytes');
    await client.authenticate(s.email, password);
    _ok('login (nothing sent)');
  } finally {
    await client.quit();
  }
}

/// Syncs INBOX twice into a temporary encrypted store, deleted afterwards.
/// No actions are queued, so nothing on the server changes.
Future<void> _checkSync(LiveSettings s, String password) async {
  stdout.writeln('Sync engine (temporary encrypted store)');
  final dir = Directory.systemTemp.createTempSync('fmail_live');
  final store = MailStore.open('${dir.path}/live.db', DatabaseKey.generate());
  try {
    final account = store.accounts.add(
      NewAccount(
        email: s.email,
        username: s.email,
        imap: ServerSettings(
          host: s.imapHost,
          port: s.imapPort,
          security: ConnectionSecurity.implicitTls,
        ),
        smtp: ServerSettings(
          host: s.smtpHost,
          port: s.smtpPort,
          security: ConnectionSecurity.implicitTls,
        ),
      ),
    );
    final connector = DefaultMailConnector(_FixedPassword(password));
    final synchronizer = AccountSynchronizer(
      store,
      connector,
      MailboxSynchronizer(store, const SummaryMapper(PeopleClassifier())),
      OutboxReplayer(store),
    );
    await synchronizer.sync(account, mailboxIds: const {});
    final inbox = store.mailboxes.inbox(account.id)!;
    for (final label in ['first', 'second']) {
      final watch = Stopwatch()..start();
      final result = (await synchronizer.sync(
        account,
        mailboxIds: {inbox.id},
      )).mailboxes[inbox.id]!;
      _ok(
        '$label sync: ${result.method.name}, +${result.added} ~${result.updated} -${result.removed} '
        '(${watch.elapsedMilliseconds} ms)',
      );
    }
    final messages = store.messages.list(
      MessageQuery(mailboxIds: [inbox.id], limit: 500),
    );
    final withPreview = messages.where((m) => m.snippet != null).length;
    _ok('${messages.length} summaries stored, $withPreview with previews');
  } finally {
    store.close();
    dir.deleteSync(recursive: true);
  }
}

final class _FixedPassword implements CredentialProvider {
  _FixedPassword(this._password);

  final String _password;

  @override
  Future<String> passwordFor(Account account) async => _password;
}

void _ok(String message) => stdout.writeln('  ok  $message');

/// Settings from live-test.env. Parsed line by line, never executed, and
/// refused if they contain anything that looks like a secret.
final class LiveSettings {
  LiveSettings(
    this.email,
    this.imapHost,
    this.imapPort,
    this.smtpHost,
    this.smtpPort,
  );

  factory LiveSettings.load(File file) {
    if (!file.existsSync()) {
      throw StateError(
        '${file.path} not found; copy live-test.env.example and fill it in',
      );
    }
    final values = <String, String>{};
    for (final line in file.readAsLinesSync()) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final match = RegExp(r'^([A-Z_]+)=(.*)$').firstMatch(trimmed);
      if (match == null) {
        throw FormatException('bad line in ${file.path}: $trimmed');
      }
      final key = match.group(1)!;
      if (RegExp('PASSWORD|SECRET|TOKEN').hasMatch(key)) {
        throw StateError(
          '${file.path} must not contain secrets ($key); use the keychain',
        );
      }
      values[key] = match.group(2)!.trim();
    }
    String get(String key) =>
        values[key] ?? (throw StateError('$key missing from ${file.path}'));
    int port(String key) {
      final value = int.tryParse(get(key));
      if (value == null || value < 1 || value > 65535) {
        throw StateError('$key is not a port');
      }
      return value;
    }

    final email = get('LIVE_EMAIL');
    if (email == 'you@example.com') {
      throw StateError('fill in your own account in ${file.path}');
    }
    return LiveSettings(
      email,
      get('LIVE_IMAP_HOST'),
      port('LIVE_IMAP_PORT'),
      get('LIVE_SMTP_HOST'),
      port('LIVE_SMTP_PORT'),
    );
  }

  final String email;
  final String imapHost;
  final int imapPort;
  final String smtpHost;
  final int smtpPort;
}

/// Reads the password stored with
/// `secret-tool store ... service fmail-test account <email>`.
abstract final class Keychain {
  static Future<String> lookup(String email) async {
    final result = await Process.run('secret-tool', [
      'lookup',
      'service',
      'fmail-test',
      'account',
      email,
    ]);
    final password = (result.stdout as String).replaceAll(RegExp(r'\n$'), '');
    if (result.exitCode != 0 || password.isEmpty) {
      throw StateError(
        'no password in the keychain for $email (see live-test.env.example)',
      );
    }
    return password;
  }
}
