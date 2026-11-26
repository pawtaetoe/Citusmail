// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

/// The words of subjects and sender names that search corrects typos
/// against, and how they are compared.
///
/// Words are folded: lower case, without accents ("Müller" is "muller"),
/// like the search index. Only words in scripts written with spaces are
/// kept: Chinese or Japanese text is searched exactly.
abstract final class SearchWords {
  /// Words shorter than this are not kept, and terms shorter than
  /// [minCorrectable] are never corrected.
  static const minLength = 3;
  static const maxLength = 32;

  /// Typed terms shorter than this are searched exactly ("cat" never
  /// finds "cart").
  static const minCorrectable = 4;

  /// How many typing mistakes a term of [length] characters may have:
  /// one for 4 to 6 characters, two from 7.
  static int allowedEdits(int length) => length < minCorrectable
      ? 0
      : length < 7
      ? 1
      : 2;

  static final _word = RegExp(r'[\p{L}\p{N}]+', unicode: true);
  static final _letter = RegExp(r'\p{L}', unicode: true);
  static final _marks = RegExp(r'\p{M}', unicode: true);

  /// Scripts written without spaces between words: their runs of letters
  /// are not words, so they are left to the exact search.
  static final _noSpaces = RegExp(
    r'[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}'
    r'\p{Script=Hangul}\p{Script=Thai}\p{Script=Lao}\p{Script=Khmer}'
    r'\p{Script=Myanmar}\p{Script=Tibetan}]',
    unicode: true,
  );

  static final Map<int, String> _plain = () {
    const groups = {
      'a': 'àáâãäåāăą',
      'c': 'çćĉċč',
      'd': 'ďđ',
      'e': 'èéêëēĕėęě',
      'g': 'ĝğġģ',
      'h': 'ĥħ',
      'i': 'ìíîïĩīĭįı',
      'j': 'ĵ',
      'k': 'ķ',
      'l': 'ĺļľŀł',
      'n': 'ñńņňŉ',
      'o': 'òóôõöøōŏő',
      'r': 'ŕŗř',
      's': 'śŝşšș',
      't': 'ţťŧț',
      'u': 'ùúûüũūŭůűų',
      'w': 'ŵ',
      'y': 'ýÿŷ',
      'z': 'źżž',
    };
    return {
      for (final MapEntry(key: plain, value: accented) in groups.entries)
        for (final rune in accented.runes) rune: plain,
    };
  }();

  /// [text] in lower case, without accents.
  static String fold(String text) {
    final lower = text.toLowerCase().replaceAll(_marks, '');
    if (lower.runes.every((r) => r < 0xc0)) return lower;
    final out = StringBuffer();
    for (final rune in lower.runes) {
      final plain = _plain[rune];
      if (plain != null) {
        out.write(plain);
      } else {
        out.writeCharCode(rune);
      }
    }
    return out.toString();
  }

  /// Whether a folded [word] can be kept and corrected against.
  static bool isWord(String word) {
    final length = word.runes.length;
    return length >= minLength &&
        length <= maxLength &&
        _letter.hasMatch(word) &&
        !_noSpaces.hasMatch(word);
  }

  /// The distinct words of [texts] (a subject, a sender's name and
  /// address), folded.
  static Set<String> of(Iterable<String?> texts) => {
    for (final text in texts)
      if (text != null && text.isNotEmpty)
        for (final match in _word.allMatches(fold(text)))
          if (isWord(match[0]!)) match[0]!,
  };

  /// [of] as a JSON array, for the SQL function `search_words_of`.
  static String ofAsJson(Iterable<String?> texts) =>
      jsonEncode(of(texts).toList(growable: false));

  /// Whether a typed [term] may be corrected: one word of a script with
  /// spaces, long enough, folded.
  static bool isCorrectable(String term) {
    final folded = fold(term);
    final match = _word.matchAsPrefix(folded);
    return match != null &&
        match.end == folded.length &&
        folded.runes.length >= minCorrectable &&
        isWord(folded);
  }

  /// The trigrams of a folded [word], with its start and end marked, so
  /// the first and last letters count too: "cat" is `^^c ^ca cat at$ t$$`.
  static Set<String> trigrams(String word) {
    final runes = [0x5e, 0x5e, ...word.runes, 0x24, 0x24];
    return {
      for (var i = 0; i + 3 <= runes.length; i++)
        String.fromCharCodes(runes, i, i + 3),
    };
  }

  /// The number of typing mistakes between [a] and [b]: a letter missing,
  /// extra or wrong, or two letters swapped ("recieve" and "receive" are
  /// one apart). Stops counting above [max] (returns max + 1).
  static int distance(String a, String b, {int max = 2}) {
    final s = a.runes.toList(growable: false);
    final t = b.runes.toList(growable: false);
    if ((s.length - t.length).abs() > max) return max + 1;
    // Three rows of the table are enough for swaps.
    var before = List<int>.filled(t.length + 1, 0);
    var previous = List<int>.generate(t.length + 1, (j) => j);
    var current = List<int>.filled(t.length + 1, 0);
    for (var i = 1; i <= s.length; i++) {
      current[0] = i;
      var smallest = i;
      for (var j = 1; j <= t.length; j++) {
        final cost = s[i - 1] == t[j - 1] ? 0 : 1;
        var d = previous[j] + 1;
        if (current[j - 1] + 1 < d) d = current[j - 1] + 1;
        if (previous[j - 1] + cost < d) d = previous[j - 1] + cost;
        if (i > 1 &&
            j > 1 &&
            s[i - 1] == t[j - 2] &&
            s[i - 2] == t[j - 1] &&
            before[j - 2] + 1 < d) {
          d = before[j - 2] + 1;
        }
        current[j] = d;
        if (d < smallest) smallest = d;
      }
      if (smallest > max) return max + 1;
      final spare = before;
      before = previous;
      previous = current;
      current = spare;
    }
    final d = previous[t.length];
    return d > max ? max + 1 : d;
  }
}
