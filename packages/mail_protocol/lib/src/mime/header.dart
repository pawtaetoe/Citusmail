// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import '../charset/charsets.dart';
import '../charset/simple_charsets.dart';
import 'byte_lines.dart';
import 'mime_defect.dart';

/// One header field, e.g. `Subject: Hello`.
final class HeaderField {
  HeaderField(this.name, this.rawValue);

  /// The field name as written (case preserved).
  final String name;

  /// The raw value bytes after the colon, still folded. Kept so signatures
  /// (DKIM) can later be checked against the exact bytes.
  final Uint8List rawValue;

  /// The value unfolded and trimmed, as text. Raw 8-bit bytes (RFC 6532)
  /// are read as UTF-8 if valid, otherwise as Windows-1252. RFC 2047
  /// encoded words are NOT decoded here; that depends on the field type.
  late final String value = _decodeRaw(_unfold(rawValue)).trim();

  bool hasName(String other) => name.toLowerCase() == other.toLowerCase();

  static Uint8List _unfold(Uint8List raw) {
    // Remove CRLF / LF that is followed by a space or tab (RFC 5322 2.2.3).
    final out = BytesBuilder(copy: false);
    var i = 0;
    while (i < raw.length) {
      final c = raw[i];
      if (c == 0x0D && i + 1 < raw.length && raw[i + 1] == 0x0A) {
        i += 2;
        continue;
      }
      if (c == 0x0A) {
        i++;
        continue;
      }
      out.addByte(c);
      i++;
    }
    return out.takeBytes();
  }

  static String _decodeRaw(Uint8List bytes) {
    if (bytes.every((b) => b < 0x80)) return latin1.decode(bytes);
    return Utf8Charset.isValid(bytes)
        ? Charsets.utf8.decode(bytes)
        : Charsets.windows1252.decode(bytes);
  }

  @override
  String toString() => 'HeaderField($name)';
}

/// The header fields of a message or MIME part, in order. Names are matched
/// case-insensitively and repeated fields are kept.
final class HeaderSection {
  HeaderSection(List<HeaderField> fields) : fields = List.unmodifiable(fields);

  static final HeaderSection empty = HeaderSection(const []);

  final List<HeaderField> fields;

  /// The first field with [name], or null.
  HeaderField? operator [](String name) {
    for (final field in fields) {
      if (field.hasName(name)) return field;
    }
    return null;
  }

  /// Every field with [name], in order.
  Iterable<HeaderField> all(String name) =>
      fields.where((f) => f.hasName(name));

  /// The unfolded value of the first field with [name], or null.
  String? value(String name) => this[name]?.value;

  bool contains(String name) => this[name] != null;
}

/// Limits that protect the parser from hostile header sections.
final class HeaderLimits {
  const HeaderLimits({this.maxBytes = 256 * 1024, this.maxFields = 1000});

  final int maxBytes;
  final int maxFields;
}

/// The result of reading a header section.
final class HeaderParseResult {
  HeaderParseResult(this.headers, this.bodyStart, this.defects);

  final HeaderSection headers;

  /// Offset of the first body byte.
  final int bodyStart;
  final List<MimeDefect> defects;
}

/// Reads a header section from bytes.
///
/// The section ends at the first empty line. A line that is neither a
/// field nor a continuation also ends it (the separator is missing), and the
/// body starts at that line. Beyond the limits, fields are skipped but the
/// end of the section is still found, so the body stays correct.
final class HeaderParser {
  const HeaderParser({this.limits = const HeaderLimits()});

  final HeaderLimits limits;

  HeaderParseResult parse(Uint8List bytes, [int start = 0, int? end]) {
    final stop = RangeError.checkValidRange(start, end, bytes.length);
    final fields = <HeaderField>[];
    final defects = <MimeDefect>[];

    String? pendingName;
    var pendingStart = 0, pendingEnd = 0;
    var collecting = true;

    void flush() {
      final name = pendingName;
      if (name == null) return;
      if (collecting) {
        fields.add(
          HeaderField(
            name,
            Uint8List.sublistView(bytes, pendingStart, pendingEnd),
          ),
        );
      }
      pendingName = null;
    }

    var isFirstLine = true;
    for (final line in byteLines(bytes, start, stop)) {
      if (line.isEmpty) {
        flush();
        return HeaderParseResult(HeaderSection(fields), line.end, defects);
      }

      if (collecting && line.end - start > limits.maxBytes) {
        collecting = false;
        pendingName = null;
        defects.add(const MimeDefect(MimeDefectKind.headerSectionTooLarge));
      }

      final first = bytes[line.start];
      if (first == 0x20 || first == 0x09) {
        if (pendingName != null) {
          pendingEnd = line.contentEnd; // continuation keeps its fold
        } else if (collecting) {
          defects.add(
            const MimeDefect(
              MimeDefectKind.malformedHeaderLine,
              'continuation without field',
            ),
          );
        }
        isFirstLine = false;
        continue;
      }

      final colon = _fieldNameEnd(bytes, line);
      if (colon < 0) {
        if (isFirstLine && _startsWithMboxFrom(bytes, line)) {
          // "From sender date" line from an mbox file: skip it.
          defects.add(
            const MimeDefect(
              MimeDefectKind.malformedHeaderLine,
              'mbox From line',
            ),
          );
          isFirstLine = false;
          continue;
        }
        flush();
        defects.add(
          const MimeDefect(MimeDefectKind.missingHeaderBodySeparator),
        );
        return HeaderParseResult(HeaderSection(fields), line.start, defects);
      }

      flush();
      if (collecting && fields.length >= limits.maxFields) {
        collecting = false;
        defects.add(const MimeDefect(MimeDefectKind.tooManyHeaderFields));
      }
      final name = latin1
          .decode(Uint8List.sublistView(bytes, line.start, colon))
          .trimRight();
      pendingName = name;
      pendingStart = colon + 1;
      pendingEnd = line.contentEnd;
      isFirstLine = false;
    }

    // Input ended inside the header section: no body.
    flush();
    return HeaderParseResult(HeaderSection(fields), stop, defects);
  }

  /// Index of the colon ending a valid field name on [line], or -1.
  /// Names are printable ASCII without colon; whitespace before the colon
  /// (obsolete syntax) is accepted.
  static int _fieldNameEnd(Uint8List bytes, ByteLine line) {
    var sawName = false;
    var sawSpace = false;
    for (var i = line.start; i < line.contentEnd; i++) {
      final c = bytes[i];
      if (c == 0x3A) return sawName ? i : -1;
      if (c == 0x20 || c == 0x09) {
        if (!sawName) return -1;
        sawSpace = true;
        continue;
      }
      if (c < 0x21 || c > 0x7E || sawSpace) return -1;
      sawName = true;
    }
    return -1;
  }

  static bool _startsWithMboxFrom(Uint8List bytes, ByteLine line) =>
      line.contentLength >= 5 &&
      bytes[line.start] == 0x46 && // F
      bytes[line.start + 1] == 0x72 && // r
      bytes[line.start + 2] == 0x6F && // o
      bytes[line.start + 3] == 0x6D && // m
      bytes[line.start + 4] == 0x20;
}
