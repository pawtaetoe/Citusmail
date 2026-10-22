// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmail/main.dart';
import 'package:fmail/src/services/app_services.dart';
import 'package:fmail/src/services/secret_store.dart';
import 'package:fmail/src/setup/setup_controller.dart';
import 'package:fmail/src/setup/setup_page.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_setup/mail_setup.dart';
import 'package:mail_store/mail_store.dart';

DiscoveredSettings found({
  DiscoverySource source = DiscoverySource.httpAutoconfig,
  String host = 'tommykung.cc',
}) => DiscoveredSettings(
  email: 'me@tommykung.cc',
  imap: ServerCandidate(host, 993, ConnectionSecurity.implicitTls),
  smtp: ServerCandidate(host, 465, ConnectionSecurity.implicitTls),
  username: 'me@tommykung.cc',
  source: source,
);

final account = Account(
  id: 1,
  email: 'me@tommykung.cc',
  username: 'me@tommykung.cc',
  imap: ServerSettings(
    host: 'tommykung.cc',
    port: 993,
    security: ConnectionSecurity.implicitTls,
  ),
  smtp: ServerSettings(
    host: 'tommykung.cc',
    port: 465,
    security: ConnectionSecurity.implicitTls,
  ),
  sortOrder: 0,
  createdAt: DateTime.utc(2026),
);

/// A controller with scripted discovery, verification and saving.
final class Script {
  DiscoveryResult discovery = DiscoveryResult(found());
  final verifications = <VerificationResult>[];
  final verified = <(DiscoveredSettings, String)>[];
  final saved = <(DiscoveredSettings, String, String?)>[];

  late final controller = SetupController(
    discover: (email, {askMozillaConsent, onStep}) async {
      onStep?.call(DiscoveryStep.providerFileSecure);
      return discovery;
    },
    verify: (settings, password) async {
      verified.add((settings, password));
      return verifications.isEmpty
          ? const VerificationResult.success()
          : verifications.removeAt(0);
    },
    save: (settings, password, {displayName}) async {
      saved.add((settings, password, displayName));
      return account;
    },
  );
}

Future<bool> noMozilla(String _) async => false;

void main() {
  group('SetupController', () {
    test('discover, confirm, verify, save', () async {
      final s = Script();
      await s.controller.start(
        email: ' me@tommykung.cc ',
        password: 'pw',
        displayName: ' Tommy ',
        askMozillaConsent: noMozilla,
      );
      final review = s.controller.state as ReviewingSettings;
      expect(
        review.settings.needsConfirmation,
        isTrue,
        reason: 'found over HTTP',
      );
      await s.controller.useSettings(review.settings);
      expect(s.controller.state, isA<SetupDone>());
      expect(s.saved.single.$2, 'pw');
      expect(s.saved.single.$3, 'Tommy');
    });

    test(
      'nothing found or OAuth-only leads to the manual form with a reason',
      () async {
        final s = Script()..discovery = const DiscoveryResult(null);
        await s.controller.start(
          email: 'a@x.example',
          password: 'pw',
          askMozillaConsent: noMozilla,
        );
        expect(
          (s.controller.state as EditingSettings).notice,
          contains('couldn\'t find'),
        );
        s.discovery = const DiscoveryResult(null, oauthOnly: true);
        await s.controller.start(
          email: 'a@x.example',
          password: 'pw',
          askMozillaConsent: noMozilla,
        );
        expect(
          (s.controller.state as EditingSettings).notice,
          contains('OAuth'),
        );
      },
    );

    test('a failed check is shown, and nothing is saved', () async {
      final s = Script()
        ..verifications.add(
          const VerificationResult.failure(
            ServerRole.imap,
            VerificationProblem.credentials,
            'no',
          ),
        );
      await s.controller.start(
        email: 'me@tommykung.cc',
        password: 'wrong',
        askMozillaConsent: noMozilla,
      );
      await s.controller.useSettings(found());
      expect(s.controller.state, isA<VerificationFailed>());
      expect(s.saved, isEmpty);
    });

    test(
      'the suggested host replaces the shared host on both servers',
      () async {
        final s = Script();
        await s.controller.start(
          email: 'me@tommykung.cc',
          password: 'pw',
          askMozillaConsent: noMozilla,
        );
        await s.controller.useSuggestedHost(
          found(host: 'mail.tommykung.cc'),
          ServerRole.imap,
          'business905.web-hosting.com',
        );
        final used = s.verified.last.$1;
        expect(used.imap.host, 'business905.web-hosting.com');
        expect(used.smtp.host, 'business905.web-hosting.com');
        expect(used.source, DiscoverySource.manual);
      },
    );

    test('an empty password is caught before any network work', () async {
      final s = Script();
      await s.controller.start(
        email: 'me@tommykung.cc',
        password: '',
        askMozillaConsent: noMozilla,
      );
      expect((s.controller.state as EnteringCredentials).error, isNotNull);
    });
  });

  group('SetupPage', () {
    Future<Script> pump(WidgetTester tester) async {
      final s = Script();
      await tester.pumpWidget(
        MaterialApp(
          home: SetupPage(controller: s.controller, onDone: (_) {}),
        ),
      );
      return s;
    }

    testWidgets('warns about settings found over an unencrypted connection', (
      tester,
    ) async {
      await pump(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email address'),
        'me@tommykung.cc',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'pw',
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Settings found'), findsOneWidget);
      expect(find.textContaining('unencrypted connection'), findsOneWidget);
      expect(find.text('Incoming (IMAP): tommykung.cc'), findsOneWidget);
      expect(find.text('I\'ve checked, continue'), findsOneWidget);
    });

    testWidgets('a certificate for another name offers to use that name', (
      tester,
    ) async {
      final s = await pump(tester);
      s.verifications.add(
        VerificationResult.failure(
          ServerRole.imap,
          VerificationProblem.certificate,
          'x',
          tlsFailure: TlsFailure.hostnameMismatch,
          certificate: RejectedCertificate(
            subject: '/CN=business905.web-hosting.com',
            issuer: '',
            validFrom: DateTime(2026),
            validUntil: DateTime(2027),
          ),
        ),
      );
      await s.controller.start(
        email: 'me@tommykung.cc',
        password: 'pw',
        askMozillaConsent: noMozilla,
      );
      await s.controller.useSettings(found(host: 'mail.tommykung.cc'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('is for business905.web-hosting.com'),
        findsOneWidget,
      );
      expect(
        find.text('Use business905.web-hosting.com instead'),
        findsOneWidget,
      );
    });

    testWidgets('the password field hides input by default', (tester) async {
      await pump(tester);
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.widgetWithText(TextFormField, 'Password'),
          matching: find.byType(TextField),
        ),
      );
      expect(field.obscureText, isTrue);
      expect(field.enableSuggestions, isFalse);
    });
  });

  group('start-up problems', () {
    testWidgets('no keychain: explains instead of storing secrets unsafely', (
      tester,
    ) async {
      await tester.pumpWidget(
        FmailApp(
          startup: () async =>
              const StartupKeychainUnavailable('no secret service'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('A keychain is needed'), findsOneWidget);
    });

    testWidgets('an unexpected failure is shown, and Try again retries', (
      tester,
    ) async {
      var attempts = 0;
      final reported = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = reported.add;
      addTearDown(() => FlutterError.onError = previous);

      await tester.pumpWidget(
        FmailApp(
          startup: () async {
            attempts++;
            if (attempts == 1) throw StateError('disk on fire');
            return const StartupKeychainUnavailable('locked');
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('disk on fire'), findsOneWidget);
      expect(reported.single.exception, isA<StateError>());

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.text('A keychain is needed'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('unreadable data offers a fresh start', (tester) async {
      await tester.pumpWidget(
        FmailApp(startup: () async => const StartupDataUnreadable('/tmp/x.db')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Start fresh'), findsOneWidget);
    });
  });

  test(
    'KeychainCredentials reads the account password, and reports a missing one',
    () async {
      final secrets = _MemorySecrets()..values[account.keychainKey] = 'secret';
      expect(await KeychainCredentials(secrets).passwordFor(account), 'secret');
      secrets.values.clear();
      expect(
        KeychainCredentials(secrets).passwordFor(account),
        throwsA(isA<ImapAuthenticationException>()),
      );
    },
  );

  test(
    'the app name is defined in one place',
    () => expect(appName, 'Citusmail'),
  );
}

final class _MemorySecrets implements SecretStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
