// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

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
    this.signOff,
    this.quote = '',
    this.attachments = const [],
    this.inReplyTo,
    this.references = const [],
    this.answeredMessageId,
    this.savedMessageId,
    this.requestReceipt = false,
    this.calendar,
  });

  /// Local id once saved on the device.
  final int? id;
  final int accountId;
  final List<MailAddress> to;
  final List<MailAddress> cc;
  final List<MailAddress> bcc;
  final String subject;

  /// Plain text: what the user writes (above the sign-off).
  final String body;

  /// Ends the message, below [body] and above [quote]; null for none.
  final SignOff? signOff;

  /// What a reply quotes or a forward carries, below the sign-off.
  final String quote;
  final List<DraftAttachment> attachments;

  /// Threading, for replies.
  final String? inReplyTo;
  final List<String> references;

  /// The stored message this replies to, marked answered once sent.
  final int? answeredMessageId;

  /// Message-ID of this draft's copy in the server's Drafts folder, removed
  /// when a newer copy is saved or the message is sent.
  final String? savedMessageId;

  /// Ask the recipients' mail apps for a read receipt (their choice).
  final bool requestReceipt;

  /// An answer to a meeting invitation, sent along as text/calendar. Not
  /// stored with the draft: such answers are sent at once, never kept
  /// as drafts.
  final OutgoingCalendar? calendar;

  List<MailAddress> get recipients => [...to, ...cc, ...bcc];

  /// The whole text as it is sent: [body], then the sign-off, then the
  /// [quote], a blank line apart.
  String get text {
    final block = signOff?.block ?? '';
    if (block.isEmpty && quote.isEmpty) return body;
    final out = StringBuffer(body.trimRight());
    for (final part in [block, quote]) {
      if (part.isEmpty) continue;
      if (out.isNotEmpty) out.write('\n\n');
      out.write(part);
    }
    return out.toString();
  }

  /// Nothing worth keeping has been written (a sign-off alone isn't).
  bool get isEmpty =>
      recipients.isEmpty &&
      subject.trim().isEmpty &&
      body.trim().isEmpty &&
      quote.trim().isEmpty &&
      attachments.isEmpty;

  /// Splits [text] (a whole message, as [text] makes it) at the first of
  /// [known] sign-offs that stands on lines of its own: what is above is
  /// the body, below the quote. Without one, it is all body.
  static ({String body, SignOff? signOff, String quote}) split(
    String text,
    Iterable<SignOff> known,
  ) {
    ({int at, SignOff signOff})? found;
    for (final s in known) {
      final block = s.block;
      if (block.trim().isEmpty) continue;
      var from = 0;
      while (true) {
        final at = text.indexOf(block, from);
        if (at < 0) break;
        final end = at + block.length;
        final ownLines =
            (at == 0 || text[at - 1] == '\n') &&
            (end == text.length || text[end] == '\n' || text[end] == '\r');
        if (ownLines) {
          if (found == null ||
              at < found.at ||
              (at == found.at && block.length > found.signOff.block.length)) {
            found = (at: at, signOff: s);
          }
          break;
        }
        from = at + 1;
      }
    }
    if (found == null) return (body: text, signOff: null, quote: '');
    return (
      body: text.substring(0, found.at).trimRight(),
      signOff: found.signOff,
      quote: text
          .substring(found.at + found.signOff.block.length)
          .replaceFirst(RegExp(r'^\s*\n'), '')
          .trimRight(),
    );
  }

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
    SignOff? signOff,
    bool clearSignOff = false,
    String? quote,
    List<DraftAttachment>? attachments,
    String? savedMessageId,
    bool? requestReceipt,
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
    signOff: clearSignOff ? null : signOff ?? this.signOff,
    quote: quote ?? this.quote,
    attachments: attachments ?? this.attachments,
    inReplyTo: inReplyTo,
    references: references,
    answeredMessageId: answeredMessageId,
    savedMessageId: clearSaved ? null : savedMessageId ?? this.savedMessageId,
    requestReceipt: requestReceipt ?? this.requestReceipt,
    calendar: calendar,
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
    if (signOff case final s?) 'signOff': s.toJson(),
    if (quote.isNotEmpty) 'quote': quote,
    'inReplyTo': inReplyTo,
    'references': references,
    'answeredMessageId': answeredMessageId,
    if (requestReceipt) 'receipt': true,
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
      signOff: SignOff.fromJson(json['signOff']),
      quote: text('quote'),
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
      requestReceipt: json['receipt'] == true,
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
