// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Base class for every error the mail protocol layer reports.
///
/// Messages never contain credentials or message content, so they are safe
/// to show to the user or write to a log.
abstract base class MailException implements Exception {
  const MailException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Could not connect, or the connection was lost.
final class MailConnectionException extends MailException {
  const MailConnectionException(super.message);
}

/// The server did not answer in time.
final class MailTimeoutException extends MailException {
  const MailTimeoutException(super.message);
}

/// Why a TLS connection was refused.
enum TlsFailure {
  /// The certificate is not signed by a trusted authority (or self-signed).
  untrusted,

  /// The certificate has expired or is not yet valid.
  expired,

  /// The certificate is for a different host name.
  hostnameMismatch,

  /// The handshake failed for another reason (for example, the server
  /// only offers TLS versions older than 1.2).
  handshakeFailed,
}

/// Details of a certificate that was rejected, for explaining the problem
/// (e.g. "the certificate is for *.web-hosting.com").
final class RejectedCertificate {
  const RejectedCertificate({
    required this.subject,
    required this.issuer,
    required this.validFrom,
    required this.validUntil,
  });

  /// e.g. `/CN=*.web-hosting.com`.
  final String subject;
  final String issuer;
  final DateTime validFrom;
  final DateTime validUntil;

  /// The common name from [subject], if any.
  String? get commonName =>
      RegExp(r'CN=([^/,]+)').firstMatch(subject)?.group(1)?.trim();
}

/// The TLS handshake or certificate check failed. The connection was
/// closed before anything, including credentials, was sent.
final class MailTlsException extends MailException {
  const MailTlsException(this.failure, super.message, {this.certificate});

  final TlsFailure failure;

  /// The certificate the server presented, when it was rejected.
  final RejectedCertificate? certificate;

  /// Classifies a Dart [HandshakeException] message.
  static TlsFailure classify(String details) {
    final text = details.toLowerCase();
    if (text.contains('hostname mismatch') || text.contains('hostname')) {
      return TlsFailure.hostnameMismatch;
    }
    if (text.contains('expired') || text.contains('not yet valid')) {
      return TlsFailure.expired;
    }
    if (text.contains('self signed') ||
        text.contains('self-signed') ||
        text.contains('unable to get local issuer') ||
        text.contains('certificate_verify_failed') ||
        text.contains('unknown ca')) {
      return TlsFailure.untrusted;
    }
    return TlsFailure.handshakeFailed;
  }
}

/// The connection would break a security rule, so it was stopped: for
/// example, the server does not offer STARTTLS, or sent unencrypted data
/// where only encrypted data is allowed.
final class MailSecurityException extends MailException {
  const MailSecurityException(super.message);
}

/// The server sent something that does not follow the protocol, or that
/// exceeds a safety limit.
final class MailProtocolException extends MailException {
  const MailProtocolException(super.message);
}
