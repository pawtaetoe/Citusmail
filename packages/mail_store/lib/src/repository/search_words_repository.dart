// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;

import '../database/mail_database.dart';
import 'search_query.dart';
import 'search_words.dart';

/// What a typed term was corrected to.
final class SearchCorrection {
  const SearchCorrection(this.term, this.words, {required this.count});

  /// As typed.
  final String term;

  /// One word, or two for words typed together ("deliveryupdate").
  final List<String> words;

  /// How many messages have the word (the rarer one, for two).
  final int count;

  @override
  String toString() => '$term -> ${words.join(' ')} ($count)';
}

/// The words of subjects and sender names, with how many messages have
/// each (see [SearchWords]). Kept current as messages are stored
/// ([addNew]), changed and removed (by triggers); mail stored before they
/// were kept is counted in batches with [addPending].
final class SearchWordsRepository {
  SearchWordsRepository(this._db);

  final MailDatabase _db;

  /// How many messages have [word] (as typed: it is folded first).
  int count(String word) =>
      _db
              .select('SELECT count FROM search_words WHERE word = ?', [
                SearchWords.fold(word),
              ])
              .firstOrNull
              ?.columnAt(0)
          as int? ??
      0;

  /// Every word with its count, for tests.
  Map<String, int> all() => {
    for (final row in _db.select(
      'SELECT word, count FROM search_words ORDER BY word',
    ))
      row['word'] as String: row['count'] as int,
  };

  /// Counts the words of messages stored since the last call, all at
  /// once. Called after storing a batch of messages.
  void addNew() {
    _db
      ..execute(
        'INSERT INTO search_words (word, count) '
        'SELECT j.value, count(*) FROM search_words_new n '
        'JOIN messages m ON m.id = n.message_id, '
        'json_each(search_words_of(m.subject, m.from_name, m.from_address)) j '
        'WHERE true GROUP BY j.value '
        'ON CONFLICT (word) DO UPDATE SET count = count + excluded.count',
      )
      ..execute('DELETE FROM search_words_new');
  }

  /// Whether some stored mail is not counted yet.
  bool get hasPending => _pendingBelow > 0;

  int get _pendingBelow =>
      _db.select('SELECT below FROM search_words_pending').first.columnAt(0)
          as int;

  /// Counts the words of up to [limit] messages stored before the words
  /// were kept, newest first, in one transaction. Returns how many
  /// messages were counted: 0 once all are. Safe to stop between calls.
  int addPending({int limit = 500}) => _db.transaction(() {
    addNew();
    final below = _pendingBelow;
    if (below <= 0) return 0;
    final ids = _db
        .select(
          'SELECT id FROM messages WHERE id <= ? ORDER BY id DESC LIMIT ?',
          [below, limit],
        )
        .map((r) => r.columnAt(0) as int)
        .toList(growable: false);
    if (ids.isNotEmpty) {
      _db.execute(
        'INSERT INTO search_words (word, count) '
        'SELECT j.value, count(*) FROM messages m, '
        'json_each(search_words_of(m.subject, m.from_name, m.from_address)) j '
        'WHERE m.id BETWEEN ? AND ? GROUP BY j.value '
        'ON CONFLICT (word) DO UPDATE SET count = count + excluded.count',
        [ids.last, below],
      );
    }
    _db.execute('UPDATE search_words_pending SET below = ?', [
      ids.length < limit ? 0 : ids.last - 1,
    ]);
    return ids.length;
  });

  /// Words read per typed term, those with the most (and rarest)
  /// trigrams in common first, before the typing mistakes are counted.
  static const _candidates = 300;

  /// The most likely word [term] was meant to be, or null: a word of the
  /// user's mail at most [SearchWords.allowedEdits] mistakes away (the
  /// fewest, then the most used), or two words typed without the space
  /// between them. A term that is itself a word of their mail, or too
  /// short, is not corrected.
  SearchCorrection? correct(String term) {
    if (!SearchWords.isCorrectable(term)) return null;
    final word = SearchWords.fold(term);
    if (count(word) > 0) return null;
    final length = word.runes.length;
    final edits = SearchWords.allowedEdits(length);
    final rows = _db.select(
      'SELECT w.word, w.count FROM search_word_trigrams t '
      'JOIN search_words w ON w.id = t.rowid '
      'WHERE search_word_trigrams MATCH ? AND length(w.word) BETWEEN ? AND ? '
      'ORDER BY t.rank LIMIT ?',
      [
        SearchWords.trigrams(word).map(SearchQuery.ftsWord).join(' OR '),
        length - edits,
        length + edits,
        _candidates,
      ],
    );
    SearchCorrection? best;
    var bestEdits = edits + 1;
    for (final row in rows) {
      final candidate = row['word'] as String;
      final n = row['count'] as int;
      final d = SearchWords.distance(word, candidate, max: edits);
      if (d > edits) continue;
      if (d < bestEdits || (d == bestEdits && n > best!.count)) {
        best = SearchCorrection(term, [candidate], count: n);
        bestEdits = d;
      }
    }
    // Two words typed together count as one mistake.
    final split = _split(term, word);
    if (split != null &&
        (best == null ||
            bestEdits > 1 ||
            (bestEdits == 1 && split.count > best.count))) {
      return split;
    }
    return best;
  }

  /// [word] as two words of the user's mail, the most used pair (by its
  /// rarer word).
  SearchCorrection? _split(String term, String word) {
    final runes = word.runes.toList(growable: false);
    const least = SearchWords.minLength;
    if (runes.length < 2 * least) return null;
    final pairs = [
      for (var i = least; i <= runes.length - least; i++)
        (
          String.fromCharCodes(runes.sublist(0, i)),
          String.fromCharCodes(runes.sublist(i)),
        ),
    ];
    final parts = {
      for (final (a, b) in pairs) ...[a, b],
    }.toList();
    final counts = {
      for (final row in _db.select(
        'SELECT word, count FROM search_words WHERE word IN '
        '(${List.filled(parts.length, '?').join(', ')})',
        parts,
      ))
        row['word'] as String: row['count'] as int,
    };
    SearchCorrection? best;
    for (final (a, b) in pairs) {
      final n = math.min(counts[a] ?? 0, counts[b] ?? 0);
      if (n > 0 && (best == null || n > best.count)) {
        best = SearchCorrection(term, [a, b], count: n);
      }
    }
    return best;
  }
}
