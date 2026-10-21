// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert' show utf8;
import 'dart:typed_data';

import '../charset/charsets.dart';
import '../charset/text_decoder.dart';
import 'encoded_word.dart';
import 'mime_defect.dart';

/// Parameters of a MIME field (`; name=value`), with RFC 2231 extended
/// values (`name*=utf-8''%E2%82%AC`) and continuations (`name*0=`, `name*1*=`)
/// already decoded. Names are lowercase.
final class MimeParameters {
  MimeParameters(Map<String, String> values)
    : values = Map.unmodifiable(values);

  static final MimeParameters none = MimeParameters(const {});

  final Map<String, String> values;

  String? operator [](String name) => values[name.toLowerCase()];

  bool get isEmpty => values.isEmpty;
}

/// A parsed `Content-Type` field (RFC 2045 section 5).
final class ContentType {
  ContentType(String type, String subtype, [MimeParameters? parameters])
    : type = type.toLowerCase(),
      subtype = subtype.toLowerCase(),
      parameters = parameters ?? MimeParameters.none;

  /// RFC 2045 default when the field is missing or invalid.
  static final ContentType textPlain = ContentType(
    'text',
    'plain',
    MimeParameters(const {'charset': 'us-ascii'}),
  );

  /// Default for parts of multipart/digest (RFC 2046 5.1.5).
  static final ContentType messageRfc822 = ContentType('message', 'rfc822');

  final String type;
  final String subtype;
  final MimeParameters parameters;

  /// e.g. `text/html`.
  String get mimeType => '$type/$subtype';

  bool get isMultipart => type == 'multipart';
  bool get isText => type == 'text';

  /// message/rfc822 and message/global contain a whole message.
  bool get isEmbeddedMessage =>
      type == 'message' && (subtype == 'rfc822' || subtype == 'global');

  String? get charset => parameters['charset'];
  String? get boundary => parameters['boundary'];

  @override
  String toString() => mimeType;
}

/// A parsed `Content-Disposition` field (RFC 2183).
final class ContentDisposition {
  ContentDisposition(String type, [MimeParameters? parameters])
    : type = type.toLowerCase(),
      parameters = parameters ?? MimeParameters.none;

  final String type;
  final MimeParameters parameters;

  bool get isAttachment => type == 'attachment';
  bool get isInline => type == 'inline';

  String? get filename => parameters['filename'];
}

/// A field value parsed with its defects.
final class ParsedField<T> {
  ParsedField(this.value, [List<MimeDefect> defects = const []])
    : defects = List.unmodifiable(defects);

  final T value;
  final List<MimeDefect> defects;
}

/// Parses Content-Type, Content-Disposition and their parameters.
final class MimeFieldParser {
  const MimeFieldParser({this.maxContinuationSections = 64});

  /// RFC 2231 continuations beyond this are ignored (hostile input).
  final int maxContinuationSections;

  static final _token = RegExp(r'^[^\s()<>@,;:\\"/\[\]?=]+$');

  /// Parses a Content-Type value. Invalid values give null and a defect;
  /// callers then use [ContentType.textPlain] as RFC 2045 says.
  ParsedField<ContentType?> parseContentType(String value) {
    final defects = <MimeDefect>[];
    final (head, rest) = _splitHead(value);
    final slash = head.indexOf('/');
    if (slash <= 0 || slash == head.length - 1) {
      defects.add(const MimeDefect(MimeDefectKind.invalidContentType));
      return ParsedField(null, defects);
    }
    final type = head.substring(0, slash).trim();
    final subtype = head.substring(slash + 1).trim();
    if (!_token.hasMatch(type) || !_token.hasMatch(subtype)) {
      defects.add(const MimeDefect(MimeDefectKind.invalidContentType));
      return ParsedField(null, defects);
    }
    return ParsedField(
      ContentType(type, subtype, parseParameters(rest, defects)),
      defects,
    );
  }

  ParsedField<ContentDisposition?> parseContentDisposition(String value) {
    final defects = <MimeDefect>[];
    final (head, rest) = _splitHead(value);
    final type = head.trim();
    if (!_token.hasMatch(type)) {
      defects.add(
        const MimeDefect(MimeDefectKind.invalidParameter, 'disposition type'),
      );
      return ParsedField(null, defects);
    }
    return ParsedField(
      ContentDisposition(type, parseParameters(rest, defects)),
      defects,
    );
  }

  /// Parses `; a=b; c="d"` into parameters, decoding RFC 2231 values.
  /// Lenient: unquoted values may contain spaces and tspecials up to ";".
  MimeParameters parseParameters(String text, List<MimeDefect> defects) {
    final plain = <String, String>{};
    final sections = <String, Map<int, _Section>>{};

    for (final (rawName, rawValue) in _splitParameters(text)) {
      final name = rawName.trim().toLowerCase();
      if (name.isEmpty) {
        defects.add(
          const MimeDefect(MimeDefectKind.invalidParameter, 'empty name'),
        );
        continue;
      }
      final star = name.indexOf('*');
      if (star < 0) {
        // First occurrence wins: a repeated parameter (e.g. two boundaries)
        // must not let later text override what other software saw first.
        if (plain.containsKey(name)) {
          defects.add(
            MimeDefect(MimeDefectKind.invalidParameter, 'duplicate $name'),
          );
        } else {
          plain[name] = rawValue;
        }
        continue;
      }
      // RFC 2231: name*, name*N or name*N*
      final base = name.substring(0, star);
      final suffix = name.substring(star + 1);
      final encoded = suffix.isEmpty || suffix.endsWith('*');
      final numberText = suffix.endsWith('*')
          ? suffix.substring(0, suffix.length - 1)
          : suffix;
      final number = numberText.isEmpty ? 0 : int.tryParse(numberText);
      if (base.isEmpty ||
          number == null ||
          number < 0 ||
          numberText.length > 3) {
        defects.add(
          MimeDefect(MimeDefectKind.invalidParameter, 'bad section $name'),
        );
        continue;
      }
      if (number >= maxContinuationSections) continue;
      // Encoded sections are percent-decoded even when quoted: not strictly
      // allowed, but some mailers send filename*="utf-8''%E2%82%AC".
      final sectionsOfName = sections.putIfAbsent(base, () => {});
      if (sectionsOfName.containsKey(number)) {
        defects.add(
          MimeDefect(MimeDefectKind.invalidParameter, 'duplicate $name'),
        );
      } else {
        sectionsOfName[number] = _Section(rawValue, encoded: encoded);
      }
    }

    final result = Map<String, String>.of(plain);
    for (final MapEntry(key: name, value: parts) in sections.entries) {
      final value = _joinSections(parts, defects, name);
      if (value != null) result[name] = value; // RFC 2231 value wins
    }
    return MimeParameters(result);
  }

  /// Joins RFC 2231 sections 0, 1, 2, ... and decodes the charset.
  String? _joinSections(
    Map<int, _Section> parts,
    List<MimeDefect> defects,
    String name,
  ) {
    final bytes = BytesBuilder(copy: false);
    String? charsetLabel;
    for (var n = 0; parts.containsKey(n); n++) {
      final section = parts[n]!;
      var text = section.text;
      if (n == 0 && section.encoded) {
        // charset'language'value
        final first = text.indexOf("'");
        final second = first < 0 ? -1 : text.indexOf("'", first + 1);
        if (second < 0) {
          defects.add(
            MimeDefect(MimeDefectKind.invalidParameter, '$name charset'),
          );
        } else {
          charsetLabel = text.substring(0, first);
          text = text.substring(second + 1);
        }
      }
      bytes.add(
        section.encoded
            ? _percentDecode(text, defects, name)
            : utf8.encode(text),
      );
    }
    if (parts.isEmpty || !parts.containsKey(0)) {
      defects.add(
        MimeDefect(MimeDefectKind.invalidParameter, '$name missing section 0'),
      );
      return null;
    }
    if (parts.length != parts.keys.reduce((a, b) => a > b ? a : b) + 1) {
      defects.add(
        MimeDefect(MimeDefectKind.invalidParameter, '$name gap in sections'),
      );
    }
    final data = bytes.takeBytes();
    final charset = charsetLabel == null || charsetLabel.isEmpty
        ? null
        : Charsets.forLabel(charsetLabel);
    if (charsetLabel != null && charsetLabel.isNotEmpty && charset == null) {
      defects.add(MimeDefect(MimeDefectKind.unknownCharset, name));
    }
    return charset?.decode(data) ?? const TextDecoder().decode(data).text;
  }

  static Uint8List _percentDecode(
    String text,
    List<MimeDefect> defects,
    String name,
  ) {
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (c == 0x25 && i + 2 < text.length) {
        final hex = int.tryParse(text.substring(i + 1, i + 3), radix: 16);
        if (hex != null) {
          out.addByte(hex);
          i += 2;
          continue;
        }
      }
      if (c == 0x25) {
        defects.add(MimeDefect(MimeDefectKind.invalidParameter, '$name %'));
      }
      out.add(utf8.encode(String.fromCharCode(c)));
    }
    return out.takeBytes();
  }

  /// Splits "type/subtype; params" at the first ";" outside quotes.
  static (String, String) _splitHead(String value) {
    final semicolon = _indexOutsideQuotes(value, ';', 0);
    return semicolon < 0
        ? (value, '')
        : (value.substring(0, semicolon), value.substring(semicolon + 1));
  }

  /// Splits "a=b; c="d;e"" into (name, value) pairs, unquoting values.
  static Iterable<(String, String)> _splitParameters(String text) sync* {
    var i = 0;
    while (i < text.length) {
      final end = _indexOutsideQuotes(text, ';', i);
      final part = text.substring(i, end < 0 ? text.length : end);
      i = end < 0 ? text.length : end + 1;
      final eq = part.indexOf('=');
      if (eq < 0) continue; // stray text between semicolons: ignore
      final name = part.substring(0, eq);
      final rawValue = part.substring(eq + 1).trim();
      yield (
        name,
        rawValue.startsWith('"')
            ? _unquote(rawValue)
            : _stripComments(rawValue),
      );
    }
  }

  static String _unquote(String s) {
    final out = StringBuffer();
    for (var i = 1; i < s.length; i++) {
      final c = s[i];
      if (c == '\\' && i + 1 < s.length) {
        out.write(s[++i]);
      } else if (c == '"') {
        break;
      } else {
        out.write(c);
      }
    }
    return out.toString();
  }

  /// Removes a trailing "(comment)" from an unquoted value.
  static String _stripComments(String s) {
    final paren = s.indexOf('(');
    return paren < 0 ? s : s.substring(0, paren).trim();
  }

  static int _indexOutsideQuotes(String s, String char, int start) {
    var inQuotes = false;
    for (var i = start; i < s.length; i++) {
      final c = s[i];
      if (c == '\\' && inQuotes) {
        i++;
      } else if (c == '"') {
        inQuotes = !inQuotes;
      } else if (c == char && !inQuotes) {
        return i;
      }
    }
    return -1;
  }

  /// Decodes RFC 2047 encoded words in a filename. Not standard in
  /// parameters, but many mailers do it, and all major clients decode it.
  static String decodeFilename(String raw) =>
      const EncodedWordDecoder().decode(raw).text;
}

final class _Section {
  const _Section(this.text, {required this.encoded});

  final String text;
  final bool encoded;
}
