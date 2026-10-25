// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';

import 'discovered_settings.dart';

/// Turns stored settings into an endpoint (tests point it at 127.0.0.1).
typedef EndpointResolver = ServerEndpoint Function(ServerCandidate candidate);

ServerEndpoint _direct(ServerCandidate c) => c.endpoint;

/// Whether a server answers, with a valid certificate, without logging in.
abstract interface class ServerAvailability {
  Future<bool> imapAvailable(ServerCandidate candidate);
  Future<bool> smtpAvailable(ServerCandidate candidate);
}

/// Checks that a server speaks IMAP or SMTP with a valid certificate,
/// without sending any credentials.
final class ServerProber implements ServerAvailability {
  const ServerProber({
    this.tls = const TlsSettings(),
    this.timeout = const Duration(seconds: 8),
    this.resolve = _direct,
  });

  final TlsSettings tls;
  final Duration timeout;
  final EndpointResolver resolve;

  @override
  Future<bool> imapAvailable(ServerCandidate candidate) async {
    try {
      final client = await ImapClient.connect(
        resolve(candidate),
        tls: tls,
        timeouts: ImapTimeouts(connect: timeout, command: timeout),
      );
      await client.close();
      return true;
    } on MailException {
      return false;
    }
  }

  @override
  Future<bool> smtpAvailable(ServerCandidate candidate) async {
    try {
      final client = await SmtpClient.connect(
        resolve(candidate),
        tls: tls,
        timeouts: SmtpTimeouts(connect: timeout, command: timeout),
      );
      await client.close();
      return true;
    } on MailException {
      return false;
    }
  }
}

/// Which server a verification problem is about.
enum ServerRole { imap, smtp }

/// What went wrong, in terms the setup screen can explain.
enum VerificationProblem {
  /// Wrong user name or password.
  credentials,

  /// The provider refuses the account's own password from mail apps and
  /// wants an app password (Gmail with 2-Step Verification).
  appPasswordRequired,

  /// The certificate is not valid for this host (see the certificate's
  /// name for a hint), expired, or not trusted.
  certificate,

  /// The server refused to go encrypted (no STARTTLS, or TLS too old).
  security,

  /// Could not reach the server.
  network,

  /// The server misbehaved.
  server,
}

/// The outcome of checking settings with a real login.
final class VerificationResult {
  const VerificationResult.success()
    : role = null,
      problem = null,
      message = null,
      tlsFailure = null,
      certificate = null;

  const VerificationResult.failure(
    ServerRole this.role,
    VerificationProblem this.problem,
    String this.message, {
    this.tlsFailure,
    this.certificate,
  });

  final ServerRole? role;
  final VerificationProblem? problem;

  /// Technical detail (no credentials).
  final String? message;
  final TlsFailure? tlsFailure;

  /// For certificate problems: what the server presented.
  final RejectedCertificate? certificate;

  bool get succeeded => problem == null;

  /// For a host name mismatch: a host name the certificate is valid for,
  /// when it is a concrete name (not a wildcard), to suggest to the user.
  String? get suggestedHost {
    final name = certificate?.commonName?.replaceFirst(RegExp(r'^DNS:'), '');
    if (tlsFailure != TlsFailure.hostnameMismatch ||
        name == null ||
        name.startsWith('*')) {
      return null;
    }
    return name;
  }
}

/// Checks discovered or typed settings with a real IMAP login and SMTP
/// authentication. Nothing is saved; nothing is sent.
final class AccountVerifier {
  const AccountVerifier({
    this.tls = const TlsSettings(),
    this.resolve = _direct,
  });

  final TlsSettings tls;
  final EndpointResolver resolve;

  /// Logs in with [password], or with [password] as an OAuth access
  /// token when [oauth] is set (SASL XOAUTH2).
  Future<VerificationResult> verify(
    DiscoveredSettings settings,
    String password, {
    bool oauth = false,
  }) async {
    final imapProblem = await _check(ServerRole.imap, () async {
      final imap = await ImapClient.connect(resolve(settings.imap), tls: tls);
      try {
        if (oauth) {
          await imap.loginOAuth(settings.username, password);
        } else {
          await imap.login(settings.username, password);
        }
      } finally {
        await imap.logout();
      }
    });
    if (imapProblem != null) return imapProblem;
    return await _check(ServerRole.smtp, () async {
          final smtp = await SmtpClient.connect(
            resolve(settings.smtp),
            tls: tls,
          );
          try {
            if (oauth) {
              await smtp.authenticateOAuth(settings.username, password);
            } else {
              await smtp.authenticate(settings.username, password);
            }
          } finally {
            await smtp.quit();
          }
        }) ??
        const VerificationResult.success();
  }

  /// Google's refusal of an account password: "Application-specific
  /// password required" (IMAP, and SMTP with 534 5.7.9). The text decides,
  /// not the code: other servers use 5.7.9 for "mechanism too weak".
  static bool _asksForAppPassword(String text) =>
      text.toLowerCase().contains('application-specific password');

  static Future<VerificationResult?> _check(
    ServerRole role,
    Future<void> Function() action,
  ) async {
    try {
      await action();
      return null;
    } on ImapAuthenticationException catch (e) {
      return VerificationResult.failure(
        role,
        _asksForAppPassword(e.message)
            ? VerificationProblem.appPasswordRequired
            : VerificationProblem.credentials,
        e.message,
      );
    } on SmtpAuthenticationException catch (e) {
      final reply = e.reply;
      return VerificationResult.failure(
        role,
        reply != null && _asksForAppPassword(reply.text)
            ? VerificationProblem.appPasswordRequired
            : VerificationProblem.credentials,
        e.message,
      );
    } on MailTlsException catch (e) {
      final problem = e.failure == TlsFailure.handshakeFailed
          ? VerificationProblem.security
          : VerificationProblem.certificate;
      return VerificationResult.failure(
        role,
        problem,
        e.message,
        tlsFailure: e.failure,
        certificate: e.certificate,
      );
    } on MailSecurityException catch (e) {
      return VerificationResult.failure(
        role,
        VerificationProblem.security,
        e.message,
      );
    } on MailConnectionException catch (e) {
      return VerificationResult.failure(
        role,
        VerificationProblem.network,
        e.message,
      );
    } on MailTimeoutException catch (e) {
      return VerificationResult.failure(
        role,
        VerificationProblem.network,
        e.message,
      );
    } on MailException catch (e) {
      return VerificationResult.failure(
        role,
        VerificationProblem.server,
        e.message,
      );
    }
  }
}
