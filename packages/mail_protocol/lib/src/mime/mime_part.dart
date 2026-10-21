// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import '../charset/charsets.dart';
import '../charset/text_decoder.dart';
import 'content_type.dart';
import 'header.dart';
import 'mime_defect.dart';
import 'mime_message.dart';
import 'transfer_encoding.dart';

/// Text content of a part, decoded from its transfer encoding and charset,
/// with line endings normalised to "\n".
final class TextContent {
  TextContent(
    this.text,
    this.charset,
    this.source, [
    List<MimeDefect> defects = const [],
  ]) : defects = List.unmodifiable(defects);

  final String text;

  /// The WHATWG name of the charset actually used.
  final String charset;
  final CharsetSource source;
  final List<MimeDefect> defects;
}

/// One entity in a MIME tree: a whole message, a multipart container or a
/// leaf such as a text body or an attachment.
final class MimePart {
  MimePart({
    required this.headers,
    required this.contentType,
    required this.transferEncoding,
    required this.section,
    required this._source,
    required this.bodyStart,
    required this.bodyEnd,
    this.disposition,
    List<MimePart> children = const [],
    this.embeddedMessage,
    List<MimeDefect> defects = const [],
  }) : children = List.unmodifiable(children),
       defects = List.unmodifiable(defects);

  final HeaderSection headers;

  /// The declared type, or the RFC 2045 default if missing or invalid.
  final ContentType contentType;
  final ContentDisposition? disposition;

  /// The declared encoding; unknown values are treated as 7bit.
  final TransferEncoding transferEncoding;

  /// IMAP section number (RFC 3501 6.4.5), e.g. `1`, `2.1`. Empty for a
  /// multipart root, which has no number of its own.
  final String section;

  /// Child parts of a multipart, in order.
  final List<MimePart> children;

  /// The parsed message inside a message/rfc822 part.
  final MimeMessage? embeddedMessage;

  /// Problems found while parsing this part's own headers and structure.
  final List<MimeDefect> defects;

  final Uint8List _source;

  /// Offsets of the raw (still transfer-encoded) body in the source.
  final int bodyStart;
  final int bodyEnd;

  bool get isMultipart => contentType.isMultipart && children.isNotEmpty;

  /// The body as transmitted (no copy).
  Uint8List get rawBody => Uint8List.sublistView(_source, bodyStart, bodyEnd);

  /// Size of the raw body in bytes.
  int get rawSize => bodyEnd - bodyStart;

  /// The body with its transfer encoding removed.
  DecodedBytes decodeBody() =>
      transferEncoding.decode(_source, bodyStart, bodyEnd);

  /// The body as text, for text parts. Uses the declared charset, a byte
  /// order mark, or a guess, in that order of strength.
  TextContent decodeText() {
    final decoded = decodeBody();
    final label = contentType.charset;
    final result = const TextDecoder().decode(
      decoded.bytes,
      charsetLabel: label,
    );
    final defects = [
      ...decoded.defects,
      if (label != null && Charsets.forLabel(label) == null)
        const MimeDefect(MimeDefectKind.unknownCharset, 'body'),
    ];
    final text = result.text.replaceAll('\r\n', '\n');
    return TextContent(text, result.charset.name, result.source, defects);
  }

  /// The attachment's file name from Content-Disposition, else from the
  /// Content-Type `name` parameter, with encoded words decoded.
  ///
  /// This is the name as the sender wrote it. It is untrusted: never use
  /// it as a path without sanitising it first.
  String? get filename {
    final raw = disposition?.filename ?? contentType.parameters['name'];
    if (raw == null || raw.trim().isEmpty) return null;
    return MimeFieldParser.decodeFilename(raw.trim());
  }

  /// Content-ID without angle brackets, used by `cid:` links in HTML.
  String? get contentId {
    final value = headers.value('content-id');
    if (value == null) return null;
    final id = value.trim().replaceAll(RegExp(r'^<|>$'), '');
    return id.isEmpty ? null : id;
  }

  /// Whether this part is meant to be saved as a file rather than shown
  /// as the message body.
  bool get isAttachment {
    if (isMultipart || embeddedMessage != null) return false;
    if (disposition?.isAttachment ?? false) return true;
    if (disposition?.isInline ?? false) return false;
    return filename != null;
  }

  /// This part and every part below it, depth first, not entering
  /// embedded messages.
  Iterable<MimePart> get allParts sync* {
    yield this;
    for (final child in children) {
      yield* child.allParts;
    }
  }

  @override
  String toString() =>
      'MimePart(${section.isEmpty ? 'root' : section} $contentType)';
}
