import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/filter_group.dart';
import 'package:memora/data/models/settings.dart';
import 'package:memora/data/models/source_platform.dart';
import 'package:memora/data/services/backup_data.dart';

void main() {
  group('model JSON round-trip', () {
    test('Article survives toJson/fromJson', () {
      final original = Article(
        id: 'a1',
        url: 'https://x.com/post/1',
        title: 'Hello',
        source: SourcePlatform.x,
        tags: ['tech', 'flutter'],
        notes: 'a note',
        createdAt: DateTime(2025, 1, 2, 3, 4, 5),
        updatedAt: DateTime(2025, 6, 7, 8, 9, 10),
        isFavorite: true,
      );

      final restored = Article.fromJson(original.toJson());

      expect(restored.id, original.id);
      expect(restored.url, original.url);
      expect(restored.title, original.title);
      expect(restored.source, SourcePlatform.x);
      expect(restored.tags, original.tags);
      expect(restored.notes, original.notes);
      expect(restored.createdAt, original.createdAt);
      expect(restored.updatedAt, original.updatedAt);
      expect(restored.isFavorite, isTrue);
    });

    test('FilterGroup survives toJson/fromJson', () {
      final original = FilterGroup(
        id: 'f1',
        name: 'Tech videos',
        tagPatterns: ['ai'],
        sourcePlatforms: ['youtube', 'bilibili'],
      );
      final restored = FilterGroup.fromJson(original.toJson());
      expect(restored.id, 'f1');
      expect(restored.name, 'Tech videos');
      expect(restored.tagPatterns, ['ai']);
      expect(restored.sourcePlatforms, ['youtube', 'bilibili']);
    });

    test('AppSettings survives toJson/fromJson', () {
      final original = AppSettings(
        fontSize: 18,
        webZoomPercent: 120,
        themeModeIndex: 2,
        clipboardDetectionEnabled: false,
        memorySortNewestFirst: false,
      );
      final restored = AppSettings.fromJson(original.toJson());
      expect(restored.fontSize, 18);
      expect(restored.webZoomPercent, 120);
      expect(restored.themeModeIndex, 2);
      expect(restored.clipboardDetectionEnabled, isFalse);
      expect(restored.memorySortNewestFirst, isFalse);
    });

    test(
      'AppSettings defaults clipboardDetectionEnabled to true when absent',
      () {
        // Older backups won't have the field; it should default to enabled.
        final restored = AppSettings.fromJson({'fontSize': 14});
        expect(restored.clipboardDetectionEnabled, isTrue);
      },
    );

    test('AppSettings defaults memory sorting to newest first when absent', () {
      final restored = AppSettings.fromJson({'fontSize': 14});
      expect(restored.memorySortNewestFirst, isTrue);
    });

    test('AppSettings.toJson excludes API keys from export payloads', () {
      // API keys stay local to the device and must not enter backup or sync
      // payloads.
      final settings = AppSettings(
        fontSize: 16,
        aiBaseUrl: 'https://api.openai.com/v1',
        aiApiKey: 'sk-test-key',
        aiModel: 'gpt-4o-mini',
      );
      final json = settings.toJson();
      expect(
        json.containsKey('aiApiKey'),
        isFalse,
        reason: 'API key must not appear in AppSettings JSON export path',
      );
      expect(json.toString().contains('sk-test-key'), isFalse);
      expect(json['aiBaseUrl'], 'https://api.openai.com/v1');
      expect(json['aiModel'], 'gpt-4o-mini');
    });

    test('Article.fromJson throws on missing required fields', () {
      expect(() => Article.fromJson({'title': 'x'}), throwsFormatException);
    });
  });

  group('BackupData', () {
    test('structured Article exports use backup schema version 3', () {
      expect(kBackupSchemaVersion, 3);
    });

    test('full backup round-trips through JSON string', () {
      final backup = BackupData.create(
        articles: [
          Article(
            id: 'a1',
            url: 'https://example.com/p/1',
            title: 'Post',
            source: SourcePlatform.web,
            tags: ['x'],
          ),
        ],
        filterGroups: [
          FilterGroup(id: 'f1', name: 'G', sourcePlatforms: ['web']),
        ],
        folders: const [],
        settings: AppSettings(fontSize: 16),
      );

      final restored = BackupData.fromJsonString(backup.toJsonString());

      expect(restored.schemaVersion, kBackupSchemaVersion);
      expect(restored.articles, hasLength(1));
      expect(restored.articles.first.id, 'a1');
      expect(restored.articles.first.source, SourcePlatform.web);
      expect(restored.filterGroups, hasLength(1));
      expect(restored.settings?.fontSize, 16);
    });

    test('skips malformed article entries but keeps valid ones', () {
      const json = '''
      {
        "schemaVersion": 1,
        "articles": [
          {"id": "ok", "url": "https://a.com", "title": "T", "source": 2},
          {"title": "missing id and url"}
        ],
        "filterGroups": []
      }
      ''';
      final backup = BackupData.fromJsonString(json);
      expect(backup.articles, hasLength(1));
      expect(backup.articles.first.id, 'ok');
    });

    test('throws on non-JSON input', () {
      expect(
        () => BackupData.fromJsonString('not json at all'),
        throwsFormatException,
      );
    });

    test('throws when there are no articles or filter groups', () {
      expect(
        () => BackupData.fromJsonString('{"schemaVersion": 1}'),
        throwsFormatException,
      );
    });

    test('imports legacy backup with app="article-hub"', () {
      const json = '''
      {
        "schemaVersion": 2,
        "app": "article-hub",
        "exportedAt": "2025-01-01T00:00:00.000",
        "articles": [
          {"id": "a1", "url": "https://a.com", "title": "T", "source": 2}
        ],
        "filterGroups": []
      }
      ''';
      final backup = BackupData.fromJsonString(json);
      expect(backup.articles, hasLength(1));
      expect(backup.articles.first.id, 'a1');
    });

    test('imports backup with app="memora"', () {
      const json = '''
      {
        "schemaVersion": 2,
        "app": "memora",
        "exportedAt": "2025-01-01T00:00:00.000",
        "articles": [
          {"id": "a2", "url": "https://b.com", "title": "T2", "source": 2}
        ],
        "filterGroups": []
      }
      ''';
      final backup = BackupData.fromJsonString(json);
      expect(backup.articles, hasLength(1));
      expect(backup.articles.first.id, 'a2');
    });

    test('throws on unrecognized app field', () {
      const json = '''
      {
        "schemaVersion": 2,
        "app": "unknown-app",
        "articles": [
          {"id": "a1", "url": "https://a.com", "title": "T", "source": 2}
        ],
        "filterGroups": []
      }
      ''';
      expect(() => BackupData.fromJsonString(json), throwsFormatException);
    });

    test('new export uses app="memora"', () {
      final backup = BackupData.create(
        articles: [
          Article(
            id: 'a1',
            url: 'https://example.com/p/1',
            title: 'Post',
            source: SourcePlatform.web,
          ),
        ],
        filterGroups: const [],
        folders: const [],
        settings: null,
      );
      final json = backup.toJson();
      expect(json['app'], 'memora');
    });
  });

  group('UTF-8 byte round-trip (import path regression)', () {
    // The import path reads the picked file as raw bytes and must decode them
    // as UTF-8. A previous bug used String.fromCharCodes, which mangles every
    // multibyte character (Chinese, emoji). This guards that the bytes the
    // export writes survive a utf8.decode the way the importer does it.
    test('non-ASCII content survives utf8 encode/decode round-trip', () {
      final original = Article(
        id: 'cn1',
        url: 'https://zhihu.com/p/1',
        title: '深度学习入门 🚀',
        source: SourcePlatform.zhihu,
        tags: ['机器学习', '笔记'],
        notes: '这是一条中文备注，含 emoji 😀 和符号 ——。',
        createdAt: DateTime(2025, 1, 2, 3, 4, 5),
        updatedAt: DateTime(2025, 6, 7, 8, 9, 10),
      );
      final backup = BackupData.create(
        articles: [original],
        filterGroups: const [],
        folders: const [],
        settings: null,
      );

      // Simulate export (UTF-8 bytes) → import (utf8.decode of those bytes).
      final bytes = utf8.encode(backup.toJsonString());
      final decoded = utf8.decode(bytes);
      final restored = BackupData.fromJsonString(decoded);

      expect(restored.articles, hasLength(1));
      final a = restored.articles.first;
      expect(a.title, '深度学习入门 🚀');
      expect(a.tags, ['机器学习', '笔记']);
      expect(a.notes, '这是一条中文备注，含 emoji 😀 和符号 ——。');
    });
  });

  group('Article.copyWith nullable clearing', () {
    final base = Article(
      id: 'x',
      url: 'https://example.com',
      title: 'T',
      source: SourcePlatform.web,
      coverImageUrl: 'https://img/cover.png',
      summary: 'a summary',
      folderId: 'folder-1',
    );

    test('omitting a nullable field leaves it unchanged', () {
      final copy = base.copyWith(title: 'New title');
      expect(copy.coverImageUrl, 'https://img/cover.png');
      expect(copy.summary, 'a summary');
      expect(copy.folderId, 'folder-1');
    });

    test('clearValue resets nullable fields to null', () {
      final copy = base.copyWith(
        coverImageUrl: Article.clearValue,
        summary: Article.clearValue,
        folderId: Article.clearValue,
      );
      expect(copy.coverImageUrl, isNull);
      expect(copy.summary, isNull);
      expect(copy.folderId, isNull);
    });

    test('passing a new value replaces a nullable field', () {
      final copy = base.copyWith(folderId: 'folder-2');
      expect(copy.folderId, 'folder-2');
    });
  });

  group('Processing status fields', () {
    test('new Article defaults to completed with no stage/error/retries', () {
      final a = Article(
        id: 'p1',
        url: 'https://example.com',
        title: 'T',
        source: SourcePlatform.web,
      );
      expect(a.processingStatus, ProcessingStatus.completed);
      expect(a.processingStage, isNull);
      expect(a.processingError, isNull);
      expect(a.retryCount, 0);
      expect(a.lastProcessedAt, isNull);
      expect(a.suggestedFolderId, isNull);
    });

    test('processing fields survive toJson/fromJson round-trip', () {
      final original = Article(
        id: 'p2',
        url: 'https://example.com',
        title: 'T',
        source: SourcePlatform.web,
        processingStatus: ProcessingStatus.failed,
        processingStage: ProcessingStage.summary,
        processingError: 'API timeout',
        retryCount: 3,
        lastProcessedAt: DateTime(2026, 6, 15, 10, 30),
        suggestedFolderId: 'folder-abc',
      );
      final restored = Article.fromJson(original.toJson());
      expect(restored.processingStatus, ProcessingStatus.failed);
      expect(restored.processingStage, ProcessingStage.summary);
      expect(restored.processingError, 'API timeout');
      expect(restored.retryCount, 3);
      expect(restored.lastProcessedAt, DateTime(2026, 6, 15, 10, 30));
      expect(restored.suggestedFolderId, 'folder-abc');
    });

    test(
      'fromJson defaults to completed when processing fields are absent',
      () {
        final json = <String, dynamic>{
          'id': 'old',
          'url': 'https://old.com',
          'title': 'Old article',
          'source': 2,
        };
        final a = Article.fromJson(json);
        expect(a.processingStatus, ProcessingStatus.completed);
        expect(a.processingStage, isNull);
        expect(a.processingError, isNull);
        expect(a.retryCount, 0);
        expect(a.lastProcessedAt, isNull);
        expect(a.suggestedFolderId, isNull);
      },
    );

    test('copyWith updates processing fields', () {
      final a = Article(
        id: 'p3',
        url: 'https://example.com',
        title: 'T',
        source: SourcePlatform.web,
      );
      final updated = a.copyWith(
        processingStatus: ProcessingStatus.processing,
        processingStage: ProcessingStage.content,
        retryCount: 1,
      );
      expect(updated.processingStatus, ProcessingStatus.processing);
      expect(updated.processingStage, ProcessingStage.content);
      expect(updated.retryCount, 1);
    });

    test('copyWith clearValue resets nullable processing fields', () {
      final a = Article(
        id: 'p4',
        url: 'https://example.com',
        title: 'T',
        source: SourcePlatform.web,
        processingStage: ProcessingStage.metadata,
        processingError: 'err',
        lastProcessedAt: DateTime(2026, 1, 1),
        suggestedFolderId: 'f1',
      );
      final cleared = a.copyWith(
        processingStage: Article.clearValue,
        processingError: Article.clearValue,
        lastProcessedAt: Article.clearValue,
        suggestedFolderId: Article.clearValue,
      );
      expect(cleared.processingStage, isNull);
      expect(cleared.processingError, isNull);
      expect(cleared.lastProcessedAt, isNull);
      expect(cleared.suggestedFolderId, isNull);
    });

    test('all ProcessingStatus enum values are valid', () {
      for (final status in ProcessingStatus.values) {
        final a = Article(
          id: 's',
          url: 'https://x.com',
          title: 'T',
          source: SourcePlatform.x,
          processingStatus: status,
        );
        final restored = Article.fromJson(a.toJson());
        expect(restored.processingStatus, status);
      }
    });

    test('all ProcessingStage enum values survive round-trip', () {
      for (final stage in ProcessingStage.values) {
        final a = Article(
          id: 's',
          url: 'https://x.com',
          title: 'T',
          source: SourcePlatform.x,
          processingStage: stage,
        );
        final restored = Article.fromJson(a.toJson());
        expect(restored.processingStage, stage);
      }
    });
  });
}
