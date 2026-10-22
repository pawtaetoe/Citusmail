// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';

/// The unsubscribe headers of a message.
final class ListUnsubscribe {
  const ListUnsubscribe(this.links, {required this.oneClick});

  /// Most links read (hostile mail can list thousands).
  static const maxLinks = 10;

  /// Longest link kept.
  static const maxLinkLength = 4096;

  /// `https:`, `http:` and `mailto:` links, in the sender's order.
  final List<Uri> links;

  /// `List-Unsubscribe-Post: List-Unsubscribe=One-Click` is present: the
  /// sender accepts a POST to its https link (RFC 8058).
  final bool oneClick;

  bool get isEmpty => links.isEmpty;

  /// Reads `List-Unsubscribe` and `List-Unsubscribe-Post` from [headers].
  /// Only the first of each counts.
  static ListUnsubscribe parse(HeaderSection headers) {
    final value = headers.value('list-unsubscribe') ?? '';
    final links = <Uri>[];
    // RFC 2369: a list of <uri> separated by commas, possibly with
    // comments and folding whitespace (also inside the brackets).
    for (final match in RegExp(r'<([^<>]*)>').allMatches(value)) {
      if (links.length >= maxLinks) break;
      final text = match.group(1)!.replaceAll(RegExp(r'\s+'), '');
      if (text.isEmpty || text.length > maxLinkLength) continue;
      final uri = Uri.tryParse(text);
      if (uri == null) continue;
      if (const {'https', 'http', 'mailto'}.contains(uri.scheme)) {
        links.add(uri);
      }
    }
    final post = headers.value('list-unsubscribe-post')?.trim();
    return ListUnsubscribe(
      List.unmodifiable(links),
      oneClick: post == 'List-Unsubscribe=One-Click',
    );
  }
}

/// The parts of a `DKIM-Signature` header that say what was signed.
final class DkimSignature {
  const DkimSignature({
    required this.domain,
    required this.selector,
    required this.signedHeaders,
  });

  /// `d=`, lower case.
  final String domain;

  /// `s=`, lower case.
  final String selector;

  /// `h=`, lower-case header names.
  final Set<String> signedHeaders;

  /// Parses a header value; null if `d=` or `h=` is missing.
  static DkimSignature? parse(String value) {
    final tags = <String, String>{};
    for (final part in value.split(';')) {
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      final name = part.substring(0, eq).trim().toLowerCase();
      tags.putIfAbsent(name, () => part.substring(eq + 1).trim());
    }
    final d = tags['d'], h = tags['h'];
    if (d == null || h == null || d.isEmpty) return null;
    return DkimSignature(
      domain: d.toLowerCase(),
      selector: (tags['s'] ?? '').toLowerCase(),
      signedHeaders: {
        for (final name in h.replaceAll(RegExp(r'\s+'), '').split(':'))
          if (name.isNotEmpty) name.toLowerCase(),
      },
    );
  }
}

/// A `mailto:` unsubscribe address, limited to what is safe to send.
final class MailtoRequest {
  const MailtoRequest(this.address, {this.subject, this.body});

  /// The one recipient. Extra recipients (more addresses, `to=`, `cc=`,
  /// `bcc=`) are ignored: unsubscribing must not mail anyone else.
  final String address;
  final String? subject;
  final String? body;

  static const maxSubject = 200;
  static const maxBody = 2000;

  /// The request in [uri], or null if it has no usable address.
  static MailtoRequest? parse(Uri uri) {
    if (uri.scheme != 'mailto') return null;
    final String path;
    try {
      path = Uri.decodeComponent(uri.path);
    } on ArgumentError {
      return null;
    }
    final first = path.split(',').first.trim();
    if (!RegExp(r'^[^\s@<>(),;:"\\]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
        .hasMatch(first)) {
      return null;
    }
    String? param(String name, int max) {
      String? value;
      try {
        value =
            uri.queryParameters[name] ??
            uri.queryParameters[name[0].toUpperCase() + name.substring(1)];
      } on FormatException {
        return null;
      }
      if (value == null) return null;
      // One line for the subject; no control characters anywhere.
      final cleaned = value
          .replaceAll(
            RegExp(
              name == 'subject'
                  ? r'[\x00-\x1F\x7F]+'
                  : r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]+',
            ),
            ' ',
          )
          .trim();
      if (cleaned.isEmpty) return null;
      return cleaned.length > max ? cleaned.substring(0, max) : cleaned;
    }

    return MailtoRequest(
      first,
      subject: param('subject', maxSubject),
      body: param('body', maxBody),
    );
  }
}
