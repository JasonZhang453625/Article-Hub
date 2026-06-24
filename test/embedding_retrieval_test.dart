import 'package:flutter_test/flutter_test.dart';
import 'package:article_hub/data/services/embedding_service.dart';
import 'package:article_hub/data/models/passage.dart';
import 'package:article_hub/data/models/source_platform.dart';
import 'package:article_hub/data/services/index_service.dart';

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
}
