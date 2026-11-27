// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;
import 'dart:typed_data';

import 'mail_types.dart' show MailSample;
import 'subscriptions.dart' show SubscriptionFinder;
import 'travel_places.dart';

/// One email as [MailModel] reads it: hashed features, each with a value,
/// scaled to length one. The same email always gives the same vector.
final class MailFeatureVector {
  MailFeatureVector._(this.buckets, this.values);

  /// The features' buckets, ascending, each once.
  final Int32List buckets;

  /// Each bucket's value; the squares add up to one (or nothing at all).
  final Float64List values;

  int get length => buckets.length;
}

/// The features of [MailModel] (version [version]): what it reads in an
/// email, turned into numbers on the device.
///
/// - Words and word pairs of the subject and of the first [bodyChars] of
///   the text, lower case, accents folded, numbers by their shape.
/// - The sender: domain, its labels, the address's words and the name's.
/// - Structure: how many dates, times, amounts, known airport codes (and
///   codes alone in a table cell), station names, booking-reference-like
///   codes (and ones after a label), flight and train numbers, table
///   cells and "label: value" lines it has, and cue words ("e-ticket",
///   "invoice", "redemption", "unsubscribe" and their German and French
///   kin).
/// - Flags: from a mailing list, a reply or forward.
///
/// Read in one pass over the text, without regular expressions, so that
/// thousands of emails take well under a second. Each feature's name is
/// hashed (32-bit FNV-1a) into one of [buckets]. Bump [version] whenever
/// anything here changes: the trained weights and the user's stored
/// adjustments are tied to it.
abstract final class MailModelFeatures {
  /// Changes whenever the features do.
  static const version = 2;

  static const bits = 14;
  static const buckets = 1 << bits;

  /// How much of the text is read.
  static const bodyChars = 2000;

  /// The features of [sample].
  static MailFeatureVector of(MailSample sample) {
    final acc = <int, double>{};
    final seen = <int>{};
    _extract(sample, (a, [b = '', c = '', d = '']) {
      // The hash of a + b + c + d, without joining them.
      final h = _fnv(_fnv(_fnv(_fnv(_fnvStart, a), b), c), d);
      if (!seen.add(h)) return;
      final bucket = h & (buckets - 1);
      acc[bucket] = (acc[bucket] ?? 0) + 1;
    });
    final keys = acc.keys.toList()..sort();
    final out = Int32List(keys.length);
    final values = Float64List(keys.length);
    var norm = 0.0;
    for (final (i, k) in keys.indexed) {
      out[i] = k;
      final v = acc[k]!;
      values[i] = v;
      norm += v * v;
    }
    if (norm > 0) {
      final scale = 1 / math.sqrt(norm);
      for (var i = 0; i < values.length; i++) {
        values[i] *= scale;
      }
    }
    return MailFeatureVector._(out, values);
  }

  /// The features of [sample] by name, before hashing: for tests and to
  /// see what the model reads.
  static Set<String> named(MailSample sample) {
    final out = <String>{};
    _extract(sample, (a, [b = '', c = '', d = '']) => out.add('$a$b$c$d'));
    return out;
  }

  /// 32-bit FNV-1a: the same on every device and every run.
  static int hash(String s) => _fnv(_fnvStart, s);

  static const _fnvStart = 0x811c9dc5;

  static int _fnv(int h, String s) {
    for (var i = 0; i < s.length; i++) {
      h ^= s.codeUnitAt(i);
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h;
  }

  /// [s] in lower case with accents taken off (`ÖBB` → `obb`,
  /// `Réservation` → `reservation`).
  static String fold(String s) {
    final lower = s.toLowerCase();
    var plain = true;
    for (var i = 0; i < lower.length; i++) {
      if (lower.codeUnitAt(i) > 127) {
        plain = false;
        break;
      }
    }
    if (plain) return lower;
    final out = StringBuffer();
    for (var i = 0; i < lower.length; i++) {
      final c = lower.codeUnitAt(i);
      out.write(c > 127 ? (_folds[c] ?? String.fromCharCode(c)) : lower[i]);
    }
    return out.toString();
  }

  // ------------------------------------------------------------- reading

  /// Calls [once] with each feature's name, in up to four parts to be
  /// joined; the same name may come more than once.
  static void _extract(MailSample s, _Add once) {
    // The sender.
    final address = s.address?.toLowerCase() ?? '';
    final at = address.lastIndexOf('@');
    final domain =
        (s.domain?.toLowerCase() ?? (at < 0 ? '' : address.substring(at + 1)))
            .trim();
    if (domain.isNotEmpty) {
      once('d:', domain);
      final labels = domain.split('.');
      once('dt:', labels.last);
      for (final label in labels.take(labels.length - 1)) {
        if (label.length > 1 && label != 'www' && label != 'mail') {
          once('dl:', fold(label));
        }
      }
    }
    if (at > 0) {
      for (final t in _scan(address.substring(0, at))) {
        if (t.lower.length > 1) once('l:', t.word);
      }
    }
    for (final t in _scan(s.senderName ?? '')) {
      if (t.lower.length > 1) once('n:', t.word);
    }

    // Words.
    final body = s.text.length > bodyChars
        ? s.text.substring(0, bodyChars)
        : s.text;
    final subject = _scan(s.subject);
    final text = _scan(body);
    _words('s:', 'sb:', subject, once);
    _words('t:', 'tb:', text, once);

    // Structure, over the subject and the text.
    final counts = <String, int>{};
    void count(String name, [int n = 1]) =>
        counts[name] = (counts[name] ?? 0) + n;
    final cues = <String>{};
    _structure(s.subject, subject, count, cues);
    _structure(body, text, count, cues);
    _lines(body, count);
    for (final MapEntry(key: name, value: n) in counts.entries) {
      if (n <= 0) continue;
      once('c:', name);
      once('c:', name, n >= 4 ? ':4+' : ':$n');
    }
    for (final cue in cues) {
      once('k:', cue);
    }

    // Flags.
    if (s.bulk) once('f:bulk');
    if (SubscriptionFinder.isReplyOrForward(s.subject)) once('f:reply');
    if (subject.isEmpty) once('f:no-subject');
    if (text.isEmpty) once('f:no-text');
    once('f:bias');
  }

  /// Unigrams (without very common words) and word pairs (with them).
  static void _words(String one, String two, List<_Token> tokens, _Add once) {
    for (var i = 0; i < tokens.length; i++) {
      final w = tokens[i].word;
      if (w.length > 1 && !_stop.contains(w)) once(one, w);
      if (i > 0) once(two, tokens[i - 1].word, '_', w);
    }
  }

  static void _structure(
    String text,
    List<_Token> tokens,
    void Function(String, [int]) count,
    Set<String> cues,
  ) {
    final airports = <String>{};
    _Token? lastAirport;
    var sinceAirport = 99;
    for (var i = 0; i < tokens.length; i++) {
      final t = tokens[i];
      final next = i + 1 < tokens.length ? tokens[i + 1] : null;
      final prev = i > 0 ? tokens[i - 1] : null;

      // Times: 08:30, 8:30pm, 14h30, 7 pm.
      if (t.number && t.lower.length <= 2 && _value(t) <= 23) {
        if (_joined(text, t, next, ':') &&
            next!.lower.length >= 2 &&
            _digits(next.lower) == 2) {
          count('time');
        } else if (next != null &&
            next.start - t.end <= 2 &&
            (next.lower == 'am' || next.lower == 'pm') &&
            _value(t) <= 12) {
          count('time');
        }
      } else if (t.mixed && _clock(t.lower) && !_joined(text, prev, t, ':')) {
        count('time');
      }

      // Dates: 12.12.2026, 2026-12-12, 12 Dec, Dec 12, 12. Dezember.
      if (t.number) {
        final n = t.lower.length;
        final after = i + 2 < tokens.length ? tokens[i + 2] : null;
        if (n <= 2 &&
            _joined(text, t, next, '/.') &&
            next!.number &&
            next.lower.length <= 2 &&
            _joined(text, next, after, '/.') &&
            after!.number &&
            after.lower.length >= 2 &&
            after.lower.length <= 4) {
          count('date');
        } else if (n == 4 &&
            _joined(text, t, next, '-') &&
            next!.number &&
            _joined(text, next, after, '-') &&
            after!.number) {
          count('date');
        } else if (n <= 2 &&
            next != null &&
            next.start - t.end <= 3 &&
            _months.contains(next.lower)) {
          count('date');
        } else if (n <= 2 &&
            prev != null &&
            t.start - prev.end <= 2 &&
            _months.contains(prev.lower) &&
            !(i >= 2 &&
                tokens[i - 2].number &&
                prev.start - tokens[i - 2].end <= 3)) {
          count('date');
        }
      } else if (t.mixed &&
          _ordinal(t.lower) &&
          next != null &&
          _months.contains(next.lower)) {
        count('date');
      }

      // Amounts: a currency sign or code next to a number ("1,203.50" is
      // one number).
      if (t.number &&
          !(prev != null && prev.number && _joined(text, prev, t, '.,'))) {
        var j = i;
        while (j + 1 < tokens.length &&
            tokens[j + 1].number &&
            _joined(text, tokens[j], tokens[j + 1], '.,')) {
          j++;
        }
        final last = tokens[j];
        final after = j + 1 < tokens.length ? tokens[j + 1] : null;
        if (_sign(text, t.start - 1, -1) ||
            _sign(text, last.end, 1) ||
            (prev != null &&
                t.start - prev.end <= 2 &&
                _currencyCodes.contains(prev.lower)) ||
            (after != null &&
                after.start - last.end <= 2 &&
                _currencyCodes.contains(after.lower))) {
          count('amount');
        }
        if (_at(text, last.end) == 0x25 ||
            (_at(text, last.end) == 0x20 && _at(text, last.end + 1) == 0x25)) {
          cues.add('percent');
        }
      }

      // Airport codes, alone in a cell, and routes between two.
      if (t.upper && t.lower.length == 3 && !t.digit) {
        final code = text.substring(t.start, t.end);
        if (TravelPlaces.isAirport(code)) {
          airports.add(code);
          if (_alone(text, t.start, t.end)) count('airport-cell');
          if (lastAirport != null &&
              lastAirport.lower != t.lower &&
              sinceAirport <= 2 &&
              t.start - lastAirport.end <= 12) {
            count('route');
          }
          lastAirport = t;
          sinceAirport = 0;
        }
      }
      sinceAirport++;

      // Stations.
      final pair = prev != null && _pairFirsts.contains(prev.lower)
          ? '${prev.lower}_${t.lower}'
          : null;
      if (_stations.contains(t.lower) || _stationPairs.contains(pair)) {
        count('station');
      }

      // Codes like a record locator (ZK8P4Q), and codes after a label.
      if (_refLike(t)) count('ref');
      if (_isLabel(t.lower)) {
        for (var j = i + 1; j < tokens.length && j <= i + 4; j++) {
          final c = tokens[j];
          if (_refLike(c) ||
              (c.upper &&
                  !c.digit &&
                  c.lower.length >= 6 &&
                  c.lower.length <= 10) ||
              (c.number && c.lower.length >= 6)) {
            count('labelled-ref');
            break;
          }
          if (!_labelFiller.contains(c.lower)) break;
        }
      }

      // Flight numbers (SQ 636, LH1236) and train numbers (ICE 514).
      if (t.upper && t.lower.length == 2 && _airlineLike(t.lower)) {
        if (next != null &&
            next.number &&
            next.start - t.end <= 1 &&
            next.lower.length >= 2 &&
            next.lower.length <= 4) {
          count('flight-no');
        }
      } else if (t.upper && t.mixed && _flightCode(t.lower)) {
        count('flight-no');
      }
      if (_trains.contains(t.lower) &&
          next != null &&
          next.number &&
          next.start - t.end <= 1 &&
          next.lower.length >= 2 &&
          next.lower.length <= 5) {
        count('train-no');
      }

      // Cue words and pairs of them.
      if (_cueWords[t.lower] case final cue?) cues.add(cue);
      if (t.lower.length >= 5) {
        if (_cuePrefixes[t.lower.codeUnitAt(0)] case final prefixes?) {
          for (final (prefix, cue) in prefixes) {
            if (t.lower.startsWith(prefix)) cues.add(cue);
          }
        }
      }
      if (_cuePairs[pair] case final cue?) cues.add(cue);
    }
    count('airport', airports.length);
  }

  /// Lines of the text: how many, how many short, table cells, and
  /// "label: value" lines.
  static void _lines(String body, void Function(String, [int]) count) {
    var lines = 0;
    var short = 0;
    var start = 0;
    while (start <= body.length) {
      var end = body.indexOf('\n', start);
      if (end < 0) end = body.length;
      var a = start;
      var b = end;
      while (a < b && _isSpace(body.codeUnitAt(a))) {
        a++;
      }
      while (b > a && _isSpace(body.codeUnitAt(b - 1))) {
        b--;
      }
      if (b > a) {
        lines++;
        if (b - a <= 12) short++;
        var cell = false;
        var colon = -1;
        var label = true;
        for (var i = a; i < b; i++) {
          final c = body.codeUnitAt(i);
          if (c == 0x7c || c == 0x09) cell = true;
          if (colon < 0) {
            if (c == 0x3a) {
              colon = i;
            } else if (!(_isWordChar(c) ||
                c == 0x20 ||
                c == 0x2e ||
                c == 0x2f ||
                c == 0x28 ||
                c == 0x29 ||
                c == 0x2d)) {
              label = false;
            }
          }
        }
        if (cell) count('cells');
        if (label && colon - a >= 2 && colon - a <= 30 && colon + 1 < b) {
          count('label-value');
        }
      }
      start = end + 1;
    }
    count('lines', lines ~/ 8);
    if (lines >= 6 && short * 2 >= lines) count('short-lines');
  }

  static bool _joined(String text, _Token? a, _Token? b, String seps) =>
      a != null &&
      b != null &&
      b.start == a.end + 1 &&
      seps.contains(text[a.end]);

  static int _at(String text, int k) =>
      k >= 0 && k < text.length ? text.codeUnitAt(k) : 0;

  /// A currency sign at [k], or one space on (by [step]).
  static bool _sign(String text, int k, int step) =>
      _currencySigns.contains(_at(text, k)) ||
      (_at(text, k) == 0x20 && _currencySigns.contains(_at(text, k + step)));

  static bool _alone(String text, int start, int end) {
    bool blank(int c) => c == 0x20 || c == 0x09;
    var i = start - 1;
    while (i >= 0 && blank(text.codeUnitAt(i))) {
      i--;
    }
    if (i >= 0 && text.codeUnitAt(i) != 0x0a && text.codeUnitAt(i) != 0x7c) {
      return false;
    }
    var j = end;
    while (j < text.length && blank(text.codeUnitAt(j))) {
      j++;
    }
    return j >= text.length ||
        text.codeUnitAt(j) == 0x0a ||
        text.codeUnitAt(j) == 0x7c;
  }

  static int _value(_Token t) => int.tryParse(t.lower) ?? 99;

  static int _digits(String s) {
    var n = 0;
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c >= 0x30 && c <= 0x39) n++;
    }
    return n;
  }

  /// 14h30, 7pm.
  static bool _clock(String s) {
    final h = s.indexOf('h');
    if (h > 0 && h <= 2 && s.length == h + 3) {
      return _digits(s) == s.length - 1;
    }
    if (s.endsWith('am') || s.endsWith('pm')) {
      final n = s.substring(0, s.length - 2);
      return n.isNotEmpty && n.length <= 2 && _digits(n) == n.length;
    }
    return false;
  }

  /// 1st, 2nd, 3rd, 12th, 1er.
  static bool _ordinal(String s) {
    for (final suffix in const ['st', 'nd', 'rd', 'th', 'er']) {
      if (s.endsWith(suffix)) {
        final n = s.substring(0, s.length - 2);
        return n.isNotEmpty && n.length <= 2 && _digits(n) == n.length;
      }
    }
    return false;
  }

  static bool _refLike(_Token t) =>
      t.upper &&
      t.mixed &&
      t.lower.length >= 5 &&
      t.lower.length <= 12 &&
      !_clock(t.lower);

  static bool _airlineLike(String s) {
    bool letter(int c) => c >= 0x61 && c <= 0x7a;
    bool digit(int c) => c >= 0x30 && c <= 0x39;
    final a = s.codeUnitAt(0);
    final b = s.codeUnitAt(1);
    return (letter(a) || digit(a)) &&
        (letter(b) || digit(b)) &&
        !(digit(a) && digit(b));
  }

  /// SQ636, LH1236, U21234.
  static bool _flightCode(String s) {
    if (s.length < 4 || s.length > 6) return false;
    if (!_airlineLike(s.substring(0, 2))) return false;
    return _digits(s.substring(2)) == s.length - 2;
  }

  static bool _isLabel(String w) =>
      _labels.contains(w) ||
      (w.length > 6 &&
          _labelHeads.contains(w.codeUnitAt(0)) &&
          (w.startsWith('buchung') ||
              w.startsWith('auftrag') ||
              w.startsWith('reservier') ||
              w.startsWith('bestell') ||
              w.startsWith('ticket') ||
              w.startsWith('confirmation') ||
              w.startsWith('reservation')));

  // ---------------------------------------------------------- scanning

  static bool _isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0d;

  /// Letters and digits, of any script (by ranges, the same everywhere).
  static bool _isWordChar(int c) {
    if (c < 0x80) {
      return (c >= 0x30 && c <= 0x39) ||
          (c >= 0x41 && c <= 0x5a) ||
          (c >= 0x61 && c <= 0x7a);
    }
    if (c < 0xc0) return c == 0xaa || c == 0xb5 || c == 0xba;
    if (c == 0xd7 || c == 0xf7) return false;
    return c <= 0x24f ||
        (c >= 0x370 && c <= 0x52f) ||
        (c >= 0x590 && c <= 0x6ff) ||
        (c >= 0x900 && c <= 0xe7f) ||
        (c >= 0x1e00 && c <= 0x1fff) ||
        (c >= 0x3040 && c <= 0x30ff) ||
        (c >= 0x3400 && c <= 0x9fff) ||
        (c >= 0xac00 && c <= 0xd7af);
  }

  /// The words and numbers of [text], with where they stand.
  static List<_Token> _scan(String text) {
    final out = <_Token>[];
    var i = 0;
    final n = text.length;
    while (i < n) {
      if (!_isWordChar(text.codeUnitAt(i))) {
        i++;
        continue;
      }
      final start = i;
      var letters = 0;
      var digits = 0;
      var lower = 0;
      var plain = true;
      while (i < n) {
        final c = text.codeUnitAt(i);
        if (_isWordChar(c)) {
          if (c >= 0x30 && c <= 0x39) {
            digits++;
          } else {
            letters++;
            if (c >= 0x61 && c <= 0x7a) {
              lower++;
            } else if (c >= 0x80) {
              plain = false;
              if (c >= 0xdf && c <= 0xff) lower++;
            }
          }
          i++;
        } else if ((c == 0x27 || c == 0x2019) &&
            i + 1 < n &&
            letters > 0 &&
            _isWordChar(text.codeUnitAt(i + 1))) {
          // you're, King's
          if (c > 0x7f) plain = false;
          i++;
        } else {
          break;
        }
      }
      final word = text.substring(start, i);
      out.add(
        _Token(
          start,
          i,
          plain && lower == letters ? word : fold(word),
          letters: letters,
          digits: digits,
          upper: lower == 0,
        ),
      );
    }
    return out;
  }

  static const _folds = {
    0xe0: 'a', 0xe1: 'a', 0xe2: 'a', 0xe4: 'a', 0xe3: 'a', 0xe5: 'a', //
    0xe7: 'c', 0xe8: 'e', 0xe9: 'e', 0xea: 'e', 0xeb: 'e', 0xec: 'i', //
    0xed: 'i', 0xee: 'i', 0xef: 'i', 0xf1: 'n', 0xf2: 'o', 0xf3: 'o', //
    0xf4: 'o', 0xf6: 'o', 0xf5: 'o', 0xf8: 'o', 0xf9: 'u', 0xfa: 'u', //
    0xfb: 'u', 0xfc: 'u', 0xff: 'y', 0xdf: 'ss', 0x2019: "'", //
  };

  /// Very common words, in English, German and French.
  static const _stop = {
    'the', 'and', 'for', 'you', 'your', 'our', 'with', 'this', 'that', //
    'are', 'was', 'from', 'have', 'has', 'will', 'can', 'any', 'all', //
    'not', 'but', 'its', 'it', 'is', 'to', 'of', 'in', 'on', 'at', 'by', //
    'or', 'an', 'be', 'we', 'us', 'if', 'as', 'me', 'my', 'do', 'so', //
    'der', 'die', 'das', 'und', 'ihre', 'ihr', 'sie', 'wir', 'mit', //
    'fur', 'den', 'dem', 'des', 'ein', 'eine', 'ist', 'zu', 'im', 'auf', //
    'le', 'la', 'les', 'de', 'du', 'et', 'votre', 'vos', 'pour', //
    'un', 'une', 'est', 'au', 'aux', 'en', 'nous', 'vous', 'sur', //
  };

  // ----------------------------------------------------------- structure

  static const _months = {
    'jan', 'january', 'januar', 'janvier', 'janv', 'feb', 'february', //
    'februar', 'fevrier', 'fev', 'mar', 'march', 'marz', 'mrz', 'mars', //
    'apr', 'april', 'avril', 'avr', 'may', 'mai', 'jun', 'june', 'juni', //
    'juin', 'jul', 'july', 'juli', 'juillet', 'juil', 'aug', 'august', //
    'aout', 'sep', 'sept', 'september', 'septembre', 'oct', 'october', //
    'okt', 'oktober', 'octobre', 'nov', 'november', 'novembre', 'dec', //
    'december', 'dez', 'dezember', 'decembre', //
  };

  static const _currencySigns = {0x24, 0x20ac, 0xa3, 0xa5, 0x20b9};

  static const _currencyCodes = {
    'usd', 'eur', 'gbp', 'sgd', 'chf', 'aud', 'cad', 'jpy', 'rm', 'nzd', //
    'hkd', 'sek', 'nok', 'dkk', //
  };

  static const _stations = {
    'hbf', 'hauptbahnhof', 'bahnhof', 'bhf', 'central', 'centraal', //
    'centrale', 'gare', 'station', 'stazione', 'estacion', 'euston', //
    'paddington', 'waterloo', 'piccadilly', 'westbahnhof', 'midi', 'zuid', //
    'montparnasse', 'pancras', 'hb', 'ostbahnhof', 'sudkreuz', 'zob', //
  };

  static const _stationPairs = {'kings_cross', "king's_cross", 'part_dieu'};

  static const _labels = {
    'booking', 'reservation', 'confirmation', 'reference', 'ref', 'pnr', //
    'locator', 'dossier', 'order', 'itinerary', 'buchungscode', //
    'buchungsnummer', 'ticketcode', 'auftragsnummer', 'code', //
  };

  /// The first letters of the labels [_isLabel] takes by their start.
  static final _labelHeads = {for (final c in 'abrtc'.codeUnits) c};

  /// The first words of [_stationPairs] and [_cuePairs].
  static final _pairFirsts = {
    for (final pair in [..._stationPairs, ..._cuePairs.keys])
      pair.substring(0, pair.indexOf('_')),
  };

  static const _labelFiller = {
    'no', 'number', 'nr', 'nummer', 'code', 'id', 'reference', 'ref', //
    'de', 'reservation', 'is', 'votre', 'ihre', 'your', 'locator', //
  };

  static const _trains = {
    'ice', 'ic', 'ec', 'rj', 'rjx', 'tgv', 'inoui', 'ouigo', 'ter', //
    'nightjet', 'nj', 'eurostar', 'railjet', 'westbahn', 'frecciarossa', //
    'ave', 'ire', 're', 'rex', 'flx', 'train', 'zug', //
  };

  /// Cue words by what they hint at, lower case with accents folded.
  static const _cueWords = {
    // Paid with miles or points.
    'redemption': 'redemption', 'award': 'redemption', //
    'avios': 'redemption', 'miles': 'redemption', 'meilen': 'redemption', //
    'krisflyer': 'redemption', 'skymiles': 'redemption', //
    'aadvantage': 'redemption', 'pramienflug': 'redemption', //
    'mileageplus': 'redemption', 'redeemed': 'redemption', //
    // Tickets.
    'eticket': 'e-ticket', 'etickets': 'e-ticket', //
    'ticketnummer': 'e-ticket', 'handyticket': 'e-ticket', //
    'bordkarte': 'e-ticket', 'ticketcode': 'e-ticket', //
    'fahrkarte': 'e-ticket', 'billet': 'e-ticket', 'billets': 'e-ticket', //
    'ebillet': 'e-ticket', 'tickets': 'e-ticket', 'ticket': 'e-ticket', //
    // Bills.
    'invoice': 'invoice', 'rechnung': 'invoice', 'facture': 'invoice', //
    'receipt': 'invoice', 'quittung': 'invoice', 'beleg': 'invoice', //
    'recu': 'invoice', 'ebill': 'invoice', 'bill': 'invoice', //
    'abschlag': 'invoice', 'abschlagsrechnung': 'invoice', //
    // Promotions and lists.
    'sale': 'marketing', 'deal': 'marketing', 'deals': 'marketing', //
    'angebot': 'marketing', 'angebote': 'marketing', //
    'rabatt': 'marketing', 'promo': 'marketing', 'soldes': 'marketing', //
    'offer': 'marketing', 'offers': 'marketing', 'discount': 'marketing', //
    'newsletter': 'unsubscribe', 'unsubscribe': 'unsubscribe', //
    'abmelden': 'unsubscribe', 'abbestellen': 'unsubscribe', //
    'preferences': 'unsubscribe', //
    // Journeys.
    'departure': 'travel', 'departs': 'travel', 'depart': 'travel', //
    'arrival': 'travel', 'arrives': 'travel', 'arrive': 'travel', //
    'abfahrt': 'travel', 'ankunft': 'travel', 'platform': 'travel', //
    'gleis': 'travel', 'voie': 'travel', 'coach': 'travel', //
    'wagen': 'travel', 'seat': 'travel', 'sitzplatz': 'travel', //
    'platz': 'travel', 'voiture': 'travel', 'place': 'travel', //
    'outward': 'travel', 'outbound': 'travel', 'hinfahrt': 'travel', //
    'ruckfahrt': 'travel', 'aller': 'travel', 'retour': 'travel', //
    'journey': 'journey', 'reise': 'journey', 'voyage': 'journey', //
    'trajet': 'journey', 'verbindung': 'journey', 'fahrt': 'journey', //
    'railcard': 'journey', 'tarif': 'journey', 'sparschiene': 'journey', //
    'flight': 'flight', 'flights': 'flight', 'flug': 'flight', //
    'vol': 'flight', 'terminal': 'flight', 'gate': 'flight', //
    'baggage': 'flight', 'gepack': 'flight', 'bagage': 'flight', //
    'cabin': 'flight', 'economy': 'flight', 'airline': 'flight', //
    // Stays.
    'nights': 'stay', 'night': 'stay', 'nachte': 'stay', 'nacht': 'stay', //
    'nuit': 'stay', 'nuits': 'stay', 'room': 'stay', 'rooms': 'stay', //
    'zimmer': 'stay', 'chambre': 'stay', 'guests': 'stay', //
    'gaste': 'stay', 'hotel': 'stay', 'host': 'stay', 'anreise': 'stay', //
    'abreise': 'stay', 'checkin': 'stay', 'checkout': 'stay', //
    // Tables, events, cars.
    'tisch': 'table', 'covers': 'table', 'personen': 'table', //
    'venue': 'venue', 'row': 'venue', 'section': 'venue', 'stalls': 'venue', //
    'vehicle': 'car', 'fahrzeug': 'car', 'vehicule': 'car', //
    'mileage': 'car', 'driver': 'car', 'abholung': 'car', //
    'ruckgabe': 'car', 'pickup': 'car', 'dropoff': 'car', //
    // Deliveries.
    'tracking': 'delivery', 'parcel': 'delivery', 'paket': 'delivery', //
    'colis': 'delivery', 'shipped': 'delivery', 'versandt': 'delivery', //
    'versendet': 'delivery', 'dispatched': 'delivery', //
    'zugestellt': 'delivery', 'livre': 'delivery', 'courier': 'delivery', //
    'delivered': 'delivery', 'package': 'delivery', 'sendung': 'delivery', //
    // Accounts.
    'password': 'account', 'passwort': 'account', 'verify': 'account', //
    'verification': 'account', 'signin': 'account', 'login': 'account', //
    // Appointments.
    'appointment': 'appointment', 'termin': 'appointment', //
    'dentist': 'appointment', 'zahnarzt': 'appointment', //
    'clinic': 'appointment', 'praxis': 'appointment', //
    'surgery': 'appointment', 'consultation': 'appointment', //
    'treatment': 'appointment', 'stylist': 'appointment', //
    'hygienist': 'appointment', //
    // Other.
    'visa': 'permit', 'eta': 'permit', 'esta': 'permit', 'etias': 'permit', //
    'evisa': 'permit', 'permit': 'permit', //
    'statement': 'statement', 'kontoauszug': 'statement', //
    'releve': 'statement', 'balance': 'statement', //
    'subscription': 'renewal', 'abonnement': 'renewal', 'abo': 'renewal', //
    'membership': 'renewal', 'jahreskarte': 'renewal', //
    'booked': 'booked', 'gebucht': 'booked', 'reserve': 'booked', //
    'reserved': 'booked', //
    'changed': 'change', 'geandert': 'change', 'anderung': 'change', //
  };

  static final _cuePrefixes = <int, List<(String, String)>>{
    for (final (prefix, _) in _prefixCues)
      prefix.codeUnitAt(0): [
        for (final (p, c) in _prefixCues)
          if (p.codeUnitAt(0) == prefix.codeUnitAt(0)) (p, c),
      ],
  };

  static const _prefixCues = [
    ('confirm', 'confirmed'),
    ('bestatig', 'confirmed'),
    ('cancel', 'cancel'),
    ('storn', 'cancel'),
    ('annul', 'cancel'),
    ('renew', 'renewal'),
    ('verlanger', 'renewal'),
    ('renouvel', 'renewal'),
    ('modifi', 'change'),
    ('unsubscrib', 'unsubscribe'),
    ('desabonn', 'unsubscribe'),
    ('desinscri', 'unsubscribe'),
    ('verifi', 'account'),
    ('anmeld', 'account'),
    ('terminbest', 'appointment'),
    ('sendungs', 'delivery'),
    ('reservier', 'booked'),
    ('buchungs', 'booked'),
  ];

  static const _cuePairs = {
    'e_ticket': 'e-ticket', 'e_tickets': 'e-ticket', //
    'ticket_number': 'e-ticket', 'boarding_pass': 'e-ticket', //
    'mobile_ticket': 'e-ticket', 'online_ticket': 'e-ticket', //
    'e_bill': 'invoice', 'tax_invoice': 'invoice', //
    'amount_paid': 'payment', 'amount_due': 'payment', //
    'amount_charged': 'payment', 'total_paid': 'payment', //
    'paid_with': 'payment', 'payment_method': 'payment', //
    'save_up': 'marketing', 'special_offer': 'marketing', //
    'limited_time': 'marketing', 'last_chance': 'marketing', //
    'book_now': 'marketing', 'jetzt_buchen': 'marketing', //
    'from_just': 'marketing', 'ab_nur': 'marketing', //
    'view_in': 'unsubscribe', 'email_preferences': 'unsubscribe', //
    'im_browser': 'unsubscribe', //
    'return_journey': 'travel', 'ticket_type': 'journey', //
    'check_in': 'stay', 'check_out': 'stay', //
    'table_for': 'table', 'party_of': 'table', 'party_size': 'table', //
    'doors_open': 'venue', 'gates_open': 'venue', //
    'pick_up': 'car', 'drop_off': 'car', 'prise_en': 'car', //
    'out_for': 'delivery', 'on_its': 'delivery', //
    'sign_in': 'account', 'log_in': 'account', 'security_code': 'account', //
    'security_alert': 'account', 'one_time': 'account', //
    'two_factor': 'account', 'mot_de': 'account', //
    'confirm_your': 'account', //
    'schedule_change': 'change', 'new_time': 'change', //
    'season_ticket': 'renewal', 'monthly_plan': 'renewal', //
    'annual_plan': 'renewal', //
    'travel_authorisation': 'permit', 'travel_authorization': 'permit', //
    'flying_blue': 'redemption', 'points_used': 'redemption', //
    'rendez_vous': 'appointment', //
  };
}

/// Takes a feature's name in up to four parts, to be joined.
typedef _Add = void Function(String a, [String b, String c, String d]);

/// One word or number of a text, and where it stands.
final class _Token {
  _Token(
    this.start,
    this.end,
    this.lower, {
    required int letters,
    required int digits,
    required this.upper,
  }) : number = letters == 0,
       mixed = letters > 0 && digits > 0,
       digit = digits > 0;

  final int start;
  final int end;

  /// Lower case, accents folded.
  final String lower;

  /// No lower-case letters (upper case, or digits).
  final bool upper;

  /// Only digits.
  final bool number;

  /// Letters and digits.
  final bool mixed;

  /// Any digit.
  final bool digit;

  /// The word as a feature: numbers by their shape (`#`, `##`, `###`),
  /// codes mixing letters and digits as `a#`.
  String get word => mixed
      ? 'a#'
      : number
      ? (lower.length <= 2
            ? '#'
            : lower.length <= 4
            ? '##'
            : '###')
      : lower;
}
