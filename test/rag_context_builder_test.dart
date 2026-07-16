import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/models/memory_document.dart';
import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/source_platform.dart';
import 'package:memora/data/services/rag_context_builder.dart';

void main() {
  Article structuredArticle({
    required String id,
    required String title,
    required String overview,
    required List<MemoryKeyPoint> keyPoints,
    List<String> tags = const [],
  }) {
    return Article(
      id: id,
      url: 'https://example.com/$id',
      title: title,
      source: SourcePlatform.web,
      tags: tags,
      memory: MemoryDocument.ai(
        overview: overview,
        keyPoints: keyPoints,
        conclusion: 'Conclusion for $title.',
      ),
    );
  }

  test('reranker promotes an article whose key point matches the query', () {
    final unrelated = structuredArticle(
      id: 'coffee',
      title: 'Coffee brewing',
      overview: 'Water temperature and grind size affect coffee extraction.',
      keyPoints: const [
        MemoryKeyPoint(
          id: 'kp-coffee',
          order: 1,
          topic: 'Extraction',
          content: 'Use water near 93 degrees Celsius.',
        ),
      ],
    );
    final matching = structuredArticle(
      id: 'agents',
      title: 'Agent SDK',
      overview: 'A framework for coordinating multiple agents.',
      keyPoints: const [
        MemoryKeyPoint(
          id: 'kp-handoff',
          order: 1,
          topic: 'Handoff mechanism',
          content: 'A running agent transfers a task to a specialist agent.',
        ),
      ],
      tags: const ['multi-agent'],
    );

    final ranked = const RagEvidenceReranker().rerank(
      'How does the handoff mechanism transfer tasks?',
      [unrelated, matching],
    );

    expect(ranked.first.article.id, 'agents');
    expect(ranked.first.evidence.first.text, contains('Handoff mechanism'));
  });

  test('context builder selects relevant evidence within a token budget', () {
    final article = structuredArticle(
      id: 'agents',
      title: 'Agent SDK',
      overview: List.filled(80, 'unrelated introduction').join(' '),
      keyPoints: const [
        MemoryKeyPoint(
          id: 'kp-handoff',
          order: 1,
          topic: 'Handoff',
          content: 'Handoff transfers work to a specialist agent.',
        ),
        MemoryKeyPoint(
          id: 'kp-tracing',
          order: 2,
          topic: 'Tracing',
          content: 'Tracing records model and tool calls.',
        ),
      ],
    );

    final context = const RagContextBuilder().build(
      query: 'How does handoff transfer work?',
      candidates: [article],
      tokenBudget: 55,
    );

    expect(context.estimatedTokens, lessThanOrEqualTo(55));
    expect(context.text, contains('Handoff transfers work'));
    expect(context.text, isNot(contains('unrelated introduction unrelated')));
  });

  test('citation numbers follow reranked context order', () {
    final first = structuredArticle(
      id: 'first',
      title: 'First',
      overview: 'Gardening and soil.',
      keyPoints: const [],
    );
    final second = structuredArticle(
      id: 'second',
      title: 'Tracing',
      overview: 'Tracing provides observability for agent execution.',
      keyPoints: const [],
    );

    final context = const RagContextBuilder().build(
      query: 'agent tracing observability',
      candidates: [first, second],
      tokenBudget: 120,
    );

    expect(context.articles.first.id, 'second');
    expect(context.citationMap['1'], 'second');
    expect(context.text, startsWith('[1] Tracing'));
  });

  test(
    'legacy markdown uses a relevant later chunk instead of a fixed prefix',
    () {
      final article = Article(
        id: 'legacy',
        url: 'https://example.com/legacy',
        title: 'Legacy article',
        source: SourcePlatform.web,
        memory: MemoryDocument.legacyMarkdown(
          body:
              '${List.filled(100, 'weather').join(' ')}\n\n'
              'Handoff delegates the task to another agent that has specialist tools.',
        ),
      );

      final context = const RagContextBuilder().build(
        query: 'handoff specialist tools',
        candidates: [article],
        tokenBudget: 60,
      );

      expect(context.text, contains('specialist tools'));
      expect(context.estimatedTokens, lessThanOrEqualTo(60));
    },
  );
}
