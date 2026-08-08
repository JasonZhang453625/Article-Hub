import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/models/memory_document.dart';
import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/source_platform.dart';
import 'package:memora/data/services/prompt_service.dart';
import 'package:memora/data/services/rag_conversation_service.dart';
import 'package:memora/data/services/retrieval_log_service.dart';
import 'package:memora/data/services/retrieval_service.dart';

void main() {
  Article agentArticle() => Article(
    id: 'agent-sdk',
    url: 'https://example.com/agents',
    title: 'Agent SDK',
    source: SourcePlatform.web,
    memory: MemoryDocument.ai(
      overview: 'Agent SDK coordinates multiple agents.',
      keyPoints: const [
        MemoryKeyPoint(
          id: 'kp-handoff',
          order: 1,
          topic: 'Handoff',
          content: 'Handoff transfers work to a specialist agent.',
        ),
      ],
      conclusion: 'Use handoffs for specialist delegation.',
    ),
  );

  test(
    'history is rewritten for retrieval while the original question answers',
    () async {
      final completions = <String>[];
      final logs = <RetrievalLog>[];
      String? retrievalQuery;
      final article = agentArticle();
      final service = RagConversationService(
        retrieve: (query, articles) async {
          retrievalQuery = query;
          return RetrievalResult(
            articles: [article],
            method: RetrievalMethod.hybrid,
            duration: const Duration(milliseconds: 12),
            candidateIds: [article.id],
          );
        },
        complete:
            ({
              required String systemPrompt,
              required String userMessage,
              List<Map<String, String>> history = const [],
              double temperature = 0.3,
              int maxTokens = 800,
            }) async {
              completions.add(userMessage);
              if (completions.length == 1) {
                return 'What limitations does Agent SDK handoff have?';
              }
              expect(userMessage, contains('Handoff transfers work'));
              expect(userMessage, contains('第二点有什么缺陷？'));
              return 'Handoff can transfer work to a specialist [1].';
            },
        saveLog: (log) async => logs.add(log),
        promptService: _FakePromptService(),
      );

      final result = await service.ask(
        RagConversationRequest(
          question: '第二点有什么缺陷？',
          history: const [
            RagConversationTurn(
              role: 'user',
              content: 'Agent SDK 的 handoff 机制是什么？',
            ),
            RagConversationTurn(role: 'assistant', content: '第二点介绍任务转移。'),
          ],
          articles: [article],
          knowledgeOnly: true,
          detailedAnswer: false,
          languageHint: 'Answer in Chinese.',
        ),
      );

      expect(retrievalQuery, 'What limitations does Agent SDK handoff have?');
      expect(result.outcome, RagConversationOutcome.answer);
      expect(result.rewrittenQuery, retrievalQuery);
      expect(result.citedIds, ['agent-sdk']);
      expect(logs.single.rewrittenQuery, retrievalQuery);
    },
  );

  test(
    'askWithProgress forwards streamed answer deltas before completion',
    () async {
      final article = agentArticle();
      final deltas = <String>[];
      final service = RagConversationService(
        retrieve: (query, articles) async => RetrievalResult(
          articles: [article],
          method: RetrievalMethod.keyword,
          duration: Duration.zero,
          candidateIds: [article.id],
        ),
        complete:
            ({
              required String systemPrompt,
              required String userMessage,
              List<Map<String, String>> history = const [],
              double temperature = 0.3,
              int maxTokens = 800,
            }) async => fail('stream completion should be used'),
        completeStream:
            ({
              required String systemPrompt,
              required String userMessage,
              List<Map<String, String>> history = const [],
              double temperature = 0.3,
              int maxTokens = 800,
            }) => Stream<String>.fromIterable(['Handoff ', 'works [1].']),
        saveLog: (_) async {},
        promptService: _FakePromptService(),
      );

      final result = await service.askWithProgress(
        RagConversationRequest(
          question: 'Explain handoff',
          articles: [article],
          knowledgeOnly: true,
          detailedAnswer: false,
          languageHint: '',
        ),
        onDelta: deltas.add,
      );

      expect(deltas, ['Handoff ', 'works [1].']);
      expect(result.outcome, RagConversationOutcome.answer);
      expect(result.answer, 'Handoff works [1].');
      expect(result.citedIds, [article.id]);
    },
  );

  test('an uncited answer does not expose every retrieved candidate', () async {
    final article = agentArticle();
    final service = RagConversationService(
      retrieve: (query, articles) async => RetrievalResult(
        articles: [article],
        method: RetrievalMethod.keyword,
        duration: const Duration(milliseconds: 4),
        candidateIds: [article.id],
      ),
      complete:
          ({
            required String systemPrompt,
            required String userMessage,
            List<Map<String, String>> history = const [],
            double temperature = 0.3,
            int maxTokens = 800,
          }) async => 'The answer contains no explicit citation.',
      saveLog: (_) async {},
      promptService: _FakePromptService(),
    );

    final result = await service.ask(
      RagConversationRequest(
        question: 'Explain handoff',
        articles: [article],
        knowledgeOnly: true,
        detailedAnswer: false,
        languageHint: '',
      ),
    );

    expect(result.outcome, RagConversationOutcome.answer);
    expect(result.citedIds, isEmpty);
  });

  test(
    'provider failure details are surfaced instead of empty response',
    () async {
      final article = agentArticle();
      final service = RagConversationService(
        retrieve: (query, articles) async => RetrievalResult(
          articles: [article],
          method: RetrievalMethod.keyword,
          duration: const Duration(milliseconds: 4),
          candidateIds: [article.id],
        ),
        complete:
            ({
              required String systemPrompt,
              required String userMessage,
              List<Map<String, String>> history = const [],
              double temperature = 0.3,
              int maxTokens = 800,
            }) async => null,
        completionError: () => 'HTTP 429: rate limit exceeded',
        saveLog: (_) async {},
        promptService: _FakePromptService(),
      );

      final result = await service.ask(
        RagConversationRequest(
          question: 'Explain handoff',
          articles: [article],
          knowledgeOnly: true,
          detailedAnswer: false,
          languageHint: '',
        ),
      );

      expect(result.outcome, RagConversationOutcome.error);
      expect(result.error, 'HTTP 429: rate limit exceeded');
    },
  );

  test('missing provider details keep the empty response fallback', () async {
    final article = agentArticle();
    final service = RagConversationService(
      retrieve: (query, articles) async => RetrievalResult(
        articles: [article],
        method: RetrievalMethod.keyword,
        duration: const Duration(milliseconds: 4),
      ),
      complete:
          ({
            required String systemPrompt,
            required String userMessage,
            List<Map<String, String>> history = const [],
            double temperature = 0.3,
            int maxTokens = 800,
          }) async => '   ',
      completionError: () => '   ',
      saveLog: (_) async {},
      promptService: _FakePromptService(),
    );

    final result = await service.ask(
      RagConversationRequest(
        question: 'Explain handoff',
        articles: [article],
        knowledgeOnly: true,
        detailedAnswer: false,
        languageHint: '',
      ),
    );

    expect(result.outcome, RagConversationOutcome.error);
    expect(result.error, 'empty response');
  });

  test('query rewrite failure falls back to the original question', () async {
    final rewriter = HistoryAwareQueryRewriter(
      complete:
          ({
            required String systemPrompt,
            required String userMessage,
            List<Map<String, String>> history = const [],
            double temperature = 0.3,
            int maxTokens = 800,
          }) async => null,
      promptService: _FakePromptService(),
    );

    final rewritten = await rewriter.rewrite(
      question: '第二点呢？',
      history: const [
        RagConversationTurn(role: 'user', content: '介绍 Agent handoff'),
      ],
    );

    expect(rewritten, '第二点呢？');
  });

  test(
    'knowledge-only mode returns no-result without calling answer model',
    () async {
      var completionCalls = 0;
      final service = RagConversationService(
        retrieve: (query, articles) async => const RetrievalResult(
          articles: [],
          method: RetrievalMethod.none,
          duration: Duration(milliseconds: 3),
        ),
        complete:
            ({
              required String systemPrompt,
              required String userMessage,
              List<Map<String, String>> history = const [],
              double temperature = 0.3,
              int maxTokens = 800,
            }) async {
              completionCalls++;
              return 'should not run';
            },
        saveLog: (_) async {},
        promptService: _FakePromptService(),
      );

      final result = await service.ask(
        RagConversationRequest(
          question: 'Unknown subject',
          articles: [agentArticle()],
          knowledgeOnly: true,
          detailedAnswer: false,
          languageHint: '',
        ),
      );

      expect(result.outcome, RagConversationOutcome.noResult);
      expect(completionCalls, 0);
    },
  );

  test(
    'rejects a prompt that cannot fit the configured context window',
    () async {
      var completionCalls = 0;
      final article = agentArticle();
      final service = RagConversationService(
        retrieve: (query, articles) async => RetrievalResult(
          articles: [article],
          method: RetrievalMethod.keyword,
          duration: const Duration(milliseconds: 3),
        ),
        complete:
            ({
              required String systemPrompt,
              required String userMessage,
              List<Map<String, String>> history = const [],
              double temperature = 0.3,
              int maxTokens = 800,
            }) async {
              completionCalls++;
              return 'should not run';
            },
        saveLog: (_) async {},
        promptService: _FakePromptService(),
      );

      final result = await service.ask(
        RagConversationRequest(
          question: 'A question that cannot fit',
          articles: [article],
          knowledgeOnly: true,
          detailedAnswer: false,
          languageHint: '',
          contextWindowTokens: 100,
        ),
      );

      expect(result.outcome, RagConversationOutcome.error);
      expect(result.error, contains('context window'));
      expect(completionCalls, 0);
    },
  );

  test(
    'hybrid mode keeps its general-knowledge contract when retrieval is empty',
    () async {
      final promptService = _FakePromptService();
      String? capturedSystemPrompt;
      int? capturedMaxTokens;
      final service = RagConversationService(
        retrieve: (query, articles) async => const RetrievalResult(
          articles: [],
          method: RetrievalMethod.none,
          duration: Duration(milliseconds: 3),
        ),
        complete:
            ({
              required String systemPrompt,
              required String userMessage,
              List<Map<String, String>> history = const [],
              double temperature = 0.3,
              int maxTokens = 800,
            }) async {
              capturedSystemPrompt = systemPrompt;
              capturedMaxTokens = maxTokens;
              return 'A useful general answer.';
            },
        saveLog: (_) async {},
        promptService: promptService,
      );

      final result = await service.ask(
        RagConversationRequest(
          question: 'What is a vector database?',
          articles: const [],
          knowledgeOnly: false,
          detailedAnswer: true,
          languageHint: 'Answer in English.',
        ),
      );

      expect(result.outcome, RagConversationOutcome.answer);
      expect(promptService.loadedPaths, contains('chat/knowledge_hybrid.txt'));
      expect(
        promptService.loadedPaths,
        isNot(contains('chat/knowledge_general.txt')),
      );
      expect(capturedSystemPrompt, contains('chat/knowledge_hybrid.txt'));
      expect(capturedMaxTokens, 2500);
    },
  );
}

class _FakePromptService extends PromptService {
  final List<String> loadedPaths = [];

  @override
  Future<String> load(String path, [Map<String, String>? vars]) async {
    loadedPaths.add(path);
    if (path == 'chat/query_rewrite.txt') return 'Rewrite the query.';
    if (path == 'chat/system.txt') {
      return 'System prompt\n'
          '${vars?['knowledgeRule'] ?? ''}\n'
          '${vars?['lengthRule'] ?? ''}\n'
          '${vars?['langHint'] ?? ''}';
    }
    if (path == 'chat/user.txt') {
      return 'Context:\n${vars?['context'] ?? ''}\n'
          'Question: ${vars?['question'] ?? ''}';
    }
    return path;
  }
}
