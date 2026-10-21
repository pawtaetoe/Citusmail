// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Mailing-list identifiers (RFC 2919).
abstract final class ListId {
  /// The identifier from a `List-Id` value, normalized to lower case, or
  /// null if there is no valid one.
  ///
  /// `Project developers <dev.lists.project.example>` ->
  /// `dev.lists.project.example`. The angle brackets are required by the
  /// RFC, but a bare identifier is accepted too.
  static String? parse(String? value) {
    if (value == null) return null;
    final open = value.lastIndexOf('<');
    final close = value.lastIndexOf('>');
    final id = open >= 0 && close > open
        ? value.substring(open + 1, close)
        : value;
    final trimmed = id.trim();
    // Checked before lower-casing: only ASCII may pass (some non-ASCII
    // letters lower-case to ASCII ones).
    if (trimmed.length > maxLength || !_valid.hasMatch(trimmed)) return null;
    return trimmed.toLowerCase();
  }

  /// The first valid identifier in a message's lower-case headers.
  static String? fromHeaders(Map<String, List<String>> headers) {
    for (final value in headers['list-id'] ?? const <String>[]) {
      final id = parse(value);
      if (id != null) return id;
    }
    return null;
  }

  static const maxLength = 255;

  /// A dot-atom with at least one dot: `list-label "." namespace`.
  static final _valid = RegExp(
    r"^[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)+$",
  );
}
