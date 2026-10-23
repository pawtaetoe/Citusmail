// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import '../address.dart';

/// A file to attach. Inline parts (with [contentId]) are referenced from
/// the HTML body as `cid:<contentId>`.
final class OutgoingAttachment {
  OutgoingAttachment({
    required this.filename,
    required this.mimeType,
    required this.bytes,
    this.contentId,
  });

  /// Shown to the recipient. Path separators and control characters are
  /// removed when the message is built.
  final String filename;

  /// e.g. `application/pdf`. Must be a valid `type/subtype`.
  final String mimeType;
  final Uint8List bytes;
  final String? contentId;

  bool get isInline => contentId != null;
}

/// Everything needed to build a message to send.
final class OutgoingMessage {
  OutgoingMessage({
    required this.from,
    this.to = const [],
    this.cc = const [],
    this.bcc = const [],
    this.replyTo,
    this.subject = '',
    this.textBody,
    this.htmlBody,
    this.attachments = const [],
    this.inReplyTo,
    this.references = const [],
    this.messageId,
    this.date,
    this.receiptTo,
  });

  final MailAddress from;
  final List<MailAddress> to;
  final List<MailAddress> cc;

  /// Receive the message but are never listed in its headers.
  final List<MailAddress> bcc;
  final MailAddress? replyTo;
  final String subject;
  final String? textBody;
  final String? htmlBody;
  final List<OutgoingAttachment> attachments;

  /// Message-ID being replied to, without brackets.
  final String? inReplyTo;

  /// Thread ancestry, oldest first, without brackets.
  final List<String> references;

  /// Without brackets. Generated when null.
  final String? messageId;

  /// When null, the time of building is used.
  final DateTime? date;

  /// Asks the recipients' mail apps for a read receipt to this address
  /// (`Disposition-Notification-To`, RFC 8098). Their app decides; nothing
  /// else is added to find out whether the message was read.
  final MailAddress? receiptTo;

  /// Everyone the SMTP envelope must deliver to: To, Cc and Bcc.
  List<MailAddress> get envelopeRecipients => [...to, ...cc, ...bcc];
}

/// A built message ready for SMTP and for saving to the Sent folder.
final class BuiltMessage {
  BuiltMessage({
    required this.bytes,
    required this.messageId,
    required List<MailAddress> recipients,
  }) : recipients = List.unmodifiable(recipients);

  /// The complete message with CRLF line endings.
  final Uint8List bytes;

  /// Without brackets.
  final String messageId;

  /// SMTP envelope recipients (To, Cc and Bcc).
  final List<MailAddress> recipients;
}

/// The message cannot be built as given (for example, an invalid address).
final class MessageBuildException implements Exception {
  const MessageBuildException(this.message);

  final String message;

  @override
  String toString() => 'MessageBuildException: $message';
}
