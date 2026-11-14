// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:mail_ai/mail_ai.dart';
import 'package:test/test.dart';

import 'support/fake_server.dart';

/// The Claude adapter against a stand-in for the Messages API.
void main() {
  late FakeServer server;
  late AnthropicProvider claude;

  const opus = {
    'id': 'claude-opus-5-5',
    'display_name': 'Claude Opus 5.5',
    'type': 'model',
    'max_input_tokens': 1000000,
    'max_tokens': 128000,
    'capabilities': {
      'effort': {'supported': true},
      'structured_outputs': {'supported': true},
      'thinking': {
        'supported': true,
        'types': {
          'adaptive': {'supported': true},
          'enabled': {'supported': false},
        },
      },
    },
  };
  const oldHaiku = {
    'id': 'claude-haiku-4-5',
    'display_name': 'Claude Haiku 4.5',
    'capabilities': {
      'effort': {'supported': false},
      'structured_outputs': {'supported': true},
      'thinking': {
        'supported': true,
        'types': {
          'adaptive': {'supported': false},
          'enabled': {'supported': true},
        },
      },
    },
  };

  /// A whole streamed answer, as the API sends it.
  List<String> answer({
    List<String> text = const ['Hello', ' Alice'],
    String stopReason = 'end_turn',
    List<String> extra = const [],
  }) => [
    sse({
      'type': 'message_start',
      'message': {
        'id': 'msg_1',
        'type': 'message',
        'role': 'assistant',
        'model': 'claude-opus-5-5',
        'content': <Object?>[],
        'usage': {
          'input_tokens': 1200,
          'cache_creation_input_tokens': 0,
          'cache_read_input_tokens': 0,
          'output_tokens': 1,
        },
      },
    }, event: 'message_start'),
    sse({'type': 'ping'}, event: 'ping'),
    // Thinking first (its text omitted), then the answer.
    sse({
      'type': 'content_block_start',
      'index': 0,
      'content_block': {'type': 'thinking', 'thinking': ''},
    }, event: 'content_block_start'),
    sse({
      'type': 'content_block_delta',
      'index': 0,
      'delta': {'type': 'signature_delta', 'signature': 'sig=='},
    }, event: 'content_block_delta'),
    sse({
      'type': 'content_block_stop',
      'index': 0,
    }, event: 'content_block_stop'),
    sse({
      'type': 'content_block_start',
      'index': 1,
      'content_block': {'type': 'text', 'text': ''},
    }, event: 'content_block_start'),
    for (final piece in text)
      sse({
        'type': 'content_block_delta',
        'index': 1,
        'delta': {'type': 'text_delta', 'text': piece},
      }, event: 'content_block_delta'),
    sse({
      'type': 'content_block_stop',
      'index': 1,
    }, event: 'content_block_stop'),
    ...extra,
    sse({
      'type': 'message_delta',
      'delta': {'stop_reason': stopReason, 'stop_sequence': null},
      'usage': {'output_tokens': 87},
    }, event: 'message_delta'),
    sse({'type': 'message_stop'}, event: 'message_stop'),
  ];

  setUp(() async {
    AnthropicProvider.forgetModels();
    server = await FakeServer.start((request) {
      if (request.uri.path == '/v1/models/claude-opus-5-5') {
        return Reply.json(opus);
      }
      if (request.uri.path == '/v1/models/claude-haiku-4-5') {
        return Reply.json(oldHaiku);
      }
      return Reply.events(answer());
    });
    claude = AnthropicProvider(
      apiKey: 'sk-ant-test',
      http: IoAiHttp(),
      baseUrl: server.url,
    );
  });
  tearDown(() => server.close());

  Received messagesRequest() =>
      server.requests.lastWhere((r) => r.uri.path == '/v1/messages');

  test('lists models from the models endpoint, page by page', () async {
    server.handler = (request) =>
        request.uri.queryParameters['after_id'] == null
        ? Reply.json({
            'data': [opus],
            'has_more': true,
            'first_id': 'claude-opus-5-5',
            'last_id': 'claude-opus-5-5',
          })
        : Reply.json({
            'data': [oldHaiku],
            'has_more': false,
            'last_id': 'claude-haiku-4-5',
          });
    final models = await claude.listModels();
    expect(models.map((m) => m.id), ['claude-opus-5-5', 'claude-haiku-4-5']);
    expect(models.first.name, 'Claude Opus 5.5');
    expect(models.first.contextTokens, 1000000);
    expect(models.first.maxOutputTokens, 128000);
    expect(models.first.supportsEffort, isTrue);
    expect(models.last.supportsEffort, isFalse);

    final first = server.requests.first;
    expect(first.method, 'GET');
    expect(first.uri.path, '/v1/models');
    expect(first.uri.queryParameters['limit'], '1000');
    expect(first.headers.value('x-api-key'), 'sk-ant-test');
    expect(first.headers.value('anthropic-version'), '2026-10-21');
    expect(first.headers.value('authorization'), isNull);
    expect(
      server.requests.last.uri.queryParameters['after_id'],
      'claude-opus-5-5',
    );
  });

  test('a request: the documented shape, streamed back as it comes', () async {
    final events = await claude
        .stream(
          const AiRequest(
            model: 'claude-opus-5-5',
            system: 'Summarise.',
            messages: [AiMessage.user('the email')],
            maxOutputTokens: 6000,
            effort: AiEffort.low,
          ),
        )
        .toList();
    expect(events.whereType<AiTextDelta>().map((e) => e.text), [
      'Hello',
      ' Alice',
    ]);
    final response = (events.last as AiCompleted).response;
    expect(response.text, 'Hello Alice');
    expect(response.stopReason, AiStopReason.finished);
    expect(response.model, 'claude-opus-5-5');
    expect(response.usage, const AiUsage(inputTokens: 1200, outputTokens: 87));

    final request = messagesRequest();
    expect(request.method, 'POST');
    expect(request.headers.value('x-api-key'), 'sk-ant-test');
    expect(request.headers.value('anthropic-version'), '2026-10-21');
    expect(request.headers.contentType?.mimeType, 'application/json');
    expect(request.json, {
      'model': 'claude-opus-5-5',
      'max_tokens': 6000,
      'stream': true,
      'system': 'Summarise.',
      'messages': [
        {'role': 'user', 'content': 'the email'},
      ],
      'thinking': {'type': 'adaptive'},
      'output_config': {'effort': 'low'},
    });
    // Sampling settings are refused on this API version.
    expect(request.json.keys, isNot(contains('temperature')));
    expect(request.json.keys, isNot(contains('top_p')));
  });

  test('a model without effort or adaptive thinking gets neither', () async {
    await claude.complete(
      const AiRequest(
        model: 'claude-haiku-4-5',
        messages: [AiMessage.user('x')],
        effort: AiEffort.low,
      ),
    );
    final json = messagesRequest().json;
    expect(json.containsKey('thinking'), isFalse);
    expect(json.containsKey('output_config'), isFalse);
  });

  test('structured output through output_config.format', () async {
    server.handler = (request) => request.uri.path.startsWith('/v1/models/')
        ? Reply.json(opus)
        : Reply.events(answer(text: ['{"category": ', '"bills"}']));
    const schema = {
      'type': 'object',
      'properties': {
        'category': {'type': 'string'},
      },
      'required': ['category'],
      'additionalProperties': false,
    };
    final response = await claude.complete(
      const AiRequest(
        model: 'claude-opus-5-5',
        messages: [AiMessage.user('x')],
        jsonSchema: AiJsonSchema(name: 'sort', schema: schema),
      ),
    );
    expect(response.json, {'category': 'bills'});
    expect(messagesRequest().json['output_config'], {
      'format': {'type': 'json_schema', 'schema': schema},
    });
  });

  test('tools: strict, never forced; calls come back, and go back', () async {
    server.handler = (request) => request.uri.path.startsWith('/v1/models/')
        ? Reply.json(opus)
        : Reply.events(
            answer(
              text: ['I will move it.'],
              stopReason: 'tool_use',
              extra: [
                sse({
                  'type': 'content_block_start',
                  'index': 2,
                  'content_block': {
                    'type': 'tool_use',
                    'id': 'toolu_1',
                    'name': 'move',
                    'input': <String, Object?>{},
                  },
                }, event: 'content_block_start'),
                sse({
                  'type': 'content_block_delta',
                  'index': 2,
                  'delta': {
                    'type': 'input_json_delta',
                    'partial_json': '{"folder": ',
                  },
                }, event: 'content_block_delta'),
                sse({
                  'type': 'content_block_delta',
                  'index': 2,
                  'delta': {
                    'type': 'input_json_delta',
                    'partial_json': '"Bills"}',
                  },
                }, event: 'content_block_delta'),
                sse({
                  'type': 'content_block_stop',
                  'index': 2,
                }, event: 'content_block_stop'),
              ],
            ),
          );
    const tool = AiTool(
      name: 'move',
      description: 'Move the email to a folder.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'folder': {'type': 'string'},
        },
        'required': ['folder'],
        'additionalProperties': false,
      },
    );
    final response = await claude.complete(
      const AiRequest(
        model: 'claude-opus-5-5',
        messages: [AiMessage.user('file this')],
        tools: [tool],
      ),
    );
    expect(response.stopReason, AiStopReason.toolUse);
    final call = response.toolCalls.single;
    expect(call.id, 'toolu_1');
    expect(call.name, 'move');
    expect(call.input, {'folder': 'Bills'});
    final sent = messagesRequest().json;
    expect(sent['tools'], [
      {
        'name': 'move',
        'description': 'Move the email to a folder.',
        'input_schema': tool.inputSchema,
        'strict': true,
      },
    ]);
    expect(sent.containsKey('tool_choice'), isFalse);

    // The next turn sends the answer back as it came (thinking included)
    // with the tool's result.
    await claude.complete(
      AiRequest(
        model: 'claude-opus-5-5',
        messages: [
          const AiMessage.user('file this'),
          AiMessage.fromResponse(response),
          const AiMessage.user(
            '',
            toolResults: [AiToolResult(toolCallId: 'toolu_1', content: 'done')],
          ),
        ],
        tools: const [tool],
      ),
    );
    final messages = messagesRequest().json['messages']! as List<Object?>;
    final assistant = messages[1]! as Map<String, Object?>;
    final blocks = assistant['content']! as List<Object?>;
    expect(blocks.map((b) => (b! as Map<String, Object?>)['type']), [
      'thinking',
      'text',
      'tool_use',
    ]);
    expect((blocks.first! as Map<String, Object?>)['signature'], 'sig==');
    expect((blocks.last! as Map<String, Object?>)['input'], {
      'folder': 'Bills',
    });
    expect(messages[2], {
      'role': 'user',
      'content': [
        {'type': 'tool_result', 'tool_use_id': 'toolu_1', 'content': 'done'},
      ],
    });
  });

  test('a refusal ends the answer as refused', () async {
    server.handler = (request) => request.uri.path.startsWith('/v1/models/')
        ? Reply.json(opus)
        : Reply.events(answer(text: [], stopReason: 'refusal'));
    final response = await claude.complete(
      const AiRequest(
        model: 'claude-opus-5-5',
        messages: [AiMessage.user('x')],
      ),
    );
    expect(response.stopReason, AiStopReason.refusal);
    expect(response.text, isEmpty);
  });

  group('errors', () {
    Future<AiException> failWith(Reply reply) async {
      server.handler = (request) =>
          request.uri.path.startsWith('/v1/models/') ? Reply.json(opus) : reply;
      try {
        await claude.complete(
          const AiRequest(
            model: 'claude-opus-5-5',
            messages: [AiMessage.user('x')],
          ),
        );
      } on AiException catch (e) {
        return e;
      }
      fail('no error');
    }

    Map<String, Object?> error(String type, String message) => {
      'type': 'error',
      'error': {'type': type, 'message': message},
      'request_id': 'req_1',
    };

    test('a bad key', () async {
      final e = await failWith(
        Reply.json(
          error('authentication_error', 'invalid x-api-key'),
          status: 401,
        ),
      );
      expect(e.problem, AiProblem.badKey);
      expect(e.explain('Anthropic'), contains('didn\'t accept the key'));
    });

    test('rate limited, with the wait asked for', () async {
      final e = await failWith(
        Reply.json(
          error('rate_limit_error', 'Number of requests has exceeded'),
          status: 429,
          headers: {'retry-after': '30'},
        ),
      );
      expect(e.problem, AiProblem.rateLimited);
      expect(e.retryAfter, const Duration(seconds: 30));
      expect(e.explain('Anthropic'), contains('30 seconds'));
    });

    test('too long, no credit, overloaded, unknown model', () async {
      expect(
        (await failWith(
          Reply.json(
            error(
              'invalid_request_error',
              'prompt is too long: 1200000 tokens > 1000000 maximum',
            ),
            status: 400,
          ),
        )).problem,
        AiProblem.contextTooLong,
      );
      expect(
        (await failWith(
          Reply.json(
            error(
              'invalid_request_error',
              'Your credit balance is too low to access the Anthropic API.',
            ),
            status: 400,
          ),
        )).problem,
        AiProblem.billing,
      );
      expect(
        (await failWith(
          Reply.json(error('overloaded_error', 'Overloaded'), status: 529),
        )).problem,
        AiProblem.server,
      );
      expect(
        (await failWith(
          Reply.json(error('not_found_error', 'model: claude-x'), status: 404),
        )).problem,
        AiProblem.modelNotFound,
      );
    });

    test('an error in the middle of the stream', () async {
      final e = await failWith(
        Reply.events([
          ...answer().take(3),
          sse({
            'type': 'error',
            'error': {'type': 'overloaded_error', 'message': 'Overloaded'},
          }, event: 'error'),
        ]),
      );
      expect(e.problem, AiProblem.server);
    });

    test('an answer that stops early', () async {
      final e = await failWith(Reply.events(answer().take(5).toList()));
      expect(e.problem, AiProblem.badResponse);
    });

    test('nobody there', () async {
      await server.close();
      final e = await failWith(const Reply(200));
      expect(e.problem, AiProblem.network);
    });
  });

  test('cancel stops the answer and closes the connection', () async {
    server.handler = (request) => request.uri.path.startsWith('/v1/models/')
        ? Reply.json(opus)
        : Reply.events(
            answer(text: List.filled(50, 'word ')),
            delay: const Duration(milliseconds: 20),
          );
    final cancel = AiCancel();
    final pieces = <String>[];
    Object? error;
    final done = Completer<void>();
    claude
        .stream(
          const AiRequest(
            model: 'claude-opus-5-5',
            messages: [AiMessage.user('x')],
          ),
          cancel: cancel,
        )
        .listen(
          (event) {
            if (event is AiTextDelta) {
              pieces.add(event.text);
              cancel.cancel();
            }
          },
          onError: (Object e) => error = e,
          onDone: done.complete,
        );
    await done.future.timeout(const Duration(seconds: 10));
    expect(pieces.length, lessThan(50));
    expect(
      error,
      isA<AiException>().having(
        (e) => e.problem,
        'problem',
        AiProblem.cancelled,
      ),
    );
  });

  test('cancelling the subscription closes the connection too', () async {
    server.handler = (request) => request.uri.path.startsWith('/v1/models/')
        ? Reply.json(opus)
        : Reply.events(
            answer(text: List.filled(100, 'word ')),
            delay: const Duration(milliseconds: 20),
          );
    final first = await claude
        .stream(
          const AiRequest(
            model: 'claude-opus-5-5',
            messages: [AiMessage.user('x')],
          ),
        )
        .firstWhere((e) => e is AiTextDelta);
    expect((first as AiTextDelta).text, 'word ');
    // Closed while the server still had most of the answer to send.
    for (var i = 0; i < 20 && server.openConnections > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(server.openConnections, 0);
  });
}
