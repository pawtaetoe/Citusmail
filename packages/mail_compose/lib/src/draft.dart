// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';

/// A file attached to a message being written.
final class DraftAttachment {
  const DraftAttachment({
    required this.fileName,
    required this.mimeType,
    required this.bytes,
  });

  final String fileName;
  final String mimeType;
  final Uint8List bytes;
}

/// A message being written. Immutable: edits make a new one.
final class Draft {
  const Draft({
    required this.accountId,
    this.id,
    this.to = const [],
    this.cc = const [],
    this.bcc = const [],
    this.subject = '',
    this.body = '',
    this.attachments = const [],
    this.inReplyTo,
    this.references = const [],
    this.answeredMessageId,
    this.savedMessageId,
  });

  /// Local id once saved on the device.
  final int? id;
  final int accountId;
  final List<MailAddress> to;
  final List<MailAddress> cc;
  final List<MailAddress> bcc;
  final String subject;

  /// Plain text.
  final String body;
  final List<DraftAttachment> attachments;

  /// Threading, for replies.
  final String? inReplyTo;
  final List<String> references;

  /// The stored message this replies to, marked answered once sent.
  final int? answeredMessageId;

  /// Message-ID of this draft's copy in the server's Drafts folder, removed
  /// when a newer copy is saved or the message is sent.
  final String? savedMessageId;

  List<MailAddress> get recipients => [...to, ...cc, ...bcc];

  /// Nothing worth keeping has been written.
  bool get isEmpty =>
      recipients.isEmpty &&
      subject.trim().isEmpty &&
      body.trim().isEmpty &&
      attachments.isEmpty;

  int get attachmentBytes =>
      attachments.fold(0, (sum, a) => sum + a.bytes.length);

  Draft copyWith({
    int? id,
    int? accountId,
    List<MailAddress>? to,
    List<MailAddress>? cc,
    List<MailAddress>? bcc,
    String? subject,
    String? body,
    List<DraftAttachment>? attachments,
    String? savedMessageId,
    bool clearId = false,
    bool clearSaved = false,
  }) => Draft(
    id: clearId ? null : id ?? this.id,
    accountId: accountId ?? this.accountId,
    to: to ?? this.to,
    cc: cc ?? this.cc,
    bcc: bcc ?? this.bcc,
    subject: subject ?? this.subject,
    body: body ?? this.body,
    attachments: attachments ?? this.attachments,
    inReplyTo: inReplyTo,
    references: references,
    answeredMessageId: answeredMessageId,
    savedMessageId: clearSaved ? null : savedMessageId ?? this.savedMessageId,
  );

  /// The fields stored as the draft's content (attachments are stored
  /// separately).
  String encodeContent() => jsonEncode({
    'v': 1,
    'to': _addresses(to),
    'cc': _addresses(cc),
    'bcc': _addresses(bcc),
    'subject': subject,
    'body': body,
    'inReplyTo': inReplyTo,
    'references': references,
    'answeredMessageId': answeredMessageId,
  });

  /// Reads stored content; unreadable content gives an empty draft rather
  /// than an error, so a damaged draft never blocks the app.
  static Draft decodeContent(
    String content, {
    required int id,
    required int accountId,
    required List<DraftAttachment> attachments,
    String? savedMessageId,
  }) {
    Map<String, Object?> json;
    try {
      final decoded = jsonDecode(content);
      json = decoded is Map<String, Object?> ? decoded : const {};
    } on FormatException {
      json = const {};
    }
    String text(String key) => json[key] is String ? json[key]! as String : '';
    return Draft(
      id: id,
      accountId: accountId,
      to: _parseAddresses(json['to']),
      cc: _parseAddresses(json['cc']),
      bcc: _parseAddresses(json['bcc']),
      subject: text('subject'),
      body: text('body'),
      inReplyTo: json['inReplyTo'] is String
          ? json['inReplyTo']! as String
          : null,
      references: [
        for (final r
            in json['references'] is List
                ? json['references']! as List
                : const [])
          if (r is String) r,
      ],
      answeredMessageId: json['answeredMessageId'] is int
          ? json['answeredMessageId']! as int
          : null,
      attachments: attachments,
      savedMessageId: savedMessageId,
    );
  }

  static List<Map<String, String?>> _addresses(List<MailAddress> list) => [
    for (final a in list)
      {'name': a.displayName, 'local': a.localPart, 'domain': a.domain},
  ];

  static List<MailAddress> _parseAddresses(Object? value) => [
    if (value is List)
      for (final item in value)
        if (item case {
          'local': final String local,
          'domain': final String domain,
        })
          MailAddress(
            displayName: item['name'] is String
                ? item['name']! as String
                : null,
            localPart: local,
            domain: domain,
          ),
  ];
}
