import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:memora/data/models/memory_document.dart';
import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/source_platform.dart';
import 'package:memora/data/services/agent_client_tool_api.dart';
import 'package:memora/data/services/agent_client_tool_executor.dart';
import 'package:memora/data/services/agent_client_tool_store.dart';
import 'package:memora/data/services/embedding_service.dart';
import 'package:memora/data/services/hosted_ai_capabilities.dart';
import 'package:memora/data/services/index_service.dart';
import 'package:memora/data/services/retrieval_service.dart';

void main() {
  late Directory directory;
  late AgentClientToolStore store;
  late AgentClientToolExecutor executor;
  const binding = AgentToolRunBinding(
    ownerUserId: 'user-a',
    ownerDeviceId: 'device-a',
    runId: 'run-a',
  );
  const capabilities = HostedAgentClientToolsCapabilities(
    version: 1,
    models: ['mimo-v2.5'],
    tools: {'local_search', 'read_article'},
    maxTotalCalls: 6,
    maxLocalSearchCalls: 4,
    maxReadArticleCalls: 4,
    maxResultBytes: 65536,
    leaseSeconds: 60,
    waitSeconds: 600,
    wallSeconds: 900,
    localSearch: HostedAgentLocalSearchLimits(
      maxResults: 5,
      maxSnippetsPerResult: 2,
      maxResultBytes: 16384,
      maxResultTokens: 1200,
    ),
    readArticle: HostedAgentClientToolResultLimits(
      maxResultBytes: 24576,
      maxResultTokens: 4000,
    ),
  );

  Article article({String? title}) => Article(
    id: 'secret-real-id',
    url: 'https://secret.example/article',
    title: title ?? 'https://secret.example/article',
    source: SourcePlatform.web,
    notes: 'private note must never leave device',
    tags: const ['private-tag'],
    localFilePath: r'C:\Users\owner\secret.pdf',
    memory: MemoryDocument.ai(
      overview:
          r'Overview references https://leak.example and C:\vault\private.txt',
      keyPoints: const [
        MemoryKeyPoint(
          id: 'point-1',
          order: 1,
          topic: 'Topic',
          content: 'Useful local evidence without identifiers.',
        ),
      ],
      conclusion: 'Conclusion.',
    ),
  );

  AgentClientToolCall call(String tool, Map<String, dynamic> arguments) =>
      AgentClientToolCall(
        callId: 'call-1',
        tool: tool,
        arguments: arguments,
        status: 'claimed',
        leaseEpoch: '1',
        remainingResultBytes: 65536,
        leaseExpiresAt: null,
        createdAt: DateTime.utc(2026),
      );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('memora-agent-executor-');
    Hive.init(directory.path);
    store = AgentClientToolStore();
    await store.init();
    executor = AgentClientToolExecutor(
      retrieval: _FakeRetrievalService(),
      store: store,
    );
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('local_search emits only whitelisted bounded evidence', () async {
    final result = await executor.execute(
      binding: binding,
      call: call('local_search', {'query': 'local evidence'}),
      articles: [article()],
      capabilities: capabilities,
    );
    final encoded = jsonEncode(result);

    expect(result['status'], 'ok');
    expect(utf8.encode(encoded).length, lessThanOrEqualTo(16384));
    expect(encoded, isNot(contains('secret-real-id')));
    expect(encoded, isNot(contains('secret.example')));
    expect(encoded, isNot(contains('private note')));
    expect(encoded, isNot(contains('private-tag')));
    expect(encoded, isNot(contains(r'C:\Users')));
    final item = ((result['results'] as List).single as Map);
    expect(item.keys.toSet(), {'article_ref', 'title', 'snippets'});
    expect(item['title'], 'Saved article');
  });

  test(
    'read_article accepts only a same-run ref and uses 24KiB hard cap',
    () async {
      final search = await executor.execute(
        binding: binding,
        call: call('local_search', {'query': 'evidence'}),
        articles: [article(title: 'Readable title')],
        capabilities: capabilities,
      );
      final reference =
          (((search['results'] as List).single as Map)['article_ref']
              as String);
      final read = await executor.execute(
        binding: binding,
        call: call('read_article', {'article_ref': reference}),
        articles: [article(title: 'Readable title')],
        capabilities: capabilities,
      );
      expect(read['status'], 'ok');
      expect(utf8.encode(jsonEncode(read)).length, lessThanOrEqualTo(24576));

      final wrongRun = await executor.execute(
        binding: const AgentToolRunBinding(
          ownerUserId: 'user-a',
          ownerDeviceId: 'device-a',
          runId: 'run-b',
        ),
        call: call('read_article', {'article_ref': reference}),
        articles: [article(title: 'Readable title')],
        capabilities: capabilities,
      );
      expect(wrongRun['status'], 'not_found');
    },
  );

  test(
    'run-wide byte remainder bounds output and fails closed when tiny',
    () async {
      final bounded = AgentClientToolCall(
        callId: 'call-budget',
        tool: 'local_search',
        arguments: const {'query': 'local evidence'},
        status: 'claimed',
        leaseEpoch: '2',
        remainingResultBytes: 256,
        leaseExpiresAt: null,
        createdAt: DateTime.utc(2026),
      );
      final result = await executor.execute(
        binding: binding,
        call: bounded,
        articles: [article(title: 'Readable title')],
        capabilities: capabilities,
      );
      expect(utf8.encode(jsonEncode(result)).length, lessThanOrEqualTo(256));

      final exhausted = AgentClientToolCall(
        callId: 'call-exhausted',
        tool: 'local_search',
        arguments: const {'query': 'second-hop private excerpt'},
        status: 'claimed',
        leaseEpoch: '3',
        remainingResultBytes: 1,
        leaseExpiresAt: null,
        createdAt: DateTime.utc(2026),
      );
      await expectLater(
        executor.execute(
          binding: binding,
          call: exhausted,
          articles: [article()],
          capabilities: capabilities,
        ),
        throwsA(isA<AgentClientToolBudgetExhausted>()),
      );
    },
  );

  test(
    'multi-hop local_search never calls a configured embedding API',
    () async {
      final embedding = _CountingEmbeddingService();
      final localExecutor = AgentClientToolExecutor(
        retrieval: RetrievalService(
          embedding: embedding,
          index: IndexService(),
        ),
        store: store,
      );
      for (final query in ['local evidence', 'Useful local evidence']) {
        await localExecutor.execute(
          binding: binding,
          call: call('local_search', {'query': query}),
          articles: [article(title: 'Local evidence')],
          capabilities: capabilities,
        );
      }
      expect(embedding.calls, 0);
    },
  );
}

class _FakeRetrievalService extends RetrievalService {
  _FakeRetrievalService()
    : super(
        embedding: EmbeddingService(baseUrl: '', apiKey: '', model: ''),
        index: IndexService(),
      );

  @override
  Future<RetrievalResult> retrieveLocalOnly(
    String query,
    List<Article> articles,
  ) async {
    return RetrievalResult(
      articles: articles,
      method: RetrievalMethod.keyword,
      duration: Duration.zero,
      candidateIds: articles.map((article) => article.id).toList(),
    );
  }
}

class _CountingEmbeddingService extends EmbeddingService {
  int calls = 0;

  _CountingEmbeddingService()
    : super(
        baseUrl: 'https://embedding.example',
        apiKey: 'configured-secret',
        model: 'remote-embedding',
      );

  @override
  Future<EmbeddingResult?> embed(String text) async {
    calls++;
    return const EmbeddingResult(vector: [1], model: 'remote-embedding');
  }
}
