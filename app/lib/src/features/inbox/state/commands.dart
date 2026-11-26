// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;

import 'package:mail_store/mail_store.dart';

/// How well a typed text matches a command's name: forgiving, so people
/// find things the way they think of them. Words can come in any order,
/// match from their start, ignore case and accents, and survive a small
/// typo ("archve", "setings").
abstract final class CommandMatch {
  /// [text] in lower case without accents ("Café" is "cafe").
  static String fold(String text) {
    final lower = text.toLowerCase();
    final out = StringBuffer();
    for (final rune in lower.runes) {
      // Accents typed as a mark after the letter.
      if (rune >= 0x300 && rune <= 0x36f) continue;
      final c = String.fromCharCode(rune);
      out.write(_plain[c] ?? c);
    }
    return out.toString();
  }

  /// The words of [text], folded.
  static List<String> words(String text) => [
    for (final w in fold(text).split(RegExp('[^a-z0-9]+')))
      if (w.isNotEmpty) w,
  ];

  /// How well [query] matches a command named [title] with other [words]
  /// for it; null if it doesn't. Higher is better. Every word of the
  /// query must match a word of the name or of [words].
  static double? score(
    String query,
    String title, {
    List<String> words = const [],
  }) {
    final typed = CommandMatch.words(query);
    if (typed.isEmpty) return null;
    final name = CommandMatch.words(title);
    final other = [for (final w in words) ...CommandMatch.words(w)];
    var total = 0.0;
    for (final q in typed) {
      final inName = _best(q, name);
      final inOther = _best(q, other, loose: false) * 0.6;
      final best = math.max(inName, inOther);
      if (best == 0) return null;
      total += best;
    }
    // The name starting with what was typed comes first ("arch" for
    // Archive rather than for "Search all mail").
    final folded = fold(title).trim();
    final whole = fold(query).trim();
    if (folded.startsWith(whole)) total += 6;
    if (folded == whole) total += 4;
    return total;
  }

  /// The best match of one typed word [q] among [words] (0 for none).
  static double _best(String q, List<String> words, {bool loose = true}) {
    var best = 0.0;
    for (final w in words) {
      final s = _word(q, w, loose: loose);
      if (s > best) best = s;
    }
    return best;
  }

  /// [loose]: also letters in order, or inside a word (for names only:
  /// in the other words they find too much).
  static double _word(String q, String w, {required bool loose}) {
    if (w == q) return 10;
    if (w.startsWith(q)) return 8 + q.length / w.length;
    // A typo: one letter wrong, missing, extra or swapped, once there
    // are enough letters to tell.
    if (q.length >= 4 && q[0] == w[0] && _prefixDistance(q, w) <= 1) {
      return 5;
    }
    if (!loose) return 0;
    // Letters in order, from the first ("mvt" for "move to").
    if (q.length >= 2 && q[0] == w[0] && _inOrder(q, w)) return 3;
    // Inside a word ("box" in "inbox").
    if (q.length >= 3 && w.contains(q)) return 2;
    return 0;
  }

  /// Whether every letter of [q] is in [w], in order.
  static bool _inOrder(String q, String w) {
    var i = 0;
    for (var j = 0; j < w.length && i < q.length; j++) {
      if (w[j] == q[i]) i++;
    }
    return i == q.length;
  }

  /// The fewest edits (a letter changed, added, removed or two swapped)
  /// that turn [q] into the start of [w].
  static int _prefixDistance(String q, String w) {
    final n = q.length;
    final m = w.length;
    // d[i][j]: edits between q[0..i) and w[0..j).
    final d = List.generate(n + 1, (i) => List.filled(m + 1, 0));
    for (var i = 0; i <= n; i++) {
      d[i][0] = i;
    }
    for (var j = 0; j <= m; j++) {
      d[0][j] = j;
    }
    for (var i = 1; i <= n; i++) {
      for (var j = 1; j <= m; j++) {
        final cost = q[i - 1] == w[j - 1] ? 0 : 1;
        var v = math.min(
          math.min(d[i - 1][j] + 1, d[i][j - 1] + 1),
          d[i - 1][j - 1] + cost,
        );
        if (i > 1 && j > 1 && q[i - 1] == w[j - 2] && q[i - 2] == w[j - 1]) {
          v = math.min(v, d[i - 2][j - 2] + 1);
        }
        d[i][j] = v;
      }
    }
    var best = n;
    for (var j = 0; j <= m; j++) {
      if (d[n][j] < best) best = d[n][j];
    }
    return best;
  }

  /// Letters with accents, and the plain letters they are typed as.
  static final _plain = {
    for (final (from, to) in [
      ('àáâãäåāăą', 'a'),
      ('çćčĉ', 'c'),
      ('ďđð', 'd'),
      ('èéêëēėęě', 'e'),
      ('ğĝ', 'g'),
      ('ìíîïīı', 'i'),
      ('ł', 'l'),
      ('ñńň', 'n'),
      ('òóôõöøōő', 'o'),
      ('řŕ', 'r'),
      ('śšşŝ', 's'),
      ('ťţ', 't'),
      ('ùúûüūůű', 'u'),
      ('ýÿ', 'y'),
      ('źżž', 'z'),
    ])
      for (final c in from.split('')) c: to,
    'æ': 'ae',
    'œ': 'oe',
    'ß': 'ss',
    'þ': 'th',
  };
}

/// The commands used last in the command bar, newest first, kept on this
/// device. Only the commands' ids are kept ("go.inbox", "action.archive"),
/// never anything from an email.
final class CommandHistory {
  CommandHistory(this._store);

  final MailStore _store;

  static const key = 'commandBar.recent';
  static const size = 8;

  List<String> get ids => [
    for (final id in (_store.settings.read(key) ?? '').split(','))
      if (id.isNotEmpty) id,
  ];

  /// [id] was just used: it moves to the front.
  void used(String id) {
    if (id.isEmpty || id.contains(',')) return;
    final list = [id, ...ids.where((i) => i != id)];
    _store.settings.write(key, list.take(size).join(','));
  }
}
