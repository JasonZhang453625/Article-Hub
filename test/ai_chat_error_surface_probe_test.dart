import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/source_platform.dart';
import 'package:memora/data/services/prompt_service.dart';
import 'package:memora/data/services/rag_conversation_service.dart';
import 'package:memora/data/services/retrieval_service.dart';

/// Simulates the exact user-visible error strings for common provider
/// failure modes, tracing where the real cause gets lost.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final prompts = PromptService();
  final sLocale = _MockLocaleStrings();

  Future<RagConversationResult> runAsk({
    required Future<String?> Function(dynamic args) completion,
  }) async {
    final service = RagConversationService(
      retrieve: (query, articles) async => RetrievalResult(
        articles: articles,
        method: RetrievalMethod.hybrid,
        duration: const Duration(milliseconds: 1),
        candidateIds: articles.map((a) => a.id).toList(),
      ),
      complete: ({
        required String systemPrompt,
        required String userMessage,
        List<Map<String, String>> history = const [],
        double temperature = 0.3,
        int maxTokens = 800,
      }) => completion(null),
      saveLog: (log) async {},
      promptService: prompts,
    );
    return service.ask(
      RagConversationRequest(
        question: '测试问题',
        articles: [article],
        knowledgeOnly: false,
        detailedAnswer: false,
        languageHint: '',
      ),
    );
  }

  test('PROBE: provider HTTP 400 surfaces as misleading "empty response"',
      () async {
    final result = await runAsk(completion: (_) async => null);
    // AiService.chat() returns null on 400; the real reason lives in
    // ai.lastError which never reaches the RAG layer.
    expect(result.outcome, RagConversationOutcome.error);
    print('PROBE error: ${result.error}');
    print('PROBE user sees: ${sLocale.aiError}: ${result.error}');
    expect(result.error, 'empty response');
  });

  test('PROBE: timeout also surfaces as "empty response"', () async {
    final result = await runAsk(completion: (_) async => null);
    print('PROBE timeout user sees: ${sLocale.aiError}: ${result.error}');
    expect(result.error, 'empty response');
  });

  test('PROBE: empty content from model surfaces as "empty response"',
      () async {
    final result = await runAsk(completion: (_) async => '   ');
    expect(result.outcome, RagConversationOutcome.error);
    print('PROBE empty-content user sees: ${sLocale.aiError}: ${result.error}');
    expect(result.error, 'empty response');
  });

  test('PROBE: no retry is attempted on transient failures', () async {
    var calls = 0;
    final result = await runAsk(
      completion: (_) async {
        calls++;
        return null; // e.g. 429 rate-limit / 5xx / timeout
      },
    );
    print('PROBE completion calls=$calls outcome=${result.outcome}');
    expect(calls, 1, reason: 'no automatic retry on transient failure');
    expect(result.outcome, RagConversationOutcome.error);
  });
}

class _MockLocaleStrings {
  String get aiError => '与 AI 服务通信出错';
}

final article = Article(
  id: 'a1',
  title: '测试文章',
  url: 'https://example.com/a',
  source: SourcePlatform.web,
  createdAt: null,
  updatedAt: null,
  processingStatus: ProcessingStatus.completed,
  notes: '测试文章内容',
  tags: ['测试'],
);
