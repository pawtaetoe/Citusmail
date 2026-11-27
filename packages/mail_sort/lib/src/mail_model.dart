// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'generated/mail_model_weights.g.dart' as trained;
import 'mail_learning.dart';
import 'mail_model_features.dart';
import 'mail_types.dart';

/// What kind of booking an email is about.
enum BookingType { flight, train, stay, event, restaurant, car }

/// What [MailModel] tells apart: the [MailKind]s, bookings by type, and
/// two kinds of everything else (promotions, and the rest).
enum MailClass {
  /// None of them: mail from people, newsletters, statements, visas...
  none(),

  /// Promotions and deals ("Save 30% on trains"): never a booking.
  marketing(),
  subscription(MailKind.subscription),
  delivery(MailKind.delivery),
  flight(MailKind.booking, BookingType.flight),

  /// A train, bus or coach ticket.
  train(MailKind.booking, BookingType.train),
  stay(MailKind.booking, BookingType.stay),
  event(MailKind.booking, BookingType.event),
  restaurant(MailKind.booking, BookingType.restaurant),
  car(MailKind.booking, BookingType.car),
  account(MailKind.account),
  appointment(MailKind.appointment);

  const MailClass([this.kind, this.booking]);

  /// What the app finds in mail of this class, if anything.
  final MailKind? kind;

  /// For a booking, its type.
  final BookingType? booking;

  static MailClass? named(String name) =>
      values.where((c) => c.name == name).firstOrNull;
}

/// How likely an email is to be each [MailClass]; the chances add up to
/// one.
final class MailPrediction {
  MailPrediction._(this._p);

  final Float64List _p;

  /// The chance it is a [c].
  double operator [](MailClass c) => _p[c.index];

  /// The chance it is a [kind] (for a booking: of any type).
  double of(MailKind kind) {
    var sum = 0.0;
    for (final c in MailClass.values) {
      if (c.kind == kind) sum += _p[c.index];
    }
    return sum;
  }

  /// The chance of each kind.
  Map<MailKind, double> get kinds => {
    for (final k in MailKind.values) k: of(k),
  };

  /// The most likely class.
  MailClass get best {
    var best = MailClass.none;
    for (final c in MailClass.values) {
      if (_p[c.index] > _p[best.index]) best = c;
    }
    return best;
  }

  /// The most likely type, were it a booking.
  BookingType get bookingType {
    MailClass? best;
    for (final c in MailClass.values) {
      if (c.booking == null) continue;
      if (best == null || _p[c.index] > _p[best.index]) best = c;
    }
    return best!.booking!;
  }

  @override
  String toString() => [
    for (final c in MailClass.values)
      if (_p[c.index] >= 0.01) '${c.name} ${_p[c.index].toStringAsFixed(2)}',
  ].join(', ');
}

/// A small model of what an email is: a multinomial logistic regression
/// (softmax) over [MailModelFeatures], trained offline on synthetic mail
/// only (`tool/train_mail_model.dart`; never anyone's real mail) and
/// shipped as int8 weights with a scale per class. Pure Dart, on the
/// device; it reads an email in well under a millisecond and sends
/// nothing anywhere.
///
/// With [MailLearning], the user's own corrections shift it: "Not a
/// booking" makes emails like that one less likely to be bookings.
///
/// The finders do not use it yet; [thresholds] are where, on the
/// held-out evaluation, it is right often enough to add what the rules
/// miss.
final class MailModel {
  MailModel._(this._weights, this._scales, this._biases, this._learning);

  /// The trained model, read once.
  static final MailModel standard = _load();

  /// The chance above which, in the evaluation, an email of each kind
  /// the rules missed is worth listing.
  static const thresholds = {
    MailKind.subscription: 0.8,
    MailKind.delivery: 0.8,
    MailKind.booking: 0.8,
    MailKind.account: 0.9,
    MailKind.appointment: 0.9,
  };

  final Int8List _weights;
  final Float64List _scales;
  final Float64List _biases;
  final MailLearning? _learning;

  static final _classes = MailClass.values.length;

  /// This model with the user's corrections on top.
  MailModel withLearning(MailLearning? learning) =>
      MailModel._(_weights, _scales, _biases, learning);

  /// The size of the shipped weights, in bytes.
  static int get shippedBytes =>
      trained.mailModelWeights.fold(0, (n, s) => n + s.length);

  /// How likely [sample] is to be each class.
  MailPrediction classify(MailSample sample) {
    final x = MailModelFeatures.of(sample);
    final z = Float64List(_classes);
    for (var i = 0; i < x.length; i++) {
      final base = x.buckets[i] * _classes;
      final v = x.values[i];
      for (var c = 0; c < _classes; c++) {
        z[c] += v * _weights[base + c];
      }
    }
    for (var c = 0; c < _classes; c++) {
      z[c] = z[c] * _scales[c] + _biases[c];
    }
    if (_learning case final learning? when !learning.isEmpty) {
      for (final kind in MailKind.values) {
        final shift = learning.adjustment(kind, sample, x);
        if (shift == 0) continue;
        for (final c in MailClass.values) {
          if (c.kind == kind) z[c.index] += shift;
        }
      }
    }
    return MailPrediction._(_softmax(z));
  }

  /// How likely [sample] is to be each kind.
  Map<MailKind, double> kindOf(MailSample sample) => classify(sample).kinds;

  /// Whether [sample] is a [kind], with at least [threshold] chance
  /// (by default the evaluated one, [thresholds]).
  bool isA(MailKind kind, MailSample sample, {double? threshold}) =>
      classify(sample).of(kind) >= (threshold ?? thresholds[kind]!);

  static Float64List _softmax(Float64List z) {
    var max = z[0];
    for (final v in z) {
      if (v > max) max = v;
    }
    var sum = 0.0;
    for (var i = 0; i < z.length; i++) {
      z[i] = math.exp(z[i] - max);
      sum += z[i];
    }
    for (var i = 0; i < z.length; i++) {
      z[i] /= sum;
    }
    return z;
  }

  static MailModel _load() {
    if (trained.mailModelFeatureVersion != MailModelFeatures.version ||
        trained.mailModelBuckets != MailModelFeatures.buckets) {
      throw StateError('The trained mail model is for other features.');
    }
    final names = trained.mailModelClasses;
    if (names.length != _classes ||
        [for (final (i, n) in names.indexed) MailClass.values[i].name == n]
            .contains(false)) {
      throw StateError('The trained mail model has other classes.');
    }
    final weights = decodeWeights(
      base64.decode(trained.mailModelWeights.join()),
      buckets: MailModelFeatures.buckets,
      classes: _classes,
    );
    return MailModel._(
      weights,
      Float64List.fromList(trained.mailModelScales),
      Float64List.fromList(trained.mailModelBiases),
      null,
    );
  }

  /// The weights from their stored form: a bitmap of the buckets that
  /// have any, then [classes] signed bytes for each of those.
  static Int8List decodeWeights(
    Uint8List bytes, {
    required int buckets,
    required int classes,
  }) {
    final out = Int8List(buckets * classes);
    final bitmap = buckets ~/ 8;
    var at = bitmap;
    for (var b = 0; b < buckets; b++) {
      if (bytes[b >> 3] & (1 << (b & 7)) == 0) continue;
      for (var c = 0; c < classes; c++) {
        final v = bytes[at++];
        out[b * classes + c] = v > 127 ? v - 256 : v;
      }
    }
    if (at != bytes.length) {
      throw const FormatException('Mail model weights have the wrong size.');
    }
    return out;
  }

  /// [weights] (bucket-major, [classes] per bucket) in their stored form.
  static Uint8List encodeWeights(
    Int8List weights, {
    required int buckets,
    required int classes,
  }) {
    final bitmap = Uint8List(buckets ~/ 8);
    final rows = <int>[];
    for (var b = 0; b < buckets; b++) {
      final row = weights.sublist(b * classes, (b + 1) * classes);
      if (row.every((v) => v == 0)) continue;
      bitmap[b >> 3] |= 1 << (b & 7);
      rows.addAll([for (final v in row) v & 0xff]);
    }
    return Uint8List.fromList([...bitmap, ...rows]);
  }
}
