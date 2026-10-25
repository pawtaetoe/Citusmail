// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmail/src/setup/reconnect.dart';
import 'package:fmail/src/ui/fmail_theme.dart';
import 'package:fmail/src/ui/mail_shell.dart';
import 'package:mail_oauth/mail_oauth.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_setup/mail_setup.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

Account _account({
  String email = 'me@gmail.com',
  String imapHost = 'imap.gmail.com',
  String? oauthProvider,
}) => Account(
  id: 3,
  email: email,
  username: email,
  imap: ServerSettings(
    host: imapHost,
    port: 993,
    security: ConnectionSecurity.implicitTls,
  ),
  smtp: ServerSettings(
    host: 'smtp.gmail.com',
    port: 587,
    security: ConnectionSecurity.startTls,
  ),
  sortOrder: 0,
  createdAt: DateTime.utc(2026),
  oauthProvider: oauthProvider,
);

/// A reconnector over stand-ins that records what it was asked to do.
final class _Fake {
  _Fake({
    this.verifyResult = const VerificationResult.success(),
    this.signInError,
    this.own,
  });

  VerificationResult verifyResult;
  OAuthException? signInError;
  OAuthRegistration? own;
  final secrets = <String, String>{};
  final verified = <String>[];
  final signedInWith = <OAuthProvider>[];
  final saved = <(int, String)>[];

  late final reconnector = Reconnector(
    verify: (settings, password) async {
      verified.add(password);
      return verifyResult;
    },
    verifyOAuth: (settings, token) async {
      verified.add(token);
      return verifyResult;
    },
    oauthSignIn: (provider, email) async {
      signedInWith.add(provider);
      if (signInError case final e?) throw e;
      return OAuthTokens(
        accessToken: 'AT-new',
        refreshToken: 'RT-new',
        expiresAt: DateTime.utc(2030),
      );
    },
    readSecret: (key) async => secrets[key],
    save: (account, secret) async => saved.add((account.id, secret)),
    ownClient: (id) async => own,
  );
}

void main() {
  const refused = VerificationResult.failure(
    ServerRole.imap,
    VerificationProblem.credentials,
    'no',
  );

  group('new password', () {
    test('checked first; a refused one is explained and not saved', () async {
      final f = _Fake(verifyResult: refused);
      final error = await f.reconnector.usePassword(_account(), 'wrong');
      expect(error, contains('didn\'t accept the app password'));
      expect(f.saved, isEmpty);
      expect(
        await f.reconnector.usePassword(_account(), ''),
        'Enter the password.',
      );
    });

    test('a Gmail app password loses its spaces, then is saved', () async {
      final f = _Fake();
      expect(
        await f.reconnector.usePassword(_account(), 'abcd efgh ijkl mnop'),
        isNull,
      );
      expect(f.verified, ['abcdefghijklmnop']);
      expect(f.saved, [(3, 'abcdefghijklmnop')]);
    });
  });

  group('signing in again', () {
    final own = OAuthRegistration(
      '123-abc.apps.googleusercontent.com',
      'GOCSPX-x1y2z3',
    );

    test('uses the client that signed the account in, and keeps it', () async {
      final account = _account(oauthProvider: 'google');
      final f = _Fake()
        ..secrets[account.keychainKey] = OAuthTokens(
          accessToken: 'AT-old',
          expiresAt: DateTime.utc(2020),
        ).issuedTo(own).toJson();
      expect(await f.reconnector.signInAgain(account), isNull);
      expect(f.signedInWith.single.clientId, own.clientId);
      expect(f.verified, ['AT-new']);
      final (id, json) = f.saved.single;
      expect(id, 3);
      final tokens = OAuthTokens.fromJson(json)!;
      expect(tokens.refreshToken, 'RT-new');
      expect(tokens.registration!.clientId, own.clientId);
    });

    test('with no earlier tokens: the user\'s own client', () async {
      final account = _account(oauthProvider: 'google');
      final f = _Fake(own: own);
      expect(await f.reconnector.signInAgain(account), isNull);
      expect(f.signedInWith.single.clientSecret, own.clientSecret);
    });

    test('no client at all: says so, opens no browser', () async {
      final f = _Fake();
      final error = await f.reconnector.signInAgain(
        _account(oauthProvider: 'google'),
      );
      expect(error, contains('can\'t sign in'));
      expect(f.signedInWith, isEmpty);
    });

    test('cancelled, or signed in as someone else: nothing saved', () async {
      final account = _account(oauthProvider: 'google');
      final cancelled = _Fake(
        own: own,
        signInError: const OAuthException(OAuthProblem.cancelled, 'x'),
      );
      expect(
        await cancelled.reconnector.signInAgain(account),
        'Sign-in was cancelled.',
      );
      expect(cancelled.saved, isEmpty);

      final other = _Fake(own: own, verifyResult: refused);
      expect(
        await other.reconnector.signInAgain(account),
        contains('signed in as me@gmail.com'),
      );
      expect(other.saved, isEmpty);
    });

    test('the account\'s own settings are what gets checked', () {
      final settings = Reconnector.settingsOf(
        _account(email: 'me@tommykung.cc', imapHost: 'tommykung.cc'),
      );
      expect(settings.imap.host, 'tommykung.cc');
      expect(settings.smtp.port, 587);
      expect(settings.smtp.security, ConnectionSecurity.startTls);
      expect(settings.needsConfirmation, isFalse);
    });
  });

  group('in the mail screen', () {
    late TestApp app;
    setUp(() async => app = await TestApp.create());
    tearDown(() => app.dispose());

    testWidgets('Update password from the account menu', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final save = <String>[];
      final reconnector = Reconnector(
        verify: (settings, password) async =>
            password == 'right' ? const VerificationResult.success() : refused,
        verifyOAuth: (settings, token) async => refused,
        oauthSignIn: (provider, email) async => throw StateError('no'),
        readSecret: (key) async => null,
        save: (account, secret) async => save.add(secret),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: FmailTheme.light(),
          home: MailShell(
            notifications: false,
            services: app.services,
            onAddAccount: () {},
            onAccountsChanged: () {},
            reconnector: reconnector,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Update password'));
      await tester.pumpAndSettle();
      expect(find.text('alice@fmail.test'), findsWidgets);

      await tester.enterText(
        find.widgetWithText(TextField, 'New password'),
        'wrong',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('didn\'t accept'), findsOneWidget);
      expect(save, isEmpty);

      await tester.enterText(
        find.widgetWithText(TextField, 'New password'),
        'right',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(save, ['right']);
      expect(
        find.text('Password updated for alice@fmail.test'),
        findsOneWidget,
      );
    });
  });
}
