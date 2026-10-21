// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Turns what the user typed into a safe search.
///
/// Every term is matched as literal text: FTS5 operators, quotes and
/// wildcards typed by the user have no special meaning. Terms are combined
/// with AND.
final class SearchQuery {
  SearchQuery._(this.terms);

  /// Splits [input] on whitespace. Returns null if there is nothing to find.
  static SearchQuery? parse(String input, {int maxTerms = 10}) {
    final terms = input
        .split(RegExp(r'\s+'))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .take(maxTerms)
        .toList(growable: false);
    return terms.isEmpty ? null : SearchQuery._(terms);
  }

  final List<String> terms;

  /// The trigram index matches substrings of at least 3 characters. Shorter
  /// terms (common for Chinese, e.g. "會議") need the LIKE fallback.
  bool get usesIndex => terms.every((t) => t.runes.length >= 3);

  /// FTS5 MATCH expression: each term as a quoted string, so it is always
  /// literal text ("" escapes a quote inside a term).
  String toFtsMatch() =>
      terms.map((t) => '"${t.replaceAll('"', '""')}"').join(' AND ');

  /// LIKE patterns with % and _ escaped (use with ESCAPE '\').
  List<String> toLikePatterns() => terms
      .map(
        (t) =>
            '%${t.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%',
      )
      .toList();
}
