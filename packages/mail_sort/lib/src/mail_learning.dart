// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'mail_model_features.dart';
import 'mail_types.dart';

/// What the user taught the app about what their mail is, kept as one
/// short text (synced with their other settings):
///
/// - [veto], the [MailTypeClassifier] the pages use today to leave out
///   items like ones the user said are not a subscription, a delivery...
///   It works exactly as before.
/// - Small per-user adjustments to [MailModel]: for each kind, a weight
///   change per feature. "Not a booking" takes [step] times the email's
///   feature vector off the booking weights; "List again" (and Undo) puts
///   it back, exactly. Emails like it become less (or more) likely to be
///   that kind, in proportion to how alike they are.
/// - Corrections stored before the model existed (an older app's text)
///   are kept as they were and shift the model through the classifier's
///   own score, so nothing taught is lost.
///
/// The text starts with the classifier's own (`v1;...`), so an older app
/// still reads that part and skips the rest.
final class MailLearning {
  MailLearning._(this.veto, this._legacy, this._deltas);

  /// Nothing learned yet.
  factory MailLearning() => MailLearning._(MailTypeClassifier(), null, {});

  /// From what [toText] (or an older app's [MailTypeClassifier.toText])
  /// stored; nothing learned when it can't be read.
  factory MailLearning.fromText(String? text) {
    if (text == null || !text.startsWith('v1')) return MailLearning();
    final veto = MailTypeClassifier.fromText(text);
    final parts = text.split(';');
    String? version;
    final legacy = <String>[];
    final deltas = <MailKind, Map<int, int>>{};
    try {
      for (final part in parts.skip(1)) {
        if (part.startsWith('$_versionTag:')) {
          version = part.substring(_versionTag.length + 1);
        } else if (part.startsWith(_legacyTag)) {
          legacy.add(part.substring(_legacyTag.length));
        } else if (part.startsWith(_deltaTag) && part.length > 1) {
          final colon = part.indexOf(':');
          final kind = MailKind.ofCode(part.substring(1, colon));
          if (kind == null) continue;
          final map = <int, int>{};
          for (final entry in part.substring(colon + 1).split(',')) {
            if (entry.isEmpty) continue;
            final [b, v] = entry.split('/');
            final bucket = int.parse(b, radix: 36);
            final value = int.parse(v, radix: 36);
            if (bucket < 0 || bucket >= buckets) continue;
            if (value != 0) map[bucket] = value;
          }
          if (map.isNotEmpty) deltas[kind] = map;
        }
      }
    } on Object {
      return MailLearning._(veto, veto.isEmpty ? null : _copy(veto), {});
    }
    if (version != '${MailModelFeatures.version}') {
      // Stored by an app without the model (or with other features):
      // everything the classifier holds is kept as it was.
      return MailLearning._(veto, veto.isEmpty ? null : _copy(veto), {});
    }
    final old = legacy.isEmpty
        ? null
        : MailTypeClassifier.fromText('v1;${legacy.join(';')}');
    return MailLearning._(
      veto,
      old == null || old.isEmpty ? null : old,
      deltas,
    );
  }

  static const _versionTag = 'xv';
  static const _legacyTag = 'l';
  static const _deltaTag = 'x';

  /// What the pages use today to leave out items like rejected ones.
  final MailTypeClassifier veto;

  /// Corrections from before the model, as they were stored.
  MailTypeClassifier? _legacy;

  /// Per kind, the weight change of each feature bucket, in 1/[_unit].
  final Map<MailKind, Map<int, int>> _deltas;

  static const _unit = 64;

  /// The model's feature buckets folded into this many, so that what is
  /// stored stays small (a few thousand entries per kind at most), as
  /// with [MailTypeClassifier].
  static const buckets = 4096;

  /// How far one correction moves the model, in log-odds, for that very
  /// email (and less for ones less like it).
  static const step = 2.0;

  /// How much the old classifier's score moves the model: its veto fires
  /// near a shift of -0.2, which becomes about -2 here.
  static const _legacyScale = 10.0;

  bool get isEmpty =>
      veto.isEmpty && _legacy == null && _deltas.values.every((d) => d.isEmpty);

  /// Whether the user taught anything against [kind] (only then can the
  /// pages leave out an item of that kind).
  bool hasCorrections(MailKind kind) => veto.hasCorrections(kind);

  /// The user said [sample] is not a [kind] (or, with [undo], took that
  /// back).
  void reject(MailKind kind, MailSample sample, {bool undo = false}) {
    veto.reject(kind, sample, undo: undo);
    _move(kind, sample, undo ? step : -step);
  }

  /// The user kept [sample] as a [kind] ("List again"): [weight] is
  /// [MailTypeClassifier.keptWeight], or
  /// [MailTypeClassifier.openedWeight] when they only opened it. Keeping
  /// an email moves the model as far as rejecting it did, the other way.
  void confirm(
    MailKind kind,
    MailSample sample, {
    double weight = MailTypeClassifier.keptWeight,
  }) {
    veto.confirm(kind, sample, weight: weight);
    _move(kind, sample, step * weight / MailTypeClassifier.keptWeight);
  }

  void _move(MailKind kind, MailSample sample, double by) {
    final x = MailModelFeatures.of(sample);
    final deltas = _deltas[kind] ??= {};
    for (var i = 0; i < x.length; i++) {
      // Rounded on its own, so that the same move back undoes it exactly.
      final d = (by * x.values[i] * _unit).round();
      if (d == 0) continue;
      final b = x.buckets[i] & (buckets - 1);
      final v = (deltas[b] ?? 0) + d;
      if (v == 0) {
        deltas.remove(b);
      } else {
        deltas[b] = v;
      }
    }
    if (deltas.isEmpty) _deltas.remove(kind);
  }

  /// How much the user's corrections move [sample]'s log-odds of being a
  /// [kind]: below zero, less likely. [features] are its
  /// [MailModelFeatures], if already worked out.
  double adjustment(
    MailKind kind,
    MailSample sample, [
    MailFeatureVector? features,
  ]) {
    var shift = 0.0;
    if (_deltas[kind] case final deltas? when deltas.isNotEmpty) {
      final x = features ?? MailModelFeatures.of(sample);
      var weighted = 0.0;
      for (var i = 0; i < x.length; i++) {
        final d = deltas[x.buckets[i] & (buckets - 1)];
        if (d != null) weighted += d * x.values[i];
      }
      shift += weighted / _unit;
    }
    if (_legacy case final legacy?) {
      final learned = legacy.score(kind, sample);
      final seeded = _untaught.score(kind, sample);
      shift += (learned - seeded) * _legacyScale;
    }
    return shift;
  }

  static final _untaught = MailTypeClassifier();

  /// Forgets everything learned.
  void clear() {
    veto.clear();
    _legacy = null;
    _deltas.clear();
  }

  /// What was learned, compactly.
  String toText() {
    final out = StringBuffer(veto.toText())
      ..write(';$_versionTag:${MailModelFeatures.version}');
    if (_legacy case final legacy? when !legacy.isEmpty) {
      for (final part in legacy.toText().split(';').skip(1)) {
        out.write(';$_legacyTag$part');
      }
    }
    for (final kind in MailKind.values) {
      final deltas = _deltas[kind];
      if (deltas == null || deltas.isEmpty) continue;
      out.write(';$_deltaTag${kind.code}:');
      final sorted = deltas.keys.toList()..sort();
      out.write(
        [
          for (final b in sorted)
            '${b.toRadixString(36)}/${deltas[b]!.toRadixString(36)}',
        ].join(','),
      );
    }
    return out.toString();
  }

  static MailTypeClassifier _copy(MailTypeClassifier c) =>
      MailTypeClassifier.fromText(c.toText());
}
