// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'address.dart';
import 'encoded_word.dart';
import 'header.dart';
import 'mail_date.dart';
import 'message_id.dart';
import 'mime_defect.dart';
import 'mime_part.dart';

/// A parsed message: the MIME tree plus convenient, decoded header values.
///
/// Header values are parsed on first access and cached. Parsing never
/// throws; invalid values come back as null or empty lists, with details in
/// [fieldDefects].
final class MimeMessage {
  MimeMessage(this.root, List<MimeDefect> structureDefects)
    : structureDefects = List.unmodifiable(structureDefects);

  final MimePart root;

  /// Defects found while splitting the message into parts.
  final List<MimeDefect> structureDefects;

  final List<MimeDefect> _fieldDefects = [];

  HeaderSection get headers => root.headers;

  /// Defects found while decoding header values that have been accessed.
  List<MimeDefect> get fieldDefects => List.unmodifiable(_fieldDefects);

  static const _addressParser = AddressParser();
  static const _encodedWords = EncodedWordDecoder();
  static const _messageIds = MessageIds();
  static const _dates = MailDateParser();

  /// Decoded Subject, or null if there is none.
  late final String? subject = _decoded('subject');

  late final List<MailAddress> from = _addresses('from');
  late final List<MailAddress> sender = _addresses('sender');
  late final List<MailAddress> replyTo = _addresses('reply-to');
  late final List<MailAddress> to = _addresses('to');
  late final List<MailAddress> cc = _addresses('cc');
  late final List<MailAddress> bcc = _addresses('bcc');

  /// The Date header, or null if missing or unreadable.
  late final MailDate? date = () {
    final value = headers.value('date');
    if (value == null) return null;
    final parsed = _dates.parse(value);
    if (parsed == null) {
      _fieldDefects.add(const MimeDefect(MimeDefectKind.invalidDate));
    }
    return parsed;
  }();

  /// Message-ID without brackets.
  late final String? messageId = () {
    final value = headers.value('message-id');
    return value == null ? null : _messageIds.parseSingle(value);
  }();

  late final List<String> inReplyTo = _ids('in-reply-to');
  late final List<String> references = _ids('references');

  /// The first text/plain body that is not an attachment.
  late final MimePart? textBody = _firstBody('text/plain');

  /// The first text/html body that is not an attachment.
  late final MimePart? htmlBody = _firstBody('text/html');

  /// Leaf parts meant to be saved as files.
  late final List<MimePart> attachments = root.allParts
      .where((p) => p.children.isEmpty && p.isAttachment)
      .toList(growable: false);

  /// Every defect: structure plus header fields accessed so far.
  List<MimeDefect> get allDefects => [...structureDefects, ..._fieldDefects];

  String? _decoded(String name) {
    final value = headers.value(name);
    if (value == null) return null;
    final result = _encodedWords.decode(value);
    _fieldDefects.addAll(result.defects);
    return result.text;
  }

  List<MailAddress> _addresses(String name) {
    final result = <MailAddress>[];
    for (final field in headers.all(name)) {
      final parsed = _addressParser.parse(field.value);
      _fieldDefects.addAll(parsed.defects);
      result.addAll(parsed.mailboxes);
    }
    return List.unmodifiable(result);
  }

  List<String> _ids(String name) {
    final value = headers.value(name);
    return value == null
        ? const []
        : List.unmodifiable(_messageIds.parseList(value));
  }

  MimePart? _firstBody(String mimeType) {
    for (final part in root.allParts) {
      if (part.children.isEmpty &&
          part.contentType.mimeType == mimeType &&
          !part.isAttachment) {
        return part;
      }
    }
    return null;
  }
}
