import 'package:flutter_test/flutter_test.dart';
import 'package:memora/data/services/embedding_service.dart';
import 'dart:async';

import 'package:memora/data/models/memory_document.dart';
import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/source_platform.dart';
import 'package:memora/data/services/index_service.dart';
import 'package:memora/data/services/retrieval_service.dart';
import 'package:memora/data/services/retrieval_isolate.dart';

void main() {
  group('cosineSimilarity', () {
    test('identical vectors return 1.0', () {
      final v = [1.0, 2.0, 3.0];
      expect(cosineSimilarity(v, v), closeTo(1.0, 1e-10));
    });

    test('orthogonal vectors return 0.0', () {
      final a = [1.0, 0.0, 0.0];
      final b = [0.0, 1.0, 0.0];
      expect(cosineSimilarity(a, b), closeTo(0.0, 1e-10));
    });

    test('opposite vectors return -1.0', () {
      final a = [1.0, 0.0];
      final b = [-1.0, 0.0];
      expect(cosineSimilarity(a, b), closeTo(-1.0, 1e-10));
    });

    test('zero vector returns 0.0', () {
      final a = [0.0, 0.0, 0.0];
      final b = [1.0, 2.0, 3.0];
      expect(cosineSimilarity(a, b), 0.0);
    });

    test('different length vectors return 0.0', () {
      final a = [1.0, 2.0];
      final b = [1.0, 2.0, 3.0];
      expect(cosineSimilarity(a, b), 0.0);
    });

    test('similar vectors score higher than dissimilar', () {
      final a = [1.0, 1.0, 0.0];
      final similar = [0.9, 1.1, 0.0];
      final different = [0.0, 0.0, 1.0];
      final scoreSimilar = cosineSimilarity(a, similar);
      final scoreDifferent = cosineSimilarity(a, different);
      expect(scoreSimilar, greaterThan(scoreDifferent));
    });
  });

  group('contentFingerprint', () {
    test('same input produces same fingerprint', () {
      final fp1 = contentFingerprint('Title', 'Summary', ['tag1', 'tag2']);
      final fp2 = contentFingerprint('Title', 'Summary', ['tag1', 'tag2']);
      expect(fp1, fp2);
    });

    test('different title produces different fingerprint', () {
      final fp1 = contentFingerprint('Title A', 'Summary', ['tag']);
      final fp2 = contentFingerprint('Title B', 'Summary', ['tag']);
      expect(fp1, isNot(fp2));
    });

    test('different summary produces different fingerprint', () {
      final fp1 = contentFingerprint('Title', 'Summary A', ['tag']);
      final fp2 = contentFingerprint('Title', 'Summary B', ['tag']);
      expect(fp1, isNot(fp2));
    });

    test('different tags produce different fingerprint', () {
      final fp1 = contentFingerprint('Title', 'Summary', ['tag1']);
      final fp2 = contentFingerprint('Title', 'Summary', ['tag2']);
      expect(fp1, isNot(fp2));
    });

    test('empty inputs produce valid fingerprint', () {
      final fp = contentFingerprint('', '', []);
      expect(fp, isA<int>());
    });
  });

  group('IndexService.buildEmbeddingInput', () {
    test('combines title, summary, and tags', () {
      final article = Article(
        id: 't',
        url: 'https://example.com',
        title: 'My Title',
        source: SourcePlatform.web,
        summary: 'This is the summary.',
        tags: ['ai', 'flutter'],
      );
      final input = IndexService.buildEmbeddingInput(article);
      expect(input, contains('My Title'));
      expect(input, contains('This is the summary.'));
      expect(input, contains('ai, flutter'));
    });

    test('omits empty summary', () {
      final article = Article(
        id: 't',
        url: 'https://example.com',
        title: 'My Title',
        source: SourcePlatform.web,
        tags: ['tag'],
      );
      final input = IndexService.buildEmbeddingInput(article);
      expect(input, contains('My Title'));
      expect(input, contains('tag'));
      expect(input, isNot(contains('||')));
    });

    test('uses structured memory retrieval text without Markdown markers', () {
      final article = Article(
        id: 'structured',
        url: 'https://example.com',
        title: 'Agent SDK',
        source: SourcePlatform.web,
        tags: const ['agents'],
        memory: MemoryDocument.ai(
          overview: 'Unified framework.',
          keyPoints: const [
            MemoryKeyPoint(
              id: 'kp-1',
              order: 1,
              topic: 'Handoff',
              content: 'Agents delegate tasks.',
            ),
          ],
          conclusion: 'Improves orchestration.',
        ),
      );

      final input = IndexService.buildEmbeddingInput(article);

      expect(input, contains('Unified framework.'));
      expect(input, contains('Handoff'));
      expect(input, contains('Agents delegate tasks.'));
      expect(input, isNot(contains('**摘要**')));
    });

    test('omits empty tags', () {
      final article = Article(
        id: 't',
        url: 'https://example.com',
        title: 'Title',
        source: SourcePlatform.web,
        summary: 'Summary',
      );
      final input = IndexService.buildEmbeddingInput(article);
      expect(input, contains('Title'));
      expect(input, contains('Summary'));
    });
  });

  group('Keyword retrieval fallback', () {
    final articles = [
      Article(
        id: 'a1',
        url: 'https://example.com/1',
        title: 'Introduction to Flutter',
        source: SourcePlatform.web,
        summary: 'Flutter is a cross-platform UI toolkit by Google.',
        tags: ['flutter', 'mobile'],
      ),
      Article(
        id: 'a2',
        url: 'https://example.com/2',
        title: 'Deep Learning Fundamentals',
        source: SourcePlatform.web,
        summary: 'Neural networks and backpropagation explained.',
        tags: ['ai', 'deep-learning'],
      ),
      Article(
        id: 'a3',
        url: 'https://example.com/3',
        title: 'Advanced Dart Patterns',
        source: SourcePlatform.web,
        summary: 'Mixins, extensions, and isolate patterns in Dart.',
        tags: ['dart', 'flutter'],
      ),
    ];

    test('title match scores higher than summary-only match', () {
      // "Flutter" appears in title of a1 and tags of a3.
      // a1 should rank higher because title match = 3 pts vs tag match = 2 pts.
      final query = 'flutter';
      final scored = <({String id, int score})>[];
      for (final a in articles) {
        int score = 0;
        final titleLower = a.title.toLowerCase();
        final summaryLower = (a.summary ?? '').toLowerCase();
        final tagsLower = a.tags.map((t) => t.toLowerCase()).toList();
        if (titleLower.contains(query)) score += 3;
        if (summaryLower.contains(query)) score += 2;
        if (tagsLower.any((t) => t.contains(query))) score += 2;
        if (score > 0) scored.add((id: a.id, score: score));
      }
      scored.sort((a, b) => b.score.compareTo(a.score));
      expect(scored.first.id, 'a1');
    });

    test('unrelated query returns empty', () {
      const query = 'blockchain cryptocurrency';
      final results = articles.where((a) {
        final lower = query.toLowerCase();
        return a.title.toLowerCase().contains(lower) ||
            (a.summary ?? '').toLowerCase().contains(lower) ||
            a.tags.any((t) => t.toLowerCase().contains(lower));
      }).toList();
      expect(results, isEmpty);
    });
  });

  group('Retrieval service resilience', () {
    final article = Article(
      id: 'flutter',
      url: 'https://example.com/flutter',
      title: 'Flutter state management',
      source: SourcePlatform.web,
      summary: 'Riverpod keeps application state predictable.',
      tags: const ['flutter', 'riverpod'],
    );
    final embedding = EmbeddingService(
      baseUrl: '',
      apiKey: '',
      model: 'test-embedding',
    );

    test('index read failure still returns keyword matches', () async {
      final service = RetrievalService(
        embedding: embedding,
        index: _ThrowingIndexService(),
        compute:
            ({
              required String query,
              required List<double> queryVector,
              required String embeddingModel,
              required List<Map<String, dynamic>> records,
              required List<Map<String, dynamic>> articles,
              required double minRelevance,
              required int topK,
            }) async {
              expect(records, isEmpty);
              return runKeywordRetrievalInProcess(
                query: query,
                articles: articles,
                topK: topK,
              );
            },
      );

      final result = await service.retrieve('flutter', [article]);

      expect(result.method, RetrievalMethod.keyword);
      expect(result.articles.map((item) => item.id), ['flutter']);
    });

    test(
      'isolate failure falls back to in-process keyword retrieval',
      () async {
        final service = RetrievalService(
          embedding: embedding,
          index: _EmptyIndexService(),
          compute:
              ({
                required String query,
                required List<double> queryVector,
                required String embeddingModel,
                required List<Map<String, dynamic>> records,
                required List<Map<String, dynamic>> articles,
                required double minRelevance,
                required int topK,
              }) async => throw TimeoutException('retrieval isolate timed out'),
        );

        final result = await service.retrieve('riverpod', [article]);

        expect(result.method, RetrievalMethod.keyword);
        expect(result.articles.map((item) => item.id), ['flutter']);
      },
    );
  });

  group('Hybrid retrieval RRF fusion', () {
    final articles = [
      Article(
        id: 'a1',
        url: 'https://example.com/1',
        title: 'Flutter Performance',
        source: SourcePlatform.web,
        summary: 'Widget build optimization.',
        tags: ['flutter'],
      ),
      Article(
        id: 'a2',
        url: 'https://example.com/2',
        title: 'Dart Isolates',
        source: SourcePlatform.web,
        summary: 'Concurrency in Dart.',
        tags: ['dart'],
      ),
      Article(
        id: 'a3',
        url: 'https://example.com/3',
        title: 'Riverpod State',
        source: SourcePlatform.web,
        summary: 'State management with Riverpod.',
        tags: ['flutter', 'riverpod'],
      ),
      Article(
        id: 'a4',
        url: 'https://example.com/4',
        title: 'Neural Networks',
        source: SourcePlatform.web,
        summary: 'Backpropagation explained.',
        tags: ['ai'],
      ),
      Article(
        id: 'a5',
        url: 'https://example.com/5',
        title: 'Flutter Widgets',
        source: SourcePlatform.web,
        summary: 'Building UIs with widgets.',
        tags: ['flutter', 'ui'],
      ),
      Article(
        id: 'a6',
        url: 'https://example.com/6',
        title: 'Rust Ownership',
        source: SourcePlatform.web,
        summary: 'Memory safety without GC.',
        tags: ['rust'],
      ),
    ];

    test('RRF boosts articles appearing in both methods', () {
      // a1 and a3 appear in both lists. They should rank higher than a5
      // which appears only in one list.
      final vector = [articles[0], articles[2], articles[4]]; // a1, a3, a5
      final keyword = [articles[0], articles[2], articles[1]]; // a1, a3, a2
      final fused = rrfFuse(vector, keyword, topK: 5);
      final fusedIds = fused.map((a) => a.id).toList();
      // a1 and a3 get RRF score from both lists → should be top 2.
      expect(fusedIds[0], anyOf(equals('a1'), equals('a3')));
      expect(fusedIds[1], anyOf(equals('a1'), equals('a3')));
      expect(fusedIds[0], isNot(equals(fusedIds[1])));
    });

    test('RRF does not produce duplicate articles', () {
      final vector = [articles[0], articles[1]]; // a1, a2
      final keyword = [articles[0], articles[2]]; // a1, a3
      final fused = rrfFuse(vector, keyword, topK: 5);
      final ids = fused.map((a) => a.id).toList();
      // a1 appears in both — should only appear once in output.
      expect(ids.where((id) => id == 'a1').length, 1);
      expect(ids.toSet().length, ids.length);
    });

    test('RRF with vector-only input returns vector order', () {
      final vector = [articles[0], articles[2], articles[4]]; // a1, a3, a5
      final fused = rrfFuse(vector, [], topK: 5);
      expect(fused.map((a) => a.id).toList(), ['a1', 'a3', 'a5']);
    });

    test('RRF with keyword-only input returns keyword order', () {
      final keyword = [articles[2], articles[1], articles[5]]; // a3, a2, a6
      final fused = rrfFuse([], keyword, topK: 5);
      expect(fused.map((a) => a.id).toList(), ['a3', 'a2', 'a6']);
    });

    test('RRF k=60 dampens rank differences', () {
      // a1 at rank 0 in vector gets RRF score 1/60 ≈ 0.0167
      // a4 at rank 0 in keyword gets RRF score 1/60 ≈ 0.0167
      // a1 at rank 1 in keyword gets additional 1/61 ≈ 0.0164
      // Total a1 ≈ 0.0331, a4 ≈ 0.0167 → a1 ranks higher.
      final vector = [articles[0], articles[2]]; // a1 rank=0, a3 rank=1
      final keyword = [articles[3], articles[0]]; // a4 rank=0, a1 rank=1
      final fused = rrfFuse(vector, keyword, topK: 5);
      expect(fused.first.id, 'a1');
    });

    test('topK limits the number of fused results', () {
      final vector = [
        articles[0],
        articles[1],
        articles[2],
        articles[3],
        articles[4],
        articles[5],
      ];
      final keyword = [
        articles[5],
        articles[4],
        articles[3],
        articles[2],
        articles[1],
        articles[0],
      ];
      final fused = rrfFuse(vector, keyword, topK: 3);
      expect(fused.length, 3);
    });

    test('RRF fusion preserves article objects by reference', () {
      final vector = [articles[0]];
      final keyword = [articles[0]];
      final fused = rrfFuse(vector, keyword, topK: 5);
      expect(fused.length, 1);
      expect(identical(fused[0], articles[0]), true);
    });
  });
}

class _ThrowingIndexService extends IndexService {
  @override
  Future<List<IndexRecord>> getAll() async {
    throw StateError('vector index is unavailable');
  }
}

class _EmptyIndexService extends IndexService {
  @override
  Future<List<IndexRecord>> getAll() async => const [];
}
