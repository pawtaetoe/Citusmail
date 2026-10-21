// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Kinds of lexical tokens in structured header fields (RFC 5322 3.2).
enum HeaderTokenKind { atom, quotedString, comment, domainLiteral, special }

/// One token. For quoted strings, comments and domain literals [text] is
/// the content with quoting removed; for specials it is the character.
final class HeaderToken {
  const HeaderToken(this.kind, this.text, {required this.spaceBefore});

  final HeaderTokenKind kind;
  final String text;

  /// Whether whitespace came directly before this token.
  final bool spaceBefore;

  bool isSpecial(String char) =>
      kind == HeaderTokenKind.special && text == char;

  bool get isWord =>
      kind == HeaderTokenKind.atom || kind == HeaderTokenKind.quotedString;

  @override
  String toString() => '${kind.name}($text)';
}

/// Splits a structured header value into tokens.
///
/// Lenient: unterminated quoted strings, comments and domain literals run
/// to the end of the input. Atoms may contain any non-ASCII character
/// (RFC 6532). Dots are part of atoms, so `john.doe` is one atom.
final class HeaderTokenizer {
  const HeaderTokenizer({
    this.specials = addressSpecials,
    this.domainLiterals = true,
  });

  /// Specials for address fields (RFC 5322), without "." (kept in atoms).
  static const String addressSpecials = '()<>[]:;@\\,"';

  /// "tspecials" for MIME fields such as Content-Type (RFC 2045).
  static const String mimeSpecials = '()<>@,;:\\"/[]?=';

  final String specials;
  final bool domainLiterals;

  List<HeaderToken> tokenize(String input) {
    final tokens = <HeaderToken>[];
    var i = 0;
    var space = false;
    while (i < input.length) {
      final c = input[i];
      if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
        space = true;
        i++;
        continue;
      }
      if (c == '"') {
        final (text, next) = _readQuoted(input, i + 1, '"');
        tokens.add(
          HeaderToken(HeaderTokenKind.quotedString, text, spaceBefore: space),
        );
        i = next;
      } else if (c == '(') {
        final (text, next) = _readComment(input, i + 1);
        tokens.add(
          HeaderToken(HeaderTokenKind.comment, text, spaceBefore: space),
        );
        i = next;
      } else if (c == '[' && domainLiterals) {
        final (text, next) = _readQuoted(input, i + 1, ']');
        tokens.add(
          HeaderToken(HeaderTokenKind.domainLiteral, text, spaceBefore: space),
        );
        i = next;
      } else if (specials.contains(c)) {
        tokens.add(HeaderToken(HeaderTokenKind.special, c, spaceBefore: space));
        i++;
      } else {
        final start = i;
        while (i < input.length && !_endsAtom(input.codeUnitAt(i))) {
          i++;
        }
        // Always consume at least one character, so no input can make the
        // tokenizer stop in place and loop forever.
        if (i == start) i++;
        tokens.add(
          HeaderToken(
            HeaderTokenKind.atom,
            input.substring(start, i),
            spaceBefore: space,
          ),
        );
      }
      space = false;
    }
    return tokens;
  }

  /// Whitespace and specials end an atom. Other control characters are
  /// invalid but kept inside the atom (display names replace them later).
  bool _endsAtom(int c) =>
      c == 0x20 ||
      c == 0x09 ||
      c == 0x0D ||
      c == 0x0A ||
      specials.contains(String.fromCharCode(c)) ||
      (c == 0x5B && domainLiterals);

  /// Reads up to an unescaped [close]; backslash escapes the next char.
  static (String, int) _readQuoted(String s, int start, String close) {
    final out = StringBuffer();
    var i = start;
    while (i < s.length) {
      final c = s[i];
      if (c == '\\' && i + 1 < s.length) {
        out.write(s[i + 1]);
        i += 2;
        continue;
      }
      if (c == close) return (out.toString(), i + 1);
      out.write(c);
      i++;
    }
    return (out.toString(), i);
  }

  /// Reads a comment, which may nest.
  static (String, int) _readComment(String s, int start) {
    final out = StringBuffer();
    var depth = 1;
    var i = start;
    while (i < s.length) {
      final c = s[i];
      if (c == '\\' && i + 1 < s.length) {
        out.write(s[i + 1]);
        i += 2;
        continue;
      }
      if (c == '(') depth++;
      if (c == ')' && --depth == 0) return (out.toString(), i + 1);
      out.write(c);
      i++;
    }
    return (out.toString(), i);
  }
}
