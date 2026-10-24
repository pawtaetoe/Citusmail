// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Checks the app's own IMAP, SMTP, sync and sign-in code against the real
/// account in live-test.env.
///
///   dart run repo_tools:live_check [--send] [--sign-in-again]
///
/// A password account's password comes from the system keychain. An
/// Outlook account (`LIVE_SIGN_IN=microsoft`) signs in once in the browser;
/// its tokens are then kept in the keychain, renewed and saved back as the
/// app does.
///
/// Read-only unless `--send` is given: the inbox is opened with EXAMINE,
/// only summaries are fetched, and SMTP logs in and quits. With `--send`,
/// one message goes to the account itself and is then moved to
/// LIVE_TEST_FOLDER, the only folder the check creates or changes.
/// Prints counts and capabilities only, never subjects or addresses of
/// other people's mail.
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mail_oauth/mail_oauth.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_setup/mail_setup.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:mail_trust/mail_trust.dart';
import 'package:mail_web/mail_web.dart';
import 'package:repo_tools/src/live/live_settings.dart';
import 'package:repo_tools/src/live/live_tokens.dart';
import 'package:repo_tools/src/live/test_keychain.dart';

const _usage =
    'usage: dart run repo_tools:live_check [--send] [--sign-in-again]';

Future<void> main(List<String> args) async {
  final unknown = args.where((a) => a != '--send' && a != '--sign-in-again');
  if (unknown.isNotEmpty) {
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }
  try {
    final settings = LiveSettings.load(File('live-test.env'));
    final credentials = settings.usesOAuth
        ? await _checkSignIn(settings, fresh: args.contains('--sign-in-again'))
        : _FixedPassword(
            await TestKeychain.password(settings.email).read() ??
                (throw StateError(
                  'no password in the keychain for ${settings.email} '
                  '(see live-test.env.example)',
                )),
          );
    final live = _Live(settings, credentials);
    await live.checkDiscovery();
    await live.checkImap();
    await live.checkSmtp();
    await live.checkSync();
    if (args.contains('--send')) await live.checkSend();
    stdout.writeln('\nAll live checks passed.');
  } on Object catch (e) {
    stderr.writeln('\nLive check failed: $e');
    exitCode = 1;
  }
}

/// Signs in (browser the first time, saved tokens after that) and checks
/// that the refresh token gives new access tokens.
Future<LiveTokens> _checkSignIn(LiveSettings s, {required bool fresh}) async {
  final provider = s.oauth!;
  stdout.writeln('${provider.name} sign-in for ${s.email}');
  final client = TokenClient(WebClient());
  final tokens = LiveTokens(
    _KeychainVault(TestKeychain.oauth(s.email)),
    (refresh) => client.refresh(provider, refresh),
  );

  Future<void> signIn() async {
    final signedIn = await browserSignIn(
      provider,
      s.email,
      client,
      say: (line) => stdout.writeln('  ..  $line'),
    );
    await tokens.signedIn(signedIn);
    _ok(
      'signed in in the browser (PKCE, state checked); '
      'refresh token ${signedIn.refreshToken == null ? 'MISSING' : 'received'}; '
      'access token valid ${_minutesLeft(signedIn)} min; saved to the keychain',
    );
    if (signedIn.refreshToken == null) {
      throw StateError(
        'no refresh token: is offline_access granted to the app registration?',
      );
    }
  }

  final stored = fresh ? null : await tokens.stored();
  if (stored == null) {
    await signIn();
  } else {
    _ok(
      'saved sign-in found in the keychain '
      '(access token ${stored.needsRefresh() ? 'expired' : 'valid ${_minutesLeft(stored)} min'})',
    );
  }

  final before = await tokens.stored();
  OAuthTokens renewed;
  try {
    renewed = await tokens.renew();
  } on OAuthException catch (e) {
    if (e.problem != OAuthProblem.signInAgain) rethrow;
    _ok(
      'the saved sign-in was revoked or expired (${e.message}); '
      'signing in again',
    );
    await signIn();
    renewed = await tokens.renew();
  }
  _ok(
    'refresh token renewed the access token (valid ${_minutesLeft(renewed)} min); '
    'refresh token ${renewed.refreshToken == before?.refreshToken ? 'kept' : 'rotated'} and saved',
  );
  return tokens;
}

int _minutesLeft(OAuthTokens t) =>
    t.expiresAt.difference(DateTime.now().toUtc()).inMinutes;

final class _Live {
  _Live(this.s, this.credentials);

  final LiveSettings s;
  final CredentialProvider credentials;

  /// An account like the one the app saves (never stored for good).
  late final NewAccount account = NewAccount(
    email: s.email,
    username: s.email,
    imap: _settings(s.imap),
    smtp: _settings(s.smtp),
    oauthProvider: s.oauth?.id,
  );

  static ServerSettings _settings(ServerEndpoint e) =>
      ServerSettings(host: e.host, port: e.port, security: e.security);

  Future<String> _secret() => credentials.passwordFor(_placeholderAccount);

  /// Credentials only look at whether the account signs in with OAuth.
  late final Account _placeholderAccount = Account(
    id: 0,
    email: s.email,
    username: s.email,
    imap: account.imap,
    smtp: account.smtp,
    sortOrder: 0,
    createdAt: DateTime.now(),
    oauthProvider: s.oauth?.id,
  );

  Future<void> login(ImapClient client) async => s.usesOAuth
      ? client.loginOAuth(s.email, await _secret())
      : client.login(s.email, await _secret());

  /// For a password account: discovery as the setup screen runs it
  /// (without asking Mozilla). For an OAuth account: that the address is
  /// recognised, and the provider's servers as setup saves them. Then a
  /// real login with those settings. Nothing is saved or sent.
  Future<void> checkDiscovery() async {
    stdout.writeln('Account setup for ${s.email}');
    final DiscoveredSettings found;
    if (s.oauth case final provider?) {
      final domain = s.email.substring(s.email.lastIndexOf('@') + 1);
      final recognised = OAuthProvider.forDomain(domain)?.id == provider.id;
      _ok(
        recognised
            ? 'address recognised: setup offers "Continue with ${provider.name}"'
            : 'note: $domain is not on the ${provider.name} domain list, so setup asks '
                  'for a password (expected for work and school addresses)',
      );
      found = DiscoveredSettings(
        email: s.email,
        imap: ServerCandidate(s.imap.host, s.imap.port, s.imap.security),
        smtp: ServerCandidate(s.smtp.host, s.smtp.port, s.smtp.security),
        username: s.email,
        source: DiscoverySource.manual,
      );
    } else {
      final watch = Stopwatch()..start();
      final result = await AccountDiscovery().discover(s.email);
      found = result.settings ?? (throw StateError('discovery found nothing'));
      _ok(
        'found via ${found.source.name} in ${watch.elapsedMilliseconds} ms: '
        'IMAP ${found.imap}, SMTP ${found.smtp}',
      );
      _ok(
        'warnings: ${found.warnings.isEmpty ? 'none' : found.warnings.map((w) => w.name).join(', ')}',
      );
    }
    final verified = await const AccountVerifier().verify(
      found,
      await _secret(),
      oauth: s.usesOAuth,
    );
    if (!verified.succeeded) {
      throw StateError(
        'verification failed: ${verified.problem} ${verified.message}',
      );
    }
    _ok(
      'verified with a real IMAP login and SMTP authentication'
      '${s.usesOAuth ? ' (XOAUTH2)' : ''}',
    );
  }

  Future<void> checkImap() async {
    stdout.writeln('IMAP ${s.imap}');
    final watch = Stopwatch()..start();
    final client = await ImapClient.connect(s.imap);
    _ok('TLS connection and greeting (${watch.elapsedMilliseconds} ms)');
    try {
      await login(client);
      _ok(s.usesOAuth ? 'login (XOAUTH2)' : 'login');
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
        await _checkVerification(client, uids);
      }

      final idleWatch = Stopwatch()..start();
      await client.idle(
        until: Future<void>.delayed(const Duration(seconds: 3)),
      );
      _ok('IDLE entered and left cleanly (${idleWatch.elapsed.inSeconds} s)');
    } finally {
      await client.logout();
    }
  }

  /// Whether the server writes Authentication-Results that the phishing
  /// checks can learn to trust. Prints only the server's name.
  Future<void> _checkVerification(ImapClient client, List<int> uids) async {
    final recent = uids.sublist(uids.length > 30 ? uids.length - 30 : 0);
    final fetched = await client.uidFetch(
      SequenceSet.of(recent),
      FetchItems(headerFields: const ['Authentication-Results']),
    );
    final topmost = [
      for (final m in fetched.messages)
        const HeaderParser()
            .parse(m.headerFields ?? Uint8List(0))
            .headers
            .value('authentication-results'),
    ];
    final id = AuthServIds.learn(topmost);
    final ids = <String, int>{};
    for (final value in topmost.whereType<String>()) {
      final name = AuthenticationResults.parse(value)?.authServId ?? '?';
      ids[name] = (ids[name] ?? 0) + 1;
    }
    final carrying = topmost.whereType<String>().length;
    _ok(
      id == null
          ? 'verification results: not learned yet ($carrying of ${topmost.length} recent messages carry any: $ids)'
          : 'verification results trusted from "$id" ($carrying of ${topmost.length} recent messages)',
    );
  }

  Future<void> checkSmtp() async {
    stdout.writeln('SMTP ${s.smtp}');
    final client = await SmtpClient.connect(s.smtp);
    try {
      _ok('TLS connection; extensions: ${client.extensions.keys.join(' ')}');
      _ok('size limit: ${client.maxMessageSize ?? 'not announced'} bytes');
      await _authenticate(client);
      _ok('login${s.usesOAuth ? ' (XOAUTH2)' : ''} (nothing sent)');
    } finally {
      await client.quit();
    }
  }

  Future<void> _authenticate(SmtpClient client) async => s.usesOAuth
      ? client.authenticateOAuth(s.email, await _secret())
      : client.authenticate(s.email, await _secret());

  /// Syncs INBOX twice into a temporary encrypted store, deleted afterwards.
  /// No actions are queued, so nothing on the server changes. For an OAuth
  /// account, the access token is treated as expired before the second
  /// sync, which must then renew it by itself.
  Future<void> checkSync() async {
    stdout.writeln('Sync engine (temporary encrypted store)');
    final dir = Directory.systemTemp.createTempSync('fmail_live');
    final store = MailStore.open('${dir.path}/live.db', DatabaseKey.generate());
    try {
      final saved = store.accounts.add(account);
      final synchronizer = AccountSynchronizer(
        store,
        DefaultMailConnector(credentials),
        MailboxSynchronizer(store, const SummaryMapper(HeaderRuleClassifier())),
        OutboxReplayer(store),
      );
      await synchronizer.sync(saved, mailboxIds: const {});
      final inbox = store.mailboxes.inbox(saved.id)!;
      for (final label in ['first', 'second']) {
        final tokens = credentials is LiveTokens
            ? credentials as LiveTokens
            : null;
        final renewalsBefore = tokens?.renewals ?? 0;
        if (label == 'second') tokens?.expireNow();
        final watch = Stopwatch()..start();
        final result = (await synchronizer.sync(
          saved,
          mailboxIds: {inbox.id},
        )).mailboxes[inbox.id]!;
        _ok(
          '$label sync: ${result.method.name}, +${result.added} ~${result.updated} -${result.removed} '
          '(${watch.elapsedMilliseconds} ms)',
        );
        if (tokens != null && label == 'second') {
          if (tokens.renewals <= renewalsBefore) {
            throw StateError('the expired access token was not renewed');
          }
          _ok('the expired access token was renewed during the sync');
        }
      }
      final messages = store.messages.list(
        MessageQuery(mailboxIds: [inbox.id], limit: 500),
      );
      final withPreview = messages.where((m) => m.snippet != null).length;
      _ok('${messages.length} summaries stored, $withPreview with previews');
      // Counts only: nothing about individual messages is printed.
      final counts = {
        for (final category in MessageCategory.values)
          category.name: messages.where((m) => m.category == category).length,
      };
      _ok(
        'sorted: ${counts.entries.map((e) => '${e.value} ${e.key}').join(', ')}',
      );
    } finally {
      store.close();
      dir.deleteSync(recursive: true);
    }
  }

  /// Sends one message to the account itself, waits for it in INBOX,
  /// reports whether the server kept its own copy in Sent (the app then
  /// should not add another), and moves it to the test folder.
  Future<void> checkSend() async {
    stdout.writeln('Sending to ${s.email} itself (--send)');
    final at = s.email.lastIndexOf('@');
    final me = MailAddress(
      localPart: s.email.substring(0, at),
      domain: s.email.substring(at + 1),
    );
    final tag = Random.secure().nextInt(1 << 32).toRadixString(16);
    final built = MessageBuilder().build(
      OutgoingMessage(
        from: me,
        to: [me],
        subject: 'Citusmail live check $tag',
        textBody:
            'Sent by the Citusmail live check. It moves this message to '
            '${s.testFolder} once it arrives.',
      ),
    );
    final smtp = await SmtpClient.connect(s.smtp);
    try {
      await _authenticate(smtp);
      await smtp.send(built, from: me);
      _ok('accepted by the SMTP server');
    } finally {
      await smtp.quit();
    }

    final imap = await ImapClient.connect(s.imap);
    try {
      await login(imap);
      await imap.select('INBOX');
      final watch = Stopwatch()..start();
      var uids = <int>[];
      while (uids.isEmpty) {
        uids = (await imap.uidSearch(
          SearchCriteria.header('Message-ID', built.messageId),
        )).matches.toList();
        if (uids.isNotEmpty) break;
        if (watch.elapsed > const Duration(minutes: 2)) {
          throw StateError('the message did not arrive in INBOX in 2 minutes');
        }
        await Future<void>.delayed(const Duration(seconds: 5));
      }
      _ok('delivered to INBOX in ${watch.elapsed.inSeconds} s');

      final folders = await imap.listMailboxes();
      final sent = folders
          .where((f) => f.specialUse == SpecialUse.sent)
          .firstOrNull;
      if (sent == null) {
        _ok('no Sent folder marked on the server');
      } else {
        await imap.select(sent.encodedName, readOnly: true);
        final copies = (await imap.uidSearch(
          SearchCriteria.header('Message-ID', built.messageId),
        )).matches.length;
        _ok(
          copies > 0
              ? 'the server saved a copy in ${sent.name} by itself '
                    '(the app should not add its own)'
              : 'the server kept no copy in ${sent.name} (the app adds one)',
        );
      }

      await imap.create(s.testFolder);
      await imap.select('INBOX');
      await imap.uidMove(SequenceSet.of(uids), s.testFolder);
      _ok('moved to ${s.testFolder}');
    } finally {
      await imap.logout();
    }
  }
}

final class _FixedPassword implements CredentialProvider {
  _FixedPassword(this._password);

  final String _password;

  @override
  Future<String> passwordFor(Account account) async => _password;
}

final class _KeychainVault implements TokenVault {
  _KeychainVault(this._keychain);

  final TestKeychain _keychain;

  @override
  Future<String?> read() => _keychain.read();

  @override
  Future<void> write(String value) => _keychain.write(value);
}

void _ok(String message) => stdout.writeln('  ok  $message');
