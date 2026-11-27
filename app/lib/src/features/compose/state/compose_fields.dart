// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_compose/mail_compose.dart';
import 'package:mail_protocol/mail_protocol.dart';

import '../../../core/state/validation.dart';

/// The checks for what goes into a new message: typed, pasted, picked or
/// handed over by a link.
abstract final class ComposeFields {
  /// At most this many addresses in one field (Gmail's limit per message).
  static const maxRecipients = 500;

  /// More pasted text than this is not read as addresses.
  static const maxPastedLength = 64 * 1024;

  /// A subject as it is stored: control characters (a pasted line break)
  /// become spaces, so it stays one header line. Not trimmed, so typing
  /// is not disturbed.
  static String subject(String text) => ControlCharacters.toSpaces(text);

  /// The longest file name kept; longer ones are shortened.
  static const maxFileName = 200;

  /// [name] of a picked file as it is sent: no folders, no control
  /// characters, never empty, at most [maxFileName] characters (the
  /// extension kept).
  static String fileName(String name) {
    final base = name.split(RegExp(r'[/\\]')).last;
    var clean = ControlCharacters.toSpaces(base).trim();
    if (clean.isEmpty || clean == '.' || clean == '..') clean = 'attachment';
    if (clean.runes.length <= maxFileName) return clean;
    final dot = clean.lastIndexOf('.');
    final extension = dot > 0 && clean.length - dot <= 10
        ? clean.substring(dot)
        : '';
    final runes = clean.runes.toList();
    return String.fromCharCodes(runes.take(maxFileName - extension.length)) +
        extension;
  }

  /// Whether a picked file of [size] bytes fits beside [alreadyAttached]
  /// bytes; the file's [name] (cleaned) or why not. Checked before the
  /// file is read, so a huge file is never loaded.
  static Validated<String> attachment(
    String name,
    int size, {
    int alreadyAttached = 0,
    int limit = OutgoingMessages.defaultMaxAttachmentBytes,
  }) {
    final clean = fileName(name);
    if (size < 0 || alreadyAttached + size > limit) {
      return Invalid(
        '$clean is too large to send (attachments can be at most '
        '${(limit / (1024 * 1024)).toStringAsFixed(1)} MB in all).',
      );
    }
    return Valid(clean);
  }
}

/// A `mailto:` link, read once where it arrives (a tapped link in a
/// message): its addresses and subject.
final class MailtoLink {
  const MailtoLink({required this.to, this.subject = ''});

  /// The addresses mail can be sent to; others are left out.
  final List<MailAddress> to;

  /// One line.
  final String subject;

  /// A longer link is not opened.
  static const maxLength = 8 * 1024;

  /// At most this many addresses.
  static const maxAddresses = 100;

  static const _damaged = Invalid('That email link is damaged.');

  /// The link's addresses and subject, or why it can't be used. The other
  /// fields of RFC 6068 (cc, body, …) are not used.
  static Validated<MailtoLink> parse(Uri link) {
    if (link.scheme.toLowerCase() != 'mailto') {
      return const Invalid('That isn\'t an email link.');
    }
    if (link.toString().length > maxLength) {
      return const Invalid('That email link is too long.');
    }
    final String path;
    final Map<String, String> query;
    try {
      path = Uri.decodeComponent(link.path);
      query = link.queryParameters;
    } on FormatException {
      return _damaged;
    } on ArgumentError {
      return _damaged;
    }
    final to = [
      for (final address in const AddressParser().parse(path).mailboxes)
        if (EmailAddress.sendProblem(address) == null) address,
    ];
    if (to.length > maxAddresses) {
      return const Invalid('That email link has too many addresses.');
    }
    final subject = ControlCharacters.toSpaces(query['subject'] ?? '').trim();
    return Valid(MailtoLink(to: to, subject: subject));
  }
}
