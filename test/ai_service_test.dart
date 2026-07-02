import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:memora/data/services/ai_service.dart';

void main() {
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
            : '{"title":"Useful title","summary":"Useful summary"}';
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
      expect(result.summary, 'Useful summary');
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

    expect(result.summary, isNull);
    expect(ai.lastError, 'HTTP 400: context length exceeded');
  });

  test('uses Xiaomi MiMo completion controls for summary requests', () async {
    int? requestedMaxCompletionTokens;
    Map<String, dynamic>? requestedThinking;
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      requestedMaxCompletionTokens =
          body['max_completion_tokens'] as int?;
      requestedThinking = body['thinking'] as Map<String, dynamic>?;
      expect(body.containsKey('max_tokens'), isFalse);
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {
                'content':
                    '{"title":"Embodied intelligence","summary":"Summary ready"}'
              },
              'finish_reason': 'stop',
            }
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
    expect(result.summary, 'Summary ready');
  });
}
