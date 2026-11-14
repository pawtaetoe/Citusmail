// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';

/// The services the assistant can use, each with the user's own key.
enum AiProviderKind {
  /// Claude, through Anthropic's Messages API.
  claude(
    'Claude (Anthropic)',
    'Anthropic',
    'https://api.anthropic.com',
    needsKey: true,
  ),

  /// GPT, through OpenAI's Chat Completions API.
  openai('GPT (OpenAI)', 'OpenAI', 'https://api.openai.com/v1', needsKey: true),

  /// Meta's Llama API, through its OpenAI-compatible endpoint.
  llama(
    'Meta Llama',
    'Meta',
    'https://api.llama.com/compat/v1',
    needsKey: true,
  ),

  /// Any OpenAI-compatible endpoint the user names: OpenRouter, Groq,
  /// Together, or a model on their own computer or network (Ollama, LM
  /// Studio), which needs no key.
  custom('Custom (OpenAI-compatible)', null, null, needsKey: false);

  const AiProviderKind(
    this.label,
    this.company,
    this._baseUrl, {
    required this.needsKey,
  });

  /// As the settings show it.
  final String label;

  /// Who receives what is sent ("Sent to Anthropic"); null for [custom],
  /// where it is the endpoint's host.
  final String? company;

  final String? _baseUrl;

  /// Whether a key is required (a local model needs none).
  final bool needsKey;

  /// Where requests go, unless the user named another (only [custom]).
  Uri? get defaultBaseUrl => switch (_baseUrl) {
    final url? => Uri.parse(url),
    null => null,
  };

  /// The model chosen first when this provider is added, if its models
  /// list offers it (null: the first model the list names).
  String? get defaultModel => switch (this) {
    claude => 'claude-opus-5-5',
    openai || llama || custom => null,
  };

  /// The stored name, stable across versions.
  String get id => name;

  static AiProviderKind? byId(String? id) =>
      values.where((k) => k.id == id).firstOrNull;
}

/// One model a provider offers, as its models list names it.
final class AiModel {
  const AiModel(
    this.id, {
    String? name,
    this.contextTokens,
    this.maxOutputTokens,
    this.supportsEffort,
    this.supportsStructuredOutput,
  }) : name = name ?? id;

  /// What requests name.
  final String id;

  /// What people see.
  final String name;

  /// When the provider says (null: unknown).
  final int? contextTokens;
  final int? maxOutputTokens;
  final bool? supportsEffort;
  final bool? supportsStructuredOutput;

  @override
  bool operator ==(Object other) => other is AiModel && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'AiModel($id)';
}

enum AiRole { user, assistant }

/// One turn of the conversation sent to the model.
final class AiMessage {
  const AiMessage(
    this.role,
    this.text, {
    this.toolCalls = const [],
    this.toolResults = const [],
    this.providerContent,
  });

  const AiMessage.user(this.text, {this.toolResults = const []})
    : role = AiRole.user,
      toolCalls = const [],
      providerContent = null;

  const AiMessage.assistant(
    this.text, {
    this.toolCalls = const [],
    this.providerContent,
  }) : role = AiRole.assistant,
       toolResults = const [];

  /// An earlier answer's turn as the model gave it.
  factory AiMessage.fromResponse(AiResponse response) => AiMessage.assistant(
    response.text,
    toolCalls: response.toolCalls,
    providerContent: response.providerContent,
  );

  final AiRole role;
  final String text;

  /// On an assistant turn: the tools the model asked to use.
  final List<AiToolCall> toolCalls;

  /// On a user turn: the answers to those calls.
  final List<AiToolResult> toolResults;

  /// On an assistant turn: the provider's own content of that answer
  /// ([AiResponse.providerContent]), sent back exactly as it came (some
  /// models need their reasoning back in a tool loop). Ignored by other
  /// providers.
  final ProviderContent? providerContent;
}

/// An answer's content in one provider's own form, for sending it back.
final class ProviderContent {
  const ProviderContent(this.kind, this.blocks);

  final AiProviderKind kind;
  final List<Object?> blocks;
}

/// A tool the model may ask the app to use (later stages: actions the
/// user then confirms). The app never runs one without the user.
final class AiTool {
  const AiTool({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  final String name;

  /// When to use it, for the model.
  final String description;

  /// JSON Schema of its input (an object; every object needs
  /// `additionalProperties: false` for strict use).
  final Map<String, Object?> inputSchema;
}

/// The model asking for a tool.
final class AiToolCall {
  const AiToolCall({required this.id, required this.name, required this.input});

  final String id;
  final String name;
  final Map<String, Object?> input;
}

/// The app's answer to an [AiToolCall].
final class AiToolResult {
  const AiToolResult({
    required this.toolCallId,
    required this.content,
    this.isError = false,
  });

  final String toolCallId;
  final String content;
  final bool isError;
}

/// Structured output: the answer is a JSON object matching [schema].
final class AiJsonSchema {
  const AiJsonSchema({required this.name, required this.schema});

  /// A short name (letters, digits, `_`), for providers that want one.
  final String name;

  /// JSON Schema of the answer; every object needs
  /// `additionalProperties: false`.
  final Map<String, Object?> schema;
}

/// How much the model may think before answering, where the model lets
/// the caller choose: less is faster and cheaper.
enum AiEffort { low, medium, high }

/// One request: instructions, the conversation, and what to answer with.
final class AiRequest {
  const AiRequest({
    required this.model,
    required this.messages,
    this.system,
    this.maxOutputTokens = 4096,
    this.jsonSchema,
    this.tools = const [],
    this.effort,
  });

  /// An [AiModel.id].
  final String model;

  /// The instructions (for mail, from [MailPrompt]).
  final String? system;
  final List<AiMessage> messages;

  /// Upper limit of what the answer may cost in output tokens (on models
  /// that think first, the thinking counts too).
  final int maxOutputTokens;

  /// Ask for a JSON object matching this schema.
  final AiJsonSchema? jsonSchema;

  /// Tools the model may ask for (never forced).
  final List<AiTool> tools;

  /// Where the model supports it; ignored elsewhere.
  final AiEffort? effort;
}

/// Tokens one call used, as the provider counted them.
final class AiUsage {
  const AiUsage({this.inputTokens = 0, this.outputTokens = 0});

  static const zero = AiUsage();

  final int inputTokens;
  final int outputTokens;

  AiUsage operator +(AiUsage other) => AiUsage(
    inputTokens: inputTokens + other.inputTokens,
    outputTokens: outputTokens + other.outputTokens,
  );

  @override
  bool operator ==(Object other) =>
      other is AiUsage &&
      other.inputTokens == inputTokens &&
      other.outputTokens == outputTokens;

  @override
  int get hashCode => Object.hash(inputTokens, outputTokens);

  @override
  String toString() => 'AiUsage(in: $inputTokens, out: $outputTokens)';
}

/// Why the answer ended.
enum AiStopReason {
  /// It was complete.
  finished,

  /// It reached [AiRequest.maxOutputTokens]: it may be cut off.
  maxTokens,

  /// The model asked for tools ([AiResponse.toolCalls]).
  toolUse,

  /// The model or the provider's safety checks declined.
  refusal,

  other,
}

/// A whole answer.
final class AiResponse {
  const AiResponse({
    required this.text,
    required this.usage,
    required this.stopReason,
    required this.model,
    this.toolCalls = const [],
    this.providerContent,
  });

  final String text;

  /// The answer as the provider gave it, for a tool loop
  /// ([AiMessage.fromResponse]).
  final ProviderContent? providerContent;
  final List<AiToolCall> toolCalls;
  final AiUsage usage;
  final AiStopReason stopReason;

  /// The model that answered, as the provider named it.
  final String model;

  /// [text] as the JSON object a [AiRequest.jsonSchema] asked for, or
  /// null if it isn't one.
  Map<String, Object?>? get json {
    try {
      final value = jsonDecode(text.trim());
      return value is Map<String, Object?> ? value : null;
    } on FormatException {
      return null;
    }
  }
}

/// What [AiProvider.stream] gives: text as it is written, then the whole
/// answer.
sealed class AiEvent {
  const AiEvent();
}

/// More of the answer's text.
final class AiTextDelta extends AiEvent {
  const AiTextDelta(this.text);

  final String text;
}

/// The answer is complete (always the last event).
final class AiCompleted extends AiEvent {
  const AiCompleted(this.response);

  final AiResponse response;
}

/// Stops a request that is under way: the connection is closed and the
/// stream ends with [AiProblem.cancelled]. Cancelling the stream's
/// subscription does the same.
final class AiCancel {
  final _done = Completer<void>();

  bool get isCancelled => _done.isCompleted;

  /// Completes when [cancel] is called.
  Future<void> get whenCancelled => _done.future;

  void cancel() {
    if (!_done.isCompleted) _done.complete();
  }
}
