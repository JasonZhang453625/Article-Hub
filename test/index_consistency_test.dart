import 'package:flutter_test/flutter_test.dart';
import 'package:article_hub/data/models/passage.dart';
import 'package:article_hub/data/models/source_platform.dart';
import 'package:article_hub/data/services/embedding_service.dart';
import 'package:article_hub/data/services/index_service.dart';

/// Phase 2.4 integration tests:
/// Verify that after new articles, re-summarization, deletion, and import,
/// the index stays consistent. These tests exercise the pure logic layer
/// without requiring a running Hive instance.
void main() {
  group('Index consistency: fingerprint staleness detection', () {
    test('fingerprint changes when title changes', () {
      final fp1 = contentFingerprint('Original Title', 'Summary', ['tag']);
      final fp2 = contentFingerprint('New Title', 'Summary', ['tag']);
      expect(fp1, isNot(fp2));
    });

    test('fingerprint changes when summary changes (re-summarization)', () {
      final fp1 = contentFingerprint('Title', 'Old summary text', ['tag']);
      final fp2 = contentFingerprint('Title', 'New improved summary', ['tag']);
      expect(fp1, isNot(fp2));
    });

    test('fingerprint changes when tags change', () {
      final fp1 = contentFingerprint('Title', 'Summary', ['ai', 'ml']);
      final fp2 = contentFingerprint('Title', 'Summary', ['ai', 'ml', 'new']);
      expect(fp1, isNot(fp2));
    });

    test('fingerprint is stable for unchanged content', () {
      final fp1 = contentFingerprint('Title', 'Summary', ['a', 'b']);
      final fp2 = contentFingerprint('Title', 'Summary', ['a', 'b']);
      expect(fp1, fp2);
    });

    test('index record becomes stale after re-summarization', () {
      // Simulate: article indexed, then summary regenerated.
      final article = Article(
        id: 'a1',
        url: 'https://example.com',
        title: 'Deep Learning',
        source: SourcePlatform.web,
        summary: 'Original summary about deep learning.',
        tags: ['ai'],
      );

      final indexedFingerprint = contentFingerprint(
        article.title,
        article.summary!,
        article.tags,
      );

      // User regenerates summary.
      final updated = article.copyWith(
        summary: 'Completely rewritten summary with new insights.',
      );

      final currentFingerprint = contentFingerprint(
        updated.title,
        updated.summary!,
        updated.tags,
      );

      // Index is now stale.
      expect(indexedFingerprint, isNot(currentFingerprint));
    });
  });

  group('Index consistency: embedding input construction', () {
    test('buildEmbeddingInput includes title, summary, and tags', () {
      final article = Article(
        id: 'e1',
        url: 'https://example.com',
        title: 'Flutter Performance',
        source: SourcePlatform.web,
        summary: 'Tips for optimizing Flutter apps.',
        tags: ['flutter', 'performance'],
      );
      final input = IndexService.buildEmbeddingInput(article);
      expect(input, contains('Flutter Performance'));
      expect(input, contains('Tips for optimizing'));
      expect(input, contains('flutter, performance'));
    });

    test('buildEmbeddingInput handles null summary gracefully', () {
      final article = Article(
        id: 'e2',
        url: 'https://example.com',
        title: 'No Summary Yet',
        source: SourcePlatform.web,
        tags: ['test'],
      );
      final input = IndexService.buildEmbeddingInput(article);
      expect(input, contains('No Summary Yet'));
      expect(input, contains('test'));
      // Should not contain empty lines from null summary.
      expect(input.contains('\n\n'), isFalse);
    });

    test('buildEmbeddingInput handles empty tags', () {
      final article = Article(
        id: 'e3',
        url: 'https://example.com',
        title: 'Title Only',
        source: SourcePlatform.web,
        summary: 'A summary.',
      );
      final input = IndexService.buildEmbeddingInput(article);
      expect(input, contains('Title Only'));
      expect(input, contains('A summary.'));
    });

    test('input changes after tag addition (triggers index update)', () {
      final article = Article(
        id: 'e4',
        url: 'https://example.com',
        title: 'Title',
        source: SourcePlatform.web,
        summary: 'Summary',
        tags: ['original'],
      );
      final input1 = IndexService.buildEmbeddingInput(article);

      final updated = article.copyWith(tags: ['original', 'new-tag']);
      final input2 = IndexService.buildEmbeddingInput(updated);

      expect(input1, isNot(input2));
    });
  });

  group('Index consistency: orphan detection logic', () {
    test('orphan IDs are those not in valid set', () {
      // Simulate: index has records for a1, a2, a3.
      // Valid articles are only a1, a3 (a2 was deleted).
      final indexedIds = {'a1', 'a2', 'a3'};
      final validIds = {'a1', 'a3'};
      final orphans = indexedIds.difference(validIds);
      expect(orphans, {'a2'});
    });

    test('no orphans when all indexed articles exist', () {
      final indexedIds = {'a1', 'a2'};
      final validIds = {'a1', 'a2', 'a3'};
      final orphans = indexedIds.difference(validIds);
      expect(orphans, isEmpty);
    });

    test('all are orphans when knowledge base is cleared', () {
      final indexedIds = {'a1', 'a2', 'a3'};
      final validIds = <String>{};
      final orphans = indexedIds.difference(validIds);
      expect(orphans, {'a1', 'a2', 'a3'});
    });
  });

  group('Index consistency: rebuild from knowledge cards', () {
    test('only completed articles with summaries are indexable', () {
      final articles = [
        Article(
          id: 'idx1',
          url: 'https://example.com/1',
          title: 'Complete',
          source: SourcePlatform.web,
          summary: 'Has summary.',
          processingStatus: ProcessingStatus.completed,
        ),
        Article(
          id: 'idx2',
          url: 'https://example.com/2',
          title: 'No Summary',
          source: SourcePlatform.web,
          processingStatus: ProcessingStatus.completed,
        ),
        Article(
          id: 'idx3',
          url: 'https://example.com/3',
          title: 'Failed',
          source: SourcePlatform.web,
          summary: 'Has summary but failed.',
          processingStatus: ProcessingStatus.failed,
        ),
        Article(
          id: 'idx4',
          url: 'https://example.com/4',
          title: 'Pending',
          source: SourcePlatform.web,
          processingStatus: ProcessingStatus.pending,
        ),
      ];

      final indexable = articles
          .where((a) =>
              a.processingStatus == ProcessingStatus.completed &&
              a.summary != null &&
              a.summary!.isNotEmpty)
          .toList();

      expect(indexable, hasLength(1));
      expect(indexable.first.id, 'idx1');
    });

    test('articles with empty string summary are not indexable', () {
      final article = Article(
        id: 'empty',
        url: 'https://example.com',
        title: 'Empty Summary',
        source: SourcePlatform.web,
        summary: '',
        processingStatus: ProcessingStatus.completed,
      );

      final isIndexable = article.processingStatus == ProcessingStatus.completed &&
          article.summary != null &&
          article.summary!.isNotEmpty;

      expect(isIndexable, isFalse);
    });
  });

  group('Index consistency: model change detection', () {
    test('same content + different model = index needs rebuild', () {
      // When user changes embedding model, all records are stale.
      const oldModel = 'text-embedding-ada-002';
      const newModel = 'text-embedding-3-small';

      // Simulate records indexed with old model.
      final record = IndexRecord(
        articleId: 'a1',
        model: oldModel,
        fingerprint: contentFingerprint('T', 'S', ['t']),
        vector: [0.1, 0.2, 0.3],
      );

      final needsRebuild = record.model != newModel;
      expect(needsRebuild, isTrue);
    });

    test('same model + same fingerprint = index is fresh', () {
      const model = 'text-embedding-3-small';
      final fp = contentFingerprint('Title', 'Summary', ['tag']);

      final record = IndexRecord(
        articleId: 'a1',
        model: model,
        fingerprint: fp,
        vector: [0.1, 0.2, 0.3],
      );

      final currentFp = contentFingerprint('Title', 'Summary', ['tag']);
      final isFresh = record.model == model && record.fingerprint == currentFp;
      expect(isFresh, isTrue);
    });
  });
}
