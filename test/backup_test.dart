import 'package:flutter_test/flutter_test.dart';
import 'package:article_hub/data/models/passage.dart';
import 'package:article_hub/data/models/filter_group.dart';
import 'package:article_hub/data/models/settings.dart';
import 'package:article_hub/data/models/source_platform.dart';
import 'package:article_hub/data/services/backup_data.dart';

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
      );
      final restored = AppSettings.fromJson(original.toJson());
      expect(restored.fontSize, 18);
      expect(restored.webZoomPercent, 120);
      expect(restored.themeModeIndex, 2);
      expect(restored.clipboardDetectionEnabled, isFalse);
    });

    test('AppSettings defaults clipboardDetectionEnabled to true when absent',
        () {
      // Older backups won't have the field; it should default to enabled.
      final restored = AppSettings.fromJson({'fontSize': 14});
      expect(restored.clipboardDetectionEnabled, isTrue);
    });

    test('Article.fromJson throws on missing required fields', () {
      expect(() => Article.fromJson({'title': 'x'}), throwsFormatException);
    });
  });

  group('BackupData', () {
    test('full backup round-trips through JSON string', () {
      final backup = BackupData.create(
        articles: [
          Article(
            id: 'a1',
            url: 'https://medium.com/p/1',
            title: 'Post',
            source: SourcePlatform.medium,
            tags: ['x'],
          ),
        ],
        filterGroups: [
          FilterGroup(id: 'f1', name: 'G', sourcePlatforms: ['medium']),
        ],
        settings: AppSettings(fontSize: 16),
      );

      final restored = BackupData.fromJsonString(backup.toJsonString());

      expect(restored.schemaVersion, kBackupSchemaVersion);
      expect(restored.articles, hasLength(1));
      expect(restored.articles.first.id, 'a1');
      expect(restored.articles.first.source, SourcePlatform.medium);
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
  });
}
