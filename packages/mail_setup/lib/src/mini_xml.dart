// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// An element of a small, untrusted XML document.
final class XmlElement {
  XmlElement(this.name, this.attributes);

  /// Local name (any namespace prefix removed).
  final String name;
  final Map<String, String> attributes;
  final List<XmlElement> children = [];
  final StringBuffer _text = StringBuffer();

  /// Text directly inside this element, trimmed.
  String get text => _text.toString().trim();

  /// Children named [name].
  Iterable<XmlElement> all(String name) =>
      children.where((c) => c.name == name);

  /// The first child named [name], or null.
  XmlElement? first(String name) => all(name).firstOrNull;

  /// Text of the first child named [name], or null.
  String? childText(String name) => first(name)?.text;
}

/// A deliberately small XML reader for untrusted documents such as mail
/// autoconfig files.
///
/// Refuses DOCTYPE (and with it all entity definitions, so neither external
/// entities nor "billion laughs" expansion is possible), processes only the
/// five predefined entities and numeric character references, and limits
/// size, nesting and element count. Throws [FormatException] on anything
/// else.
final class MiniXml {
  const MiniXml({
    this.maxLength = 256 * 1024,
    this.maxDepth = 32,
    this.maxElements = 2000,
  });

  final int maxLength;
  final int maxDepth;
  final int maxElements;

  static const _entities = {
    'lt': '<',
    'gt': '>',
    'amp': '&',
    'quot': '"',
    'apos': "'",
  };

  XmlElement parse(String input) {
    if (input.length > maxLength) {
      throw const FormatException('XML document too large');
    }
    final stack = <XmlElement>[];
    XmlElement? root;
    var elements = 0;
    var i = 0;

    while (i < input.length) {
      final lt = input.indexOf('<', i);
      final textEnd = lt < 0 ? input.length : lt;
      if (textEnd > i) {
        final text = input.substring(i, textEnd);
        if (stack.isNotEmpty) {
          stack.last._text.write(_decode(text));
        } else if (text.trim().isNotEmpty) {
          throw const FormatException('text outside the root element');
        }
      }
      if (lt < 0) break;
      i = lt;

      if (input.startsWith('<?', i)) {
        i = _skipTo(input, '?>', i) + 2;
      } else if (input.startsWith('<!--', i)) {
        i = _skipTo(input, '-->', i) + 3;
      } else if (input.startsWith('<![CDATA[', i)) {
        final end = _skipTo(input, ']]>', i);
        if (stack.isEmpty) {
          throw const FormatException('CDATA outside the root element');
        }
        stack.last._text.write(input.substring(i + 9, end));
        i = end + 3;
      } else if (input.startsWith('<!', i)) {
        throw const FormatException('DOCTYPE and declarations are not allowed');
      } else if (input.startsWith('</', i)) {
        final end = _skipTo(input, '>', i);
        final name = _localName(input.substring(i + 2, end).trim());
        if (stack.isEmpty || stack.last.name != name) {
          throw FormatException('unexpected </$name>');
        }
        stack.removeLast();
        i = end + 1;
      } else {
        final end = _tagEnd(input, i);
        var body = input.substring(i + 1, end);
        final selfClosing = body.endsWith('/');
        if (selfClosing) body = body.substring(0, body.length - 1);
        final element = _element(body);
        if (++elements > maxElements) {
          throw const FormatException('too many XML elements');
        }
        if (stack.isEmpty) {
          if (root != null) {
            throw const FormatException('more than one root element');
          }
          root = element;
        } else {
          stack.last.children.add(element);
        }
        if (!selfClosing) {
          if (stack.length >= maxDepth) {
            throw const FormatException('XML nested too deeply');
          }
          stack.add(element);
        }
        i = end + 1;
      }
    }
    if (stack.isNotEmpty) throw const FormatException('unclosed XML element');
    return root ?? (throw const FormatException('empty XML document'));
  }

  static int _skipTo(String input, String token, int from) {
    final index = input.indexOf(token, from);
    if (index < 0) throw FormatException('missing "$token"');
    return index;
  }

  /// End of a start tag, ignoring ">" inside quoted attribute values.
  static int _tagEnd(String input, int from) {
    String? quote;
    for (var i = from + 1; i < input.length; i++) {
      final c = input[i];
      if (quote != null) {
        if (c == quote) quote = null;
      } else if (c == '"' || c == "'") {
        quote = c;
      } else if (c == '>') {
        return i;
      } else if (c == '<') {
        throw const FormatException('"<" inside a tag');
      }
    }
    throw const FormatException('unterminated tag');
  }

  static final _attribute = RegExp(
    r'''([^\s=]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''',
  );
  static final _name = RegExp(r'^[A-Za-z_][\w.:-]*$');

  XmlElement _element(String body) {
    final trimmed = body.trim();
    final space = trimmed.indexOf(RegExp(r'\s'));
    final rawName = space < 0 ? trimmed : trimmed.substring(0, space);
    if (!_name.hasMatch(rawName)) {
      throw FormatException('invalid element name "$rawName"');
    }
    final attributes = <String, String>{};
    if (space >= 0) {
      for (final m in _attribute.allMatches(trimmed.substring(space))) {
        attributes[_localName(m.group(1)!)] = _decode(
          m.group(2) ?? m.group(3) ?? '',
        );
      }
    }
    return XmlElement(_localName(rawName), attributes);
  }

  static String _localName(String name) {
    final colon = name.indexOf(':');
    return colon < 0 ? name : name.substring(colon + 1);
  }

  /// Replaces predefined entities and numeric references; any other "&"
  /// sequence is invalid.
  static String _decode(String text) {
    if (!text.contains('&')) return text;
    return text.replaceAllMapped(RegExp(r'&([^;\s]{1,10});|&'), (m) {
      final entity = m.group(1);
      if (entity == null) throw const FormatException('bare "&" in XML text');
      if (_entities[entity] case final value?) return value;
      final code = entity.startsWith('#x')
          ? int.tryParse(entity.substring(2), radix: 16)
          : entity.startsWith('#')
          ? int.tryParse(entity.substring(1))
          : null;
      if (code == null ||
          code < 1 ||
          code > 0x10FFFF ||
          (code >= 0xD800 && code <= 0xDFFF)) {
        throw FormatException('unknown XML entity &$entity;');
      }
      return String.fromCharCode(code);
    });
  }
}
