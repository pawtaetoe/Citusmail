// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'settings_repository.dart';

/// One setting in [SettingsRepository]: its [key], its default
/// ([fallback]) and how its value is stored as text.
///
/// Declare each setting once, as a `static const`, and read and write it
/// only through that declaration:
///
/// ```dart
/// static const notifications = BoolSetting('app.notifications');
/// final on = notifications.read(store.settings);
/// notifications.write(store.settings, false);
/// ```
///
/// Reading never throws: a value that is missing or can't be read (from
/// an older or newer version, or damaged) reads as [fallback], and is left
/// as it is until the next write.
abstract base class Setting<T> {
  const Setting(this.key, {required this.fallback});

  /// The name it is stored under. Never change it: the stored value would
  /// be lost, and a synced setting would stop syncing.
  final String key;

  /// The value when nothing (or nothing readable) is stored.
  final T fallback;

  /// [stored] as a value, or null when it can't be read.
  T? tryDecode(String stored);

  /// [stored] as a value, or [fallback] when it can't be read.
  T decode(String stored) => tryDecode(stored) ?? fallback;

  /// [value] as stored text.
  String encode(T value);

  /// The stored value, or [fallback].
  T read(SettingsRepository settings) {
    final stored = settings.read(key);
    return stored == null ? fallback : decode(stored);
  }

  /// The stored value, or null when none is stored or it can't be read.
  T? readOrNull(SettingsRepository settings) {
    final stored = settings.read(key);
    return stored == null ? null : tryDecode(stored);
  }

  /// Whether anything is stored, readable or not.
  bool isSetIn(SettingsRepository settings) => settings.read(key) != null;

  /// [at] and [device]: when applying another device's change.
  void write(
    SettingsRepository settings,
    T value, {
    DateTime? at,
    String? device,
  }) => settings.write(key, encode(value), at: at, device: device);

  /// Removes the stored value: [read] gives [fallback] again.
  void clear(SettingsRepository settings, {DateTime? at, String? device}) =>
      settings.delete(key, at: at, device: device);

  @override
  String toString() => '$runtimeType($key)';
}

/// On or off, stored as [onText] and [offText] (`on` and `off`). Anything
/// else reads as [fallback].
final class BoolSetting extends Setting<bool> {
  const BoolSetting(
    super.key, {
    super.fallback = false,
    this.onText = 'on',
    this.offText = 'off',
  });

  final String onText;
  final String offText;

  @override
  bool? tryDecode(String stored) => stored == onText
      ? true
      : stored == offText
      ? false
      : null;

  @override
  String encode(bool value) => value ? onText : offText;
}

/// A whole number, as decimal text. A value outside [min] to [max]
/// (either may be null: no limit) reads as [fallback]; a write outside
/// them is clamped.
final class IntSetting extends Setting<int> {
  const IntSetting(super.key, {super.fallback = 0, this.min, this.max})
    : assert(min == null || max == null || min <= max);

  final int? min;
  final int? max;

  @override
  int? tryDecode(String stored) {
    final value = int.tryParse(stored);
    if (value == null) return null;
    if (min case final min? when value < min) return null;
    if (max case final max? when value > max) return null;
    return value;
  }

  @override
  String encode(int value) {
    var clamped = value;
    if (min case final min? when clamped < min) clamped = min;
    if (max case final max? when clamped > max) clamped = max;
    return '$clamped';
  }
}

/// One of an enum's [values], by its `name` (or by [storedAs], for an
/// enum whose stored names differ). An unknown name (from another
/// version) reads as [fallback].
final class EnumSetting<E extends Enum> extends Setting<E> {
  const EnumSetting(
    super.key,
    this.values, {
    required super.fallback,
    this.storedAs = _name,
  });

  final List<E> values;

  /// The text a value is stored as.
  final String Function(E value) storedAs;

  static String _name(Enum value) => value.name;

  @override
  E? tryDecode(String stored) {
    for (final value in values) {
      if (storedAs(value) == stored) return value;
    }
    return null;
  }

  @override
  String encode(E value) => storedAs(value);
}

/// Free text, stored as it is.
final class StringSetting extends Setting<String> {
  const StringSetting(super.key, {super.fallback = ''});

  @override
  String tryDecode(String stored) => stored;

  @override
  String encode(String value) => value;
}

/// How a [DateTimeSetting] is stored.
enum DateTimeFormat {
  /// Milliseconds since 1970 (UTC), as decimal text.
  milliseconds,

  /// ISO-8601 in UTC, as [DateTime.toIso8601String] writes it.
  iso8601,
}

/// A moment, read back in UTC; null when none is set. Writing null stores
/// empty text, which reads as null.
final class DateTimeSetting extends Setting<DateTime?> {
  const DateTimeSetting(super.key, {this.format = DateTimeFormat.milliseconds})
    : super(fallback: null);

  final DateTimeFormat format;

  @override
  DateTime? tryDecode(String stored) => switch (format) {
    DateTimeFormat.milliseconds => switch (int.tryParse(stored)) {
      final ms? => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
      null => null,
    },
    DateTimeFormat.iso8601 => DateTime.tryParse(stored)?.toUtc(),
  };

  @override
  String encode(DateTime? value) => switch ((value, format)) {
    (null, _) => '',
    (final at?, DateTimeFormat.milliseconds) => '${at.millisecondsSinceEpoch}',
    (final at?, DateTimeFormat.iso8601) => at.toUtc().toIso8601String(),
  };
}

/// A list of texts joined by [separator] (`,` by default). Empty items
/// are left out when reading; an empty list is stored as empty text.
/// Items must not contain [separator].
final class StringListSetting extends Setting<List<String>> {
  const StringListSetting(
    super.key, {
    this.separator = ',',
    super.fallback = const [],
  });

  final String separator;

  @override
  List<String> tryDecode(String stored) => [
    for (final item in stored.split(separator))
      if (item.isNotEmpty) item,
  ];

  @override
  String encode(List<String> value) => value.join(separator);
}

/// A list of texts stored as a JSON array (any text allowed in an item).
/// Anything but an array of texts reads as [fallback].
final class JsonListSetting extends Setting<List<String>> {
  const JsonListSetting(super.key, {super.fallback = const []});

  @override
  List<String>? tryDecode(String stored) {
    final Object? json;
    try {
      json = jsonDecode(stored);
    } on FormatException {
      return null;
    }
    if (json is! List<Object?> || json.any((item) => item is! String)) {
      return null;
    }
    return json.cast<String>().toList();
  }

  @override
  String encode(List<String> value) => jsonEncode(value);
}

/// A value stored as JSON, through [fromJson] and [toJson]. Text that
/// isn't JSON, or that [fromJson] rejects (by throwing or returning
/// null), reads as [fallback].
final class JsonSetting<T> extends Setting<T> {
  const JsonSetting(
    super.key, {
    required super.fallback,
    required this.fromJson,
    required this.toJson,
  });

  /// The decoded JSON as a value; null (or a throw) when it isn't one.
  final T? Function(Object? json) fromJson;
  final Object? Function(T value) toJson;

  @override
  T? tryDecode(String stored) {
    try {
      return fromJson(jsonDecode(stored));
    } on Object {
      // Not JSON, or JSON of the wrong shape: whatever [fromJson] threw,
      // reading a setting never throws.
      return null;
    }
  }

  @override
  String encode(T value) => jsonEncode(toJson(value));
}
