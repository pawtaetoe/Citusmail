// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_setup/mail_setup.dart';
import 'package:mail_store/mail_store.dart';

import '../app.dart' show appName;

/// Where the account setup flow is.
sealed class SetupState {
  const SetupState();
}

/// Waiting for email and password.
final class EnteringCredentials extends SetupState {
  const EnteringCredentials({this.error});

  final String? error;
}

/// Looking for settings.
final class Discovering extends SetupState {
  const Discovering(this.step);

  final DiscoveryStep? step;
}

/// Settings found; the user confirms (always shown, so the user sees where
/// the password will go).
final class ReviewingSettings extends SetupState {
  const ReviewingSettings(this.settings);

  final DiscoveredSettings settings;
}

/// The user enters or edits settings by hand.
final class EditingSettings extends SetupState {
  const EditingSettings({this.prefill, this.notice});

  final DiscoveredSettings? prefill;

  /// Why the form is shown (e.g. nothing was found).
  final String? notice;
}

/// Logging in to check the settings.
final class Verifying extends SetupState {
  const Verifying(this.settings);

  final DiscoveredSettings settings;
}

/// The check failed.
final class VerificationFailed extends SetupState {
  const VerificationFailed(this.settings, this.result);

  final DiscoveredSettings settings;
  final VerificationResult result;
}

/// The account is saved.
final class SetupDone extends SetupState {
  const SetupDone(this.account);

  final Account account;
}

typedef DiscoverFn = Future<DiscoveryResult> Function(
  String email, {
  Future<bool> Function(String domain)? askMozillaConsent,
  void Function(DiscoveryStep step)? onStep,
});
typedef VerifyFn = Future<VerificationResult> Function(
  DiscoveredSettings settings,
  String password,
);
typedef SaveFn = Future<Account> Function(
  DiscoveredSettings settings,
  String password, {
  String? displayName,
});

/// Drives account setup: discover, confirm, verify with a real login, save.
///
/// The password stays in memory only until the account is saved (then it
/// lives in the keychain) or the flow is abandoned.
final class SetupController extends ChangeNotifier {
  SetupController({
    required this._discover,
    required this._verify,
    required this._save,
  });

  final DiscoverFn _discover;
  final VerifyFn _verify;
  final SaveFn _save;

  SetupState _state = const EnteringCredentials();
  String _email = '';
  String _password = '';
  String? _displayName;

  SetupState get state => _state;
  String get email => _email;

  /// Step 1: look for settings for [email].
  Future<void> start({
    required String email,
    required String password,
    String? displayName,
    required Future<bool> Function(String domain) askMozillaConsent,
  }) async {
    _email = email.trim();
    _password = password;
    final name = displayName?.trim() ?? '';
    _displayName = name.isEmpty ? null : name;
    if (_password.isEmpty) {
      return _set(const EnteringCredentials(error: 'Enter your password.'));
    }

    _set(const Discovering(null));
    final DiscoveryResult result;
    try {
      result = await _discover(
        _email,
        askMozillaConsent: askMozillaConsent,
        onStep: (s) => _set(Discovering(s)),
      );
    } on ArgumentError {
      return _set(
        const EnteringCredentials(
          error: 'That doesn\'t look like an email address $appName can use.',
        ),
      );
    }
    final found = result.settings;
    if (found != null) return _set(ReviewingSettings(found));
    _set(
      EditingSettings(
        notice: result.oauthOnly
            ? 'Your provider only allows sign-in through its own web page (OAuth), which $appName doesn\'t support yet.'
            : '$appName couldn\'t find the settings automatically. Your provider\'s help pages list them.',
      ),
    );
  }

  /// The user confirmed the found settings (or typed them).
  Future<void> useSettings(DiscoveredSettings settings) async {
    _set(Verifying(settings));
    final result = await _verify(settings, _password);
    if (!result.succeeded) return _set(VerificationFailed(settings, result));
    final account = await _save(settings, _password, displayName: _displayName);
    _password = '';
    _set(SetupDone(account));
  }

  /// Try again with the host the certificate is valid for.
  Future<void> useSuggestedHost(
    DiscoveredSettings settings,
    ServerRole role,
    String host,
  ) {
    ServerCandidate swap(ServerCandidate c) =>
        ServerCandidate(host, c.port, c.security);
    // When both servers share the failing host name, fix both.
    final sameHost = settings.imap.host == settings.smtp.host;
    final fixImap = role == ServerRole.imap || sameHost;
    final fixSmtp = role == ServerRole.smtp || sameHost;
    return useSettings(
      DiscoveredSettings(
        email: settings.email,
        imap: fixImap ? swap(settings.imap) : settings.imap,
        smtp: fixSmtp ? swap(settings.smtp) : settings.smtp,
        username: settings.username,
        source: DiscoverySource.manual,
      ),
    );
  }

  void editSettings([DiscoveredSettings? prefill]) =>
      _set(EditingSettings(prefill: prefill));

  /// Back to the first step (the password is forgotten).
  void restart() {
    _password = '';
    _set(const EnteringCredentials());
  }

  void _set(SetupState state) {
    _state = state;
    notifyListeners();
  }
}

/// User-facing wording for setup, in one place.
abstract final class SetupText {
  static String step(DiscoveryStep? step) => switch (step) {
    null => 'Starting…',
    DiscoveryStep.providerFileSecure =>
      'Asking your provider for its settings…',
    DiscoveryStep.dnsRecords => 'Checking your domain\'s mail records…',
    DiscoveryStep.providerFileUnencrypted =>
      'Trying your provider\'s settings file…',
    DiscoveryStep.probing => 'Trying common server names…',
    DiscoveryStep.mozillaDatabase => 'Checking Mozilla\'s database…',
  };

  static String source(DiscoverySource source) => switch (source) {
    DiscoverySource.httpsAutoconfig => 'from your provider (secure connection)',
    DiscoverySource.dnsSrv => 'from your domain\'s DNS records',
    DiscoverySource.httpAutoconfig => 'from your provider\'s settings file',
    DiscoverySource.probed => 'by trying common server names',
    DiscoverySource.mozillaDatabase => 'from Mozilla\'s database',
    DiscoverySource.manual => 'entered by you',
  };

  static String warning(
    SetupWarning warning,
    DiscoveredSettings s,
  ) => switch (warning) {
    SetupWarning.unauthenticatedSource =>
      'These settings came over an unencrypted connection, so someone on your network could have changed '
          'them. Check the server names below before continuing.',
    SetupWarning.serverOutsideDomain =>
      'A server isn\'t part of ${s.domain}. Your password will be sent to it. Continue only if your mail '
          'is hosted there.',
  };

  static String security(ConnectionSecurity security) => switch (security) {
    ConnectionSecurity.implicitTls => 'Encrypted (TLS)',
    ConnectionSecurity.startTls => 'Encrypted (STARTTLS)',
  };

  static String problem(VerificationResult r, DiscoveredSettings s) {
    final server = r.role == ServerRole.smtp ? s.smtp : s.imap;
    final kind = r.role == ServerRole.smtp
        ? 'outgoing (SMTP)'
        : 'incoming (IMAP)';
    return switch (r.problem) {
      VerificationProblem.credentials =>
        'The $kind server didn\'t accept the user name or password.',
      VerificationProblem.certificate => switch (r.tlsFailure) {
        TlsFailure.hostnameMismatch =>
          'The certificate of ${server.host} is for ${r.certificate?.commonName ?? 'a different name'}, '
              'so $appName can\'t be sure it\'s the right server.',
        TlsFailure.expired =>
          'The certificate of ${server.host} expired'
              '${r.certificate == null ? '' : ' on ${r.certificate!.validUntil.toLocal().toString().split(' ').first}'}.',
        _ =>
          'The certificate of ${server.host} isn\'t from an authority your device trusts.',
      },
      VerificationProblem.security =>
        '${server.host} doesn\'t offer an encrypted connection, so $appName won\'t connect to it.',
      VerificationProblem.network =>
        'Couldn\'t reach ${server.host}:${server.port}. Check the name and your connection.',
      VerificationProblem.server ||
      null => 'The $kind server answered unexpectedly. (${r.message})',
    };
  }
}
