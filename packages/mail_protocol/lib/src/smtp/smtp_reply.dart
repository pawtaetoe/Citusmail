// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import '../mime/address.dart';
import '../net/line_source.dart';
import '../net/mail_exception.dart';

/// A server reply (RFC 5321 4.2): a 3-digit code and one or more lines.
final class SmtpReply {
  SmtpReply(this.code, List<String> lines, {this.enhancedCode})
    : lines = List.unmodifiable(lines);

  final int code;

  /// e.g. `5.7.1` (RFC 3463), when the server sends one.
  final String? enhancedCode;
  final List<String> lines;

  bool get isPositive => code >= 200 && code < 400;
  bool get isPermanentFailure => code >= 500;

  /// The text, shortened, for error messages.
  String get text {
    final joined = lines.join(' ');
    return joined.length > 300 ? joined.substring(0, 300) : joined;
  }

  @override
  String toString() =>
      '$code${enhancedCode == null ? '' : ' $enhancedCode'} $text';

  /// Reads one reply, joining "250-..." continuation lines.
  static Future<SmtpReply> read(
    LineSource source, {
    required Duration timeout,
    int maxLines = 500,
  }) async {
    final lines = <String>[];
    int? code;
    while (true) {
      final raw = utf8.decode(
        await source.readLine(timeout: timeout),
        allowMalformed: true,
      );
      final match = RegExp(r'^(\d{3})([ -]|$)(.*)$').firstMatch(raw);
      if (match == null) {
        throw const MailProtocolException('malformed SMTP reply');
      }
      final lineCode = int.parse(match.group(1)!);
      if (code != null && lineCode != code) {
        throw const MailProtocolException(
          'SMTP reply lines with different codes',
        );
      }
      code = lineCode;
      lines.add(match.group(3)!);
      if (lines.length > maxLines) {
        throw const MailProtocolException('SMTP reply too long');
      }
      if (match.group(2) != '-') break;
    }
    final enhanced = RegExp(r'^([245]\.\d{1,3}\.\d{1,3})\s')
        .firstMatch('${lines.first} ');
    return SmtpReply(code, lines, enhancedCode: enhanced?.group(1));
  }
}

/// The server rejected a command.
final class SmtpReplyException extends MailException {
  SmtpReplyException(this.command, this.reply)
    : super('$command failed: $reply');

  /// Command name only (never its arguments).
  final String command;
  final SmtpReply reply;
}

/// Login was refused. The password is not part of this error.
final class SmtpAuthenticationException extends MailException {
  SmtpAuthenticationException(this.reply)
    : super('login refused by the server: $reply');

  final SmtpReply? reply;
}

/// One or more recipients were refused, so nothing was sent.
final class SmtpRecipientsRejectedException extends MailException {
  SmtpRecipientsRejectedException(Map<MailAddress, SmtpReply> rejected)
    : rejected = Map.unmodifiable(rejected),
      super(
        '${rejected.length} recipient(s) refused; nothing was sent: '
        '${rejected.entries.map((e) => '${e.key.address} (${e.value.code})').join(', ')}',
      );

  final Map<MailAddress, SmtpReply> rejected;
}

/// The message is larger than the server accepts (SIZE, RFC 1870).
final class SmtpMessageTooLargeException extends MailException {
  SmtpMessageTooLargeException(this.size, this.limit)
    : super('the message is $size bytes; the server accepts at most $limit');

  final int size;
  final int limit;
}
