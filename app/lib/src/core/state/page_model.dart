// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'load_state.dart';

/// A view model that loads a page's data: it owns the [state], runs one
/// [fetch] at a time, and is safe to use after [dispose].
///
/// A subclass says how to [fetch] the data. [load] may be called at any
/// time: a call while a fetch is under way asks for one more, and only
/// the newest result is kept (what an earlier fetch found is dropped).
/// While loading again, the data loaded before stays. Pass [reloadOn] to
/// load again whenever it changes (the store's counts, say).
abstract base class PageModel<T> extends ChangeNotifier {
  PageModel({Listenable? reloadOn}) : _reloadOn = reloadOn {
    reloadOn?.addListener(_changed);
  }

  final Listenable? _reloadOn;

  LoadState<T> _state = Loading<T>();
  Completer<void>? _running;
  bool _again = false;
  bool _disposed = false;

  /// Where loading stands; a page shows it with a `switch`.
  LoadState<T> get state => _state;

  /// Nothing loaded yet.
  bool get loading => _state is Loading<T>;

  /// The data once loaded, else null.
  T? get data => _state.valueOrNull;

  bool get isDisposed => _disposed;

  /// Reads the page's data.
  @protected
  Future<T> fetch();

  /// The reason [LoadFailed] gives when [fetch] throws [error].
  @protected
  String failureReason(Object error) =>
      'Couldn\'t read this from your mail on this device.';

  /// Loads the data (again). Completes once the newest data asked for is
  /// in [state].
  Future<void> load() {
    if (_disposed) return Future.value();
    _again = true;
    if (_running case final running?) return running.future;
    final done = _running = Completer<void>();
    unawaited(_run(done));
    return done.future;
  }

  Future<void> _run(Completer<void> done) async {
    while (_again && !_disposed) {
      _again = false;
      LoadState<T> next;
      try {
        next = Loaded<T>(await fetch());
      } on Object catch (error, stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'citusmail',
            context: ErrorDescription('while loading $runtimeType'),
          ),
        );
        next = LoadFailed<T>(failureReason(error), error: error);
      }
      // A newer load was asked for meanwhile: this result is stale.
      if (_again || _disposed) continue;
      // A failed reload keeps what was loaded before.
      if (next is LoadFailed<T> && _state is Loaded<T>) continue;
      _state = next;
      notifyListeners();
    }
    _running = null;
    done.complete();
  }

  /// Replaces the loaded data at once, for a change made on the page that
  /// needs no new load. A fetch under way read from before the change:
  /// what it finds is dropped, and it reads again.
  @protected
  void change(T value) {
    if (_disposed) return;
    if (_running != null) _again = true;
    _state = Loaded<T>(value);
    notifyListeners();
  }

  /// Tells the listeners, unless disposed.
  @protected
  void notify() {
    if (!_disposed) notifyListeners();
  }

  /// What [reloadOn] tells: loads again once something was loaded, or
  /// while the first load is under way (it may have read from before).
  void _changed() {
    if (!loading || _running != null) unawaited(load());
  }

  @override
  void dispose() {
    _disposed = true;
    _reloadOn?.removeListener(_changed);
    super.dispose();
  }
}
