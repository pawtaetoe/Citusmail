// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Turns what the user typed into a safe search.
///
/// Every term is matched as literal text: FTS5 operators, quotes and
/// wildcards typed by the user have no special meaning. Terms are combined
/// with AND.
final class SearchQuery {
  SearchQuery._(this.terms, this.options);

  /// Splits [input] on whitespace. Returns null if there is nothing to find.
  static SearchQuery? parse(String input, {int maxTerms = 10}) {
    final terms = input
        .split(RegExp(r'\s+'))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .take(maxTerms)
        .toList(growable: false);
    return terms.isEmpty
        ? null
        : SearchQuery._(terms, [
            for (final t in terms)
              [
                [t],
              ],
          ]);
  }

  final List<String> terms;

  /// For each term, what may match in its place: the term itself, then
  /// any corrections ([withCorrections]). Each is one or more words that
  /// must all match ("deliveryupdate" may be "delivery" and "update").
  final List<List<List<String>>> options;

  /// This search, where a term of [corrections] (by position) may also be
  /// matched by its corrected words.
  SearchQuery withCorrections(Map<int, List<String>> corrections) =>
      SearchQuery._(terms, [
        for (final (i, t) in terms.indexed)
          [
            [t],
            ?corrections[i],
          ],
      ]);

  /// The terms with their corrections in their place.
  String correctedText(Map<int, List<String>> corrections) =>
      [for (final (i, t) in terms.indexed) corrections[i]?.join(' ') ?? t]
          .join(' ');

  /// The trigram index matches substrings of at least 3 characters. Shorter
  /// terms (common for Chinese, e.g. "會議") need the LIKE fallback.
  bool get usesIndex => options.every(
    (term) => term.every((words) => words.every((w) => w.runes.length >= 3)),
  );

  /// FTS5 MATCH expression: each term as a quoted string, so it is always
  /// literal text ("" escapes a quote inside a term).
  String toFtsMatch() => [
    for (final term in options)
      term.length == 1
          ? _ftsAll(term.single)
          : '(${term.map((words) => '(${_ftsAll(words)})').join(' OR ')})',
  ].join(' AND ');

  /// One word for an FTS5 MATCH expression.
  static String ftsWord(String word) => '"${word.replaceAll('"', '""')}"';

  static String _ftsAll(List<String> words) => words.map(ftsWord).join(' AND ');

  /// A WHERE condition (with its arguments) for searching without the
  /// index: each word must be a substring of one of [columns].
  (String, List<Object?>) toLikeCondition(List<String> columns) {
    final args = <Object?>[];
    String word(String w) {
      final pattern = likePattern(w);
      args.addAll(List.filled(columns.length, pattern));
      return '(${columns.map((c) => "$c LIKE ? ESCAPE '\\'").join(' OR ')})';
    }

    String all(List<String> words) => words.map(word).join(' AND ');
    final sql = [
      for (final term in options)
        term.length == 1
            ? all(term.single)
            : '(${term.map((words) => '(${all(words)})').join(' OR ')})',
    ].join(' AND ');
    return (sql, args);
  }

  /// A LIKE pattern for [word] with % and _ escaped (use with ESCAPE '\').
  static String likePattern(String word) =>
      '%${word.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%';
}
