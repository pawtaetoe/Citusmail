// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:mail_oauth/mail_oauth.dart';
import 'package:mail_protocol/mail_protocol.dart';

/// The live test account, from live-test.env. Parsed line by line, never
/// executed, and refused if it contains anything that looks like a secret.
///
/// A password account needs its servers; an OAuth account
/// (`LIVE_SIGN_IN=microsoft` or `google`) uses the provider's servers unless they are
/// given.
final class LiveSettings {
  LiveSettings({
    required this.email,
    required this.imap,
    required this.smtp,
    this.oauth,
    this.testFolder = defaultTestFolder,
  });

  /// Parses the text of a live-test.env file; [source] names it in errors.
  ///
  /// [buildClientId] stands in for the client id compiled in with
  /// `-DCITUSMAIL_MS_CLIENT_ID=...` (or `CITUSMAIL_GOOGLE_CLIENT_ID`),
  /// used when the file names none.
  factory LiveSettings.parse(
    String text, {
    String source = 'live-test.env',
    String? buildClientId,
  }) {
    final values = <String, String>{};
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final match = RegExp(r'^([A-Z_]+)=(.*)$').firstMatch(trimmed);
      if (match == null) {
        throw FormatException('bad line in $source: $trimmed');
      }
      final key = match.group(1)!;
      if (RegExp('PASSWORD|SECRET|TOKEN').hasMatch(key)) {
        throw StateError(
          '$source must not contain secrets ($key); use the keychain',
        );
      }
      values[key] = match.group(2)!.trim();
    }
    String? optional(String key) {
      final value = values[key];
      return value == null || value.isEmpty ? null : value;
    }

    String get(String key) =>
        optional(key) ?? (throw StateError('$key missing from $source'));

    final email = get('LIVE_EMAIL');
    if (email == 'you@example.com') {
      throw StateError('fill in your own account in $source');
    }
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      throw StateError('LIVE_EMAIL in $source is not an address');
    }

    final signIn = optional('LIVE_SIGN_IN') ?? 'password';
    OAuthProvider? oauth;
    if (signIn != 'password') {
      final provider = OAuthProvider.byId(signIn);
      if (provider == null) {
        throw StateError(
          'LIVE_SIGN_IN in $source must be "password" or one of: '
          '${OAuthProvider.all.map((p) => p.id).join(', ')}',
        );
      }
      final clientId =
          optional('LIVE_OAUTH_CLIENT_ID') ??
          buildClientId ??
          provider.clientId;
      if (clientId.isEmpty) {
        throw StateError(
          '${provider.name} sign-in needs the app\'s client id: set '
          'LIVE_OAUTH_CLIENT_ID in $source (see packaging/README.md)',
        );
      }
      if (!RegExp(r'^[A-Za-z0-9._-]{8,200}$').hasMatch(clientId)) {
        throw StateError('LIVE_OAUTH_CLIENT_ID in $source is not a client id');
      }
      oauth = clientId == provider.clientId
          ? provider
          : provider.withClientId(clientId);
    }

    ServerEndpoint endpoint(
      String prefix, {
      required String? defaultHost,
      required int? defaultPort,
      required Set<int> startTlsPorts,
    }) {
      final host = optional('${prefix}_HOST') ?? defaultHost;
      if (host == null) {
        throw StateError('${prefix}_HOST missing from $source');
      }
      if (!RegExp(r'^[A-Za-z0-9.-]+$').hasMatch(host)) {
        throw StateError('${prefix}_HOST in $source is not a host name');
      }
      final portText = optional('${prefix}_PORT');
      final port = portText == null ? defaultPort : int.tryParse(portText);
      if (port == null || port < 1 || port > 65535) {
        throw StateError('${prefix}_PORT in $source is not a port');
      }
      return ServerEndpoint(
        host,
        port,
        startTlsPorts.contains(port)
            ? ConnectionSecurity.startTls
            : ConnectionSecurity.implicitTls,
      );
    }

    final folder = optional('LIVE_TEST_FOLDER') ?? defaultTestFolder;
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(folder)) {
      throw StateError('LIVE_TEST_FOLDER in $source must be a simple name');
    }

    return LiveSettings(
      email: email,
      oauth: oauth,
      imap: endpoint(
        'LIVE_IMAP',
        defaultHost: oauth?.imapHost,
        defaultPort: oauth == null ? null : 993,
        startTlsPorts: const {143},
      ),
      smtp: endpoint(
        'LIVE_SMTP',
        defaultHost: oauth?.smtpHost,
        defaultPort: oauth?.smtpPort,
        startTlsPorts: const {25, 587},
      ),
      testFolder: folder,
    );
  }

  factory LiveSettings.load(File file) {
    if (!file.existsSync()) {
      throw StateError(
        '${file.path} not found; copy live-test.env.example and fill it in',
      );
    }
    return LiveSettings.parse(file.readAsStringSync(), source: file.path);
  }

  static const defaultTestFolder = 'CitusmailTest';

  final String email;
  final ServerEndpoint imap;
  final ServerEndpoint smtp;

  /// The provider to sign in with, with its client id; null for a
  /// password account.
  final OAuthProvider? oauth;

  /// The only folder live checks may create or change.
  final String testFolder;

  bool get usesOAuth => oauth != null;
}
