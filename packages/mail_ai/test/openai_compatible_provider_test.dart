// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:mail_ai/mail_ai.dart';
import 'package:test/test.dart';

import 'support/fake_server.dart';

/// GPT, Meta's Muse models and custom endpoints, against a stand-in for the
/// Chat Completions API.
void main() {
  late FakeServer server;

  Map<String, Object?> chunk(
    Map<String, Object?> delta, {
    String? finish,
    Map<String, Object?>? usage,
  }) => {
    'id': 'chatcmpl-1',
    'object': 'chat.completion.chunk',
    'model': 'gpt-test',
    'choices': [
      {'index': 0, 'delta': delta, 'finish_reason': finish},
    ],
    'usage': ?usage,
  };

  List<String> answer({
    List<String> text = const ['Hi', ' there'],
    String finish = 'stop',
    List<Map<String, Object?>> extra = const [],
    bool done = true,
  }) => [
    sse(chunk({'role': 'assistant', 'content': ''})),
    for (final piece in text) sse(chunk({'content': piece})),
    for (final e in extra) sse(e),
    sse(chunk({}, finish: finish)),
    // With include_usage, a last chunk without choices has the tokens.
    sse({
      'id': 'chatcmpl-1',
      'object': 'chat.completion.chunk',
      'model': 'gpt-test',
      'choices': <Object?>[],
      'usage': {
        'prompt_tokens': 900,
        'completion_tokens': 42,
        'total_tokens': 942,
      },
    }),
    if (done) sse('[DONE]'),
  ];

  setUp(() async {
    server = await FakeServer.start((request) => Reply.events(answer()));
  });
  tearDown(() => server.close());

  OpenAiCompatibleProvider provider(AiProviderKind kind, {String? key}) =>
      OpenAiCompatibleProvider(
        kind: kind,
        baseUrl: server.url.replace(path: '/v1'),
        http: IoAiHttp(),
        apiKey: key,
      );

  test('GPT: models listed, only those that can chat', () async {
    server.handler = (_) => Reply.json({
      'object': 'list',
      'data': [
        for (final id in [
          'gpt-5',
          'text-embedding-3-large',
          'gpt-4o-mini-tts',
          'o4-mini',
          'dall-e-3',
          'whisper-1',
          'gpt-image-1',
          'chatgpt-4o-latest',
        ])
          {'id': id, 'object': 'model', 'owned_by': 'openai'},
      ],
    });
    final models = await provider(
      AiProviderKind.openai,
      key: 'sk-test',
    ).listModels();
    expect(models.map((m) => m.id), ['chatgpt-4o-latest', 'gpt-5', 'o4-mini']);
    final request = server.requests.single;
    expect(request.uri.path, '/v1/models');
    expect(request.headers.value('authorization'), 'Bearer sk-test');
  });

  test(
    'a custom endpoint lists every model, and sends no key if none',
    () async {
      server.handler = (_) => Reply.json({
        'data': [
          {'id': 'llama3.2:3b'},
          {'id': 'qwen3:8b'},
        ],
      });
      final models = await provider(AiProviderKind.custom).listModels();
      expect(models.map((m) => m.id), ['llama3.2:3b', 'qwen3:8b']);
      expect(server.requests.single.headers.value('authorization'), isNull);
    },
  );

  test('Gemini lists only its chat models, by the id requests use', () async {
    server.handler = (_) => Reply.json({
      'data': [
        {'id': 'models/gemini-3-flash'},
        {'id': 'models/gemini-3-pro'},
        {'id': 'models/gemini-embedding-001'},
        {'id': 'models/gemini-3-flash-image'},
        {'id': 'models/gemini-live-3-flash'},
        {'id': 'models/imagen-4.0-generate'},
        {'id': 'models/text-embedding-004'},
      ],
    });
    final models = await provider(
      AiProviderKind.google,
      key: 'AIza-test',
    ).listModels();
    expect(models.map((m) => m.id), ['gemini-3-flash', 'gemini-3-pro']);
    expect(
      server.requests.single.headers.value('authorization'),
      'Bearer AIza-test',
    );
  });

  test('Gemini answers with max_tokens as its limit', () async {
    const request = AiRequest(
      model: 'gemini-3-flash',
      messages: [AiMessage.user('x')],
    );
    await provider(AiProviderKind.google, key: 'AIza-test').complete(request);
    expect(server.requests.last.uri.path, endsWith('/chat/completions'));
    expect(server.requests.last.json['max_tokens'], 4096);
    expect(server.requests.last.json['model'], 'gemini-3-flash');
  });

  test('a wrong address is not a missing model', () async {
    server.handler = (_) => const Reply(404, body: 'not found');
    await expectLater(
      provider(AiProviderKind.custom).listModels(),
      throwsA(
        isA<AiException>()
            .having((e) => e.problem, 'problem', AiProblem.badRequest)
            .having((e) => e.message, 'message', contains('/v1/models')),
      ),
    );
  });

  test('GPT: the request shape, streamed back with usage', () async {
    final events = await provider(AiProviderKind.openai, key: 'sk-test')
        .stream(
          const AiRequest(
            model: 'gpt-5',
            system: 'Summarise.',
            messages: [AiMessage.user('the email')],
            maxOutputTokens: 3000,
            effort: AiEffort.low,
          ),
        )
        .toList();
    expect(events.whereType<AiTextDelta>().map((e) => e.text), [
      'Hi',
      ' there',
    ]);
    final response = (events.last as AiCompleted).response;
    expect(response.text, 'Hi there');
    expect(response.stopReason, AiStopReason.finished);
    expect(response.usage, const AiUsage(inputTokens: 900, outputTokens: 42));
    expect(response.model, 'gpt-test');

    final request = server.requests.single;
    expect(request.method, 'POST');
    expect(request.uri.path, '/v1/chat/completions');
    expect(request.headers.value('authorization'), 'Bearer sk-test');
    expect(request.json, {
      'model': 'gpt-5',
      'messages': [
        {'role': 'system', 'content': 'Summarise.'},
        {'role': 'user', 'content': 'the email'},
      ],
      'stream': true,
      'stream_options': {'include_usage': true},
      'max_completion_tokens': 3000,
    });
  });

  test('Meta and custom endpoints: their names for the limit', () async {
    const request = AiRequest(model: 'm', messages: [AiMessage.user('x')]);
    await provider(AiProviderKind.meta, key: 'meta-key').complete(request);
    expect(server.requests.last.json['max_completion_tokens'], 4096);
    expect(
      server.requests.last.headers.value('authorization'),
      'Bearer meta-key',
    );
    await provider(AiProviderKind.custom).complete(request);
    expect(server.requests.last.json['max_tokens'], 4096);
    expect(
      server.requests.last.json.keys,
      isNot(contains('max_completion_tokens')),
    );
  });

  test('structured output with a strict JSON schema', () async {
    server.handler = (_) => Reply.events(answer(text: ['{"ok":', 'true}']));
    const schema = {
      'type': 'object',
      'properties': {
        'ok': {'type': 'boolean'},
      },
      'required': ['ok'],
      'additionalProperties': false,
    };
    final response = await provider(AiProviderKind.openai, key: 'k').complete(
      const AiRequest(
        model: 'gpt-5',
        messages: [AiMessage.user('x')],
        jsonSchema: AiJsonSchema(name: 'answer', schema: schema),
      ),
    );
    expect(response.json, {'ok': true});
    expect(server.requests.single.json['response_format'], {
      'type': 'json_schema',
      'json_schema': {'name': 'answer', 'schema': schema, 'strict': true},
    });
  });

  test('a refusal, as text or as a content filter', () async {
    server.handler = (_) => Reply.events(
      answer(
        text: [],
        extra: [
          chunk({'refusal': 'I can\'t help with that.'}),
        ],
      ),
    );
    final refused = await provider(AiProviderKind.openai, key: 'k').complete(
      const AiRequest(model: 'gpt-5', messages: [AiMessage.user('x')]),
    );
    expect(refused.stopReason, AiStopReason.refusal);
    expect(refused.text, 'I can\'t help with that.');

    server.handler = (_) => Reply.events(answer(finish: 'content_filter'));
    final filtered = await provider(AiProviderKind.custom)
        .complete(const AiRequest(model: 'm', messages: [AiMessage.user('x')]));
    expect(filtered.stopReason, AiStopReason.refusal);
  });

  test('tool calls, put together from their pieces, and sent back', () async {
    server.handler = (_) => Reply.events(
      answer(
        text: [],
        finish: 'tool_calls',
        extra: [
          chunk({
            'tool_calls': [
              {
                'index': 0,
                'id': 'call_1',
                'type': 'function',
                'function': {'name': 'move', 'arguments': '{"fol'},
              },
            ],
          }),
          chunk({
            'tool_calls': [
              {
                'index': 0,
                'function': {'arguments': 'der":"Bills"}'},
              },
            ],
          }),
        ],
      ),
    );
    const tool = AiTool(
      name: 'move',
      description: 'Move it.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'folder': {'type': 'string'},
        },
        'required': ['folder'],
        'additionalProperties': false,
      },
    );
    final gpt = provider(AiProviderKind.openai, key: 'k');
    final response = await gpt.complete(
      const AiRequest(
        model: 'gpt-5',
        messages: [AiMessage.user('file it')],
        tools: [tool],
      ),
    );
    expect(response.stopReason, AiStopReason.toolUse);
    expect(response.toolCalls.single.id, 'call_1');
    expect(response.toolCalls.single.input, {'folder': 'Bills'});
    expect(server.requests.last.json['tools'], [
      {
        'type': 'function',
        'function': {
          'name': 'move',
          'description': 'Move it.',
          'parameters': tool.inputSchema,
          'strict': true,
        },
      },
    ]);
    expect(server.requests.last.json.keys, isNot(contains('tool_choice')));

    await gpt.complete(
      AiRequest(
        model: 'gpt-5',
        messages: [
          const AiMessage.user('file it'),
          AiMessage.fromResponse(response),
          const AiMessage.user(
            '',
            toolResults: [AiToolResult(toolCallId: 'call_1', content: 'moved')],
          ),
        ],
      ),
    );
    final messages = server.requests.last.json['messages']! as List<Object?>;
    expect(messages[1], {
      'role': 'assistant',
      'content': null,
      'tool_calls': [
        {
          'id': 'call_1',
          'type': 'function',
          'function': {'name': 'move', 'arguments': '{"folder":"Bills"}'},
        },
      ],
    });
    expect(messages[2], {
      'role': 'tool',
      'tool_call_id': 'call_1',
      'content': 'moved',
    });
    expect(messages, hasLength(3));
  });

  test('a server that ends without [DONE] after finishing is fine', () async {
    server.handler = (_) => Reply.events(answer(done: false));
    final response = await provider(AiProviderKind.custom)
        .complete(const AiRequest(model: 'm', messages: [AiMessage.user('x')]));
    expect(response.text, 'Hi there');
  });

  group('errors', () {
    Future<AiException> failWith(Reply reply) async {
      server.handler = (_) => reply;
      try {
        await provider(AiProviderKind.openai, key: 'k').complete(
          const AiRequest(model: 'gpt-5', messages: [AiMessage.user('x')]),
        );
      } on AiException catch (e) {
        return e;
      }
      fail('no error');
    }

    Map<String, Object?> error(String code, String message, {String? type}) => {
      'error': {
        'message': message,
        'type': type ?? 'invalid_request_error',
        'param': null,
        'code': code,
      },
    };

    test('bad key, rate limit, no credit, too long', () async {
      expect(
        (await failWith(
          Reply.json(
            error('invalid_api_key', 'Incorrect API key provided'),
            status: 401,
          ),
        )).problem,
        AiProblem.badKey,
      );
      final limited = await failWith(
        Reply.json(
          error('rate_limit_exceeded', 'Rate limit reached', type: 'requests'),
          status: 429,
          headers: {'retry-after-ms': '1500'},
        ),
      );
      expect(limited.problem, AiProblem.rateLimited);
      expect(limited.retryAfter, const Duration(milliseconds: 1500));
      expect(
        (await failWith(
          Reply.json(
            error(
              'insufficient_quota',
              'You exceeded your current quota',
              type: 'insufficient_quota',
            ),
            status: 429,
          ),
        )).problem,
        AiProblem.billing,
      );
      expect(
        (await failWith(
          Reply.json(
            error(
              'context_length_exceeded',
              'This model\'s maximum context length is 128000 tokens.',
            ),
            status: 400,
          ),
        )).problem,
        AiProblem.contextTooLong,
      );
      expect(
        (await failWith(const Reply(502, body: '<html>Bad gateway</html>')))
            .problem,
        AiProblem.server,
      );
    });

    test('an error inside the stream', () async {
      final e = await failWith(
        Reply.events([
          sse(chunk({'content': 'Hi'})),
          sse({
            'error': {'message': 'model crashed'},
          }),
        ]),
      );
      expect(e.problem, AiProblem.server);
      expect(e.message, 'model crashed');
    });

    test('an answer that stops early', () async {
      final e = await failWith(
        Reply.events([
          sse(chunk({'content': 'Hi'})),
        ]),
      );
      expect(e.problem, AiProblem.badResponse);
    });
  });

  group('the factory', () {
    test('each provider at its own address', () {
      final gpt = AiProviders.create(
        const AiProviderConfig(kind: AiProviderKind.openai, apiKey: 'k'),
      );
      expect(gpt, isA<OpenAiCompatibleProvider>());
      expect(gpt.recipient, 'OpenAI');
      final meta = AiProviders.create(
        const AiProviderConfig(kind: AiProviderKind.meta, apiKey: 'k'),
      );
      expect(meta.recipient, 'Meta');
      expect(
        AiProviderKind.meta.defaultBaseUrl.toString(),
        'https://api.meta.ai/v1',
      );
      final gemini = AiProviders.create(
        const AiProviderConfig(kind: AiProviderKind.google, apiKey: 'k'),
      );
      expect(gemini, isA<OpenAiCompatibleProvider>());
      expect(gemini.recipient, 'Google');
      expect(
        AiProviderKind.google.defaultBaseUrl.toString(),
        'https://generativelanguage.googleapis.com/v1beta/openai',
      );
      final claude = AiProviders.create(
        const AiProviderConfig(kind: AiProviderKind.claude, apiKey: 'k'),
      );
      expect(claude, isA<AnthropicProvider>());
      expect(claude.recipient, 'Anthropic');
      final local = AiProviders.create(
        AiProviderConfig(
          kind: AiProviderKind.custom,
          baseUrl: Uri.parse('http://192.168.1.20:1234/v1'),
        ),
      );
      expect(local.recipient, '192.168.1.20:1234');
    });

    test('a key where one is needed; an address for a custom endpoint', () {
      expect(
        () => AiProviders.create(
          const AiProviderConfig(kind: AiProviderKind.claude, apiKey: ' '),
        ),
        throwsA(isA<AiException>()),
      );
      expect(
        () => AiProviders.create(
          const AiProviderConfig(kind: AiProviderKind.custom),
        ),
        throwsA(
          isA<AiException>().having(
            (e) => e.problem,
            'problem',
            AiProblem.notConfigured,
          ),
        ),
      );
    });
  });

  group('the HTTP client', () {
    Future<AiException> refused(
      Uri url, {
      List<InternetAddress>? resolves,
    }) async {
      final http = IoAiHttp(lookup: (_) async => resolves ?? []);
      try {
        await http.send(AiHttpRequest('GET', url));
      } on AiException catch (e) {
        return e;
      }
      fail('not refused');
    }

    test('plain http only into your own network', () async {
      final public = await refused(
        Uri.parse('http://models.example.com/v1/models'),
        resolves: [InternetAddress('93.184.216.34')],
      );
      expect(public.problem, AiProblem.badRequest);
      expect(public.message, contains('https'));
      // A name that is also public is refused even if one address is local.
      expect(
        (await refused(
          Uri.parse('http://mixed.example.com/v1'),
          resolves: [
            InternetAddress('192.168.1.5'),
            InternetAddress('93.184.216.34'),
          ],
        )).problem,
        AiProblem.badRequest,
      );
      expect(
        (await refused(Uri.parse('http://8.8.8.8/v1'))).problem,
        AiProblem.badRequest,
      );
      // Local addresses are fine (the test server is one).
      final ok = await IoAiHttp().send(AiHttpRequest('GET', server.url));
      expect(ok.statusCode, 200);
      await ok.body.drain<void>();
    });

    test('no user names in addresses, no other schemes', () async {
      expect(
        (await refused(Uri.parse('https://user:pw@api.example.com/'))).problem,
        AiProblem.badRequest,
      );
      expect(
        (await refused(Uri.parse('ftp://api.example.com/'))).problem,
        AiProblem.badRequest,
      );
    });

    test('redirects are not followed', () async {
      server.handler = (_) => const Reply(
        302,
        headers: {'location': 'http://127.0.0.1:1/elsewhere'},
      );
      final response = await IoAiHttp().send(AiHttpRequest('GET', server.url));
      expect(response.statusCode, 302);
      await response.body.drain<void>();
      expect(server.requests, hasLength(1));
    });
  });
}
