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

/// What a model accepts, from Anthropic's models list.
final class _Capabilities {
  const _Capabilities({
    required this.effort,
    required this.adaptiveThinking,
    required this.structuredOutputs,
  });

  /// Unknown: send what the default model takes.
  static const unknown = _Capabilities(
    effort: true,
    adaptiveThinking: true,
    structuredOutputs: true,
  );

  final bool effort;
  final bool adaptiveThinking;
  final bool structuredOutputs;
}

/// Claude, through Anthropic's Messages API, over plain HTTP (there is
/// no Dart SDK). Request shapes as documented for API version
/// [apiVersion]:
///
/// - `POST /v1/messages` with `x-api-key` and `anthropic-version`,
///   always streamed (server-sent events), so long answers arrive as
///   they are written.
/// - No `temperature` or `top_p` (refused on this API version).
/// - Thinking can't be turned off on the newest models: where the model
///   supports it, `thinking: {type: adaptive}`, and the depth is set
///   with `output_config.effort`.
/// - JSON answers with `output_config.format` (a JSON schema). Tools
///   are offered with `strict: true` and the default `tool_choice`
///   (auto): forcing a tool is refused by the newest models.
/// - `stop_reason: "refusal"` (the model or its safety checks declined)
///   ends the answer with [AiStopReason.refusal].
/// - `GET /v1/models` lists the models (paged), with what each supports;
///   requests to a model leave out what it doesn't support.
final class AnthropicProvider extends AiProvider {
  AnthropicProvider({required this.apiKey, required this.http, Uri? baseUrl})
    : _base = baseUrl ?? AiProviderKind.claude.defaultBaseUrl!;

  /// The `anthropic-version` header.
  static const apiVersion = '2026-10-21';

  final String apiKey;

  /// How requests reach Anthropic.
  final AiHttp http;
  final Uri _base;

  /// What each model supports, once known (shared by every instance:
  /// it doesn't depend on the key).
  static final _known = <String, _Capabilities>{};

  /// Forgets what models support (for tests).
  static void forgetModels() => _known.clear();

  @override
  AiProviderKind get kind => AiProviderKind.claude;

  @override
  String get recipient => 'Anthropic';

  Uri _url(String path, [Map<String, String>? query]) => _base.replace(
    path: '${_base.path.replaceAll(RegExp(r'/+$'), '')}$path',
    queryParameters: query,
  );

  Map<String, String> get _headers => {
    'x-api-key': apiKey,
    'anthropic-version': apiVersion,
  };

  @override
  Future<List<AiModel>> listModels({AiCancel? cancel}) async {
    final models = <AiModel>[];
    String? after;
    for (var page = 0; page < 20; page++) {
      final response = await http.send(
        AiHttpRequest(
          'GET',
          _url('/v1/models', {'limit': '1000', 'after_id': ?after}),
          headers: _headers,
        ),
        cancel: cancel,
      );
      if (response.statusCode != 200) throw await errorFrom(response);
      final json = await readJson(response);
      final data = json['data'];
      if (data is! List) {
        throw const AiException(AiProblem.badResponse, 'no models list');
      }
      for (final item in data.whereType<Map<String, Object?>>()) {
        if (_model(item) case final model?) models.add(model);
      }
      if (json['has_more'] != true || json['last_id'] is! String) break;
      after = json['last_id']! as String;
    }
    return models;
  }

  AiModel? _model(Map<String, Object?> item) {
    final id = item['id'];
    if (id is! String || id.isEmpty) return null;
    final caps = item['capabilities'];
    bool? supported(List<String> path) {
      Object? node = caps;
      for (final key in path) {
        if (node is! Map<String, Object?>) return null;
        node = node[key];
      }
      return node is Map<String, Object?> && node['supported'] is bool
          ? node['supported']! as bool
          : null;
    }

    final effort = supported(['effort']);
    final adaptive = supported(['thinking', 'types', 'adaptive']);
    final structured = supported(['structured_outputs']);
    if (caps is Map<String, Object?>) {
      _known[id] = _Capabilities(
        effort: effort ?? false,
        adaptiveThinking: adaptive ?? false,
        structuredOutputs: structured ?? false,
      );
    }
    return AiModel(
      id,
      name: item['display_name'] as String?,
      contextTokens: item['max_input_tokens'] as int?,
      maxOutputTokens: item['max_tokens'] as int?,
      supportsEffort: effort,
      supportsStructuredOutput: structured,
    );
  }

  /// [model]'s capabilities: known from a models list, else asked for
  /// once (`GET /v1/models/{id}`), else assumed like the default model.
  Future<_Capabilities> _capabilities(String model, AiCancel? cancel) async {
    if (_known[model] case final known?) return known;
    try {
      final response = await http.send(
        AiHttpRequest(
          'GET',
          _url('/v1/models/${Uri.encodeComponent(model)}'),
          headers: _headers,
        ),
        cancel: cancel,
      );
      if (response.statusCode == 200) {
        _model(await readJson(response));
      } else {
        await response.body.drain<void>();
        // Not listed: send only what every model takes.
        if (response.statusCode == 404) {
          _known[model] = const _Capabilities(
            effort: false,
            adaptiveThinking: false,
            structuredOutputs: false,
          );
        }
      }
    } on AiException catch (e) {
      if (e.problem == AiProblem.cancelled) rethrow;
    }
    return _known[model] ?? _Capabilities.unknown;
  }

  /// The request body for [request], to a model that supports [effort],
  /// [adaptiveThinking] and [structuredOutputs] (what it doesn't support
  /// is left out).
  static Map<String, Object?> requestBody(
    AiRequest request, {
    bool effort = true,
    bool adaptiveThinking = true,
    bool structuredOutputs = true,
  }) {
    final output = <String, Object?>{
      if (request.effort case final level? when effort) 'effort': level.name,
      if (request.jsonSchema case final schema? when structuredOutputs)
        'format': {'type': 'json_schema', 'schema': schema.schema},
    };
    return {
      'model': request.model,
      'max_tokens': request.maxOutputTokens,
      'stream': true,
      if (request.system case final system? when system.isNotEmpty)
        'system': system,
      'messages': [for (final m in request.messages) _message(m)],
      if (adaptiveThinking) 'thinking': {'type': 'adaptive'},
      if (output.isNotEmpty) 'output_config': output,
      if (request.tools.isNotEmpty)
        'tools': [
          for (final tool in request.tools)
            {
              'name': tool.name,
              'description': tool.description,
              'input_schema': tool.inputSchema,
              'strict': true,
            },
        ],
    };
  }

  static Map<String, Object?> _message(AiMessage m) {
    if (m.role == AiRole.assistant) {
      if (m.providerContent case final own?
          when own.kind == AiProviderKind.claude) {
        return {'role': 'assistant', 'content': own.blocks};
      }
      return {
        'role': 'assistant',
        'content': [
          if (m.text.isNotEmpty) {'type': 'text', 'text': m.text},
          for (final call in m.toolCalls)
            {
              'type': 'tool_use',
              'id': call.id,
              'name': call.name,
              'input': call.input,
            },
        ],
      };
    }
    if (m.toolResults.isEmpty) return {'role': 'user', 'content': m.text};
    return {
      'role': 'user',
      'content': [
        for (final result in m.toolResults)
          {
            'type': 'tool_result',
            'tool_use_id': result.toolCallId,
            'content': result.content,
            if (result.isError) 'is_error': true,
          },
        if (m.text.isNotEmpty) {'type': 'text', 'text': m.text},
      ],
    };
  }

  @override
  Stream<AiEvent> stream(AiRequest request, {AiCancel? cancel}) async* {
    final caps = await _capabilities(request.model, cancel);
    final response = await http.send(
      AiHttpRequest(
        'POST',
        _url('/v1/messages'),
        headers: {
          ..._headers,
          'content-type': 'application/json',
          'accept': 'text/event-stream',
        },
        body: utf8.encode(
          jsonEncode(
            requestBody(
              request,
              effort: caps.effort,
              adaptiveThinking: caps.adaptiveThinking,
              structuredOutputs: caps.structuredOutputs,
            ),
          ),
        ),
      ),
      cancel: cancel,
    );
    if (response.statusCode != 200) throw await errorFrom(response);

    final blocks = <Map<String, Object?>>[];
    final toolInput = <int, StringBuffer>{};
    final text = StringBuffer();
    var input = 0, output = 0;
    var model = request.model;
    String? stopReason;
    var stopped = false;
    try {
      await for (final event in parseSse(response.body)) {
        final Object? data;
        try {
          data = jsonDecode(event.data);
        } on FormatException {
          throw const AiException(AiProblem.badResponse, 'unreadable event');
        }
        if (data is! Map<String, Object?>) continue;
        switch (data['type']) {
          case 'message_start':
            final message = data['message'];
            if (message is Map<String, Object?>) {
              model = message['model'] as String? ?? model;
              input = _input(message['usage']) ?? input;
              output = _int(message['usage'], 'output_tokens') ?? output;
            }
          case 'content_block_start':
            final block = data['content_block'];
            final index = data['index'];
            if (block is Map<String, Object?> && index is int) {
              while (blocks.length <= index) {
                blocks.add({});
              }
              blocks[index] = Map.of(block);
              if (block['type'] == 'tool_use') {
                toolInput[index] = StringBuffer();
              }
            }
          case 'content_block_delta':
            final delta = data['delta'];
            final index = data['index'];
            if (delta is! Map<String, Object?> ||
                index is! int ||
                index >= blocks.length) {
              continue;
            }
            final block = blocks[index];
            switch (delta['type']) {
              case 'text_delta':
                final piece = delta['text'] as String? ?? '';
                block['text'] = '${block['text'] ?? ''}$piece';
                text.write(piece);
                if (piece.isNotEmpty) yield AiTextDelta(piece);
              case 'input_json_delta':
                toolInput[index]?.write(delta['partial_json'] as String? ?? '');
              case 'thinking_delta':
                block['thinking'] =
                    '${block['thinking'] ?? ''}${delta['thinking'] ?? ''}';
              case 'signature_delta':
                block['signature'] =
                    '${block['signature'] ?? ''}${delta['signature'] ?? ''}';
            }
          case 'content_block_stop':
            final index = data['index'];
            if (index is int && toolInput[index] != null) {
              blocks[index]['input'] = _object(toolInput[index].toString());
            }
          case 'message_delta':
            final delta = data['delta'];
            if (delta is Map<String, Object?>) {
              stopReason = delta['stop_reason'] as String? ?? stopReason;
            }
            output = _int(data['usage'], 'output_tokens') ?? output;
            input = _input(data['usage']) ?? input;
          case 'message_stop':
            stopped = true;
          case 'error':
            final error = data['error'];
            final type = error is Map<String, Object?> ? error['type'] : null;
            final message = error is Map<String, Object?>
                ? error['message'] as String? ?? 'error'
                : 'error';
            throw AiException(switch (type) {
              'overloaded_error' || 'api_error' => AiProblem.server,
              'rate_limit_error' => AiProblem.rateLimited,
              _ => AiProblem.badResponse,
            }, message);
        }
        if (stopped) break;
      }
    } on FormatException {
      throw const AiException(AiProblem.badResponse, 'unreadable answer');
    }
    if (!stopped) {
      if (cancel?.isCancelled ?? false) throw aiCancelled;
      throw const AiException(AiProblem.badResponse, 'the answer ended early');
    }
    yield AiCompleted(
      AiResponse(
        text: text.toString(),
        usage: AiUsage(inputTokens: input, outputTokens: output),
        stopReason: switch (stopReason) {
          'end_turn' || 'stop_sequence' => AiStopReason.finished,
          'max_tokens' ||
          'model_context_window_exceeded' => AiStopReason.maxTokens,
          'tool_use' => AiStopReason.toolUse,
          'refusal' => AiStopReason.refusal,
          _ => AiStopReason.other,
        },
        model: model,
        toolCalls: [
          for (final block in blocks)
            if (block['type'] == 'tool_use')
              AiToolCall(
                id: block['id'] as String? ?? '',
                name: block['name'] as String? ?? '',
                input: block['input'] is Map<String, Object?>
                    ? block['input']! as Map<String, Object?>
                    : const {},
              ),
        ],
        providerContent: ProviderContent(AiProviderKind.claude, [
          for (final block in blocks)
            if (block.isNotEmpty) block,
        ]),
      ),
    );
  }

  static int? _int(Object? usage, String name) =>
      usage is Map<String, Object?> && usage[name] is int
      ? usage[name]! as int
      : null;

  /// Input tokens, cached or not.
  static int? _input(Object? usage) {
    final plain = _int(usage, 'input_tokens');
    if (plain == null) return null;
    return plain +
        (_int(usage, 'cache_creation_input_tokens') ?? 0) +
        (_int(usage, 'cache_read_input_tokens') ?? 0);
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
