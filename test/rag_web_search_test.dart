import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/models/memory_document.dart';
import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/source_platform.dart';
import 'package:memora/data/services/prompt_service.dart';
import 'package:memora/data/services/rag_conversation_service.dart';
import 'package:memora/data/services/retrieval_log_service.dart';
import 'package:memora/data/services/retrieval_service.dart';
import 'package:memora/data/services/web_search_service.dart';

/// End-to-end orchestration tests for web search inside
/// [RagConversationService]: parallel retrieval, merged evidence, [wN]
/// citations, graceful degradation, and analytics logging.
void main() {
  Article article({String id = 'agent-sdk'}) => Article(
    id: id,
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

  List<WebSearchResult> webHits() => const [
    WebSearchResult(
      title: 'Postgres Logical Replication',
      url: 'https://postgresql.org/docs/logical-replication',
      content: 'Logical replication replicates data changes via publications.',
    ),
    WebSearchResult(
      title: 'Streaming Replication',
      url: 'https://wiki.postgresql.org/wiki/Streaming_Replication',
      content: 'Streaming replication ships WAL records continuously.',
    ),
  ];

  test(
    'web fallback answers when local retrieval finds nothing, with [wN] URLs',
    () async {
      final logs = <RetrievalLog>[];
      String? sentContext;
      String? sentSystem;
      var searchedQuery = '';
      final service = RagConversationService(
        retrieve: (query, articles) async => RetrievalResult(
          articles: const [],
          method: RetrievalMethod.none,
          duration: const Duration(milliseconds: 3),
          candidateIds: const [],
        ),
        webSearch: (query, {topK = 5}) async {
          searchedQuery = query;
          return webHits();
        },
        complete:
            ({
              required String systemPrompt,
              required String userMessage,
              List<Map<String, String>> history = const [],
              double temperature = 0.3,
              int maxTokens = 800,
            }) async {
              sentSystem = systemPrompt;
              sentContext = userMessage;
              return 'Logical replication ships changes via publications [w1], '
                  'while streaming ships WAL [w2].';
            },
        saveLog: (log) async => logs.add(log),
        promptService: _WebPromptService(),
      );

      final result = await service.ask(
        RagConversationRequest(
          question: 'logical vs streaming replication',
          articles: [article()],
          knowledgeOnly: true,
          detailedAnswer: false,
          languageHint: '',
          webSearch: true,
        ),
      );

      expect(searchedQuery, 'logical vs streaming replication');
      expect(result.outcome, RagConversationOutcome.answer);
      expect(result.method, 'web');
      expect(result.webUrls, [
        'https://postgresql.org/docs/logical-replication',
        'https://wiki.postgresql.org/wiki/Streaming_Replication',
      ]);
      expect(result.citedIds, isEmpty);
      expect(sentSystem, contains('chat/knowledge_only.txt'));
      expect(sentSystem, contains('Web knowledge rules'));
      expect(sentContext, contains('[w1] Postgres Logical Replication'));
      expect(
        sentContext,
        contains('https://postgresql.org/docs/logical-replication'),
      );
      final log = logs.single;
      expect(log.method, 'web');
      expect(log.webCandidateUrls, hasLength(2));
      expect(log.webCitedUrls, hasLength(2));
    },
  );

  test('a fabricated [wN] never becomes a web citation', () async {
    final service = RagConversationService(
      retrieve: (query, articles) async => RetrievalResult(
        articles: const [],
        method: RetrievalMethod.none,
        duration: const Duration(milliseconds: 3),
        candidateIds: const [],
      ),
      webSearch: (query, {topK = 5}) async => webHits(),
      complete:
          ({
            required String systemPrompt,
            required String userMessage,
            List<Map<String, String>> history = const [],
            double temperature = 0.3,
            int maxTokens = 800,
          }) async => 'The docs say so [w1], but also see [w42].',
      saveLog: (_) async {},
      promptService: _WebPromptService(),
    );

    final result = await service.ask(
      RagConversationRequest(
        question: 'replication',
        articles: [article()],
        knowledgeOnly: true,
        detailedAnswer: false,
        languageHint: '',
        webSearch: true,
      ),
    );

    expect(result.outcome, RagConversationOutcome.answer);
    expect(result.webUrls, ['https://postgresql.org/docs/logical-replication']);
  });

  test(
    'local and web evidence are merged and both citations are preserved',
    () async {
      var webSearches = 0;
      String? sentContext;
      String? sentSystem;
      final logs = <RetrievalLog>[];
      final local = article();
      final service = RagConversationService(
        retrieve: (query, articles) async => RetrievalResult(
          articles: [local],
          method: RetrievalMethod.hybrid,
          duration: const Duration(milliseconds: 4),
          candidateIds: [local.id],
        ),
        webSearch: (query, {topK = 5}) async {
          webSearches++;
          return webHits();
        },
        complete:
            ({
              required String systemPrompt,
              required String userMessage,
              List<Map<String, String>> history = const [],
              double temperature = 0.3,
              int maxTokens = 800,
            }) async {
              sentSystem = systemPrompt;
              sentContext = userMessage;
              return 'Handoff works [1]; current docs add details [w1].';
            },
        saveLog: (log) async => logs.add(log),
        promptService: _WebPromptService(),
      );

      final result = await service.ask(
        RagConversationRequest(
          question: 'handoff',
          articles: [local],
          knowledgeOnly: false,
          detailedAnswer: false,
          languageHint: '',
          webSearch: true,
        ),
      );

      expect(webSearches, 1);
      expect(result.method, 'hybrid+web');
      expect(result.citedIds, [local.id]);
      expect(result.webUrls, [
        'https://postgresql.org/docs/logical-replication',
      ]);
      expect(result.outcome, RagConversationOutcome.answer);
      expect(sentSystem, contains('chat/knowledge_hybrid.txt'));
      expect(sentSystem, contains('Web knowledge rules'));
      expect(sentContext, contains('## 本地知识库'));
      expect(sentContext, contains('Handoff transfers work'));
      expect(sentContext, contains('## 联网搜索'));
      expect(sentContext, contains('[w1] Postgres Logical Replication'));
      expect(logs.single.method, 'hybrid+web');
      expect(logs.single.citedIds, [local.id]);
      expect(logs.single.webCitedUrls, result.webUrls);
    },
  );

  test('local retrieval and web search really start concurrently', () async {
    final localStarted = Completer<void>();
    final webStarted = Completer<void>();
    final release = Completer<void>();
    final local = article();
    final service = RagConversationService(
      retrieve: (query, articles) async {
        localStarted.complete();
        await release.future;
        return RetrievalResult(
          articles: [local],
          method: RetrievalMethod.hybrid,
          duration: const Duration(milliseconds: 4),
          candidateIds: [local.id],
        );
      },
      webSearch: (query, {topK = 5}) async {
        webStarted.complete();
        await release.future;
        return webHits();
      },
      complete:
          ({
            required String systemPrompt,
            required String userMessage,
            List<Map<String, String>> history = const [],
            double temperature = 0.3,
            int maxTokens = 800,
          }) async => 'Combined answer [1] [w1].',
      saveLog: (_) async {},
      promptService: _WebPromptService(),
    );

    final answerFuture = service.ask(
      RagConversationRequest(
        question: 'handoff updates',
        articles: [local],
        knowledgeOnly: true,
        detailedAnswer: false,
        languageHint: '',
        webSearch: true,
      ),
    );

    await Future.wait([
      localStarted.future,
      webStarted.future,
    ]).timeout(const Duration(seconds: 1));
    release.complete();
    final result = await answerFuture;

    expect(result.outcome, RagConversationOutcome.answer);
    expect(result.method, 'hybrid+web');
  });

  test('web evidence still answers when local retrieval throws', () async {
    final service = RagConversationService(
      retrieve: (query, articles) async => throw Exception('index unavailable'),
      webSearch: (query, {topK = 5}) async => webHits(),
      complete:
          ({
            required String systemPrompt,
            required String userMessage,
            List<Map<String, String>> history = const [],
            double temperature = 0.3,
            int maxTokens = 800,
          }) async => 'Web answer [w1].',
      saveLog: (_) async {},
      promptService: _WebPromptService(),
    );

    final result = await service.ask(
      RagConversationRequest(
        question: 'latest replication docs',
        articles: [article()],
        knowledgeOnly: true,
        detailedAnswer: false,
        languageHint: '',
        webSearch: true,
      ),
    );

    expect(result.outcome, RagConversationOutcome.answer);
    expect(result.method, 'web');
    expect(result.webUrls, ['https://postgresql.org/docs/logical-replication']);
  });

  test(
    'web search failure degrades to the existing noResult outcome',
    () async {
      final service = RagConversationService(
        retrieve: (query, articles) async => RetrievalResult(
          articles: const [],
          method: RetrievalMethod.none,
          duration: const Duration(milliseconds: 3),
          candidateIds: const [],
        ),
        webSearch: (query, {topK = 5}) async => throw Exception('tavily down'),
        complete:
            ({
              required String systemPrompt,
              required String userMessage,
              List<Map<String, String>> history = const [],
              double temperature = 0.3,
              int maxTokens = 800,
            }) async => 'unused',
        saveLog: (_) async {},
        promptService: _WebPromptService(),
      );

      final result = await service.ask(
        RagConversationRequest(
          question: 'something obscure',
          articles: [article()],
          knowledgeOnly: true,
          detailedAnswer: false,
          languageHint: '',
          webSearch: true,
        ),
      );

      expect(result.outcome, RagConversationOutcome.noResult);
      expect(result.webUrls, isEmpty);
    },
  );

  test('hosted daily web quota error stays visible to the caller', () async {
    final service = RagConversationService(
      retrieve: (query, articles) async => const RetrievalResult(
        articles: [],
        method: RetrievalMethod.none,
        duration: Duration.zero,
        candidateIds: [],
      ),
      webSearch: (query, {topK = 5}) async => throw const WebSearchException(
        code: 'daily_quota_exceeded',
        message: 'Daily web-search limit reached. Try tomorrow.',
        statusCode: 429,
      ),
      complete:
          ({
            required systemPrompt,
            required userMessage,
            history = const [],
            temperature = 0.3,
            maxTokens = 800,
          }) async => fail('completion must not run after quota failure'),
      saveLog: (_) async {},
      promptService: _WebPromptService(),
    );

    final result = await service.ask(
      const RagConversationRequest(
        question: 'latest news',
        articles: [],
        knowledgeOnly: true,
        detailedAnswer: false,
        languageHint: '',
        webSearch: true,
      ),
    );

    expect(result.outcome, RagConversationOutcome.error);
    expect(result.error, contains('Try tomorrow'));
  });

  test('completion errors are not collapsed into empty response', () async {
    final service = RagConversationService(
      retrieve: (query, articles) async => const RetrievalResult(
        articles: [],
        method: RetrievalMethod.none,
        duration: Duration.zero,
        candidateIds: [],
      ),
      complete:
          ({
            required systemPrompt,
            required userMessage,
            history = const [],
            temperature = 0.3,
            maxTokens = 800,
          }) async => null,
      completionError: () =>
          'HTTP 429: Daily chat limit reached. Try again tomorrow.',
      saveLog: (_) async {},
      promptService: _WebPromptService(),
    );

    final result = await service.ask(
      const RagConversationRequest(
        question: 'question',
        articles: [],
        knowledgeOnly: false,
        detailedAnswer: false,
        languageHint: '',
      ),
    );

    expect(result.outcome, RagConversationOutcome.error);
    expect(result.error, contains('Daily chat limit'));
  });

  test('webSearch defaults to off — legacy behavior is untouched', () async {
    final local = article();
    final service = RagConversationService(
      retrieve: (query, articles) async => RetrievalResult(
        articles: [local],
        method: RetrievalMethod.vector,
        duration: const Duration(milliseconds: 4),
        candidateIds: [local.id],
      ),
      webSearch: (query, {topK = 5}) async => fail('must not be called'),
      complete:
          ({
            required String systemPrompt,
            required String userMessage,
            List<Map<String, String>> history = const [],
            double temperature = 0.3,
            int maxTokens = 800,
          }) async => 'Local answer [1].',
      saveLog: (_) async {},
      promptService: _WebPromptService(),
    );

    final result = await service.ask(
      RagConversationRequest(
        question: 'handoff',
        articles: [local],
        knowledgeOnly: true,
        detailedAnswer: false,
        languageHint: '',
      ),
    );

    expect(result.outcome, RagConversationOutcome.answer);
    expect(result.method, 'vector');
    expect(result.citedIds, [local.id]);
    expect(result.webUrls, isEmpty);
  });

  test(
    'hosted Agent owns web tool selection instead of eager client search',
    () async {
      var directSearches = 0;
      bool? agentWebPermission;
      final logs = <RetrievalLog>[];
      final service = RagConversationService(
        retrieve: (query, articles) async => const RetrievalResult(
          articles: [],
          method: RetrievalMethod.none,
          duration: Duration(milliseconds: 2),
          candidateIds: [],
        ),
        webSearch: (query, {topK = 5}) async {
          directSearches++;
          return webHits();
        },
        complete:
            ({
              required systemPrompt,
              required userMessage,
              history = const [],
              temperature = 0.3,
              maxTokens = 800,
            }) async => fail('plain completion must not produce the answer'),
        agentCompleteStream:
            ({
              required systemPrompt,
              required userMessage,
              history = const [],
              temperature = 0.3,
              maxTokens = 800,
              required webSearch,
              onEvent,
            }) async* {
              agentWebPermission = webSearch;
              yield 'Agent searched when useful [w1].';
            },
        agentWebUrls: () => const ['https://example.com/live'],
        saveLog: (log) async => logs.add(log),
        promptService: _WebPromptService(),
      );

      final result = await service.ask(
        const RagConversationRequest(
          question: 'what changed today?',
          articles: [],
          knowledgeOnly: true,
          detailedAnswer: false,
          languageHint: '',
          webSearch: true,
        ),
      );

      expect(directSearches, 0);
      expect(agentWebPermission, isTrue);
      expect(result.outcome, RagConversationOutcome.answer);
      expect(result.method, 'web');
      expect(result.webUrls, ['https://example.com/live']);
      expect(logs.single.webCandidateUrls, ['https://example.com/live']);
    },
  );
}

class _WebPromptService extends PromptService {
  @override
  Future<String> load(String path, [Map<String, String>? vars]) async {
    if (path == 'chat/query_rewrite.txt') return 'Rewrite the query.';
    if (path == 'chat/system.txt') {
      return 'System prompt\n'
          '${vars?['knowledgeRule'] ?? ''}\n'
          '${vars?['lengthRule'] ?? ''}\n'
          '${vars?['langHint'] ?? ''}';
    }
    if (path == 'chat/user.txt' || path == 'chat/user_web.txt') {
      return 'Context:\n${vars?['context'] ?? ''}\n'
          'Question: ${vars?['question'] ?? ''}';
    }
    if (path == 'chat/knowledge_web.txt') return 'Web knowledge rules.';
    return path;
  }
}
