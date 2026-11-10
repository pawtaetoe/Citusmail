// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/pairing/account_export.dart';
import 'package:citusmail/src/pairing/account_import.dart';
import 'package:citusmail/src/services/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_oauth/mail_oauth.dart';
import 'package:mail_pairing/mail_pairing.dart';
import 'package:mail_protocol/mail_protocol.dart' show ConnectionSecurity;
import 'package:mail_setup/mail_setup.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

ServerSettings _server(String host, int port, ConnectionSecurity s) =>
    ServerSettings(host: host, port: port, security: s);

/// The phone's accounts: the sample one (password), plus Posteo
/// (password), Gmail with the user's own Google client, and Outlook.
Future<void> addPhoneAccounts(TestApp phone) async {
  final secrets = phone.services.secrets;
  final store = phone.store;
  await secrets.write(store.accounts.all().single.keychainKey, 'alice-pw');
  final posteo = store.accounts.add(
    NewAccount(
      email: 'bob@posteo.example',
      displayName: 'Bob',
      username: 'bob@posteo.example',
      imap: _server('posteo.example', 993, ConnectionSecurity.implicitTls),
      smtp: _server('posteo.example', 587, ConnectionSecurity.startTls),
    ),
  );
  await secrets.write(posteo.keychainKey, 'bob-pw');
  final gmail = store.accounts.add(
    NewAccount(
      email: 'bob@gmail.example',
      username: 'bob@gmail.example',
      imap: _server('imap.gmail.com', 993, ConnectionSecurity.implicitTls),
      smtp: _server('smtp.gmail.com', 587, ConnectionSecurity.startTls),
      oauthProvider: 'google',
    ),
  );
  await secrets.write(
    gmail.keychainKey,
    OAuthTokens(
      accessToken: 'old-access',
      expiresAt: DateTime.utc(2020),
      refreshToken: 'refresh-1',
      registration: OAuthRegistration(
        '123-abc.apps.googleusercontent.com',
        'own-secret',
      ),
    ).toJson(),
  );
  final outlook = store.accounts.add(
    NewAccount(
      email: 'bob@outlook.example',
      username: 'bob@outlook.example',
      imap: _server(
        'outlook.office365.com',
        993,
        ConnectionSecurity.implicitTls,
      ),
      smtp: _server('smtp-mail.outlook.com', 587, ConnectionSecurity.startTls),
      oauthProvider: 'microsoft',
    ),
  );
  await secrets.write(
    outlook.keychainKey,
    OAuthTokens(
      accessToken: 'ms-access',
      expiresAt: DateTime.utc(2030),
      refreshToken: 'ms-refresh',
    ).toJson(),
  );
}

void main() {
  late TestApp phone;
  late TestApp computer;
  setUp(() async {
    phone = await TestApp.create();
    computer = await TestApp.create();
    await addPhoneAccounts(phone);
  });
  tearDown(() async {
    await phone.dispose();
    await computer.dispose();
  });

  test('the phone sends passwords and portable sign-ins only', () async {
    final transfer = await AccountExport(phone.services)
        .build(phone.store.accounts.all(), computerClients: const {});
    final byEmail = {for (final a in transfer.accounts) a.email: a};
    expect(byEmail.keys, hasLength(4));
    expect(
      (byEmail['bob@posteo.example']!.signIn as PasswordSignIn).password,
      'bob-pw',
    );
    expect(byEmail['bob@posteo.example']!.displayName, 'Bob');
    expect(byEmail['bob@posteo.example']!.smtp.security, 'starttls');
    // Google with the user's own client: the tokens carry it.
    final google = byEmail['bob@gmail.example']!.signIn as OAuthSignIn;
    expect(google.tokens, contains('refresh-1'));
    expect(google.client, '123-abc.apps.googleusercontent.com');
    // Microsoft replaces refresh tokens on use: never sent.
    final microsoft = byEmail['bob@outlook.example']!.signIn as OAuthSignIn;
    expect(microsoft.provider, 'microsoft');
    expect(microsoft.tokens, isNull);
    expect(transfer.syncCode, isNull);
  });

  test('Google tokens of the built-in client go only to the same client', () {
    final builtIn = OAuthTokens(
      accessToken: 'a',
      expiresAt: DateTime.utc(2030),
      refreshToken: 'r',
    );
    // This test build has no built-in Google client.
    expect(
      tokensPortable('google', builtIn, computerClients: const {'google': 'x'}),
      isFalse,
    );
    expect(tokensPortable('microsoft', builtIn), isFalse);
    // The file route: the computer decides.
    expect(tokensPortable('google', builtIn), isTrue);
  });

  test('the computer checks, adds, skips and asks to sign in', () async {
    final transfer = await AccountExport(phone.services)
        .build(phone.store.accounts.all(), computerClients: const {});
    final verified = <String>[];
    final import = AccountImport(
      computer.services,
      verify: (settings, password) async {
        verified.add('${settings.email}:$password');
        return const VerificationResult.success();
      },
      verifyOAuth: (settings, token) async {
        verified.add('${settings.email}:$token');
        return const VerificationResult.success();
      },
      refresh: (provider, refresh) async {
        expect(provider.clientId, '123-abc.apps.googleusercontent.com');
        expect(refresh, 'refresh-1');
        return OAuthTokens(
          accessToken: 'new-access',
          expiresAt: DateTime.utc(2099),
          refreshToken: 'refresh-1',
        );
      },
    );
    final results = await import.receive(transfer);
    final outcome = {for (final r in results) r.email: r.outcome};
    expect(outcome, {
      'alice@citusmail.test': TransferOutcome.alreadyThere,
      'bob@posteo.example': TransferOutcome.added,
      'bob@gmail.example': TransferOutcome.added,
      'bob@outlook.example': TransferOutcome.signInOnComputer,
    });
    expect(verified, [
      'bob@posteo.example:bob-pw',
      'bob@gmail.example:new-access',
    ]);
    expect(import.signInNeeded.single.provider, OAuthProvider.microsoft);

    final added = {for (final a in computer.store.accounts.all()) a.email: a};
    expect(added['bob@posteo.example']!.displayName, 'Bob');
    expect(
      await computer.services.secrets.read(
        added['bob@posteo.example']!.keychainKey,
      ),
      'bob-pw',
    );
    final tokens = OAuthTokens.fromJson(
      await computer.services.secrets.read(
        added['bob@gmail.example']!.keychainKey,
      ),
    )!;
    expect(tokens.accessToken, 'new-access');
    // Renewals keep using the client that issued the tokens.
    expect(tokens.registration?.clientId, '123-abc.apps.googleusercontent.com');
    expect(added.containsKey('bob@outlook.example'), isFalse);
  });

  test('a failed check is reported and nothing is saved', () async {
    final transfer = await AccountExport(phone.services).build(
      phone.store.accounts
          .all()
          .where((a) => a.email == 'bob@posteo.example')
          .toList(),
    );
    final import = AccountImport(
      computer.services,
      verify: (settings, password) async => const VerificationResult.failure(
        ServerRole.imap,
        VerificationProblem.credentials,
        'NO',
      ),
    );
    final result = (await import.receive(transfer)).single;
    expect(result.outcome, TransferOutcome.failed);
    expect(result.detail, contains('didn\'t accept'));
    expect(computer.store.accounts.all(), hasLength(1));
  });

  test('own client registrations and the sync code come along', () async {
    await OwnOAuthClients(phone.services.secrets).save(
      'google',
      OAuthRegistration('123-abc.apps.googleusercontent.com', 'own-secret'),
    );
    final code = await phone.services.deviceSync.start();
    final transfer = await AccountExport(phone.services).build(
      phone.store.accounts
          .all()
          .where((a) => a.email == 'bob@posteo.example')
          .toList(),
      withSync: true,
    );
    expect(transfer.syncCode, code.toString());
    final import = AccountImport(
      computer.services,
      verify: (settings, password) async => const VerificationResult.success(),
    );
    await import.receive(transfer);
    expect(import.syncTurnedOn, isTrue);
    expect(
      (await computer.services.deviceSync.code()).toString(),
      code.toString(),
    );
    expect(
      (await OwnOAuthClients(computer.services.secrets).read('google'))
          ?.clientId,
      '123-abc.apps.googleusercontent.com',
    );
  });
}
