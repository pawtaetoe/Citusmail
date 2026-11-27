// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:mail_ai/mail_ai.dart';

/// Where one request to the AI assistant stands. A `switch` over it
/// covers every case.
@immutable
sealed class AiTaskState<R> {
  const AiTaskState();
}

/// Not asked yet.
final class AiIdle<R> extends AiTaskState<R> {
  const AiIdle();
}

/// Asking: the answer's [text] so far (empty until it streams in).
final class AiRunning<R> extends AiTaskState<R> {
  const AiRunning([this.text = '']);

  final String text;
}

/// Answered with [result].
final class AiDone<R> extends AiTaskState<R> {
  const AiDone(this.result, {this.cutOff = false});

  final R result;

  /// The answer reached the model's length limit: the end may be missing.
  final bool cutOff;
}

/// No answer: [message] says why, in plain words.
final class AiFailed<R> extends AiTaskState<R> {
  const AiFailed(this.message);

  final String message;
}

/// The user stopped it; [text] is what had arrived by then.
final class AiStopped<R> extends AiTaskState<R> {
  const AiStopped([this.text = '']);

  final String text;
}

/// One request in progress, as [AiTask.run] hands it to the feature's
/// work: its [cancel], and where the text so far goes.
final class AiTaskRun {
  AiTaskRun._(this.cancel, this._partial);

  /// Cancelled when the user stops the task (or it is disposed).
  final AiCancel cancel;
  final void Function(String text) _partial;

  /// Set when the answer reached the model's length limit.
  bool cutOff = false;

  /// Shows [text] as the answer so far.
  void partial(String text) => _partial(text);

  /// Reads a streamed answer: the text so far goes to [partial] (through
  /// [shape], if given) as it arrives, and the finished response is
  /// returned. A refusal throws [AiProblem.refused]; an answer that ends
  /// early, [AiProblem.badResponse].
  Future<({AiResponse response, String streamed})> stream(
    Stream<AiEvent> events, {
    String Function(String text)? shape,
  }) async {
    final text = StringBuffer();
    await for (final event in events) {
      switch (event) {
        case AiTextDelta(text: final piece):
          text.write(piece);
          final so = text.toString();
          partial(shape == null ? so : shape(so));
        case AiCompleted(:final response):
          return (response: refusing(response), streamed: text.toString());
      }
    }
    throw const AiException(AiProblem.badResponse, 'the answer ended early');
  }

  /// [response], unless the model declined ([AiProblem.refused]). Notes a
  /// cut-off answer.
  AiResponse refusing(AiResponse response) {
    if (response.stopReason == AiStopReason.refusal) {
      throw const AiException(AiProblem.refused, 'declined');
    }
    if (response.stopReason == AiStopReason.maxTokens) cutOff = true;
    return response;
  }
}

/// One request to the AI assistant, for one feature: asking (through the
/// feature's provider, with [AiFeatureProvider] and [MailPrompt] as the
/// feature builds them), the text as it streams in, Stop, and problems
/// in plain words. The feature keeps its own prompt, checks and cache;
/// this keeps the [state].
///
/// A newer [run] replaces one under way; after [dispose] nothing changes
/// and nothing is told.
base class AiTask<R> extends ChangeNotifier {
  AiTask({this.recipient = ''});

  /// Who answers ("Anthropic"), named in the messages.
  String recipient;

  AiTaskState<R> _state = AiIdle<R>();
  AiCancel? _cancel;
  int _runs = 0;
  bool _disposed = false;

  AiTaskState<R> get state => _state;

  bool get isRunning => _state is AiRunning<R>;

  bool get isDisposed => _disposed;

  /// Asks: [work] makes the request with the run's cancel and gives the
  /// result, telling the run the text so far as it streams. An
  /// [AiException] it throws becomes [AiFailed] with [explain]'s words;
  /// a cancelled one, [AiStopped].
  Future<void> run(Future<R> Function(AiTaskRun run) work) async {
    if (_disposed) return;
    _cancel?.cancel();
    final id = ++_runs;
    final cancel = _cancel = AiCancel();
    bool current() => id == _runs && !_disposed && _state is AiRunning<R>;
    final run = AiTaskRun._(cancel, (text) {
      if (current()) _set(AiRunning<R>(text));
    });
    _set(AiRunning<R>());
    try {
      final result = await work(run);
      if (current()) {
        _set(AiDone<R>(result, cutOff: run.cutOff));
        finished(result);
      }
    } on AiException catch (e) {
      if (!current()) return;
      if (e.problem == AiProblem.cancelled) {
        _set(AiStopped<R>(_textSoFar));
      } else {
        _set(AiFailed<R>(explain(e)));
      }
    } on Object catch (e) {
      if (current()) _set(AiFailed<R>(explain(e)));
    } finally {
      if (identical(_cancel, cancel)) _cancel = null;
    }
  }

  /// Done with [result] without asking (it was kept from before).
  void answered(R result, {bool cutOff = false}) {
    _cancel?.cancel();
    _runs++;
    _set(AiDone<R>(result, cutOff: cutOff));
  }

  /// Failed without asking (the feature isn't set up, say).
  void failed(String message) {
    _cancel?.cancel();
    _runs++;
    _set(AiFailed<R>(message));
  }

  /// Back to not asked, stopping a request under way.
  void reset() {
    _cancel?.cancel();
    _cancel = null;
    _runs++;
    if (_state is! AiIdle<R>) _set(AiIdle<R>());
  }

  /// Stops asking; what had arrived stays ([AiStopped]).
  void stop() {
    if (_state is! AiRunning<R>) return;
    _cancel?.cancel();
    _cancel = null;
    _set(AiStopped<R>(_textSoFar));
  }

  /// Called once a [run] is answered with [result] (to keep it, say).
  @protected
  void finished(R result) {}

  /// [error] in plain words for the user.
  @protected
  String explain(Object error) => switch (error) {
    final AiException e => e.explain(recipient),
    _ => 'Something went wrong.',
  };

  String get _textSoFar => switch (_state) {
    AiRunning<R>(:final text) => text,
    _ => '',
  };

  void _set(AiTaskState<R> state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel?.cancel();
    super.dispose();
  }
}
