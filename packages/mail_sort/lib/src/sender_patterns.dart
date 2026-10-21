// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';

/// Recognises addresses that machines send from: `noreply@`,
/// `do-not-reply@`, `notifications@` and similar.
abstract final class AutomatedSender {
  /// Words that mark an automated address anywhere in the local part,
  /// once separators are removed (`no-reply`, `no_reply`, `no.reply`,
  /// `bank-alerts-noreply`).
  static const _markers = [
    'noreply',
    'donotreply',
    'donotrespond',
    'noresponse',
  ];

  /// Local parts that are automated only as a whole word, so that e.g.
  /// `alertsteam` or `notify.me.jane` are not caught.
  static const _wholeNames = {
    'notifications',
    'notification',
    'notify',
    'alerts',
    'alert',
  };

  static bool matches(MailAddress? from) {
    if (from == null) return false;
    final local = _compact(from.localPart);
    if (local.isEmpty) return false;
    return _wholeNames.contains(local) || _markers.any(local.contains);
  }

  /// Lower case, without a `+tag` and without `-`, `_` and `.`.
  static String _compact(String localPart) {
    var local = _asciiLowerCase(localPart);
    final plus = local.indexOf('+');
    if (plus >= 0) local = local.substring(0, plus);
    return local.replaceAll(_separators, '');
  }

  static final _separators = RegExp('[-_.]');
}

/// Lower-cases A-Z only. Full Unicode lower-casing would turn some
/// non-ASCII letters (e.g. the Kelvin sign) into ASCII ones and let a
/// look-alike address match.
String _asciiLowerCase(String s) => String.fromCharCodes([
  for (final c in s.codeUnits) c >= 0x41 && c <= 0x5A ? c + 0x20 : c,
]);

/// A service whose mail is notifications, even when it carries mailing
/// list headers (GitHub sends every notification with a `List-Id`).
final class KnownService {
  const KnownService(this.name, this.domain, {this.localParts});

  /// For tests and explanations.
  final String name;

  /// Matches this domain and its subdomains, never look-alikes:
  /// `github.com` matches `github.com` but not `evilgithub.com`.
  final String domain;

  /// Only these senders (lower case) at the domain, or every sender if
  /// null. Restricting keeps a service's own newsletters out.
  final Set<String>? localParts;

  bool matches(MailAddress from) {
    final senderDomain = _asciiLowerCase(from.domain);
    final inDomain =
        senderDomain == domain || senderDomain.endsWith('.$domain');
    if (!inDomain) return false;
    final allowed = localParts;
    return allowed == null || allowed.contains(_asciiLowerCase(from.localPart));
  }
}

/// The built-in list of known notification services.
///
/// Kept short and specific: banks, shops and delivery firms differ by
/// country and are recognised by their `noreply`-style addresses instead.
/// The From address can be forged, so a match only decides the folder; it
/// never makes a message more trusted.
abstract final class KnownServices {
  static const List<KnownService> all = [
    KnownService(
      'GitHub',
      'github.com',
      localParts: {'notifications', 'noreply'},
    ),
    KnownService('GitLab', 'gitlab.com', localParts: {'gitlab', 'noreply'}),
    KnownService(
      'Bitbucket',
      'bitbucket.org',
      localParts: {'notifications-noreply'},
    ),
    KnownService('Jira', 'atlassian.net', localParts: {'jira'}),
    KnownService('Confluence', 'atlassian.net', localParts: {'confluence'}),
    KnownService(
      'Google Calendar',
      'google.com',
      localParts: {'calendar-notification'},
    ),
    KnownService('Facebook', 'facebookmail.com', localParts: {'notification'}),
  ];

  static KnownService? match(MailAddress? from) {
    if (from == null) return null;
    for (final service in all) {
      if (service.matches(from)) return service;
    }
    return null;
  }
}
