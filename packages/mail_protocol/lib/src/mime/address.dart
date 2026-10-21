// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'encoded_word.dart';
import 'header_tokenizer.dart';
import 'mime_defect.dart';

/// An entry in an address list: a single mailbox or a named group.
sealed class AddressEntry {
  const AddressEntry();

  /// Every mailbox in this entry (one, or a group's members).
  List<MailAddress> get mailboxes;
}

/// One mailbox, e.g. `"Alice Example" <alice@example.com>`.
final class MailAddress extends AddressEntry {
  const MailAddress({
    required this.localPart,
    required this.domain,
    this.displayName,
  });

  /// Decoded display name, or null if there is none.
  final String? displayName;

  /// The part before "@", unquoted.
  final String localPart;

  /// The part after "@", as written (may be an IDN or a [literal]).
  final String domain;

  /// `local@domain`, quoting the local part when RFC 5322 requires it.
  String get address =>
      '${_needsQuoting(localPart) ? _quote(localPart) : localPart}@$domain';

  /// Domain in lowercase, for comparisons. Domains are case-insensitive.
  String get normalizedDomain => domain.toLowerCase();

  /// `address` with the domain lowercased, for matching and lookups.
  String get normalizedAddress =>
      '${address.substring(0, address.lastIndexOf('@'))}@$normalizedDomain';

  @override
  List<MailAddress> get mailboxes => [this];

  static final _dotAtom = RegExp(
    r"^[A-Za-z0-9!#$%&'*+/=?^_`{|}~\u0080-￿-]+(\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~\u0080-￿-]+)*$",
  );

  static bool _needsQuoting(String local) => !_dotAtom.hasMatch(local);

  static String _quote(String s) =>
      '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  @override
  bool operator ==(Object other) =>
      other is MailAddress &&
      other.displayName == displayName &&
      other.localPart == localPart &&
      other.domain == domain;

  @override
  int get hashCode => Object.hash(displayName, localPart, domain);

  @override
  String toString() =>
      displayName == null ? address : '$displayName <$address>';
}

/// A group, e.g. `Team: alice@example.com, bob@example.com;`.
final class AddressGroup extends AddressEntry {
  AddressGroup(this.name, List<MailAddress> members)
    : members = List.unmodifiable(members);

  final String name;
  final List<MailAddress> members;

  @override
  List<MailAddress> get mailboxes => members;

  @override
  String toString() => '$name: ${members.join(', ')};';
}

/// Parsed address list plus anything that was wrong with it.
final class AddressListResult {
  AddressListResult(List<AddressEntry> entries, List<MimeDefect> defects)
    : entries = List.unmodifiable(entries),
      defects = List.unmodifiable(defects);

  final List<AddressEntry> entries;
  final List<MimeDefect> defects;

  /// All mailboxes, with groups flattened.
  List<MailAddress> get mailboxes => [for (final e in entries) ...e.mailboxes];
}

/// Parses address fields (From, To, Cc, Reply-To, ...) per RFC 5322 3.4,
/// leniently. Entries without an "@" are skipped and reported.
final class AddressParser {
  const AddressParser();

  static const _tokenizer = HeaderTokenizer();
  static const _encodedWords = EncodedWordDecoder();

  AddressListResult parse(String value) {
    final cursor = _Cursor(_tokenizer.tokenize(value));
    final entries = <AddressEntry>[];
    final defects = <MimeDefect>[];
    while (!cursor.atEnd) {
      if (cursor.skipSpecial(',')) continue;
      if (cursor.skipSpecial(';')) {
        defects.add(const MimeDefect(MimeDefectKind.invalidAddress, 'stray ;'));
        continue;
      }
      final before = cursor.position;
      final entry = _parseEntry(cursor, defects, inGroup: false);
      if (entry != null) entries.add(entry);
      // Guarantee progress on any input, so the loop always ends.
      if (cursor.position == before) cursor.advance();
    }
    return AddressListResult(entries, defects);
  }

  AddressEntry? _parseEntry(
    _Cursor cursor,
    List<MimeDefect> defects, {
    required bool inGroup,
  }) {
    final start = cursor.position;
    final phrase = <HeaderToken>[];
    final comments = <String>[];
    // Computed once per entry so many "@" characters stay linear time.
    final angleFollows = cursor.hasBeforeSeparator('<');

    while (!cursor.atEnd) {
      final token = cursor.peek;
      if (token.kind == HeaderTokenKind.comment) {
        comments.add(token.text);
        cursor.advance();
        continue;
      }
      if (token.isSpecial('<')) {
        cursor.advance();
        return _finishAngleAddress(cursor, phrase, defects);
      }
      if (token.isSpecial(':') && !inGroup) {
        cursor.advance();
        return _finishGroup(cursor, phrase, defects);
      }
      if (token.isSpecial('@')) {
        // An "@" before a "<" means the display name looks like an address
        // (`bob@x.com <bob@x.com>`, a common phishing trick): keep it all
        // as the display name.
        if (angleFollows) {
          phrase.add(token);
          cursor.advance();
          continue;
        }
        cursor.position = start;
        return _parseAddrSpec(cursor, defects, comments);
      }
      if (token.isSpecial(',') || token.isSpecial(';')) break;
      phrase.add(token);
      cursor.advance();
    }

    if (phrase.isNotEmpty || comments.isNotEmpty) {
      defects.add(const MimeDefect(MimeDefectKind.invalidAddress, 'no @'));
    }
    return null;
  }

  /// After "<": addr-spec up to ">" (or the next separator if ">" is missing).
  MailAddress? _finishAngleAddress(
    _Cursor cursor,
    List<HeaderToken> phrase,
    List<MimeDefect> defects,
  ) {
    final spec = <HeaderToken>[];
    var closed = false;
    while (!cursor.atEnd) {
      final token = cursor.peek;
      if (token.isSpecial('>')) {
        cursor.advance();
        closed = true;
        break;
      }
      if (token.isSpecial(',') || token.isSpecial(';')) break;
      if (token.kind != HeaderTokenKind.comment) spec.add(token);
      cursor.advance();
    }
    // Skip anything else up to the next separator (e.g. trailing comments).
    while (!cursor.atEnd &&
        !cursor.peek.isSpecial(',') &&
        !cursor.peek.isSpecial(';')) {
      cursor.advance();
    }
    if (!closed) {
      defects.add(const MimeDefect(MimeDefectKind.invalidAddress, 'missing >'));
    }

    final address = _addressFromSpec(_stripSourceRoute(spec));
    if (address == null) {
      defects.add(const MimeDefect(MimeDefectKind.invalidAddress, 'no @'));
      return null;
    }
    return MailAddress(
      localPart: address.$1,
      domain: address.$2,
      displayName: _displayName(phrase),
    );
  }

  /// A bare addr-spec, optionally followed by an old-style "(Name)" comment.
  MailAddress? _parseAddrSpec(
    _Cursor cursor,
    List<MimeDefect> defects,
    List<String> leadingComments,
  ) {
    final spec = <HeaderToken>[];
    final comments = [...leadingComments];
    while (!cursor.atEnd &&
        !cursor.peek.isSpecial(',') &&
        !cursor.peek.isSpecial(';')) {
      final token = cursor.peek;
      if (token.kind == HeaderTokenKind.comment) {
        comments.add(token.text);
      } else {
        spec.add(token);
      }
      cursor.advance();
    }
    final address = _addressFromSpec(spec);
    if (address == null) {
      defects.add(
        const MimeDefect(MimeDefectKind.invalidAddress, 'malformed addr-spec'),
      );
      return null;
    }
    final commentName = comments
        .map((c) => c.trim())
        .where((c) => c.isNotEmpty)
        .join(' ');
    return MailAddress(
      localPart: address.$1,
      domain: address.$2,
      displayName: commentName.isEmpty
          ? null
          : _encodedWords.decode(commentName).text,
    );
  }

  /// After "name:": mailboxes up to ";" (or the end).
  AddressGroup _finishGroup(
    _Cursor cursor,
    List<HeaderToken> phrase,
    List<MimeDefect> defects,
  ) {
    final members = <MailAddress>[];
    while (!cursor.atEnd) {
      if (cursor.skipSpecial(';')) break;
      if (cursor.skipSpecial(',')) continue;
      final before = cursor.position;
      final entry = _parseEntry(cursor, defects, inGroup: true);
      if (entry is MailAddress) members.add(entry);
      if (cursor.position == before) cursor.advance();
    }
    return AddressGroup(_displayName(phrase) ?? '', members);
  }

  /// Removes an obsolete source route: `<@a.example,@b.example:user@host>`.
  static List<HeaderToken> _stripSourceRoute(List<HeaderToken> spec) {
    final colon = spec.indexWhere((t) => t.isSpecial(':'));
    if (colon > 0 && spec.first.isSpecial('@')) return spec.sublist(colon + 1);
    return spec;
  }

  /// Splits tokens at the last "@" into (local part, domain).
  static (String, String)? _addressFromSpec(List<HeaderToken> spec) {
    final at = spec.lastIndexWhere((t) => t.isSpecial('@'));
    if (at <= 0 || at == spec.length - 1) return null;
    final local = spec.sublist(0, at).map((t) => t.text).join();
    final domainTokens = spec.sublist(at + 1);
    final domain =
        domainTokens.length == 1 &&
            domainTokens.first.kind == HeaderTokenKind.domainLiteral
        ? '[${domainTokens.first.text}]'
        : domainTokens.map((t) => t.text).join();
    if (local.isEmpty || domain.isEmpty) return null;
    return (local, domain);
  }

  /// Joins phrase words with single spaces and decodes encoded words
  /// (also inside quoted strings, as common clients do).
  static String? _displayName(List<HeaderToken> phrase) {
    if (phrase.isEmpty) return null;
    final joined = StringBuffer();
    for (var i = 0; i < phrase.length; i++) {
      final token = phrase[i];
      if (i > 0 &&
          (token.spaceBefore || token.isWord && phrase[i - 1].isWord)) {
        joined.write(' ');
      }
      joined.write(token.text);
    }
    final name = _encodedWords.decode(joined.toString()).text.trim();
    return name.isEmpty ? null : name;
  }
}

/// A position in a token list.
final class _Cursor {
  _Cursor(this.tokens);

  final List<HeaderToken> tokens;
  int position = 0;

  bool get atEnd => position >= tokens.length;

  HeaderToken get peek => tokens[position];

  void advance() => position++;

  bool skipSpecial(String char) {
    if (!atEnd && peek.isSpecial(char)) {
      position++;
      return true;
    }
    return false;
  }

  /// Whether special [char] appears before the next "," or ";".
  bool hasBeforeSeparator(String char) {
    for (var i = position; i < tokens.length; i++) {
      final t = tokens[i];
      if (t.isSpecial(',') || t.isSpecial(';')) return false;
      if (t.isSpecial(char)) return true;
    }
    return false;
  }
}
