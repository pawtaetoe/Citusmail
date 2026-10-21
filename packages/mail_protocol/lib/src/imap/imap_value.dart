// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

/// One value in an IMAP response (RFC 9051 / 3501 formal syntax, loosely).
sealed class ImapValue {
  const ImapValue();
}

/// An atom: a word such as `FLAGS`, `\Seen`, `42` or `BODY[1.2]<0>`.
final class ImapAtom extends ImapValue {
  const ImapAtom(this.text);

  final String text;

  /// The atom as a number, or null if it is not one.
  int? get number => int.tryParse(text);

  bool equalsIgnoreCase(String other) =>
      text.toUpperCase() == other.toUpperCase();

  @override
  String toString() => text;
}

/// A quoted string or a literal. Kept as bytes: literals carry message
/// data that may be in any encoding.
final class ImapString extends ImapValue {
  const ImapString(this.bytes);

  final Uint8List bytes;

  /// The bytes as text: UTF-8 when valid (RFC 6855), otherwise Latin-1.
  String get text {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }

  @override
  String toString() => '"$text"';
}

/// NIL.
final class ImapNil extends ImapValue {
  const ImapNil();

  @override
  String toString() => 'NIL';
}

/// A parenthesised list.
final class ImapList extends ImapValue {
  ImapList(List<ImapValue> items) : items = List.unmodifiable(items);

  final List<ImapValue> items;

  int get length => items.length;

  ImapValue operator [](int i) => items[i];

  @override
  String toString() => '(${items.join(' ')})';
}

/// Helpers for reading typed values out of a parsed response, failing
/// cleanly (null) on anything unexpected.
extension ImapValueAccess on ImapValue {
  /// Text of an atom or string; null for NIL and lists.
  String? get asText => switch (this) {
    ImapAtom(:final text) => text,
    ImapString() => (this as ImapString).text,
    _ => null,
  };

  /// Number from an atom.
  int? get asNumber => this is ImapAtom ? (this as ImapAtom).number : null;

  /// Bytes of a string or atom; null for NIL and lists.
  Uint8List? get asBytes => switch (this) {
    ImapString(:final bytes) => bytes,
    ImapAtom(:final text) => Uint8List.fromList(latin1.encode(text)),
    _ => null,
  };

  List<ImapValue>? get asList =>
      this is ImapList ? (this as ImapList).items : null;

  bool get isNil => this is ImapNil;
}
