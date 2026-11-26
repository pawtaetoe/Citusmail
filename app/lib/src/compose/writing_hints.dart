// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import '../mail/send_later_times.dart';

/// One hint under the recipients while writing, worked out on the device
/// from the user's own mail.
sealed class WritingHint {
  const WritingHint();

  /// Closing a hint hides every hint with the same key for this message.
  String get key;
}

/// The time and reply hints share a key: closing one quiets both.
const _aboutThem = 'about-them';

/// "It's 11:40 PM for Maya. Send later?": it is night where everyone the
/// message goes to is (by the time zone their mail is dated in).
final class LocalTimeHint extends WritingHint {
  const LocalTimeHint({required this.names, required this.offset});

  /// Who it is night for, as the hint names them.
  final List<String> names;

  /// Their usual offset from UTC.
  final Duration offset;

  @override
  String get key => _aboutThem;

  /// Their wall clock at [now] (read its fields; it is not an instant).
  DateTime theirClock(DateTime now) => now.toUtc().add(offset);

  /// The coming 8:00 in the morning on their clock, as an instant.
  DateTime morning(DateTime now) {
    final t = theirClock(now);
    final day = t.hour >= 8 ? 1 : 0;
    return DateTime.utc(t.year, t.month, t.day + day, 8).subtract(offset);
  }

  /// Whether [morning] is on their next day (else later on the day that
  /// has started there).
  bool morningIsTomorrow(DateTime now) => theirClock(now).hour >= 8;

  @override
  bool operator ==(Object other) =>
      other is LocalTimeHint &&
      other.offset == offset &&
      listEquals(other.names, names);

  @override
  int get hashCode => Object.hash(offset, Object.hashAll(names));
}

/// "Maya usually replies within 2 hours."
final class ReplyTimeHint extends WritingHint {
  const ReplyTimeHint({required this.name, required this.usual});

  final String name;

  /// The median time they took to answer the user.
  final Duration usual;

  @override
  String get key => _aboutThem;

  String get sentence => HintRules.replySentence(name, usual);

  @override
  bool operator ==(Object other) =>
      other is ReplyTimeHint && other.name == name && other.usual == usual;

  @override
  int get hashCode => Object.hash(name, usual);
}

/// "You haven't written to maya@exmaple.com before. Did you mean
/// maya@example.com?"
final class NearMissHint extends WritingHint {
  const NearMissHint({required this.typed, required this.suggested});

  /// The recipient as it is in the message.
  final MailAddress typed;

  /// The address the user knows that it is very close to.
  final MailAddress suggested;

  @override
  String get key => 'near:${typed.address.toLowerCase()}';

  @override
  bool operator ==(Object other) =>
      other is NearMissHint &&
      other.typed.address == typed.address &&
      other.suggested.address == suggested.address;

  @override
  int get hashCode => Object.hash(typed.address, suggested.address);
}

/// The rules behind the hints, on plain values.
abstract final class HintRules {
  /// Their mail must be this consistent about its time zone...
  static const consistent = 0.7;

  /// ...and there must be this much of it (also for reply times).
  static const enoughMail = 3;

  /// How much of their newest mail is looked at for the time zone.
  static const recentMail = 10;

  /// Their usual offset from UTC, from the dates of their recent mail:
  /// the most common one, when at least [consistent] of the mail and
  /// [enoughMail] messages have it; otherwise null.
  ///
  /// UTC itself says nothing: privacy-minded mail apps (this one too)
  /// date every message in UTC, wherever they are. Such mail still
  /// counts against consistency.
  static Duration? usualOffset(List<MailDate> dates) {
    if (dates.length < enoughMail) return null;
    final counts = <Duration, int>{};
    for (final d in dates) {
      if (!d.zoneKnown || d.offset == Duration.zero) continue;
      counts[d.offset] = (counts[d.offset] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    final best = counts.entries.reduce((a, b) => b.value > a.value ? b : a);
    if (best.value < enoughMail) return null;
    if (best.value < consistent * dates.length) return null;
    return best.key;
  }

  /// The median of [delays], with at least [enoughMail] of them.
  static Duration? medianDelay(List<Duration> delays) {
    if (delays.length < enoughMail) return null;
    final sorted = [...delays]..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) ~/ 2;
  }

  /// Late evening and night: from 22:00 to 7:00.
  static bool isNight(DateTime clock) => clock.hour >= 22 || clock.hour < 7;

  /// "Maya usually replies within 2 hours."
  static String replySentence(String name, Duration usual) {
    final minutes = usual.inMinutes;
    if (minutes <= 60) return '$name usually replies within an hour.';
    final hours = (minutes / 60).ceil();
    if (hours < 24) return '$name usually replies within $hours hours.';
    if (hours == 24) return '$name usually replies within a day.';
    final days = (minutes / (24 * 60)).ceil();
    if (days <= 7) return '$name usually replies within $days days.';
    return '$name usually takes more than a week to reply.';
  }

  /// "Maya", "Maya and Sam", "Maya and 2 others".
  static String names(List<String> names) => switch (names.length) {
    0 => 'them',
    1 => names.single,
    2 => '${names[0]} and ${names[1]}',
    _ => '${names[0]} and ${names.length - 1} others',
  };

  /// What to call [address] in a hint: the first name it is known by
  /// ([known] when the message has none), else the address.
  static String shortName(MailAddress address, [String? known]) {
    final given = address.displayName?.trim() ?? '';
    var name = (given.isNotEmpty ? given : known?.trim() ?? '')
        .replaceAll(RegExp('["\']'), '')
        .trim();
    if (name.isEmpty || name.contains('@')) return address.address;
    // "Lin, Maya"
    if (name.contains(',')) name = name.split(',').last.trim();
    final first = name.split(RegExp(r'\s+')).first;
    return first.isEmpty ? address.address : first;
  }

  /// A known address [typed] is very close to: one character off
  /// (added, missing, changed or two swapped), or the same name at a
  /// domain one or two characters off or with another ending. The
  /// closest wins, then the first in [known] (the best known first).
  /// Null when there is none, or when [typed] is itself in [known].
  static MailAddress? nearMiss(String typed, Iterable<MailAddress> known) {
    final t = typed.toLowerCase();
    final at = t.lastIndexOf('@');
    if (at <= 0 || at == t.length - 1) return null;
    final local = t.substring(0, at), domain = t.substring(at + 1);
    MailAddress? best;
    var bestScore = 3;
    for (final k in known) {
      final c = k.address.toLowerCase();
      if (c == t) return null;
      if ((c.length - t.length).abs() > 3) continue;
      final cAt = c.lastIndexOf('@');
      if (cAt <= 0) continue;
      final int score;
      if (distance(t, c) == 1) {
        score = 1;
      } else if (c.substring(0, cAt) == local &&
          _sameDomain(domain, c.substring(cAt + 1))) {
        score = 2;
      } else {
        continue;
      }
      if (score < bestScore) {
        best = k;
        bestScore = score;
      }
    }
    return best;
  }

  /// `exmaple.com` and `example.com`; `example.org` and `example.com`.
  static bool _sameDomain(String a, String b) {
    if (math.min(a.length, b.length) >= 5 && distance(a, b) <= 2) return true;
    String name(String d) {
      final dot = d.lastIndexOf('.');
      return dot <= 0 ? d : d.substring(0, dot);
    }

    return name(a) == name(b) && name(a).length >= 3;
  }

  /// Edits between [a] and [b]: characters added, removed or changed,
  /// and two neighbours swapped (each counts once).
  static int distance(String a, String b) {
    final s = a.codeUnits, t = b.codeUnits;
    var before = List<int>.filled(t.length + 1, 0);
    var prev = List<int>.generate(t.length + 1, (j) => j);
    var cur = List<int>.filled(t.length + 1, 0);
    for (var i = 1; i <= s.length; i++) {
      cur[0] = i;
      for (var j = 1; j <= t.length; j++) {
        final cost = s[i - 1] == t[j - 1] ? 0 : 1;
        var d = math.min(
          math.min(prev[j] + 1, cur[j - 1] + 1),
          prev[j - 1] + cost,
        );
        if (i > 1 && j > 1 && s[i - 1] == t[j - 2] && s[i - 2] == t[j - 1]) {
          d = math.min(d, before[j - 2] + 1);
        }
        cur[j] = d;
      }
      final spare = before;
      before = prev;
      prev = cur;
      cur = spare;
    }
    return prev[t.length];
  }
}

/// What the stored mail says about one recipient.
final class _Facts {
  const _Facts({
    this.own = false,
    this.list = false,
    this.offset,
    this.replies,
    this.name,
    this.nearMiss,
  });

  /// One of the user's own addresses.
  final bool own;

  /// A mailing list.
  final bool list;
  final Duration? offset;
  final Duration? replies;
  final String? name;
  final MailAddress? nearMiss;
}

/// The recipients of the message, field by field.
typedef HintRecipients = ({
  List<MailAddress> to,
  List<MailAddress> cc,
  List<MailAddress> bcc,
});

/// The writing hints of one compose window: at most one at a time, the
/// most useful one ([current]). Worked out from the stored mail when a
/// recipient is added or removed (never from text being typed), with
/// what is learned about each address kept for the window's lifetime
/// only. Each address costs a few indexed queries, once.
///
/// In order: a likely typo in an address ("Did you mean"), since it
/// prevents a mistake; then the late hour where everyone the message goes
/// to is; then how quickly they usually reply. Nothing for the user's own
/// addresses or for mailing lists.
final class WritingHints extends ChangeNotifier {
  WritingHints({
    required this._store,
    required this._recipients,
    required this._read,
    required this._known,
    required this._enabled,
  }) {
    _recipients.addListener(_schedule);
    _schedule();
  }

  final MailStore _store;
  final Listenable _recipients;
  final HintRecipients Function() _read;
  final List<MailAddress> Function() _known;
  final bool Function() _enabled;

  late final _mail = CorrespondenceRepository(_store.database);
  late final _own = {
    for (final a in _store.accounts.all()) a.email.toLowerCase(),
  };
  final _facts = <String, _Facts>{};
  final _closed = <String>{};
  Timer? _pending;
  bool _disposed = false;

  WritingHint? _current;

  /// The hint to show, or null for none.
  WritingHint? get current => _enabled() ? _current : null;

  /// Hides [current] for this message.
  void close() {
    final hint = _current;
    if (hint == null) return;
    _closed.add(hint.key);
    _update();
  }

  /// Works the hints out again (after the setting changed).
  void refresh() => _update();

  /// After the frame that shows the new chip: the queries never hold up
  /// the change itself.
  void _schedule() {
    _pending?.cancel();
    _pending = Timer(Duration.zero, _update);
  }

  void _update() {
    _pending = null;
    if (_disposed) return;
    WritingHint? next;
    try {
      next = _pick();
    } on Object catch (e) {
      // A hint is never worth an error.
      debugPrint('writing hints: ${e.runtimeType}');
    }
    if (next == _current) return;
    _current = next;
    notifyListeners();
  }

  WritingHint? _pick() {
    if (!_enabled()) return null;
    final r = _read();
    final all = [...r.to, ...r.cc, ...r.bcc];
    if (all.isEmpty) return null;
    bool among(MailAddress a) =>
        all.any((b) => b.address.toLowerCase() == a.address.toLowerCase());

    // A likely typo first: it prevents a mistake.
    for (final a in all) {
      final suggested = _of(a).nearMiss;
      if (suggested == null || among(suggested)) continue;
      final hint = NearMissHint(typed: a, suggested: suggested);
      if (!_closed.contains(hint.key)) return hint;
    }
    if (_closed.contains(_aboutThem)) return null;

    final people = [
      for (final a in all)
        if (!_of(a).own) a,
    ];
    if (people.isEmpty) return null;
    final facts = [for (final a in people) _of(a)];
    String name(int i) => HintRules.shortName(people[i], facts[i].name);

    // Their local time: only when everyone shares it.
    final offsets = {for (final f in facts) f.list ? null : f.offset};
    if (offsets.singleOrNull case final offset?) {
      final hint = LocalTimeHint(
        names: [for (var i = 0; i < people.length; i++) name(i)],
        offset: offset,
      );
      if (HintRules.isNight(hint.theirClock(SendLaterTimes.clock()))) {
        return hint;
      }
    }

    // How quickly they reply: the first who has a usual time.
    for (var i = 0; i < people.length; i++) {
      final usual = facts[i].replies;
      if (usual != null && !facts[i].list) {
        return ReplyTimeHint(name: name(i), usual: usual);
      }
    }
    return null;
  }

  _Facts _of(MailAddress recipient) {
    final address = recipient.address;
    return _facts.putIfAbsent(address.toLowerCase(), () {
      if (_own.contains(address.toLowerCase())) return const _Facts(own: true);
      if (_mail.isList(address)) return const _Facts(list: true);
      if (!_mail.knows(address)) {
        return _Facts(
          nearMiss: HintRules.nearMiss(address, [
            for (final k in _known())
              if (!_own.contains(k.address.toLowerCase())) k,
          ]),
        );
      }
      return _Facts(
        offset: HintRules.usualOffset(
          _mail.recentDates(address, limit: HintRules.recentMail),
        ),
        replies: HintRules.medianDelay(_mail.replyDelays(address)),
        name: _mail.nameOf(address),
      );
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _pending?.cancel();
    _recipients.removeListener(_schedule);
    super.dispose();
  }
}
