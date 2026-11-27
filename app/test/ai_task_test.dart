// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:citusmail/src/features/ai/state/ai_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_ai/mail_ai.dart';

AiResponse _response(
  String text, {
  AiStopReason stopReason = AiStopReason.finished,
}) => AiResponse(
  text: text,
  usage: AiUsage.zero,
  stopReason: stopReason,
  model: 'fake',
);

String describe(AiTaskState<String> state) => switch (state) {
  AiIdle() => 'idle',
  AiRunning(:final text) => 'running "$text"',
  AiDone(:final result, :final cutOff) =>
    'done "$result"${cutOff ? ' cut off' : ''}',
  AiFailed(:final message) => 'failed: $message',
  AiStopped(:final text) => 'stopped "$text"',
};

void main() {
  late AiTask<String> task;
  late List<String> seen;

  setUp(() {
    task = AiTask<String>(recipient: 'Anthropic');
    seen = [];
    task.addListener(() => seen.add(describe(task.state)));
  });

  test('idle, running with the text so far, then done', () async {
    expect(task.state, isA<AiIdle<String>>());
    final events = StreamController<AiEvent>();
    final done = task.run((run) async {
      final answer = await run.stream(events.stream);
      return answer.response.text;
    });
    expect(task.isRunning, isTrue);
    events
      ..add(const AiTextDelta('Hel'))
      ..add(const AiTextDelta('lo'))
      ..add(AiCompleted(_response('Hello')));
    await done;
    expect(seen, [
      'running ""',
      'running "Hel"',
      'running "Hello"',
      'done "Hello"',
    ]);
    unawaited(events.close());
  });

  test('a cut-off answer is said so', () async {
    await task.run(
      (run) async => run
          .refusing(_response('Half', stopReason: AiStopReason.maxTokens))
          .text,
    );
    expect(describe(task.state), 'done "Half" cut off');
  });

  test('Stop keeps what arrived; nothing after it counts', () async {
    final events = StreamController<AiEvent>();
    AiCancel? cancel;
    final done = task.run((run) async {
      cancel = run.cancel;
      return (await run.stream(events.stream)).response.text;
    });
    events.add(const AiTextDelta('One.'));
    await pumpEventQueue();
    task.stop();
    expect(describe(task.state), 'stopped "One."');
    expect(cancel!.isCancelled, isTrue);
    events
      ..add(const AiTextDelta(' Two.'))
      ..add(AiCompleted(_response('One. Two.')));
    await done;
    expect(describe(task.state), 'stopped "One."');
    unawaited(events.close());
  });

  test('problems in plain words', () async {
    await task.run(
      (run) async => throw const AiException(AiProblem.badKey, 'invalid key'),
    );
    expect(describe(task.state), contains('didn\'t accept the key'));

    await task.run(
      (run) async =>
          run.refusing(_response('', stopReason: AiStopReason.refusal)).text,
    );
    expect(
      describe(task.state),
      'failed: Anthropic declined to answer this one.',
    );

    await task.run(
      (run) async => (await run.stream(const Stream.empty())).response.text,
    );
    expect(
      describe(task.state),
      'failed: Anthropic\'s answer couldn\'t be read.',
    );

    await task.run((run) async => throw StateError('bug'));
    expect(describe(task.state), 'failed: Something went wrong.');
  });

  test('a cancelled request, stopped from elsewhere, is stopped', () async {
    await task.run((run) async => throw aiCancelled);
    expect(task.state, isA<AiStopped<String>>());
  });

  test('a newer run replaces one under way', () async {
    final first = Completer<String>();
    AiCancel? firstCancel;
    final a = task.run((run) {
      firstCancel = run.cancel;
      return first.future;
    });
    final b = task.run((run) async => 'second');
    await b;
    expect(firstCancel!.isCancelled, isTrue);
    first.complete('first');
    await a;
    expect(describe(task.state), 'done "second"');
  });

  test('answered, failed and reset without asking', () {
    task.answered('kept');
    expect(describe(task.state), 'done "kept"');
    task.failed('Not set up.');
    expect(describe(task.state), 'failed: Not set up.');
    task.reset();
    expect(task.state, isA<AiIdle<String>>());
  });

  test('safe after dispose', () async {
    final answer = Completer<String>();
    AiCancel? cancel;
    final done = task.run((run) {
      cancel = run.cancel;
      return answer.future;
    });
    final before = seen.length;
    task.dispose();
    expect(cancel!.isCancelled, isTrue);
    answer.complete('late');
    await done;
    expect(seen, hasLength(before), reason: 'nothing told after dispose');
    await task.run((run) async => 'again');
    expect(seen, hasLength(before));
  });

  test('a feature can word its own problems', () async {
    final writing = _Writing();
    await writing.run(
      (run) async =>
          run.refusing(_response('', stopReason: AiStopReason.refusal)).text,
    );
    expect((writing.state as AiFailed).message, 'It declined to write this.');
  });
}

final class _Writing extends AiTask<String> {
  @override
  String explain(Object error) => switch (error) {
    AiException(problem: AiProblem.refused) => 'It declined to write this.',
    _ => super.explain(error),
  };
}
