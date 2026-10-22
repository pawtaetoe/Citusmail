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
}

/// The ways to unsubscribe from a message's list, best first.
final class UnsubscribePlan {
  UnsubscribePlan(List<UnsubscribeMethod> methods, {required this.listName})
    : methods = List.unmodifiable(methods),
      refusal = methods.isEmpty ? UnsubscribeRefusal.none : null;

  UnsubscribePlan.refused(this.refusal, {required this.listName})
    : methods = const [];

  final List<UnsubscribeMethod> methods;

  /// Why [methods] is empty, or null when there are methods.
  final UnsubscribeRefusal? refusal;

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
  static UnsubscribePlan plan(MimeMessage message, TrustReport trust) {
    final name = listName(message);
    final header = ListUnsubscribe.parse(message.headers);
    if (header.isEmpty) {
      return UnsubscribePlan.refused(UnsubscribeRefusal.none, listName: name);
    }
    if (trust.level == TrustLevel.danger) {
      return UnsubscribePlan.refused(
        UnsubscribeRefusal.suspicious,
        listName: name,
      );
    }

    final https = header.links.where((l) => l.scheme == 'https').firstOrNull;
    final http = header.links.where((l) => l.scheme == 'http').firstOrNull;
    final mailto = header.links
        .where((l) => l.scheme == 'mailto')
        .map(MailtoRequest.parse)
        .nonNulls
        .firstOrNull;

    return UnsubscribePlan([
      if (https != null && header.oneClick && signedOneClick(message, trust))
        OneClickMethod(https),
      if (mailto != null) EmailMethod(mailto),
      if (https ?? http case final page?) WebPageMethod(page),
    ], listName: name);
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
