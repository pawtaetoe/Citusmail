// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_trust/mail_trust.dart';
import 'package:mail_web/mail_web.dart';

import 'headers.dart';

/// A way to unsubscribe.
sealed class UnsubscribeMethod {
  const UnsubscribeMethod();
}

/// RFC 8058: one POST to the sender's https link, done by the app. Offered
/// only when the user's server verified a DKIM signature covering both
/// unsubscribe headers, so the link really is the sender's.
final class OneClickMethod extends UnsubscribeMethod {
  const OneClickMethod(this.url);

  final Uri url;
}

/// An email from the user to the sender's unsubscribe address.
final class EmailMethod extends UnsubscribeMethod {
  const EmailMethod(this.request);

  final MailtoRequest request;
}

/// The sender's unsubscribe page, opened in the browser.
final class WebPageMethod extends UnsubscribeMethod {
  const WebPageMethod(this.url);

  final Uri url;
}

/// Why unsubscribing is not offered for a message.
enum UnsubscribeRefusal {
  /// The message has no unsubscribe header.
  none,

  /// The message looks like a scam: unsubscribing would only confirm
  /// that the address is read.
  suspicious,

  /// Every unsubscribe address failed the phishing checks.
  unsafeLink,
}

/// The ways to unsubscribe from a message's list, best first.
final class UnsubscribePlan {
  UnsubscribePlan(
    List<UnsubscribeMethod> methods, {
    required this.listName,
    List<String> warnings = const [],
  }) : methods = List.unmodifiable(methods),
       warnings = List.unmodifiable(warnings),
       refusal = methods.isEmpty ? UnsubscribeRefusal.none : null,
       reason = null;

  UnsubscribePlan.refused(this.refusal, {required this.listName, this.reason})
    : methods = const [],
      warnings = const [];

  final List<UnsubscribeMethod> methods;

  /// Why [methods] is empty, or null when there are methods.
  final UnsubscribeRefusal? refusal;

  /// For a refusal other than [UnsubscribeRefusal.none]: why, for the
  /// user.
  final String? reason;

  /// Things the user should know before unsubscribing (an unverified
  /// sender, an unusual unsubscribe address), shown when they confirm.
  final List<String> warnings;

  /// What to call the list ("Shop Weekly").
  final String listName;

  bool get available => methods.isNotEmpty;

  /// The best method, or null.
  UnsubscribeMethod? get preferred => methods.firstOrNull;

  /// The methods after [method], to fall back on when it fails.
  List<UnsubscribeMethod> after(UnsubscribeMethod method) {
    final i = methods.indexOf(method);
    return i < 0 ? const [] : methods.sublist(i + 1);
  }
}

/// Decides how a message can be unsubscribed from.
abstract final class UnsubscribePlanner {
  /// Unsubscribing is offered when the message has `List-Unsubscribe`
  /// and:
  ///
  /// - the message shows no sign of a scam other than an unverified
  ///   sender (forwarding and some lists cause that honestly; the user is
  ///   warned instead). Lookalike or imitating senders, deceptive links
  ///   and dangerous files mean a scam: unsubscribing would only confirm
  ///   the address is read;
  /// - each unsubscribe address passes the same checks as the links in a
  ///   message ([TrustChecker.checkLink]); a dangerous one is left out,
  ///   an unusual one comes with a warning. For an unverified sender, an
  ///   address outside the sender's domain is pointed out too.
  static UnsubscribePlan plan(MimeMessage message, TrustReport trust) {
    final name = listName(message);
    final header = ListUnsubscribe.parse(message.headers);
    if (header.isEmpty) {
      return UnsubscribePlan.refused(UnsubscribeRefusal.none, listName: name);
    }
    final scam = trust.findings
        .where(
          (f) =>
              f.level == TrustLevel.danger &&
              f.kind != FindingKind.failedVerification,
        )
        .firstOrNull;
    if (scam != null) {
      return UnsubscribePlan.refused(
        UnsubscribeRefusal.suspicious,
        listName: name,
        reason: 'This message may be a scam: ${scam.message}',
      );
    }

    final warnings = <String>{};
    final unsafe = <String>[];
    final sender = message.from.firstOrNull;
    final senderDomain = sender == null
        ? null
        : Domains.registrable(sender.domain);

    /// Whether [host] may be used, adding what the user should know.
    bool usable(String host, Uri link) {
      final verdict = TrustChecker.checkLink(link);
      if (verdict != null && verdict.level == TrustLevel.danger) {
        unsafe.addAll(verdict.reasons);
        return false;
      }
      if (verdict != null) warnings.addAll(verdict.reasons);
      final domain = Domains.registrable(host);
      if (!trust.verified &&
          senderDomain != null &&
          domain != null &&
          domain != senderDomain) {
        warnings.add(
          'The unsubscribe address is at $domain, not at the sender\'s '
          'domain ($senderDomain).',
        );
      }
      return true;
    }

    final https = header.links
        .where((l) => l.scheme == 'https' && usable(l.host, l))
        .firstOrNull;
    final http = https != null
        ? null
        : header.links
              .where((l) => l.scheme == 'http' && usable(l.host, l))
              .firstOrNull;
    final mailto = header.links
        .where((l) => l.scheme == 'mailto')
        .map(MailtoRequest.parse)
        .nonNulls
        .where((m) {
          final at = m.address.lastIndexOf('@');
          final host = m.address.substring(at + 1);
          return usable(host, Uri(scheme: 'https', host: host));
        })
        .firstOrNull;

    final methods = [
      if (https != null && header.oneClick && signedOneClick(message, trust))
        OneClickMethod(https),
      if (mailto != null) EmailMethod(mailto),
      if (https ?? http case final page?) WebPageMethod(page),
    ];
    if (methods.isEmpty && unsafe.isNotEmpty) {
      return UnsubscribePlan.refused(
        UnsubscribeRefusal.unsafeLink,
        listName: name,
        reason: 'The unsubscribe address isn\'t safe: ${unsafe.first}',
      );
    }
    if (trust.level == TrustLevel.danger) {
      // Only an unverified sender (see above).
      warnings.add(
        'Your mail server couldn\'t verify the sender. Unsubscribe only if '
        'you signed up for this list: to a scammer, it confirms your address '
        'is read.',
      );
    }
    return UnsubscribePlan(
      methods,
      listName: name,
      warnings: warnings.toList(),
    );
  }

  /// Whether a DKIM signature that the user's server verified covers both
  /// `List-Unsubscribe` and `List-Unsubscribe-Post` (RFC 8058 section 4):
  /// otherwise the headers could have been added by anyone on the way.
  static bool signedOneClick(MimeMessage message, TrustReport trust) {
    final signatures = [
      for (final field in message.headers.all('dkim-signature'))
        ?DkimSignature.parse(field.value),
    ];
    for (final pass in trust.dkimPasses) {
      final domain = pass.domain;
      if (domain == null) continue;
      final selector = pass.properties['header.s']?.toLowerCase();
      for (final signature in signatures) {
        if (signature.domain != domain) continue;
        if (selector != null && signature.selector != selector) continue;
        if (signature.signedHeaders.containsAll(const {
          'list-unsubscribe',
          'list-unsubscribe-post',
        })) {
          return true;
        }
      }
    }
    return false;
  }

  /// "Shop Weekly" from `List-Id: Shop Weekly <weekly.shop.example>`, else
  /// the sender's name or address.
  static String listName(MimeMessage message) {
    final listId = message.headers.value('list-id');
    if (listId != null) {
      final lt = listId.indexOf('<');
      final phrase = (lt > 0 ? listId.substring(0, lt) : '')
          .replaceAll('"', '')
          .trim();
      if (phrase.isNotEmpty && phrase.length <= 80) {
        return const EncodedWordDecoder().decode(phrase).text;
      }
    }
    final from = message.from.firstOrNull;
    final display = from?.displayName?.trim();
    if (display != null && display.isNotEmpty) return display;
    return from?.address ?? 'this list';
  }
}

/// What happened to a one-click request.
sealed class OneClickResult {
  const OneClickResult();
}

final class OneClickDone extends OneClickResult {
  const OneClickDone();
}

final class OneClickFailed extends OneClickResult {
  const OneClickFailed(this.reason);

  /// For the user ("shop.example didn't accept the request").
  final String reason;
}

/// Sends RFC 8058 one-click requests.
final class OneClickUnsubscriber {
  const OneClickUnsubscriber(this._web);

  final WebClient _web;

  static const body = 'List-Unsubscribe=One-Click';

  Future<OneClickResult> unsubscribe(Uri url) async {
    try {
      final response = await _web.post(
        url,
        body: ascii.encode(body),
        contentType: 'application/x-www-form-urlencoded',
      );
      if (response.ok) return const OneClickDone();
      return OneClickFailed(
        response.statusCode >= 300 && response.statusCode < 400
            ? '${url.host} wanted to send you to another page.'
            : '${url.host} didn\'t accept the request (error ${response.statusCode}).',
      );
    } on WebException catch (e) {
      return OneClickFailed(switch (e.problem) {
        WebProblem.unsafeUrl || WebProblem.privateAddress =>
          'The unsubscribe address isn\'t safe to use.',
        WebProblem.notFound => '${url.host} doesn\'t exist.',
        WebProblem.unreachable ||
        WebProblem.timeout => 'Couldn\'t reach ${url.host}. Are you online?',
        WebProblem.insecure =>
          '${url.host} doesn\'t have a valid security certificate.',
        WebProblem.badResponse ||
        WebProblem.notAvailable ||
        WebProblem.tooLarge => '${url.host} gave an answer that made no sense.',
      });
    }
  }
}
