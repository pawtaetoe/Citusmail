// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_oauth/mail_oauth.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:repo_tools/src/live/live_settings.dart';
import 'package:repo_tools/src/live/live_tokens.dart';
import 'package:test/test.dart';

void main() {
  group('LiveSettings', () {
    test('a password account needs its servers; ports pick the security', () {
      final s = LiveSettings.parse('''
# comment
LIVE_EMAIL=me@example.org
LIVE_IMAP_HOST=imap.example.org
LIVE_IMAP_PORT=993
LIVE_SMTP_HOST=smtp.example.org
LIVE_SMTP_PORT=587
''');
      expect(s.email, 'me@example.org');
      expect(s.usesOAuth, isFalse);
      expect(s.imap.host, 'imap.example.org');
      expect(s.imap.security, ConnectionSecurity.implicitTls);
      expect(s.smtp.port, 587);
      expect(s.smtp.security, ConnectionSecurity.startTls);
      expect(s.testFolder, 'FmailTest');

      expect(
        () => LiveSettings.parse('LIVE_EMAIL=me@example.org\n'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('LIVE_IMAP_HOST'),
          ),
        ),
      );
    });

    test('an Outlook account uses Microsoft\'s servers by default', () {
      final s = LiveSettings.parse('''
LIVE_EMAIL=me@outlook.com
LIVE_SIGN_IN=microsoft
LIVE_OAUTH_CLIENT_ID=00000000-1111-2222-3333-444444444444
''');
      expect(s.usesOAuth, isTrue);
      expect(s.oauth!.id, 'microsoft');
      expect(s.oauth!.clientId, '00000000-1111-2222-3333-444444444444');
      expect(s.imap.host, 'outlook.office365.com');
      expect(s.imap.port, 993);
      expect(s.imap.security, ConnectionSecurity.implicitTls);
      expect(s.smtp.host, 'smtp-mail.outlook.com');
      expect(s.smtp.port, 587);
      expect(s.smtp.security, ConnectionSecurity.startTls);
    });

    test('a Google account uses Gmail\'s servers with STARTTLS on 587', () {
      final s = LiveSettings.parse('''
LIVE_EMAIL=me@gmail.com
LIVE_SIGN_IN=google
LIVE_OAUTH_CLIENT_ID=123-abc.apps.googleusercontent.com
''');
      expect(s.oauth!.id, 'google');
      expect(s.oauth!.clientId, '123-abc.apps.googleusercontent.com');
      expect(s.imap.host, 'imap.gmail.com');
      expect(s.smtp.host, 'smtp.gmail.com');
      expect(s.smtp.port, 587);
      expect(s.smtp.security, ConnectionSecurity.startTls);
    });

    test('the client id can come from the build instead', () {
      final s = LiveSettings.parse(
        'LIVE_EMAIL=me@outlook.com\nLIVE_SIGN_IN=microsoft\n',
        buildClientId: 'from-the-build-123',
      );
      expect(s.oauth!.clientId, 'from-the-build-123');
      expect(
        () => LiveSettings.parse(
          'LIVE_EMAIL=me@outlook.com\nLIVE_SIGN_IN=microsoft\n',
          buildClientId: '',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('LIVE_OAUTH_CLIENT_ID'),
          ),
        ),
      );
    });

    test('refuses secrets, unknown sign-ins and placeholders', () {
      const outlook = 'LIVE_EMAIL=me@outlook.com\nLIVE_SIGN_IN=microsoft\n';
      for (final text in [
        'LIVE_EMAIL=me@example.org\nLIVE_PASSWORD=x\n',
        'LIVE_EMAIL=me@example.org\nLIVE_REFRESH_TOKEN=x\n',
        'LIVE_EMAIL=me@example.org\nLIVE_SIGN_IN=myspace\n',
        'LIVE_EMAIL=you@example.com\n',
        'LIVE_EMAIL=not-an-address\n',
        '${outlook}LIVE_OAUTH_CLIENT_ID=bad id!\n',
        '${outlook}LIVE_OAUTH_CLIENT_ID=0123456789\nLIVE_TEST_FOLDER=../INBOX\n',
      ]) {
        expect(
          () => LiveSettings.parse(text, buildClientId: ''),
          throwsStateError,
          reason: text,
        );
      }
      expect(() => LiveSettings.parse('not a setting'), throwsFormatException);
    });
  });

  group('LiveTokens', () {
    OAuthTokens tokens(String access, Duration validFor, [String? refresh]) =>
        OAuthTokens(
          accessToken: access,
          expiresAt: DateTime.now().toUtc().add(validFor),
          refreshToken: refresh,
        );

    late _MemoryVault vault;
    late List<String> renewedWith;
    late LiveTokens live;
    final account = Account(
      id: 1,
      email: 'me@outlook.com',
      username: 'me@outlook.com',
      imap: ServerSettings(
        host: 'outlook.office365.com',
        port: 993,
        security: ConnectionSecurity.implicitTls,
      ),
      smtp: ServerSettings(
        host: 'smtp-mail.outlook.com',
        port: 587,
        security: ConnectionSecurity.startTls,
      ),
      sortOrder: 0,
      createdAt: DateTime.utc(2026),
      oauthProvider: 'microsoft',
    );

    setUp(() {
      vault = _MemoryVault();
      renewedWith = [];
      var n = 0;
      live = LiveTokens(vault, (refresh) async {
        renewedWith.add(refresh);
        n++;
        return tokens('access-$n', const Duration(hours: 1), 'refresh-$n');
      });
    });

    test('not signed in yet', () async {
      expect(await live.stored(), isNull);
      expect(() => live.passwordFor(account), throwsStateError);
    });

    test('a valid saved token is used as it is', () async {
      vault.value = tokens('saved', const Duration(hours: 1), 'r0').toJson();
      expect(await live.passwordFor(account), 'saved');
      expect(live.renewals, 0);
    });

    test('a token about to expire is renewed and saved', () async {
      vault.value = tokens('old', const Duration(minutes: 2), 'r0').toJson();
      expect(await live.passwordFor(account), 'access-1');
      expect(renewedWith, ['r0']);
      expect(live.renewals, 1);
      expect(OAuthTokens.fromJson(vault.value)!.refreshToken, 'refresh-1');
    });

    test('a fresh sign-in is saved; expireNow forces a renewal', () async {
      await live.signedIn(tokens('new', const Duration(hours: 1), 'r0'));
      expect(OAuthTokens.fromJson(vault.value)!.accessToken, 'new');
      expect(await live.passwordFor(account), 'new');
      live.expireNow();
      expect(await live.passwordFor(account), 'access-1');
      expect(await live.passwordFor(account), 'access-1');
      expect(live.renewals, 1);
    });

    test('without a refresh token, renewing asks to sign in again', () async {
      vault.value = tokens('old', Duration.zero).toJson();
      expect(live.renew, throwsStateError);
    });
  });
}

final class _MemoryVault implements TokenVault {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;
}
