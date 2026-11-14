// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Fakes for tests of features built on mail_ai: a provider with
/// scripted answers that records what it was asked, and settings in
/// memory. Never used by the app itself.
library;

import 'dart:async';

import 'mail_ai.dart';

/// One scripted answer of [FakeAiProvider].
final class FakeAiReply {
  const FakeAiReply(
    this.text, {
    this.chunks,
    this.usage = const AiUsage(inputTokens: 100, outputTokens: 20),
    this.stopReason = AiStopReason.finished,
    this.toolCalls = const [],
    this.error,
    this.delay = Duration.zero,
  });

  /// Fails with [error] instead of answering.
  const FakeAiReply.error(AiException this.error)
    : text = '',
      chunks = null,
      usage = AiUsage.zero,
      stopReason = AiStopReason.other,
      toolCalls = const [],
      delay = Duration.zero;

  final String text;

  /// How [text] arrives (default: in one piece).
  final List<String>? chunks;
  final AiUsage usage;
  final AiStopReason stopReason;
  final List<AiToolCall> toolCalls;
  final AiException? error;

  /// Before each chunk, to test streaming and cancelling.
  final Duration delay;
}

/// An [AiProvider] that answers from a script and records requests.
final class FakeAiProvider extends AiProvider {
  FakeAiProvider({
    this.kind = AiProviderKind.claude,
    this.models = const [AiModel('fake-large'), AiModel('fake-small')],
    Iterable<FakeAiReply> replies = const [],
    this.fallback = const FakeAiReply('A fake answer.'),
    this.listModelsError,
    this.recipientName,
  }) {
    this.replies.addAll(replies);
  }

  @override
  final AiProviderKind kind;

  /// What [recipient] says (default: the provider's company).
  final String? recipientName;

  @override
  String get recipient => recipientName ?? kind.company ?? 'localhost';

  /// What [listModels] returns.
  List<AiModel> models;

  /// Thrown by [listModels] when set (a bad key, say).
  AiException? listModelsError;

  /// Answers in order; [fallback] when they run out.
  final List<FakeAiReply> replies = [];
  FakeAiReply fallback;

  /// Every request, in order.
  final requests = <AiRequest>[];

  /// How many requests were cancelled.
  int cancelled = 0;

  @override
  Future<List<AiModel>> listModels({AiCancel? cancel}) async {
    if (listModelsError case final error?) throw error;
    return models;
  }

  @override
  Stream<AiEvent> stream(AiRequest request, {AiCancel? cancel}) {
    requests.add(request);
    final reply = replies.isEmpty ? fallback : replies.removeAt(0);
    late final StreamController<AiEvent> out;
    var stopped = false;
    var finished = false;
    Future<void> run() async {
      try {
        if (reply.error case final error?) throw error;
        for (final chunk in reply.chunks ?? [reply.text]) {
          if (reply.delay > Duration.zero) {
            await Future<void>.delayed(reply.delay);
          }
          if (stopped) return;
          if (cancel?.isCancelled ?? false) throw aiCancelled;
          out.add(AiTextDelta(chunk));
        }
        out.add(
          AiCompleted(
            AiResponse(
              text: reply.text,
              usage: reply.usage,
              stopReason: reply.stopReason,
              model: request.model,
              toolCalls: reply.toolCalls,
            ),
          ),
        );
      } on AiException catch (e) {
        if (e.problem == AiProblem.cancelled) cancelled++;
        if (!stopped) out.addError(e);
      } finally {
        finished = true;
        if (!stopped) await out.close();
      }
    }

    out = StreamController<AiEvent>(
      onListen: () => unawaited(run()),
      onCancel: () {
        if (!stopped && !finished) cancelled++;
        stopped = true;
      },
    );
    return out.stream;
  }
}

/// Settings in memory.
final class MemoryAiStore implements AiStore {
  final values = <String, String>{};

  @override
  String? read(String key) => values[key];

  @override
  void write(String key, String value) => values[key] = value;

  @override
  void delete(String key) => values.remove(key);
}
