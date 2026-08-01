import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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
}
