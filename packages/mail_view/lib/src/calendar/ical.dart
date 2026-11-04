// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

/// One iCalendar content line (RFC 5545 3.1): `NAME;PARAM=value:value`.
///
/// The value is kept as written (still escaped), so a property can be
/// written back exactly; [text] gives it unescaped.
final class ICalProperty {
  ICalProperty(this.name, this.value, [Map<String, String>? parameters])
    : parameters = parameters ?? const {};

  /// Upper case, e.g. `DTSTART`.
  final String name;

  /// Parameter values as written (quotes included), by upper-case name.
  final Map<String, String> parameters;

  /// The raw value, still escaped.
  final String value;

  /// A parameter's value without quotes (the first one, if it has
  /// several), or null.
  String? parameter(String name) {
    final raw = parameters[name.toUpperCase()];
    if (raw == null) return null;
    return ICalProperty.parameterValues(raw).firstOrNull;
  }

  /// The value as text: `\n`, `\,`, `\;` and `\\` unescaped.
  String get text => ICalText.unescape(value);

  /// A copy with other parameters, e.g. a new PARTSTAT.
  ICalProperty withParameters(Map<String, String> parameters) =>
      ICalProperty(name, value, parameters);

  /// The values of a parameter, unquoted (`"a","b"` -> `[a, b]`).
  static List<String> parameterValues(String raw) {
    final values = <String>[];
    final current = StringBuffer();
    var quoted = false;
    for (final char in raw.split('')) {
      if (char == '"') {
        quoted = !quoted;
      } else if (char == ',' && !quoted) {
        values.add(current.toString());
        current.clear();
      } else {
        current.write(char);
      }
    }
    values.add(current.toString());
    return values;
  }

  /// A parameter value written safely: quoted when it holds `:;,`, with
  /// characters that may not appear in one (quotes, controls) removed.
  static String quoteParameter(String value) {
    final clean = value.replaceAll(RegExp(r'[\x00-\x1F\x7F"]'), '');
    return clean.contains(RegExp('[:;,]')) ? '"$clean"' : clean;
  }

  /// The content line, unfolded.
  String get line {
    final out = StringBuffer(name);
    parameters.forEach((key, value) => out.write(';$key=$value'));
    out
      ..write(':')
      ..write(value);
    return out.toString();
  }

  @override
  String toString() => line;
}

/// A component: `BEGIN:VEVENT` ... `END:VEVENT`, with its properties and
/// sub-components in order.
final class ICalComponent {
  ICalComponent(this.name);

  /// Upper case, e.g. `VEVENT`.
  final String name;
  final List<ICalProperty> properties = [];
  final List<ICalComponent> children = [];

  /// The first property called [name], or null.
  ICalProperty? property(String name) {
    for (final p in properties) {
      if (p.name == name) return p;
    }
    return null;
  }

  /// Every property called [name].
  Iterable<ICalProperty> all(String name) =>
      properties.where((p) => p.name == name);

  /// Direct sub-components called [name].
  Iterable<ICalComponent> components(String name) =>
      children.where((c) => c.name == name);

  /// Writes the component back as folded iCalendar lines.
  void write(ICalWriter out) {
    out.line('BEGIN:$name');
    for (final p in properties) {
      out.line(p.line);
    }
    for (final child in children) {
      child.write(out);
    }
    out.line('END:$name');
  }
}

/// Reads iCalendar text (RFC 5545) into components. Lenient, as mail is:
/// LF or CRLF line ends, unknown properties kept, broken lines skipped,
/// unclosed components closed at the end. Bounded, so a hostile file can
/// only waste a little time: very large input, deep nesting and too many
/// lines are cut.
final class ICalParser {
  const ICalParser();

  /// More than this is not an invitation (calendar exports, attachments
  /// inside the file): not read at all.
  static const maxLength = 2 * 1024 * 1024;
  static const maxLines = 50000;
  static const maxDepth = 8;
  static const maxLineLength = 64 * 1024;

  /// The top-level components (usually one VCALENDAR). Empty if [text] is
  /// too large or holds none.
  List<ICalComponent> parse(String text) {
    if (text.length > maxLength) return const [];
    final roots = <ICalComponent>[];
    final stack = <ICalComponent>[];
    var count = 0;
    for (final line in unfold(text)) {
      if (++count > maxLines) break;
      if (line.length > maxLineLength) continue;
      final property = parseLine(line);
      if (property == null) continue;
      if (property.name == 'BEGIN') {
        final component = ICalComponent(property.value.trim().toUpperCase());
        if (stack.length >= maxDepth) {
          stack.add(component); // kept off the tree, but tracked for END
          continue;
        }
        (stack.isEmpty ? roots : stack.last.children).add(component);
        stack.add(component);
      } else if (property.name == 'END') {
        final name = property.value.trim().toUpperCase();
        final at = stack.lastIndexWhere((c) => c.name == name);
        if (at >= 0) stack.removeRange(at, stack.length);
      } else if (stack.isNotEmpty && stack.length <= maxDepth) {
        stack.last.properties.add(property);
      }
    }
    return roots;
  }

  /// Lines with folding undone (a line starting with a space or tab
  /// continues the previous one).
  static Iterable<String> unfold(String text) sync* {
    final lines = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    StringBuffer? current;
    for (final line in lines) {
      if (line.isNotEmpty &&
          (line.codeUnitAt(0) == 0x20 || line.codeUnitAt(0) == 0x09)) {
        if (current != null && current.length < maxLineLength) {
          current.write(line.substring(1));
        }
        continue;
      }
      if (current != null) yield current.toString();
      current = StringBuffer(line);
    }
    if (current != null) yield current.toString();
  }

  /// One unfolded content line, or null if it isn't one.
  static ICalProperty? parseLine(String line) {
    // The name ends at the first ';' or ':'; parameters end at the first
    // ':' outside quotes.
    var i = 0;
    while (i < line.length && line[i] != ';' && line[i] != ':') {
      i++;
    }
    if (i == 0 || i >= line.length) return null;
    final name = line.substring(0, i).trim().toUpperCase();
    if (!_name.hasMatch(name)) return null;
    final parameters = <String, String>{};
    while (i < line.length && line[i] == ';') {
      final start = ++i;
      var quoted = false;
      while (i < line.length) {
        final c = line[i];
        if (c == '"') quoted = !quoted;
        if (!quoted && (c == ';' || c == ':')) break;
        i++;
      }
      final parameter = line.substring(start, i);
      final eq = parameter.indexOf('=');
      if (eq > 0) {
        final key = parameter.substring(0, eq).trim().toUpperCase();
        if (_name.hasMatch(key)) {
          parameters.putIfAbsent(key, () => parameter.substring(eq + 1));
        }
      }
    }
    if (i >= line.length || line[i] != ':') return null;
    return ICalProperty(name, line.substring(i + 1), parameters);
  }

  static final _name = RegExp(r'^[A-Z0-9-]+$');
}

/// Escaping of TEXT values (RFC 5545 3.3.11).
abstract final class ICalText {
  static String unescape(String value) {
    if (!value.contains(r'\')) return value;
    final out = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      final c = value[i];
      if (c == r'\' && i + 1 < value.length) {
        final next = value[++i];
        out.write(switch (next) {
          'n' || 'N' => '\n',
          _ => next, // \\ \, \; and anything else
        });
      } else {
        out.write(c);
      }
    }
    return out.toString();
  }

  static String escape(String text) => text
      .replaceAll(r'\', r'\\')
      .replaceAll(';', r'\;')
      .replaceAll(',', r'\,')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\n', r'\n')
      .replaceAll(RegExp(r'[\x00-\x08\x0B-\x1F\x7F]'), '');
}

/// Writes iCalendar lines: CRLF, folded at 75 octets without splitting a
/// UTF-8 character (RFC 5545 3.1).
final class ICalWriter {
  final _out = StringBuffer();

  void line(String line) {
    var octets = 0;
    var limit = 75;
    for (final rune in line.runes) {
      final size = utf8.encode(String.fromCharCode(rune)).length;
      if (octets + size > limit) {
        _out.write('\r\n ');
        octets = 0;
        limit = 74; // the leading space counts
      }
      _out.writeCharCode(rune);
      octets += size;
    }
    _out.write('\r\n');
  }

  @override
  String toString() => _out.toString();
}
