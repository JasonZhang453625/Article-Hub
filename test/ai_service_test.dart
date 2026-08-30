import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:memora/data/models/ai_thinking_level.dart';
import 'package:memora/data/models/ai_image_input.dart';
import 'package:memora/data/models/memory_document.dart';
import 'package:memora/data/services/ai_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'long article is summarized in bounded chunks before final synthesis',
    () async {
      final userMessageLengths = <int>[];
      var requestCount = 0;

      final client = MockClient((request) async {
        requestCount++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final messages = body['messages'] as List<dynamic>;
        final userMessage =
            (messages.last as Map<String, dynamic>)['content'] as String;
        userMessageLengths.add(userMessage.length);

        final content = requestCount <= 3
            ? 'Chunk summary $requestCount'
            : jsonEncode({
                'schemaVersion': 1,
                'title': 'Useful title',
                'tags': ['Agents', 'Tracing'],
                'overview': 'Useful overview',
                'keyPoints': [
                  {'topic': 'Handoff', 'content': 'Agents can delegate work.'},
                  {'topic': 'Tracing', 'content': 'Tracing records execution.'},
                ],
                'conclusion': 'Useful conclusion',
              });
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': content},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final ai = AiService(
        baseUrl: 'https://example.com/v1',
        apiKey: 'test-key',
        model: 'test-model',
      );
      final content = List.filled(25000, '文').join();

      final result = await http.runWithClient(
        () => ai.summarizeWithTitle(
          'Original title',
          content,
          languageHint: '中文',
        ),
        () => client,
      );

      expect(requestCount, 4);
      expect(userMessageLengths.take(3), everyElement(lessThan(12100)));
      expect(userMessageLengths.last, lessThan(1000));
      expect(result.title, 'Useful title');
      expect(result.tags, ['Agents', 'Tracing']);
      expect(result.memory?.kind, MemoryKind.aiMemory);
      expect(result.memory?.overview, 'Useful overview');
      expect(result.memory?.keyPoints, hasLength(2));
      expect(result.memory?.keyPoints.first.id, isNotEmpty);
      expect(result.memory?.keyPoints.first.order, 1);
      expect(result.memory?.keyPoints.last.order, 2);
      expect(result.summary, contains('Useful overview'));
      expect(ai.lastError, isNull);
    },
  );

  test('preserves provider error details for the caller', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'error': {'message': 'context length exceeded'},
        }),
        400,
      ),
    );
    final ai = AiService(
      baseUrl: 'https://example.com/v1',
      apiKey: 'test-key',
      model: 'test-model',
    );

    final result = await http.runWithClient(
      () => ai.summarizeWithTitle('Title', 'Content'),
      () => client,
    );

    expect(result.memory, isNull);
    expect(ai.lastError, 'HTTP 400: context length exceeded');
  });

  test('uses Xiaomi MiMo completion controls for summary requests', () async {
    int? requestedMaxCompletionTokens;
    Map<String, dynamic>? requestedThinking;
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      requestedMaxCompletionTokens = body['max_completion_tokens'] as int?;
      requestedThinking = body['thinking'] as Map<String, dynamic>?;
      expect(body.containsKey('max_tokens'), isFalse);
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {
                'content':
                    '{"schemaVersion":1,"title":"Embodied intelligence",'
                    '"tags":["Robotics","AI"],"overview":"Summary ready",'
                    '"keyPoints":[{"topic":"Embodiment",'
                    '"content":"Models act in the physical world."}],'
                    '"conclusion":"Embodied systems connect models and action."}',
              },
              'finish_reason': 'stop',
            },
          ],
        }),
        200,
      );
    });
    final ai = AiService(
      baseUrl: 'https://token-plan-cn.xiaomimimo.com/v1',
      apiKey: 'test-key',
      model: 'mimo-v2.5',
    );

    final result = await http.runWithClient(
      () => ai.summarizeWithTitle('Title', 'Content'),
      () => client,
    );

    expect(requestedMaxCompletionTokens, 4000);
    expect(requestedThinking, {'type': 'disabled'});
    expect(result.memory?.overview, 'Summary ready');
    expect(result.tags, ['Robotics', 'AI']);
  });

  test('accepts fenced JSON but assigns key-point identity locally', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {
                'content': '''```json
{"schemaVersion":1,"title":"T","tags":["A","B"],"overview":"O","keyPoints":[{"id":"model-id","order":99,"topic":"Topic","content":"Fact"}],"conclusion":"C"}
```''',
              },
            },
          ],
        }),
        200,
      ),
    );
    final ai = AiService(
      baseUrl: 'https://example.com/v1',
      apiKey: 'test-key',
      model: 'test-model',
    );

    final result = await http.runWithClient(
      () => ai.summarizeWithTitle('Title', 'Content'),
      () => client,
    );

    expect(result.memory?.keyPoints.single.id, isNot('model-id'));
    expect(result.memory?.keyPoints.single.order, 1);
  });

  test(
    'rejects incomplete structured JSON instead of storing raw output',
    () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '{"title":"Missing memory fields"}'},
              },
            ],
          }),
          200,
        ),
      );
      final ai = AiService(
        baseUrl: 'https://example.com/v1',
        apiKey: 'test-key',
        model: 'test-model',
      );

      final result = await http.runWithClient(
        () => ai.summarizeWithTitle('Title', 'Content'),
        () => client,
      );

      expect(result.memory, isNull);
      expect(ai.lastError, contains('structured memory'));
    },
  );

  test('chat keeps system first and the latest user message last', () async {
    late List<dynamic> messages;
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      messages = body['messages'] as List<dynamic>;
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'Current answer'},
              'finish_reason': 'stop',
            },
          ],
        }),
        200,
      );
    });
    final ai = AiService(
      baseUrl: 'https://example.com/v1',
      apiKey: 'test-key',
      model: 'test-model',
    );

    final result = await http.runWithClient(
      () => ai.chat(
        systemPrompt: 'System rules',
        userMessage: 'Current question',
        history: const [
          {'role': 'user', 'content': 'Earlier question'},
          {'role': 'assistant', 'content': 'Earlier answer'},
        ],
      ),
      () => client,
    );

    expect(result, 'Current answer');
    expect((messages.first as Map)['role'], 'system');
    expect((messages.first as Map)['content'], 'System rules');
    expect((messages.last as Map)['role'], 'user');
    expect((messages.last as Map)['content'], 'Current question');
  });

  test('classic chat models send only max_tokens', () async {
    late Map<String, dynamic> payload;
    final client = MockClient((request) async {
      payload = jsonDecode(request.body) as Map<String, dynamic>;
      if (payload.containsKey('max_tokens') &&
          payload.containsKey('max_completion_tokens')) {
        return http.Response(
          jsonEncode({
            'error': {
              'message':
                  "Both 'max_tokens' and 'max_completion_tokens' were supplied.",
            },
          }),
          400,
        );
      }
      return _chatResponse('ok');
    });
    final ai = AiService(
      baseUrl: 'https://example.com/v1',
      apiKey: 'test-key',
      model: 'gpt-4o-mini',
    );

    final result = await http.runWithClient(
      () => ai.chat(systemPrompt: 's', userMessage: 'u'),
      () => client,
    );

    expect(result, 'ok');
    expect(payload['max_tokens'], 800);
    expect(payload.containsKey('max_completion_tokens'), isFalse);
  });

  test('OpenAI reasoning models send only max_completion_tokens', () async {
    for (final model in ['gpt-5-mini', 'openai/o3-mini']) {
      late Map<String, dynamic> payload;
      final client = MockClient((request) async {
        payload = jsonDecode(request.body) as Map<String, dynamic>;
        return _chatResponse('ok');
      });
      final ai = AiService(
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'test-key',
        model: model,
      );

      final result = await http.runWithClient(
        () => ai.chat(systemPrompt: 's', userMessage: 'u'),
        () => client,
      );

      expect(result, 'ok', reason: model);
      expect(payload['max_completion_tokens'], 800, reason: model);
      expect(payload.containsKey('max_tokens'), isFalse, reason: model);
    }
  });

  test(
    'MiMo chat keeps its single token field and disables thinking',
    () async {
      late Map<String, dynamic> payload;
      final client = MockClient((request) async {
        payload = jsonDecode(request.body) as Map<String, dynamic>;
        return _chatResponse('ok');
      });
      final ai = AiService(
        baseUrl: 'https://token-plan-cn.xiaomimimo.com/v1',
        apiKey: 'test-key',
        model: 'mimo-v2.5',
      );

      await http.runWithClient(
        () => ai.chat(systemPrompt: 's', userMessage: 'u'),
        () => client,
      );

      expect(payload['max_completion_tokens'], 800);
      expect(payload.containsKey('max_tokens'), isFalse);
      expect(payload['thinking'], {'type': 'disabled'});
    },
  );

  test('DeepSeek chat maps four UI levels to four provider states', () async {
    final expected = <AiThinkingLevel, Map<String, dynamic>>{
      AiThinkingLevel.none: {
        'thinking': {'type': 'disabled'},
      },
      AiThinkingLevel.low: {
        'thinking': {'type': 'enabled'},
        'reasoning_effort': 'low',
      },
      AiThinkingLevel.medium: {
        'thinking': {'type': 'enabled'},
        'reasoning_effort': 'high',
      },
      AiThinkingLevel.max: {
        'thinking': {'type': 'enabled'},
        'reasoning_effort': 'max',
      },
    };

    for (final entry in expected.entries) {
      late Map<String, dynamic> payload;
      final client = MockClient((request) async {
        payload = jsonDecode(request.body) as Map<String, dynamic>;
        return _chatResponse('ok');
      });
      final ai = AiService(
        baseUrl: 'https://api.deepseek.com',
        apiKey: 'test-key',
        model: 'deepseek-v4-pro',
        thinkingLevel: entry.key,
      );

      await http.runWithClient(
        () => ai.chat(systemPrompt: 's', userMessage: 'u'),
        () => client,
      );

      expect(
        payload['thinking'],
        entry.value['thinking'],
        reason: '${entry.key}',
      );
      expect(
        payload['reasoning_effort'],
        entry.value['reasoning_effort'],
        reason: '${entry.key}',
      );
      expect(payload['max_tokens'], 800, reason: '${entry.key}');
      expect(
        payload.containsKey('temperature'),
        entry.key == AiThinkingLevel.none,
        reason: '${entry.key}',
      );
    }
  });

  for (final statusCode in [429, 503]) {
    test('chat retries HTTP $statusCode once and then succeeds', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        if (calls == 1) {
          return http.Response(
            jsonEncode({
              'error': {'message': 'transient failure'},
            }),
            statusCode,
          );
        }
        return _chatResponse('recovered');
      });
      final ai = AiService(
        baseUrl: 'https://example.com/v1',
        apiKey: 'test-key',
        model: 'gpt-4o-mini',
        retryDelay: Duration.zero,
      );

      final result = await http.runWithClient(
        () => ai.chat(systemPrompt: 's', userMessage: 'u'),
        () => client,
      );

      expect(result, 'recovered');
      expect(calls, 2);
      expect(ai.lastError, isNull);
    });
  }

  test('chat retries a timeout once and then succeeds', () async {
    var calls = 0;
    final firstRequest = Completer<void>();
    final client = MockClient((request) async {
      calls++;
      if (calls == 1) await firstRequest.future;
      return _chatResponse('recovered');
    });
    final ai = AiService(
      baseUrl: 'https://example.com/v1',
      apiKey: 'test-key',
      model: 'gpt-4o-mini',
      timeout: const Duration(milliseconds: 5),
      retryDelay: Duration.zero,
    );

    final result = await http.runWithClient(
      () => ai.chat(systemPrompt: 's', userMessage: 'u'),
      () => client,
    );
    firstRequest.complete();

    expect(result, 'recovered');
    expect(calls, 2);
    expect(ai.lastError, isNull);
  });

  test('chat retries a connection abort once and then succeeds', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (calls == 1) {
        throw http.ClientException(
          'Software caused connection abort',
          request.url,
        );
      }
      return _chatResponse('recovered after background switch');
    });
    final ai = AiService(
      baseUrl: 'https://example.com/v1',
      apiKey: 'test-key',
      model: 'gpt-4o-mini',
      retryDelay: Duration.zero,
    );

    final result = await http.runWithClient(
      () => ai.chat(systemPrompt: 's', userMessage: 'u'),
      () => client,
    );

    expect(result, 'recovered after background switch');
    expect(calls, 2);
    expect(ai.lastError, isNull);
  });

  test('chat does not retry HTTP 400 and preserves provider details', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response(
        jsonEncode({
          'error': {'message': 'invalid token parameter'},
        }),
        400,
      );
    });
    final ai = AiService(
      baseUrl: 'https://example.com/v1',
      apiKey: 'test-key',
      model: 'gpt-4o-mini',
      retryDelay: Duration.zero,
    );

    final result = await http.runWithClient(
      () => ai.chat(systemPrompt: 's', userMessage: 'u'),
      () => client,
    );

    expect(result, isNull);
    expect(calls, 1);
    expect(ai.lastError, 'HTTP 400: invalid token parameter');
  });

  test('chatStream sends SSE mode and yields each assistant delta', () async {
    late Map<String, dynamic> payload;
    late Map<String, String> headers;
    final client = MockClient.streaming((request, bodyStream) async {
      payload =
          jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>;
      headers = request.headers;
      return http.StreamedResponse(
        Stream<List<int>>.fromIterable([
          utf8.encode('data: {"choices":[{"delta":{"role":"assistant"}}]}\n\n'),
          utf8.encode('data: {"choices":[{"delta":{"content":"Hello"}}]}\n\n'),
          utf8.encode('data: {"choices":[{"delta":{"content":" world"}}]}\n\n'),
          utf8.encode(
            'data: {"choices":[{"delta":{},"finish_reason":"stop"}],'
            '"usage":{"total_tokens":12}}\n\n',
          ),
          utf8.encode('data: [DONE]\n\n'),
        ]),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final ai = AiService(
      baseUrl: 'https://example.com/v1',
      apiKey: 'test-key',
      model: 'gpt-4o-mini',
    );
    var usedTokens = 0;
    ai.onTokensUsed = (tokens) => usedTokens = tokens;

    final chunks = await http.runWithClient(
      () => ai
          .chatStream(systemPrompt: 'system', userMessage: 'question')
          .toList(),
      () => client,
    );

    expect(chunks, ['Hello', ' world']);
    expect(payload['stream'], isTrue);
    expect(headers['accept'], 'text/event-stream');
    expect(usedTokens, 12);
    expect(ai.lastError, isNull);
  });

  test('chatStream retries a pre-token transient HTTP response', () async {
    var calls = 0;
    final client = MockClient.streaming((request, _) async {
      calls++;
      if (calls == 1) {
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable([
            utf8.encode('{"error":{"message":"temporary"}}'),
          ]),
          503,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.StreamedResponse(
        Stream<List<int>>.fromIterable([
          utf8.encode('data: {"choices":[{"delta":{"content":"ok"}}]}\n\n'),
          utf8.encode('data: [DONE]\n\n'),
        ]),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final ai = AiService(
      baseUrl: 'https://example.com/v1',
      apiKey: 'test-key',
      model: 'gpt-4o-mini',
      retryDelay: Duration.zero,
    );

    final chunks = await http.runWithClient(
      () => ai
          .chatStream(systemPrompt: 'system', userMessage: 'question')
          .toList(),
      () => client,
    );

    expect(chunks, ['ok']);
    expect(calls, 2);
    expect(ai.lastError, isNull);
  });

  test(
    'chatStream keeps partial output and does not replay after a stream abort',
    () async {
      var calls = 0;
      Stream<List<int>> brokenBody() async* {
        yield utf8.encode(
          'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n',
        );
        throw http.ClientException('Software caused connection abort');
      }

      final client = MockClient.streaming((request, _) async {
        calls++;
        return http.StreamedResponse(
          brokenBody(),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final ai = AiService(
        baseUrl: 'https://example.com/v1',
        apiKey: 'test-key',
        model: 'gpt-4o-mini',
        retryDelay: Duration.zero,
      );

      final chunks = await http.runWithClient(
        () => ai
            .chatStream(systemPrompt: 'system', userMessage: 'question')
            .toList(),
        () => client,
      );

      expect(chunks, ['partial']);
      expect(calls, 1);
      expect(ai.lastError, contains('connection abort'));
    },
  );

  test('chatStream rejects a clean EOF without the SSE done marker', () async {
    final client = MockClient.streaming((request, _) async {
      return http.StreamedResponse(
        Stream<List<int>>.fromIterable([
          utf8.encode(
            'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n',
          ),
        ]),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final ai = AiService(
      baseUrl: 'https://example.com/v1',
      apiKey: 'test-key',
      model: 'gpt-4o-mini',
      retryDelay: Duration.zero,
    );

    final chunks = await http.runWithClient(
      () => ai
          .chatStream(systemPrompt: 'system', userMessage: 'question')
          .toList(),
      () => client,
    );

    expect(chunks, ['partial']);
    expect(ai.lastError, contains('ended before [DONE]'));
  });

  test(
    'multimodal chat emits OpenAI image blocks in the user message',
    () async {
      late Map<String, dynamic> payload;
      final client = MockClient.streaming((request, bodyStream) async {
        payload =
            jsonDecode(await bodyStream.bytesToString())
                as Map<String, dynamic>;
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable([
            utf8.encode('data: {"choices":[{"delta":{"content":"ok"}}]}\n\n'),
            utf8.encode('data: [DONE]\n\n'),
          ]),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final ai = AiService(
        baseUrl: 'https://example.com/v1',
        apiKey: 'test-key',
        model: 'gpt-4o-mini',
      );

      final chunks = await http.runWithClient(
        () => ai
            .chatStreamWithImages(
              systemPrompt: 'system',
              userMessage: 'question',
              images: [
                AiImageInput(
                  id: 'image-1',
                  fileName: 'chart.png',
                  mimeType: 'image/png',
                  bytes: Uint8List.fromList([1, 2, 3]),
                ),
              ],
            )
            .toList(),
        () => client,
      );

      final messages = payload['messages'] as List<dynamic>;
      final content = (messages.last as Map)['content'] as List<dynamic>;
      expect(chunks, ['ok']);
      expect((content.first as Map)['type'], 'text');
      expect((content.last as Map)['type'], 'image_url');
      expect(
        ((content.last as Map)['image_url'] as Map)['url'],
        'data:image/png;base64,AQID',
      );
    },
  );
}

http.Response _chatResponse(String content) {
  return http.Response(
    jsonEncode({
      'choices': [
        {
          'message': {'content': content},
          'finish_reason': 'stop',
        },
      ],
    }),
    200,
  );
}
