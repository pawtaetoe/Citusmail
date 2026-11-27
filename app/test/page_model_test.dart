// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:citusmail/src/core/state/load_state.dart';
import 'package:citusmail/src/core/state/page_model.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Each fetch waits for the test to finish it.
final class _Model extends PageModel<String> {
  _Model({super.reloadOn});

  final fetches = <Completer<String>>[];
  int running = 0;
  int mostAtOnce = 0;

  @override
  Future<String> fetch() async {
    running++;
    if (running > mostAtOnce) mostAtOnce = running;
    final c = Completer<String>();
    fetches.add(c);
    try {
      return await c.future;
    } finally {
      running--;
    }
  }

  void edit(String value) => change(value);
}

String describe(LoadState<String> state) => switch (state) {
  Loading() => 'loading',
  Loaded(:final value) => 'loaded $value',
  LoadFailed(:final reason) => 'failed: $reason',
};

void main() {
  group('LoadState', () {
    test('a switch covers every case', () {
      expect(describe(const Loading()), 'loading');
      expect(describe(const Loaded('a')), 'loaded a');
      expect(describe(const LoadFailed('no mail')), 'failed: no mail');
    });

    test('the value only once loaded', () {
      expect(const Loading<int>().valueOrNull, isNull);
      expect(const Loaded(3).valueOrNull, 3);
      expect(const LoadFailed<int>('x').valueOrNull, isNull);
      expect(const Loading<int>().isLoading, isTrue);
      expect(const Loaded(3).isLoading, isFalse);
    });

    test('equal by what they hold', () {
      expect(const Loaded(3), const Loaded(3));
      expect(const Loaded(3), isNot(const Loaded(4)));
      expect(const Loading<int>(), const Loading<int>());
      expect(const LoadFailed<int>('x'), const LoadFailed<int>('x'));
      expect(const LoadFailed<int>('x'), isNot(const LoadFailed<int>('y')));
    });
  });

  group('PageModel', () {
    late List<FlutterErrorDetails> reported;
    late FlutterExceptionHandler? before;

    setUp(() {
      reported = [];
      before = FlutterError.onError;
      FlutterError.onError = reported.add;
    });

    tearDown(() => FlutterError.onError = before);

    test('loading, then loaded', () async {
      final model = _Model();
      var told = 0;
      model.addListener(() => told++);
      expect(model.state, const Loading<String>());
      expect(model.loading, isTrue);
      final done = model.load();
      model.fetches.single.complete('mail');
      await done;
      expect(model.state, const Loaded('mail'));
      expect(model.data, 'mail');
      expect(model.loading, isFalse);
      expect(told, 1);
    });

    test('one fetch at a time; a newer load wins over a stale one', () async {
      final model = _Model();
      final states = <String>[];
      model.addListener(() => states.add(describe(model.state)));
      final first = model.load();
      final second = model.load();
      final third = model.load();
      expect(model.fetches, hasLength(1), reason: 'the others wait');
      model.fetches[0].complete('old');
      await pumpEventQueue();
      expect(model.fetches, hasLength(2), reason: 'one more, for all');
      expect(model.state, const Loading<String>(), reason: 'old is dropped');
      model.fetches[1].complete('new');
      await Future.wait([first, second, third]);
      expect(model.state, const Loaded('new'));
      expect(states, ['loaded new']);
      expect(model.mostAtOnce, 1);
    });

    test('loading again keeps the data until the new one is in', () async {
      final model = _Model();
      final first = model.load();
      model.fetches.single.complete('a');
      await first;
      final again = model.load();
      expect(model.state, const Loaded('a'));
      model.fetches.last.complete('b');
      await again;
      expect(model.state, const Loaded('b'));
    });

    test('a failure gives a reason, and is reported', () async {
      final model = _Model();
      final done = model.load();
      model.fetches.single.completeError(StateError('broken'));
      await done;
      expect(model.state, isA<LoadFailed<String>>());
      final failed = model.state as LoadFailed<String>;
      expect(failed.reason, isNotEmpty);
      expect(failed.error, isA<StateError>());
      expect(reported.single.exception, isA<StateError>());
    });

    test('a failed reload keeps what was loaded', () async {
      final model = _Model();
      final first = model.load();
      model.fetches.single.complete('a');
      await first;
      final again = model.load();
      model.fetches.last.completeError(StateError('offline'));
      await again;
      expect(model.state, const Loaded('a'));
      expect(reported, hasLength(1));
    });

    test('safe after dispose: no state change, no notice', () async {
      final model = _Model();
      var told = 0;
      model.addListener(() => told++);
      final done = model.load();
      model.dispose();
      expect(model.isDisposed, isTrue);
      model.fetches.single.complete('late');
      await done;
      expect(model.state, const Loading<String>());
      expect(told, 0);
      await model.load();
      expect(model.fetches, hasLength(1), reason: 'no fetch once disposed');
    });

    test('reloads when told to, once something is loaded', () async {
      final changes = ValueNotifier(0);
      final model = _Model(reloadOn: changes);
      changes.value++;
      expect(model.fetches, isEmpty, reason: 'not before the first load');
      final first = model.load();
      model.fetches.single.complete('a');
      await first;
      changes.value++;
      expect(model.fetches, hasLength(2));
      model.fetches.last.complete('b');
      await pumpEventQueue();
      expect(model.state, const Loaded('b'));
      model.dispose();
      changes.value++;
      expect(model.fetches, hasLength(2), reason: 'stops listening');
    });

    test('a change on the page shows at once', () async {
      final model = _Model();
      final done = model.load();
      model.fetches.single.complete('a');
      await done;
      var told = 0;
      model.addListener(() => told++);
      model.edit('b');
      expect(model.state, const Loaded('b'));
      expect(told, 1);
    });
  });
}
