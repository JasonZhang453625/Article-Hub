import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:article_hub/data/models/passage.dart';
import 'package:article_hub/data/models/settings.dart';
import 'package:article_hub/data/models/source_platform.dart';
import 'package:article_hub/data/services/backup_data.dart';

/// Phase 2.4 security tests:
/// - API Key (chat and embedding) must never appear in exported backup JSON.
/// - Vector data (from IndexRecord) must never enter the backup.
void main() {
  group('Security: API keys excluded from backup', () {
    test('aiApiKey is never present in AppSettings.toJson()', () {
      final settings = AppSettings(
        aiBaseUrl: 'https://api.openai.com',
        aiApiKey: 'sk-secret-key-12345',
        aiModel: 'gpt-4o-mini',
      );
      final json = settings.toJson();
      expect(json.containsKey('aiApiKey'), isFalse);
      // Ensure the key value doesn't appear anywhere in the serialized output.
      final serialized = jsonEncode(json);
      expect(serialized.contains('sk-secret-key-12345'), isFalse);
    });

    test('embeddingApiKey is never present in AppSettings.toJson()', () {
      final settings = AppSettings(
        embeddingBaseUrl: 'https://api.openai.com',
        embeddingApiKey: 'sk-embedding-secret-99',
        embeddingModel: 'text-embedding-3-small',
      );
      final json = settings.toJson();
      expect(json.containsKey('embeddingApiKey'), isFalse);
      final serialized = jsonEncode(json);
      expect(serialized.contains('sk-embedding-secret-99'), isFalse);
    });

    test('full backup export never leaks any API key', () {
      final backup = BackupData.create(
        articles: [
          Article(
            id: 'a1',
            url: 'https://example.com',
            title: 'Test',
            source: SourcePlatform.web,
          ),
        ],
        filterGroups: const [],
        folders: const [],
        settings: AppSettings(
          aiBaseUrl: 'https://api.openai.com',
          aiApiKey: 'sk-LIVE-KEY-abc123',
          aiModel: 'gpt-4o',
          embeddingBaseUrl: 'https://embed.provider.com',
          embeddingApiKey: 'sk-EMBED-KEY-xyz789',
          embeddingModel: 'text-embedding-3-small',
        ),
      );

      final jsonString = backup.toJsonString();
      expect(jsonString.contains('sk-LIVE-KEY-abc123'), isFalse,
          reason: 'AI API key must not appear in backup export');
      expect(jsonString.contains('sk-EMBED-KEY-xyz789'), isFalse,
          reason: 'Embedding API key must not appear in backup export');
      // Keys in the JSON key names
      expect(jsonString.contains('"aiApiKey"'), isFalse);
      expect(jsonString.contains('"embeddingApiKey"'), isFalse);
    });

    test('importing a backup with API key fields does not crash', () {
      // Older or manually-crafted backups might have the keys; the importer
      // must not crash, but should read them defensively.
      const jsonStr = '''
      {
        "schemaVersion": 2,
        "exportedAt": "2026-06-16T00:00:00.000",
        "articles": [{"id": "a1", "url": "https://x.com", "title": "T", "source": 2}],
        "filterGroups": [],
        "settings": {
          "aiApiKey": "sk-should-be-ignored",
          "embeddingApiKey": "sk-also-ignored",
          "fontSize": 16
        }
      }
      ''';
      final backup = BackupData.fromJsonString(jsonStr);
      expect(backup.settings, isNotNull);
      // The key is read defensively but never exported again.
      expect(backup.settings!.fontSize, 16.0);
    });
  });

  group('Security: vector index data excluded from backup', () {
    test('Article.toJson() has no vector or embedding fields', () {
      final article = Article(
        id: 'v1',
        url: 'https://example.com',
        title: 'Test Vector Exclusion',
        source: SourcePlatform.web,
        summary: 'A summary for embedding.',
        tags: ['ai', 'test'],
        processingStatus: ProcessingStatus.completed,
      );
      final json = article.toJson();
      // No vector, no embedding, no index data in the export.
      expect(json.containsKey('vector'), isFalse);
      expect(json.containsKey('embedding'), isFalse);
      expect(json.containsKey('indexRecord'), isFalse);
      expect(json.containsKey('fingerprint'), isFalse);
    });

    test('BackupData does not include any index/vector section', () {
      final backup = BackupData.create(
        articles: [
          Article(
            id: 'v2',
            url: 'https://example.com',
            title: 'Indexed Article',
            source: SourcePlatform.web,
            summary: 'This article has been indexed.',
          ),
        ],
        filterGroups: const [],
        folders: const [],
        settings: null,
      );
      final json = backup.toJson();
      expect(json.containsKey('vectorIndex'), isFalse);
      expect(json.containsKey('indexRecords'), isFalse);
      expect(json.containsKey('embeddings'), isFalse);

      final jsonString = backup.toJsonString();
      expect(jsonString.contains('vector'), isFalse);
      expect(jsonString.contains('embedding'), isFalse);
    });
  });
}
