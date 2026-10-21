// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import 'byte_lines.dart';
import 'content_type.dart';
import 'header.dart';
import 'mime_defect.dart';
import 'mime_message.dart';
import 'mime_part.dart';
import 'transfer_encoding.dart';

/// Limits that keep hostile messages from exhausting memory or time.
final class MimeParserLimits {
  const MimeParserLimits({
    this.maxDepth = 20,
    this.maxParts = 1000,
    this.headers = const HeaderLimits(),
  });

  /// Deepest nesting of multiparts and embedded messages.
  final int maxDepth;

  /// Most parts in one message, counting embedded messages.
  final int maxParts;
  final HeaderLimits headers;
}

/// Parses raw message bytes (RFC 5322 + MIME, RFC 2045-2049) into a
/// [MimeMessage]. Never throws on malformed input: it recovers and records
/// [MimeDefect]s instead.
final class MimeParser {
  const MimeParser({this.limits = const MimeParserLimits()});

  final MimeParserLimits limits;

  MimeMessage parse(Uint8List bytes) {
    final context = _ParseContext(limits);
    return _parseMessage(
      bytes,
      0,
      bytes.length,
      sectionPrefix: '',
      depth: 0,
      context: context,
    );
  }

  MimeMessage _parseMessage(
    Uint8List bytes,
    int start,
    int end, {
    required String sectionPrefix,
    required int depth,
    required _ParseContext context,
  }) {
    final defects = <MimeDefect>[];
    final root = _parseEntity(
      bytes,
      start,
      end,
      defaultType: ContentType.textPlain,
      // A non-multipart message body is part "1" (or "N.1" when embedded).
      sectionFor: (isMultipart) => isMultipart
          ? sectionPrefix
          : (sectionPrefix.isEmpty ? '1' : '$sectionPrefix.1'),
      childPrefix: sectionPrefix,
      depth: depth,
      context: context,
      sink: defects,
    );
    return MimeMessage(root, defects);
  }

  MimePart _parseEntity(
    Uint8List bytes,
    int start,
    int end, {
    required ContentType defaultType,
    required String Function(bool isMultipart) sectionFor,
    required String childPrefix,
    required int depth,
    required _ParseContext context,
    required List<MimeDefect> sink,
  }) {
    final partDefects = <MimeDefect>[];
    final headerResult = HeaderParser(limits: limits.headers)
        .parse(bytes, start, end);
    partDefects.addAll(headerResult.defects);
    final headers = headerResult.headers;
    final bodyStart = headerResult.bodyStart;

    const fieldParser = MimeFieldParser();
    var contentType = defaultType;
    final contentTypeValue = headers.value('content-type');
    if (contentTypeValue != null) {
      final parsed = fieldParser.parseContentType(contentTypeValue);
      partDefects.addAll(parsed.defects);
      // RFC 2045 5.2: an invalid Content-Type means text/plain.
      contentType = parsed.value ?? ContentType.textPlain;
    }

    ContentDisposition? disposition;
    final dispositionValue = headers.value('content-disposition');
    if (dispositionValue != null) {
      final parsed = fieldParser.parseContentDisposition(dispositionValue);
      partDefects.addAll(parsed.defects);
      disposition = parsed.value;
    }

    var transferEncoding = TransferEncoding.sevenBit;
    final encodingValue = headers.value('content-transfer-encoding');
    if (encodingValue != null) {
      final parsed = TransferEncoding.parse(encodingValue);
      if (parsed == null) {
        partDefects.add(
          const MimeDefect(MimeDefectKind.unknownTransferEncoding),
        );
      } else {
        transferEncoding = parsed;
      }
    }

    var children = const <MimePart>[];
    MimeMessage? embedded;

    if (contentType.isMultipart) {
      final boundary = contentType.boundary;
      if (depth >= limits.maxDepth) {
        partDefects.add(const MimeDefect(MimeDefectKind.nestingTooDeep));
      } else if (boundary == null ||
          boundary.isEmpty ||
          boundary.length > 200) {
        partDefects.add(const MimeDefect(MimeDefectKind.missingBoundary));
        contentType = ContentType.textPlain; // show the body as text
      } else {
        children = _parseMultipart(
          bytes,
          bodyStart,
          end,
          boundary: boundary,
          childDefault: contentType.subtype == 'digest'
              ? ContentType.messageRfc822
              : ContentType.textPlain,
          childPrefix: childPrefix,
          depth: depth,
          context: context,
          partDefects: partDefects,
          sink: sink,
        );
        if (children.isEmpty) contentType = ContentType.textPlain;
      }
    } else if (contentType.isEmbeddedMessage) {
      if (depth >= limits.maxDepth) {
        partDefects.add(const MimeDefect(MimeDefectKind.nestingTooDeep));
      } else {
        embedded = _parseEmbedded(
          bytes,
          bodyStart,
          end,
          transferEncoding,
          sectionPrefix: sectionFor(false),
          depth: depth,
          context: context,
          sink: sink,
        );
      }
    }

    sink.addAll(partDefects);
    return MimePart(
      headers: headers,
      contentType: contentType,
      disposition: disposition,
      transferEncoding: transferEncoding,
      section: sectionFor(children.isNotEmpty),
      source: bytes,
      bodyStart: bodyStart,
      bodyEnd: end,
      children: children,
      embeddedMessage: embedded,
      defects: partDefects,
    );
  }

  /// Splits a multipart body at its boundary lines (RFC 2046 5.1.1).
  ///
  /// A delimiter line is "--boundary" (or "--boundary--" to close) plus
  /// optional trailing whitespace. The line break before a delimiter
  /// belongs to the delimiter, not to the part before it.
  List<MimePart> _parseMultipart(
    Uint8List bytes,
    int start,
    int end, {
    required String boundary,
    required ContentType childDefault,
    required String childPrefix,
    required int depth,
    required _ParseContext context,
    required List<MimeDefect> partDefects,
    required List<MimeDefect> sink,
  }) {
    final delimiter = utf8.encode('--$boundary');
    final ranges = <(int, int)>[];
    int? partStart;
    var closed = false;

    for (final line in byteLines(bytes, start, end)) {
      final kind = _delimiterKind(bytes, line, delimiter);
      if (kind != _Delimiter.none) {
        // The part ends before the line break that precedes the delimiter.
        if (partStart != null) {
          ranges.add((
            partStart,
            _stripLineBreak(bytes, partStart, line.start),
          ));
        }
        if (kind == _Delimiter.close) {
          closed = true;
          break;
        }
        partStart = line.end;
      }
    }
    if (!closed && partStart != null) {
      ranges.add((partStart, end));
      partDefects.add(const MimeDefect(MimeDefectKind.missingClosingBoundary));
    }
    if (ranges.isEmpty) {
      partDefects.add(const MimeDefect(MimeDefectKind.noPartsInMultipart));
      return const [];
    }

    final children = <MimePart>[];
    for (var i = 0; i < ranges.length; i++) {
      if (!context.takePart()) {
        partDefects.add(const MimeDefect(MimeDefectKind.tooManyParts));
        break;
      }
      final (partFrom, partTo) = ranges[i];
      final section = childPrefix.isEmpty
          ? '${i + 1}'
          : '$childPrefix.${i + 1}';
      children.add(
        _parseEntity(
          bytes,
          partFrom,
          partTo,
          defaultType: childDefault,
          sectionFor: (_) => section,
          childPrefix: section,
          depth: depth + 1,
          context: context,
          sink: sink,
        ),
      );
    }
    return children;
  }

  MimeMessage? _parseEmbedded(
    Uint8List bytes,
    int start,
    int end,
    TransferEncoding encoding, {
    required String sectionPrefix,
    required int depth,
    required _ParseContext context,
    required List<MimeDefect> sink,
  }) {
    if (!context.takePart()) {
      sink.add(const MimeDefect(MimeDefectKind.tooManyParts));
      return null;
    }
    // RFC 2046 forbids encoding message/rfc822, but some mailers do it.
    final needsDecoding =
        encoding == TransferEncoding.base64 ||
        encoding == TransferEncoding.quotedPrintable;
    final source = needsDecoding
        ? encoding.decode(bytes, start, end).bytes
        : bytes;
    final from = needsDecoding ? 0 : start;
    final to = needsDecoding ? source.length : end;
    final message = _parseMessage(
      source,
      from,
      to,
      sectionPrefix: sectionPrefix,
      depth: depth + 1,
      context: context,
    );
    sink.addAll(message.structureDefects);
    return message;
  }

  static _Delimiter _delimiterKind(
    Uint8List bytes,
    ByteLine line,
    List<int> delimiter,
  ) {
    if (line.contentLength < delimiter.length) return _Delimiter.none;
    for (var i = 0; i < delimiter.length; i++) {
      if (bytes[line.start + i] != delimiter[i]) return _Delimiter.none;
    }
    var i = line.start + delimiter.length;
    var kind = _Delimiter.open;
    if (i + 2 <= line.contentEnd && bytes[i] == 0x2D && bytes[i + 1] == 0x2D) {
      kind = _Delimiter.close;
      i += 2;
    }
    // Only whitespace may follow; otherwise this is a longer boundary that
    // merely starts with ours (e.g. an inner boundary).
    for (; i < line.contentEnd; i++) {
      if (bytes[i] != 0x20 && bytes[i] != 0x09) return _Delimiter.none;
    }
    return kind;
  }

  /// [end] without the CRLF or LF directly before it (if inside the part).
  static int _stripLineBreak(Uint8List bytes, int partStart, int end) {
    var e = end;
    if (e > partStart && bytes[e - 1] == 0x0A) e--;
    if (e > partStart && bytes[e - 1] == 0x0D) e--;
    return e;
  }
}

enum _Delimiter { none, open, close }

/// State shared across one parse: the part budget.
final class _ParseContext {
  _ParseContext(this.limits);

  final MimeParserLimits limits;
  var _parts = 1; // the root

  /// Reserves one part; false once the budget is spent.
  bool takePart() {
    if (_parts >= limits.maxParts) return false;
    _parts++;
    return true;
  }
}
