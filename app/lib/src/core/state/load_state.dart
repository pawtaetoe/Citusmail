// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';

/// Where loading a page's data stands: still [Loading], [Loaded] with
/// the data, or [LoadFailed] with the reason. A `switch` over it covers
/// every case:
///
/// ```dart
/// switch (model.state) {
///   Loading() => const SkeletonRows(),
///   Loaded(:final value) => List(value),
///   LoadFailed(:final reason) => Text(reason),
/// }
/// ```
@immutable
sealed class LoadState<T> {
  const LoadState();

  /// The data once loaded, else null.
  T? get valueOrNull => switch (this) {
    Loaded<T>(:final value) => value,
    Loading<T>() || LoadFailed<T>() => null,
  };

  bool get isLoading => this is Loading<T>;
}

/// Nothing loaded yet.
final class Loading<T> extends LoadState<T> {
  const Loading();

  @override
  bool operator ==(Object other) => other is Loading<T>;

  @override
  int get hashCode => (Loading<T>).hashCode;

  @override
  String toString() => 'Loading<$T>()';
}

/// The data, loaded.
final class Loaded<T> extends LoadState<T> {
  const Loaded(this.value);

  final T value;

  @override
  bool operator ==(Object other) => other is Loaded<T> && other.value == value;

  @override
  int get hashCode => Object.hash(Loaded<T>, value);

  @override
  String toString() => 'Loaded<$T>($value)';
}

/// Loading failed before anything was loaded.
final class LoadFailed<T> extends LoadState<T> {
  const LoadFailed(this.reason, {this.error});

  /// Why, in plain words for the user.
  final String reason;

  /// What went wrong, for the logs.
  final Object? error;

  @override
  bool operator ==(Object other) =>
      other is LoadFailed<T> && other.reason == reason && other.error == error;

  @override
  int get hashCode => Object.hash(LoadFailed<T>, reason, error);

  @override
  String toString() => 'LoadFailed<$T>($reason)';
}
