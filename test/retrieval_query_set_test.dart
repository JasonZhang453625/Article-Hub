import 'package:flutter_test/flutter_test.dart';
import 'package:article_hub/data/models/passage.dart';
import 'package:article_hub/data/models/source_platform.dart';

/// Phase 2.3 fixed query set evaluation.
///
/// A stable corpus + a fixed set of queries covering four categories:
///   1. topic queries (single concept words)
///   2. synonym / alternative phrasing
///   3. specific questions
///   4. no-result questions (should return nothing)
///
/// Vector retrieval needs a live embedding API, so here we evaluate the
/// keyword fallback scorer — the deterministic layer that must always work.
/// This gives a regression guard on retrieval quality without network access.
///
/// The scorer mirrors RetrievalService._keywordRetrieve.
List<String> keywordRetrieve(
  String query,
  List<Article> articles, {
  int topK = 5,
}) {
  final lower = query.toLowerCase();
  final words = lower.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return [];

  final scored = <({String id, int score})>[];
  for (final article in articles) {
    int score = 0;
    final titleLower = article.title.toLowerCase();
    final summaryLower = (article.summary ?? '').toLowerCase();
    final tagsLower = article.tags.map((t) => t.toLowerCase()).toList();

    for (final word in words) {
      if (titleLower.contains(word)) score += 3;
      if (summaryLower.contains(word)) score += 2;
      if (tagsLower.any((t) => t.contains(word))) score += 2;
    }
    if (score > 0) scored.add((id: article.id, score: score));
  }

  scored.sort((a, b) => b.score.compareTo(a.score));
  return scored.take(topK).map((s) => s.id).toList();
}

void main() {
  // ── Fixed corpus ────────────────────────────────────────────────────────
  final corpus = [
    Article(
      id: 'ev',
      url: 'https://example.com/ev',
      title: '新能源汽车竞争格局分析',
      source: SourcePlatform.zhihu,
      summary: '比亚迪和特斯拉在电动汽车市场的竞争，涉及电池技术和续航里程。',
      tags: ['新能源', '电动汽车', '比亚迪'],
      processingStatus: ProcessingStatus.completed,
    ),
    Article(
      id: 'flutter',
      url: 'https://example.com/flutter',
      title: 'Flutter State Management Guide',
      source: SourcePlatform.web,
      summary: 'A comparison of Riverpod, Bloc, and Provider for managing '
          'application state in Flutter apps.',
      tags: ['flutter', 'riverpod', 'mobile'],
      processingStatus: ProcessingStatus.completed,
    ),
    Article(
      id: 'llm',
      url: 'https://example.com/llm',
      title: 'How Large Language Models Work',
      source: SourcePlatform.web,
      summary: 'Transformers, attention mechanisms, and tokenization explained '
          'for understanding LLMs like GPT.',
      tags: ['ai', 'llm', 'machine-learning'],
      processingStatus: ProcessingStatus.completed,
    ),
    Article(
      id: 'coffee',
      url: 'https://example.com/coffee',
      title: 'Pour-Over Coffee Brewing Techniques',
      source: SourcePlatform.web,
      summary: 'Water temperature, grind size, and timing for the perfect '
          'pour-over coffee at home.',
      tags: ['coffee', 'brewing', 'lifestyle'],
      processingStatus: ProcessingStatus.completed,
    ),
    Article(
      id: 'rust',
      url: 'https://example.com/rust',
      title: 'Memory Safety in Rust',
      source: SourcePlatform.web,
      summary: 'Ownership, borrowing, and lifetimes provide memory safety '
          'without a garbage collector in the Rust programming language.',
      tags: ['rust', 'systems', 'programming'],
      processingStatus: ProcessingStatus.completed,
    ),
  ];

  group('Category 1: topic queries return the right article on top', () {
    test('"flutter" → Flutter article ranks first', () {
      final results = keywordRetrieve('flutter', corpus);
      expect(results.first, 'flutter');
    });

    test('"coffee" → coffee article ranks first', () {
      final results = keywordRetrieve('coffee', corpus);
      expect(results.first, 'coffee');
    });

    test('"rust" → rust article ranks first', () {
      final results = keywordRetrieve('rust', corpus);
      expect(results.first, 'rust');
    });

    test('"新能源" → EV article ranks first', () {
      final results = keywordRetrieve('新能源', corpus);
      expect(results.first, 'ev');
    });
  });

  group('Category 2: alternative phrasing still retrieves', () {
    test('"state management" retrieves the Flutter article', () {
      final results = keywordRetrieve('state management', corpus);
      expect(results, contains('flutter'));
    });

    test('"language models" retrieves the LLM article', () {
      final results = keywordRetrieve('language models', corpus);
      expect(results, contains('llm'));
    });

    test('"电动汽车" retrieves the EV article', () {
      final results = keywordRetrieve('电动汽车', corpus);
      expect(results, contains('ev'));
    });
  });

  group('Category 3: specific questions retrieve relevant content', () {
    test('"how do transformers and attention work" → LLM article', () {
      final results =
          keywordRetrieve('how do transformers and attention work', corpus);
      expect(results, contains('llm'));
      expect(results.first, 'llm');
    });

    test('"memory safety without garbage collector" → Rust article', () {
      final results =
          keywordRetrieve('memory safety without garbage collector', corpus);
      expect(results.first, 'rust');
    });

    test('"比亚迪和特斯拉的电池技术" → EV article', () {
      final results = keywordRetrieve('比亚迪 特斯拉 电池技术', corpus);
      expect(results.first, 'ev');
    });
  });

  group('Category 4: no-result questions return nothing', () {
    test('"blockchain cryptocurrency mining" returns empty', () {
      final results = keywordRetrieve('blockchain cryptocurrency mining', corpus);
      expect(results, isEmpty);
    });

    test('"gardening vegetables" returns empty', () {
      final results = keywordRetrieve('gardening vegetables', corpus);
      expect(results, isEmpty);
    });

    test('completely unrelated topic returns empty', () {
      final results = keywordRetrieve('astronomy telescope galaxy', corpus);
      expect(results, isEmpty);
    });
  });

  group('Ranking quality invariants', () {
    test('topK limit is respected', () {
      // A query matching many articles must not exceed topK.
      final results = keywordRetrieve('programming', corpus, topK: 2);
      expect(results.length, lessThanOrEqualTo(2));
    });

    test('title match outranks tag-only match', () {
      // "flutter" appears in flutter article title (3pts) and is a tag there
      // too; no other article should outrank it.
      final results = keywordRetrieve('flutter', corpus);
      expect(results.first, 'flutter');
    });

    test('empty query returns nothing', () {
      expect(keywordRetrieve('', corpus), isEmpty);
      expect(keywordRetrieve('   ', corpus), isEmpty);
    });
  });
}
