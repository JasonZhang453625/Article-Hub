import 'package:flutter_test/flutter_test.dart';
import 'package:article_hub/data/models/passage.dart';
import 'package:article_hub/data/models/source_platform.dart';

void main() {
  group('ProcessingStatus state transitions', () {
    test('new article defaults to completed', () {
      final a = Article(
        id: 't1',
        url: 'https://example.com',
        title: 'T',
        source: SourcePlatform.web,
      );
      expect(a.processingStatus, ProcessingStatus.completed);
      expect(a.processingStage, isNull);
      expect(a.processingError, isNull);
      expect(a.retryCount, 0);
      expect(a.lastProcessedAt, isNull);
    });

    test('transition pending → processing preserves retryCount', () {
      final a = Article(
        id: 't2',
        url: 'https://example.com',
        title: 'T',
        source: SourcePlatform.web,
        processingStatus: ProcessingStatus.pending,
        retryCount: 2,
      );
      final processing = a.copyWith(
        processingStatus: ProcessingStatus.processing,
        processingStage: ProcessingStage.metadata,
      );
      expect(processing.processingStatus, ProcessingStatus.processing);
      expect(processing.processingStage, ProcessingStage.metadata);
      expect(processing.retryCount, 2);
    });

    test('transition processing → failed records error and stage', () {
      final a = Article(
        id: 't3',
        url: 'https://example.com',
        title: 'T',
        source: SourcePlatform.web,
        processingStatus: ProcessingStatus.processing,
        processingStage: ProcessingStage.summary,
      );
      final failed = a.copyWith(
        processingStatus: ProcessingStatus.failed,
        processingError: 'summary: API timeout',
        lastProcessedAt: DateTime(2026, 6, 16),
      );
      expect(failed.processingStatus, ProcessingStatus.failed);
      expect(failed.processingError, 'summary: API timeout');
      expect(failed.lastProcessedAt, DateTime(2026, 6, 16));
    });

    test('transition failed → pending clears error and bumps retryCount', () {
      final a = Article(
        id: 't4',
        url: 'https://example.com',
        title: 'T',
        source: SourcePlatform.web,
        processingStatus: ProcessingStatus.failed,
        processingError: 'content: extraction failed',
        retryCount: 1,
      );
      final retry = a.copyWith(
        processingStatus: ProcessingStatus.pending,
        processingError: Article.clearValue,
        retryCount: a.retryCount + 1,
      );
      expect(retry.processingStatus, ProcessingStatus.pending);
      expect(retry.processingError, isNull);
      expect(retry.retryCount, 2);
    });

    test('transition processing → completed clears stage', () {
      final a = Article(
        id: 't5',
        url: 'https://example.com',
        title: 'T',
        source: SourcePlatform.web,
        processingStatus: ProcessingStatus.processing,
        processingStage: ProcessingStage.tags,
      );
      final done = a.copyWith(
        processingStatus: ProcessingStatus.completed,
        processingStage: Article.clearValue,
        lastProcessedAt: DateTime.now(),
      );
      expect(done.processingStatus, ProcessingStatus.completed);
      expect(done.processingStage, isNull);
    });
  });

  group('Retry count tracking', () {
    test('retryCount starts at 0 and increments', () {
      var a = Article(
        id: 'r1',
        url: 'https://example.com',
        title: 'T',
        source: SourcePlatform.web,
        processingStatus: ProcessingStatus.pending,
      );
      expect(a.retryCount, 0);

      // Simulate 3 retries
      for (int i = 1; i <= 3; i++) {
        a = a.copyWith(
          processingStatus: ProcessingStatus.pending,
          processingError: Article.clearValue,
          retryCount: a.retryCount + 1,
        );
        expect(a.retryCount, i);
        expect(a.processingError, isNull);
      }
    });

    test('retryCount survives JSON round-trip', () {
      final a = Article(
        id: 'r2',
        url: 'https://example.com',
        title: 'T',
        source: SourcePlatform.web,
        retryCount: 5,
      );
      final restored = Article.fromJson(a.toJson());
      expect(restored.retryCount, 5);
    });
  });

  group('Old Hive data backward compatibility', () {
    test('fromJson with no processing fields defaults to completed', () {
      // Simulate old data that has no processing fields at all.
      final json = <String, dynamic>{
        'id': 'old1',
        'url': 'https://old.com/article',
        'title': 'Old Article',
        'source': 2,
        'tags': ['tech'],
        'notes': 'some notes',
        'createdAt': '2025-01-01T00:00:00.000',
        'updatedAt': '2025-06-01T00:00:00.000',
        'isFavorite': false,
      };
      final a = Article.fromJson(json);
      expect(a.processingStatus, ProcessingStatus.completed);
      expect(a.processingStage, isNull);
      expect(a.processingError, isNull);
      expect(a.retryCount, 0);
      expect(a.lastProcessedAt, isNull);
      expect(a.suggestedFolderId, isNull);
    });

    test('fromJson with partial processing fields handles gracefully', () {
      final json = <String, dynamic>{
        'id': 'partial',
        'url': 'https://example.com',
        'title': 'T',
        'source': 2,
        'processingStatus': 3, // failed
        // processingStage missing
        'processingError': 'network error',
      };
      final a = Article.fromJson(json);
      expect(a.processingStatus, ProcessingStatus.failed);
      expect(a.processingStage, isNull);
      expect(a.processingError, 'network error');
      expect(a.retryCount, 0);
    });
  });

  group('Backup round-trip with processing fields', () {
    test('all processing fields survive toJson/fromJson', () {
      final original = Article(
        id: 'bk1',
        url: 'https://example.com',
        title: 'Backup Test',
        source: SourcePlatform.zhihu,
        processingStatus: ProcessingStatus.failed,
        processingStage: ProcessingStage.summary,
        processingError: 'API rate limited',
        retryCount: 2,
        lastProcessedAt: DateTime(2026, 6, 15, 14, 30),
        suggestedFolderId: 'folder-xyz',
      );
      final restored = Article.fromJson(original.toJson());
      expect(restored.processingStatus, ProcessingStatus.failed);
      expect(restored.processingStage, ProcessingStage.summary);
      expect(restored.processingError, 'API rate limited');
      expect(restored.retryCount, 2);
      expect(restored.lastProcessedAt, DateTime(2026, 6, 15, 14, 30));
      expect(restored.suggestedFolderId, 'folder-xyz');
    });

    test('completed article with no suggestion round-trips cleanly', () {
      final original = Article(
        id: 'bk2',
        url: 'https://example.com',
        title: 'Done',
        source: SourcePlatform.web,
        processingStatus: ProcessingStatus.completed,
      );
      final restored = Article.fromJson(original.toJson());
      expect(restored.processingStatus, ProcessingStatus.completed);
      expect(restored.processingStage, isNull);
      expect(restored.processingError, isNull);
      expect(restored.retryCount, 0);
      expect(restored.suggestedFolderId, isNull);
    });
  });
}
