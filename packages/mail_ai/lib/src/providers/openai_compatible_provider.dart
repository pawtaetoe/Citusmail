// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import '../ai_errors.dart';
import '../ai_provider.dart';
import '../ai_types.dart';
import '../transport/ai_http.dart';
import 'http_errors.dart';
import 'sse.dart';

/// GPT (OpenAI), Meta's Llama API and any custom endpoint, through the
/// OpenAI Chat Completions shape that all of them speak:
///
/// - `POST {base}/chat/completions` with `Authorization: Bearer <key>`
///   (no header for a custom endpoint without a key), streamed as
///   server-sent events ending with `data: [DONE]`, with
///   `stream_options.include_usage` so the last event has the tokens.
/// - JSON answers with `response_format: {type: json_schema, ...,
///   strict: true}`; tools as `function` tools with `strict: true`.
/// - A refusal comes as `refusal` text or `finish_reason:
///   content_filter`.
/// - `GET {base}/models` lists the models.
///
/// What differs between them is kept in [OpenAiDialect], so a change at
/// one provider is a change in one place.
final class OpenAiCompatibleProvider extends AiProvider {
  OpenAiCompatibleProvider({
    required this.kind,
    required Uri baseUrl,
    required this.http,
    this.apiKey,
  }) : _base = baseUrl,
       dialect = OpenAiDialect.of(kind);

  @override
  final AiProviderKind kind;

  final String? apiKey;
  final OpenAiDialect dialect;
  final Uri _base;

  /// How requests reach the provider.
  final AiHttp http;

  @override
  String get recipient =>
      kind.company ??
      (_base.hasPort ? '${_base.host}:${_base.port}' : _base.host);

  Uri _url(String path) =>
      _base.replace(path: '${_base.path.replaceAll(RegExp(r'/+$'), '')}$path');

  Map<String, String> get _headers => {
    if (apiKey case final key? when key.isNotEmpty)
      'authorization': 'Bearer $key',
  };

  @override
  Future<List<AiModel>> listModels({AiCancel? cancel}) async {
    final response = await http.send(
      AiHttpRequest('GET', _url('/models'), headers: _headers),
      cancel: cancel,
    );
    if (response.statusCode != 200) {
      final error = await errorFrom(response);
      // A models list that isn't there is a wrong address, not a model.
      if (error.problem == AiProblem.modelNotFound) {
        throw AiException(
          AiProblem.badRequest,
          'no models list at ${_url('/models')}',
        );
      }
      throw error;
    }
    final json = await readJson(response);
    final data = json['data'];
    if (data is! List) {
      throw const AiException(AiProblem.badResponse, 'no models list');
    }
    final models = [
      for (final item in data.whereType<Map<String, Object?>>())
        if (item['id'] case final String id
            when id.isNotEmpty && dialect.isChatModel(id))
          AiModel(
            id,
            name: item['name'] as String?,
            contextTokens: item['context_length'] as int?,
          ),
    ]..sort((a, b) => a.id.compareTo(b.id));
    return models;
  }

  /// The request body for [request].
  Map<String, Object?> requestBody(AiRequest request) => {
    'model': request.model,
    'messages': [
      if (request.system case final system? when system.isNotEmpty)
        {'role': 'system', 'content': system},
      for (final m in request.messages) ..._messages(m),
    ],
    'stream': true,
    'stream_options': {'include_usage': true},
    dialect.maxTokensField: request.maxOutputTokens,
    if (request.jsonSchema case final schema?)
      'response_format': {
        'type': 'json_schema',
        'json_schema': {
          'name': schema.name,
          'schema': schema.schema,
          'strict': true,
        },
      },
    if (request.tools.isNotEmpty)
      'tools': [
        for (final tool in request.tools)
          {
            'type': 'function',
            'function': {
              'name': tool.name,
              'description': tool.description,
              'parameters': tool.inputSchema,
              'strict': true,
            },
          },
      ],
  };

  static List<Map<String, Object?>> _messages(AiMessage m) => switch (m.role) {
    AiRole.assistant => [
      {
        'role': 'assistant',
        'content': m.text.isEmpty && m.toolCalls.isNotEmpty ? null : m.text,
        if (m.toolCalls.isNotEmpty)
          'tool_calls': [
            for (final call in m.toolCalls)
              {
                'id': call.id,
                'type': 'function',
                'function': {
                  'name': call.name,
                  'arguments': jsonEncode(call.input),
                },
              },
          ],
      },
    ],
    AiRole.user => [
      for (final result in m.toolResults)
        {
          'role': 'tool',
          'tool_call_id': result.toolCallId,
          'content': result.content,
        },
      if (m.text.isNotEmpty || m.toolResults.isEmpty)
        {'role': 'user', 'content': m.text},
    ],
  };

  @override
  Stream<AiEvent> stream(AiRequest request, {AiCancel? cancel}) async* {
    final response = await http.send(
      AiHttpRequest(
        'POST',
        _url('/chat/completions'),
        headers: {
          ..._headers,
          'content-type': 'application/json',
          'accept': 'text/event-stream',
        },
        body: utf8.encode(jsonEncode(requestBody(request))),
      ),
      cancel: cancel,
    );
    if (response.statusCode != 200) throw await errorFrom(response);

    final text = StringBuffer();
    final refusal = StringBuffer();
    final calls = <int, ({StringBuffer args, String? id, String? name})>{};
    var usage = AiUsage.zero;
    var model = request.model;
    String? finish;
    var done = false;
    try {
      await for (final event in parseSse(response.body)) {
        if (event.data.trim() == '[DONE]') {
          done = true;
          break;
        }
        final Object? data;
        try {
          data = jsonDecode(event.data);
        } on FormatException {
          throw const AiException(AiProblem.badResponse, 'unreadable event');
        }
        if (data is! Map<String, Object?>) continue;
        if (data['error'] case final error?) {
          final message = error is Map<String, Object?>
              ? error['message']?.toString() ?? 'error'
              : error.toString();
          throw AiException(AiProblem.server, message);
        }
        model = data['model'] as String? ?? model;
        if (data['usage'] case final Map<String, Object?> u) {
          usage = AiUsage(
            inputTokens: u['prompt_tokens'] as int? ?? usage.inputTokens,
            outputTokens: u['completion_tokens'] as int? ?? usage.outputTokens,
          );
        }
        final choices = data['choices'];
        if (choices is! List || choices.isEmpty) continue;
        final choice = choices.first;
        if (choice is! Map<String, Object?>) continue;
        finish = choice['finish_reason'] as String? ?? finish;
        final delta = choice['delta'];
        if (delta is! Map<String, Object?>) continue;
        if (delta['content'] case final String piece when piece.isNotEmpty) {
          text.write(piece);
          yield AiTextDelta(piece);
        }
        if (delta['refusal'] case final String piece) refusal.write(piece);
        if (delta['tool_calls'] case final List<Object?> list) {
          for (final call in list.whereType<Map<String, Object?>>()) {
            final index = call['index'] as int? ?? 0;
            final function = call['function'];
            final old = calls[index];
            final entry = (
              args: old?.args ?? StringBuffer(),
              id: old?.id ?? call['id'] as String?,
              name:
                  old?.name ??
                  (function is Map<String, Object?>
                      ? function['name'] as String?
                      : null),
            );
            if (function is Map<String, Object?>) {
              entry.args.write(function['arguments'] as String? ?? '');
            }
            calls[index] = entry;
          }
        }
      }
    } on FormatException {
      throw const AiException(AiProblem.badResponse, 'unreadable answer');
    }
    // Some servers end without [DONE] once the answer is finished.
    if (!done && finish == null) {
      if (cancel?.isCancelled ?? false) throw aiCancelled;
      throw const AiException(AiProblem.badResponse, 'the answer ended early');
    }
    final refused = refusal.isNotEmpty || finish == 'content_filter';
    yield AiCompleted(
      AiResponse(
        text: text.isEmpty && refusal.isNotEmpty
            ? refusal.toString()
            : text.toString(),
        usage: usage,
        stopReason: refused
            ? AiStopReason.refusal
            : switch (finish) {
                'stop' => AiStopReason.finished,
                'length' => AiStopReason.maxTokens,
                'tool_calls' || 'function_call' => AiStopReason.toolUse,
                _ => AiStopReason.other,
              },
        model: model,
        toolCalls: [
          for (final index in calls.keys.toList()..sort())
            AiToolCall(
              id: calls[index]!.id ?? 'call_$index',
              name: calls[index]!.name ?? '',
              input: _object(calls[index]!.args.toString()),
            ),
        ],
      ),
    );
  }

  static Map<String, Object?> _object(String json) {
    if (json.trim().isEmpty) return const {};
    try {
      final value = jsonDecode(json);
      return value is Map<String, Object?> ? value : const {};
    } on FormatException {
      return const {};
    }
  }
}

/// How one OpenAI-compatible provider differs from the others.
final class OpenAiDialect {
  const OpenAiDialect({
    required this.maxTokensField,
    this.chatModelsOnly = false,
  });

  /// OpenAI: `max_completion_tokens` (its reasoning models refuse
  /// `max_tokens`); listed models include embeddings, speech and images,
  /// which can't answer.
  static const openai = OpenAiDialect(
    maxTokensField: 'max_completion_tokens',
    chatModelsOnly: true,
  );

  /// Meta's Llama API names the limit `max_completion_tokens`.
  static const llama = OpenAiDialect(maxTokensField: 'max_completion_tokens');

  /// Other endpoints (Ollama, LM Studio, OpenRouter, Groq, Together):
  /// `max_tokens`, which they all accept.
  static const custom = OpenAiDialect(maxTokensField: 'max_tokens');

  static OpenAiDialect of(AiProviderKind kind) => switch (kind) {
    AiProviderKind.openai => openai,
    AiProviderKind.llama => llama,
    _ => custom,
  };

  final String maxTokensField;

  /// Whether to leave out models that can't chat.
  final bool chatModelsOnly;

  static final _notChat = RegExp(
    'embedding|whisper|tts|dall-e|davinci|babbage|moderation|transcribe|'
    'realtime|audio|image|search|computer-use|sora',
  );

  bool isChatModel(String id) {
    if (!chatModelsOnly) return true;
    final lower = id.toLowerCase();
    return RegExp(r'^(gpt-|chatgpt-|o\d)').hasMatch(lower) &&
        !_notChat.hasMatch(lower);
  }
}
