import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:memora/data/services/ai_service.dart';
import 'package:memora/data/services/prompt_service.dart';
import 'package:memora/data/services/rag_context_builder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AiService.chat payload', () {
    test('PROBE: non-MiMo models send BOTH max_tokens and max_completion_tokens',
        () async {
      Map<String, dynamic>? captured;
      final client = MockClient((request) async {
        captured = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'ok'},
                'finish_reason': 'stop',
              }
            ],
          }),
          200,
        );
      });

      final ai = AiService(
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'test-key',
        model: 'gpt-4o-mini',
      );
      await http.runWithClient(
        () => ai.chat(systemPrompt: 's', userMessage: 'u'),
        () => client,
      );

      expect(captured, isNotNull);
      print('PROBE payload for gpt-4o-mini: ${jsonEncode(captured)}');
      expect(captured!['max_tokens'], isNotNull);
      expect(captured!['max_completion_tokens'], isNotNull);
      // OpenAI rejects requests that carry both parameters.
    });

    test('PROBE: strict OpenAI-compatible provider rejects dual max params',
        () async {
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body.containsKey('max_tokens') &&
            body.containsKey('max_completion_tokens')) {
          return http.Response(
            jsonEncode({
              'error': {
                'message':
                    "Both 'max_tokens' and 'max_completion_tokens' were supplied. Only one may be supplied at a time.",
              },
            }),
            400,
          );
        }
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'ok'},
                'finish_reason': 'stop',
              }
            ],
          }),
          200,
        );
      });

      final ai = AiService(
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'test-key',
        model: 'gpt-4o-mini',
      );
      final result = await http.runWithClient(
        () => ai.chat(systemPrompt: 's', userMessage: 'u'),
        () => client,
      );

      expect(result, isNull);
      print('PROBE lastError: ${ai.lastError}');
      expect(ai.lastError, contains('400'));
    });
  });

  group('Token budget math for chat prompts', () {
    test('PROBE: estimate fixed prompt tokens in detailed + web mode', () async {
      final prompts = PromptService();
      final system = await prompts.load('chat/system.txt', {
        'knowledgeRule': await prompts.load('chat/knowledge_web.txt'),
        'lengthRule': await prompts.load('chat/length_detailed.txt'),
        'langHint': '',
      });
      final baseUser = await prompts.load('chat/user_web.txt', {
        'context': '',
        'question': '测试问题',
      });

      final systemTokens = RagContextBuilder.estimateTokens(system);
      final userTokens = RagContextBuilder.estimateTokens(baseUser);
      const maxOutput = 2500;
      const safety = 512;
      const priming = 3;
      final fixed = systemTokens + userTokens + maxOutput + safety + priming;
      const window = 8192;
      print('PROBE systemTokens=$systemTokens userTokens=$userTokens '
          'fixed=$fixed available=${window - fixed}');

      // Hard error "message exceeds the configured context window" happens
      // when fixed >= window.
      expect(fixed < window, isTrue,
          reason: 'detailed+web prompts should still fit the window');
    });
  });
}
