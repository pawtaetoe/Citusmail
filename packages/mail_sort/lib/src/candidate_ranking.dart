// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'mail_model_features.dart';

/// One value a finder found in an email's text, with where it stood:
/// a date that may be the travel date, an amount that may be the total,
/// a code that may be the booking reference.
final class Candidate<T> {
  const Candidate(
    this.value, {
    required this.text,
    required this.start,
    required this.end,
  });

  final T value;

  /// The text it was found in (the subject and body, as the finder read
  /// them).
  final String text;

  /// Where it stands in [text].
  final int start;
  final int end;

  /// Up to [chars] of [text] before it, lower case, accents folded.
  String before([int chars = 48]) => MailModelFeatures.fold(
    text.substring(start - chars < 0 ? 0 : start - chars, start).toLowerCase(),
  );

  /// Up to [chars] of [text] after it, lower case, accents folded.
  String after([int chars = 24]) => MailModelFeatures.fold(
    text
        .substring(end, end + chars > text.length ? text.length : end + chars)
        .toLowerCase(),
  );
}

/// A candidate and how well it fits, higher better.
typedef Ranked<T> = ({Candidate<T> candidate, double score});

/// Picks the best of several candidates for one field ("which date is the
/// travel date?"). Finders hand it what they found; a trained ranker can
/// later replace [KeywordRanker] without changing them.
abstract interface class CandidateRanker {
  /// How well [candidate] fits, higher better.
  double score<T>(Candidate<T> candidate);
}

extension CandidateRanking on CandidateRanker {
  /// [candidates], the best first (ties keep their order).
  List<Ranked<T>> rank<T>(Iterable<Candidate<T>> candidates) {
    final scored =
        [
          for (final (i, c) in candidates.indexed)
            (i: i, candidate: c, score: score(c)),
        ]..sort((a, b) {
          final byScore = b.score.compareTo(a.score);
          return byScore != 0 ? byScore : a.i.compareTo(b.i);
        });
    return [for (final s in scored) (candidate: s.candidate, score: s.score)];
  }

  /// The best of [candidates], or null when there are none.
  Candidate<T>? best<T>(Iterable<Candidate<T>> candidates) =>
      rank(candidates).firstOrNull?.candidate;
}

/// A simple baseline: words just before a candidate count for or against
/// it, and earlier candidates win ties a little.
final class KeywordRanker implements CandidateRanker {
  const KeywordRanker(this.weights, {this.earlier = 0.1});

  /// Words (lower case, accents folded) and how much each counts when it
  /// stands just before a candidate.
  final Map<String, double> weights;

  /// How much being at the very start of the text counts, falling to
  /// nothing at its end.
  final double earlier;

  @override
  double score<T>(Candidate<T> candidate) {
    final before = candidate.before();
    var score = 0.0;
    for (final MapEntry(:key, :value) in weights.entries) {
      if (before.contains(key)) score += value;
    }
    final length = candidate.text.isEmpty ? 1 : candidate.text.length;
    return score + earlier * (1 - candidate.start / length);
  }

  /// Which date is the day of travel: departure words count for it, the
  /// day of booking, of payment or of expiry against it.
  static const travelDate = KeywordRanker({
    'depart': 1,
    'departure': 1,
    'outbound': 1,
    'outward': 1,
    'travel date': 1,
    'date of travel': 1,
    'journey': 0.6,
    'check-in': 0.8,
    'check in': 0.8,
    'pick-up': 0.8,
    'abfahrt': 1,
    'hinfahrt': 1,
    'reisedatum': 1,
    'anreise': 0.8,
    'aller': 0.8,
    'depart le': 1,
    'date du voyage': 1,
    'booked on': -1.5,
    'booking date': -1.5,
    'order date': -1.5,
    'date of issue': -1.5,
    'issued': -1.2,
    'purchased': -1.2,
    'paid': -1,
    'buchungsdatum': -1.5,
    'gebucht am': -1.5,
    'valid until': -1,
    'gultig bis': -1,
    'expires': -1,
    'cancel': -0.8,
    'storn': -0.8,
  });
}
