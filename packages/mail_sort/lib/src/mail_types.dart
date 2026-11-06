// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;
import 'dart:typed_data';

import 'mail_type_seeds.dart';
import 'subscriptions.dart';

/// What the app finds in mail, each with its own "Not a ..." correction.
enum MailKind {
  subscription('s'),
  delivery('d'),
  booking('b'),
  account('a'),
  appointment('p');

  const MailKind(this.code);

  /// One letter, in [MailTypeClassifier.toText].
  final String code;

  static MailKind? ofCode(String code) =>
      values.where((k) => k.code == code).firstOrNull;
}

/// What the classifier looks at in one email: the sender, the subject,
/// the start of the text, and whether it came from a mailing list.
final class MailSample {
  const MailSample({
    required this.subject,
    required this.text,
    this.address,
    this.domain,
    this.senderName,
    this.bulk = false,
  });

  /// The sender's address (`notifications@github.com`).
  final String? address;

  /// The sender's registrable domain (`github.com`); else taken from
  /// [address].
  final String? domain;
  final String? senderName;
  final String subject;

  /// The preview, or the whole text once downloaded (only the start is
  /// read).
  final String text;

  /// From a mailing list (`List-Id` or `List-Unsubscribe`).
  final bool bulk;
}

/// Turns a [MailSample] into a few hundred hashed features: subject words
/// and word pairs, the sender's domain, address and name, the first
/// [bodyChars] of the text, and a few flags (an amount, a tracking
/// number, a date, a reply, a mailing list). Hashing keeps the model a
/// fixed size ([buckets]); the same email always gives the same features.
abstract final class MailFeatures {
  static const buckets = 4096;
  static const bodyChars = 2048;

  static final _word = RegExp(r'[\p{L}\p{N}]+', unicode: true);
  static final _digit = RegExp(r'\d');

  /// Very common words, which say nothing about the kind of email.
  static const _stop = {
    'the', 'and', 'for', 'you', 'your', 'our', 'with', 'this', 'that', //
    'are', 'was', 'from', 'have', 'has', 'will', 'can', 'any', 'all', //
    'not', 'but', 'its', 'it', 'is', 'to', 'of', 'in', 'on', 'at', 'by', //
    'or', 'an', 'be', 'we', 'us', 'if', 'as', 'me', 'my', 'do', 'so', //
  };

  static final _tracking = RegExp(
    r'\b(?:1Z[0-9A-Z]{16}|[A-Z]{2}\d{9}[A-Z]{2}|\d{12,22})\b|'
    r'\btracking (?:number|no|id|code)\b',
    caseSensitive: false,
  );

  static final _date = RegExp(
    r'\b(?:\d{1,2}\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\w*'
    r'|(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\w*\s+\d{1,2}'
    r'|\d{1,4}[/.-]\d{1,2}[/.-]\d{2,4})\b',
    caseSensitive: false,
  );

  /// Each feature's bucket and weight (subject and sender count more
  /// than body words), sorted by bucket.
  static List<(int, int)> of(MailSample s) {
    final weights = <int, int>{};
    void add(String feature, int weight) {
      final b = _hash(feature) % buckets;
      final had = weights[b];
      if (had == null || had < weight) weights[b] = weight;
    }

    final address = s.address?.toLowerCase() ?? '';
    final at = address.lastIndexOf('@');
    final domain =
        s.domain?.toLowerCase() ?? (at < 0 ? '' : address.substring(at + 1));
    if (domain.isNotEmpty) add('d:$domain', 4);
    if (at > 0) {
      for (final part in _words(address.substring(0, at))) {
        add('l:$part', 2);
      }
    }
    for (final word in _words(s.senderName ?? '')) {
      add('n:$word', 2);
    }
    final subject = _words(s.subject).toList();
    for (final (i, word) in subject.indexed) {
      add('s:$word', 2);
      if (i > 0) add('b:${subject[i - 1]}_$word', 2);
    }
    final body = s.text.length > bodyChars
        ? s.text.substring(0, bodyChars)
        : s.text;
    for (final word in _words(body)) {
      add('t:$word', 1);
    }
    final all = '${s.subject}\n$body';
    if (SubscriptionFinder.amountIn(all) != null) add('f:amount', 2);
    if (_tracking.hasMatch(all)) add('f:tracking', 2);
    if (_date.hasMatch(all)) add('f:date', 2);
    if (SubscriptionFinder.isReplyOrForward(s.subject)) add('f:reply', 3);
    if (s.bulk) add('f:list', 2);
    return [for (final b in weights.keys.toList()..sort()) (b, weights[b]!)];
  }

  /// Lower-case words of two letters or more, numbers as `#` (an order
  /// number says nothing; that there is one does).
  static Iterable<String> _words(String text) sync* {
    for (final m in _word.allMatches(text.toLowerCase())) {
      final word = m[0]!;
      if (_digit.hasMatch(word)) {
        yield word.length > 4 ? '##' : '#';
      } else if (word.length > 1 && !_stop.contains(word)) {
        yield word;
      }
    }
  }

  /// 32-bit FNV-1a: the same on every device and every run.
  static int _hash(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h;
  }
}

/// Counts of feature weight seen in emails of one kind (`yes`) and not of
/// it (`no`).
final class _Counts {
  _Counts()
    : yes = Float64List(MailFeatures.buckets),
      no = Float64List(MailFeatures.buckets);

  final Float64List yes;
  final Float64List no;
  double yesTotal = 0;
  double noTotal = 0;
  double yesDocs = 0;
  double noDocs = 0;

  void add(List<(int, int)> features, {required bool yes, required double by}) {
    final counts = yes ? this.yes : no;
    var total = 0.0;
    for (final (b, w) in features) {
      final before = counts[b];
      final after = math.max(0.0, before + w * by);
      counts[b] = after;
      total += after - before;
    }
    if (yes) {
      yesTotal = math.max(0, yesTotal + total);
      yesDocs = math.max(0, yesDocs + by);
    } else {
      noTotal = math.max(0, noTotal + total);
      noDocs = math.max(0, noDocs + by);
    }
  }

  bool get isEmpty => yesDocs == 0 && noDocs == 0;
}

/// A small text classifier that learns, on the device, from the user's
/// own corrections: when they say "Not a subscription" (or a delivery, a
/// booking, an account, an appointment), those emails count against that
/// kind, and emails that look like them are no longer picked up.
///
/// Naive Bayes over hashed features ([MailFeatures]), with priors from a
/// small set of made-up example emails that ship with the package (never
/// anyone's mail). Only what the user taught is stored ([toText]); it is
/// a few kilobytes.
///
/// It never adds anything, and with nothing learned for a kind it never
/// takes anything away: [rejects] is false. It only vetoes an email that
/// the user's corrections, and not the examples alone, make clearly look
/// like the ones rejected.
final class MailTypeClassifier {
  MailTypeClassifier._(this._learned);

  /// Nothing learned yet.
  factory MailTypeClassifier() => MailTypeClassifier._({});

  /// From what [toText] stored (nothing learned when it can't be read).
  factory MailTypeClassifier.fromText(String? text) {
    final learned = <MailKind, _Counts>{};
    if (text != null && text.startsWith('$_format;')) {
      try {
        for (final part in text.substring(_format.length + 1).split(';')) {
          if (part.isEmpty) continue;
          final fields = part.split(':');
          final kind = MailKind.ofCode(fields[0]);
          if (kind == null || fields.length < 3) continue;
          final counts = _Counts()
            ..yesDocs = _read(fields[1])
            ..noDocs = _read(fields[2]);
          if (fields.length > 3 && fields[3].isNotEmpty) {
            for (final entry in fields[3].split(',')) {
              final [bucket, yes, no] = entry.split('/');
              final b = int.parse(bucket, radix: 36);
              if (b < 0 || b >= MailFeatures.buckets) continue;
              counts.yes[b] = _read(yes);
              counts.no[b] = _read(no);
              counts.yesTotal += counts.yes[b];
              counts.noTotal += counts.no[b];
            }
          }
          if (!counts.isEmpty) learned[kind] = counts;
        }
      } on Object {
        return MailTypeClassifier();
      }
    }
    return MailTypeClassifier._(learned);
  }

  static const _format = 'v1';

  /// What the user taught, per kind.
  final Map<MailKind, _Counts> _learned;

  /// How much one rejected email counts, against one made-up example.
  static const rejectedWeight = 3.0;

  /// How much one email the user kept counts ("List again").
  static const keptWeight = 2.0;

  /// How much one email the user opened counts: a weak sign.
  static const openedWeight = 0.5;

  /// Smoothing.
  static const _alpha = 0.5;

  /// How sure it must be, in average log-odds per unit of feature
  /// weight: overall, and from the user's corrections alone.
  static const _threshold = 0.35;
  static const _shift = 0.2;

  /// Whether the user taught anything against [kind] (only then can an
  /// email of that kind be vetoed).
  bool hasCorrections(MailKind kind) => (_learned[kind]?.noDocs ?? 0) > 0;

  bool get isEmpty => _learned.values.every((c) => c.isEmpty);

  /// The user said [sample] is not a [kind] (or, with [undo], took that
  /// back).
  void reject(MailKind kind, MailSample sample, {bool undo = false}) =>
      _counts(kind).add(
        MailFeatures.of(sample),
        yes: false,
        by: undo ? -rejectedWeight : rejectedWeight,
      );

  /// The user kept [sample] as a [kind]: [weight] is [keptWeight], or
  /// [openedWeight] when they only opened it.
  void confirm(
    MailKind kind,
    MailSample sample, {
    double weight = keptWeight,
  }) => _counts(kind).add(MailFeatures.of(sample), yes: true, by: weight);

  _Counts _counts(MailKind kind) => _learned[kind] ??= _Counts();

  /// Whether the user's corrections show that [sample] is like emails
  /// they said are not a [kind]: then it is not picked up as one.
  bool rejects(MailKind kind, MailSample sample) {
    if (!hasCorrections(kind)) return false;
    final features = MailFeatures.of(sample);
    final seeded = _score(kind, features, learned: false);
    final full = _score(kind, features, learned: true);
    return full < -_threshold && full - seeded < -_shift;
  }

  /// Whether an item found in [emails] (a subscription, a delivery...)
  /// is left out: more than half of its emails are [rejects]ed.
  bool rejectsItem(MailKind kind, Iterable<MailSample> emails) {
    if (!hasCorrections(kind)) return false;
    var all = 0;
    var rejected = 0;
    for (final email in emails) {
      all++;
      if (rejects(kind, email)) rejected++;
    }
    return rejected * 2 > all;
  }

  /// How much [sample] looks like a [kind] (above zero) or not (below),
  /// in average log-odds per unit of feature weight. For tests and the
  /// evaluation.
  double score(MailKind kind, MailSample sample) =>
      _score(kind, MailFeatures.of(sample), learned: true);

  double _score(
    MailKind kind,
    List<(int, int)> features, {
    required bool learned,
  }) {
    final seed = _seed(kind);
    final user = learned ? _learned[kind] : null;
    const b = MailFeatures.buckets;
    final yesTotal = seed.yesTotal + (user?.yesTotal ?? 0) + _alpha * b;
    final noTotal = seed.noTotal + (user?.noTotal ?? 0) + _alpha * b;
    var sum = 0.0;
    var weight = 0;
    for (final (f, w) in features) {
      final yes = seed.yes[f] + (user?.yes[f] ?? 0) + _alpha;
      final no = seed.no[f] + (user?.no[f] ?? 0) + _alpha;
      sum += w * (math.log(yes / yesTotal) - math.log(no / noTotal));
      weight += w;
    }
    return weight == 0 ? 0 : sum / weight;
  }

  /// Forgets everything learned.
  void clear() => _learned.clear();

  /// What was learned, compactly: per kind, only the buckets that hold
  /// something, in quarter units.
  String toText() {
    final out = StringBuffer(_format);
    for (final MapEntry(key: kind, value: c) in _learned.entries) {
      if (c.isEmpty) continue;
      out
        ..write(';')
        ..write(kind.code)
        ..write(':')
        ..write(_write(c.yesDocs))
        ..write(':')
        ..write(_write(c.noDocs))
        ..write(':');
      var first = true;
      for (var b = 0; b < MailFeatures.buckets; b++) {
        final yes = (c.yes[b] * 4).round();
        final no = (c.no[b] * 4).round();
        if (yes == 0 && no == 0) continue;
        if (!first) out.write(',');
        first = false;
        out.write(
          '${b.toRadixString(36)}/${yes.toRadixString(36)}/'
          '${no.toRadixString(36)}',
        );
      }
    }
    return out.toString();
  }

  static String _write(double v) => (v * 4).round().toRadixString(36);
  static double _read(String s) => int.parse(s, radix: 36) / 4;

  // ------------------------------------------------------------- priors

  static final _seeds = <MailKind, _Counts>{};

  /// Counts from the made-up example emails ([MailTypeSeeds]), made once.
  static _Counts _seed(MailKind kind) => _seeds[kind] ??= () {
    final counts = _Counts();
    for (final example in MailTypeSeeds.all) {
      counts.add(
        MailFeatures.of(example.sample),
        yes: example.kinds.contains(kind),
        by: 1,
      );
    }
    return counts;
  }();
}
