// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';

import 'document.dart';
import 'html_converter.dart';
import 'plain_text_converter.dart';
import 'safe_file_name.dart';

/// A downloaded message, ready to show: its body as a safe document and
/// its attachments with safe names.
final class MessageView {
  MessageView._(this.message, this.body, this.isHtml, this.attachments);

  /// Parses [raw] (the full message). Never throws on malformed mail.
  factory MessageView.parse(
    Uint8List raw, {
    HtmlConverter html = const HtmlConverter(),
    PlainTextConverter text = const PlainTextConverter(),
  }) {
    final message = const MimeParser().parse(raw);
    final images = _ContentIdImages(message);
    final htmlPart = message.htmlBody;
    final textPart = message.textBody;

    final RichDocument body;
    if (htmlPart != null) {
      body = html.convert(
        htmlPart.decodeText().text,
        resolveContentId: images.resolve,
      );
    } else if (textPart != null) {
      final type = textPart.contentType;
      body = text.convert(
        textPart.decodeText().text,
        flowed: type.parameters['format']?.toLowerCase() == 'flowed',
        delSp: type.parameters['delsp']?.toLowerCase() == 'yes',
      );
    } else {
      body = RichDocument.empty;
    }

    final attachments = [
      for (final part in message.root.allParts)
        if (part.children.isEmpty &&
            part.isAttachment &&
            !images.used.contains(part))
          AttachmentView._(part)
        else if (part.embeddedMessage != null)
          AttachmentView._(part, forwarded: part.embeddedMessage),
    ];
    return MessageView._(
      message,
      body,
      htmlPart != null,
      List.unmodifiable(attachments),
    );
  }

  final MimeMessage message;
  final RichDocument body;

  /// Whether [body] came from the HTML version.
  final bool isHtml;
  final List<AttachmentView> attachments;

  /// Text for the search index: the body text, capped.
  String get searchableText {
    final text = body.plainText;
    return text.length > maxSearchableLength
        ? text.substring(0, maxSearchableLength)
        : text;
  }

  static const maxSearchableLength = 200000;
}

/// One attachment. The name is the sender's and untrusted: use [fileName]
/// for saving and [displayName] for showing.
final class AttachmentView {
  AttachmentView._(this._part, {MimeMessage? forwarded})
    : fileName = SafeFileName.from(
        forwarded == null
            ? _part.filename
            : '${forwarded.subject?.trim().isNotEmpty == true ? forwarded.subject : 'message'}.eml',
      ),
      mimeType = forwarded == null
          ? _part.contentType.mimeType
          : 'message/rfc822';

  final MimePart _part;

  /// A name safe to save under (no paths, no hidden direction changes).
  final String fileName;
  final String mimeType;

  /// Shown to the user; the same sanitised name.
  String get displayName => fileName;

  /// Approximate decoded size, without decoding.
  int get approximateSize => switch (_part.transferEncoding) {
    TransferEncoding.base64 => _part.rawSize * 3 ~/ 4,
    _ => _part.rawSize,
  };

  /// The decoded content (for a forwarded message, the message itself).
  Uint8List bytes() => _part.decodeBody().bytes;
}

/// Image parts by Content-ID, remembering which the HTML used so they are
/// not listed again as attachments.
final class _ContentIdImages {
  _ContentIdImages(MimeMessage message) {
    for (final part in message.root.allParts) {
      final id = part.contentId;
      if (id != null &&
          part.children.isEmpty &&
          part.contentType.mimeType.startsWith('image/')) {
        _byId.putIfAbsent(id, () => part);
      }
    }
  }

  final _byId = <String, MimePart>{};
  final used = <MimePart>{};

  ContentIdImage? resolve(String contentId) {
    final part = _byId[contentId];
    if (part == null) return null;
    used.add(part);
    return (
      bytes: part.decodeBody().bytes,
      mimeType: part.contentType.mimeType,
    );
  }
}
