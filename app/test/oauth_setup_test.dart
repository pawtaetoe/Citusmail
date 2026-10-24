// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmail/src/services/secret_store.dart';
import 'package:fmail/src/setup/setup_controller.dart';
import 'package:fmail/src/setup/setup_page.dart';
import 'package:mail_oauth/mail_oauth.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_setup/mail_setup.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_web/mail_web.dart';

/// Microsoft's settings with a client id, as a release build would have.
const _microsoft = OAuthProvider(
  id: 'microsoft',
  name: 'Microsoft',
  authorizationUrl: 'https://login.example.com/authorize',
  tokenUrl: 'https://login.example.com/token',
  scopes: ['IMAP', 'SMTP', 'offline_access'],
  clientId: 'test-client',
  imapHost: 'outlook.office365.com',
  smtpHost: 'smtp-mail.outlook.com',
);

final _account = Account(
  id: 7,
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

final class _Secrets implements SecretStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// The flow with a stand-in browser, verifier and store.
final class _Flow {
  _Flow({
    this.signInError,
    this.verifyResult = const VerificationResult.success(),
    bool configured = true,
  }) : provider = configured ? _microsoft : OAuthProvider.microsoft;

  final OAuthProvider provider;
  final OAuthException? signInError;
  final VerificationResult verifyResult;
  final signedIn = <String>[];
  final verifiedWith = <String>[];
  final saved = <(DiscoveredSettings, OAuthTokens, String?)>[];

  late final controller = SetupController(
    discover: (email, {askMozillaConsent, onStep}) async =>
        throw StateError('no discovery for Outlook'),
    verify: (settings, password) async =>
        throw StateError('no password check for Outlook'),
    save: (settings, password, {displayName}) async =>
        throw StateError('no password save'),
    providerFor: (email) =>
        email.trim().toLowerCase().endsWith('@outlook.com') ? provider : null,
    oauthSignIn: (provider, email) async {
      signedIn.add(email);
      if (signInError case final e?) throw e;
      return OAuthTokens(
        accessToken: 'AT',
        refreshToken: 'RT',
        expiresAt: DateTime.utc(2030),
      );
    },
    verifyOAuth: (settings, token) async {
      verifiedWith.add(token);
      return verifyResult;
    },
    saveOAuth: (settings, provider, tokens, {displayName}) async {
      saved.add((settings, tokens, displayName));
      return _account;
    },
  );
}

void main() {
  group('setup with Outlook', () {
    Future<void> show(WidgetTester tester, _Flow flow) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SetupPage(controller: flow.controller, onDone: (_) {}),
        ),
      );
      await tester.pump();
    }

    testWidgets('an Outlook address needs no password: the browser signs in', (
      tester,
    ) async {
      final flow = _Flow();
      await show(tester, flow);
      expect(find.widgetWithText(TextFormField, 'Password'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email address'),
        'me@outlook.com',
      );
      await tester.pump();
      expect(find.widgetWithText(TextFormField, 'Password'), findsNothing);
      expect(find.textContaining('never sees your password'), findsOneWidget);
      await tester.ensureVisible(find.text('Continue with Microsoft'));
      await tester.tap(find.text('Continue with Microsoft'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(flow.signedIn, ['me@outlook.com']);
      expect(flow.verifiedWith, ['AT']);
      final (settings, tokens, _) = flow.saved.single;
      expect(settings.imap.host, 'outlook.office365.com');
      expect(settings.imap.port, 993);
      expect(settings.smtp.port, 587);
      expect(settings.smtp.security, ConnectionSecurity.startTls);
      expect(tokens.refreshToken, 'RT');
      expect(flow.controller.state, isA<SetupDone>());
    });

    testWidgets('without a client id in the build, it says so and waits', (
      tester,
    ) async {
      final flow = _Flow(configured: false);
      await show(tester, flow);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email address'),
        'me@outlook.com',
      );
      await tester.pump();
      expect(find.textContaining('can\'t do yet'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Continue with Microsoft'),
      );
      expect(button.onPressed, isNull);
      expect(flow.signedIn, isEmpty);
    });

    testWidgets('a cancelled sign-in returns to the start, saving nothing', (
      tester,
    ) async {
      final flow = _Flow(
        signInError: const OAuthException(
          OAuthProblem.cancelled,
          'access_denied',
        ),
      );
      await show(tester, flow);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email address'),
        'me@outlook.com',
      );
      await tester.pump();
      await tester.ensureVisible(find.text('Continue with Microsoft'));
      await tester.tap(find.text('Continue with Microsoft'));
      await tester.pumpAndSettle();
      expect(find.text('Sign-in was cancelled.'), findsOneWidget);
      expect(flow.saved, isEmpty);
    });

    test('a refused mail login is explained, nothing saved', () async {
      final flow = _Flow(
        verifyResult: const VerificationResult.failure(
          ServerRole.imap,
          VerificationProblem.credentials,
          'no',
        ),
      );
      await flow.controller.signInWith(_microsoft, email: 'me@outlook.com');
      expect(
        (flow.controller.state as EnteringCredentials).error,
        contains('didn\'t accept'),
      );
      expect(flow.saved, isEmpty);
    });

    test('other addresses keep the password flow', () {
      expect(SetupController.defaultProviderFor('me@tommykung.cc'), isNull);
      expect(
        SetupController.defaultProviderFor('Me@Hotmail.com'),
        same(OAuthProvider.microsoft),
      );
    });
  });

  group('KeychainCredentials for OAuth accounts', () {
    late ServerSocket server;
    late List<Map<String, String>> requests;
    String reply = '{}';
    int status = 200;

    setUp(() async {
      requests = [];
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((client) {
        final got = BytesBuilder();
        client.listen((data) {
          got.add(data);
          final text = latin1.decode(got.toBytes());
          final end = text.indexOf('\r\n\r\n');
          if (end < 0) return;
          final length = int.parse(
            RegExp(r'Content-Length: (\d+)').firstMatch(text)!.group(1)!,
          );
          if (text.length < end + 4 + length) return;
          requests.add(Uri.splitQueryString(text.substring(end + 4)));
          final body = utf8.encode(reply);
          client
            ..add(
              latin1.encode(
                'HTTP/1.1 $status X\r\nContent-Length: ${body.length}\r\n\r\n',
              ),
            )
            ..add(body)
            ..close();
        });
      });
    });
    tearDown(() => server.close());

    KeychainCredentials credentials(_Secrets secrets) => KeychainCredentials(
      secrets,
      tokens: TokenClient(
        WebClient(
          resolver: (_) async => [InternetAddress('93.184.216.34')],
          connector: (host, address, port, timeout) => MailSocket.connect(
            ServerEndpoint(
              host,
              server.port,
              ConnectionSecurity.startTls,
              connectAddress: '127.0.0.1',
            ),
          ),
        ),
      ),
    );

    test('a fresh token is used as it is', () async {
      final secrets = _Secrets()
        ..values[_account.keychainKey] = OAuthTokens(
          accessToken: 'AT-1',
          refreshToken: 'RT-1',
          expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        ).toJson();
      expect(await credentials(secrets).passwordFor(_account), 'AT-1');
      expect(requests, isEmpty);
    });

    test('an expiring token is renewed once, and kept', () async {
      reply = jsonEncode({
        'access_token': 'AT-2',
        'refresh_token': 'RT-2',
        'expires_in': 3600,
      });
      final secrets = _Secrets()
        ..values[_account.keychainKey] = OAuthTokens(
          accessToken: 'AT-1',
          refreshToken: 'RT-1',
          expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 1)),
        ).toJson();
      final c = credentials(secrets);
      final both = await Future.wait([
        c.passwordFor(_account),
        c.passwordFor(_account),
      ]);
      expect(both, ['AT-2', 'AT-2']);
      expect(requests, hasLength(1), reason: 'one renewal for both');
      expect(requests.single['refresh_token'], 'RT-1');
      final kept = OAuthTokens.fromJson(secrets.values[_account.keychainKey])!;
      expect((kept.accessToken, kept.refreshToken), ('AT-2', 'RT-2'));
    });

    test('a revoked sign-in asks to sign in again', () async {
      status = 400;
      reply = jsonEncode({'error': 'invalid_grant'});
      final secrets = _Secrets()
        ..values[_account.keychainKey] = OAuthTokens(
          accessToken: 'AT-1',
          refreshToken: 'RT-1',
          expiresAt: DateTime.utc(2020),
        ).toJson();
      await expectLater(
        credentials(secrets).passwordFor(_account),
        throwsA(isA<ImapAuthenticationException>()),
      );
      expect(
        credentials(_Secrets()).passwordFor(_account),
        throwsA(isA<ImapAuthenticationException>()),
        reason: 'no tokens stored',
      );
    });
  });
}
