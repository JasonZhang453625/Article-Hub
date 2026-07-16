import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:memora/data/models/memory_document.dart';
import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/source_platform.dart';
import 'package:memora/data/repositories/passage_repository.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('memora-storage-migration-');
    Hive.init(temp.path);
    if (!Hive.isAdapterRegistered(Article.typeId)) {
      Hive.registerAdapter(ArticleAdapter());
    }
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(SourcePlatformAdapter());
    }
  });

  tearDown(() async {
    await Hive.close();
    await temp.delete(recursive: true);
  });

  test(
    'repository init migrates a legacy summary without changing timestamps',
    () async {
      final originalUpdatedAt = DateTime.utc(2025, 1, 2, 3, 4, 5);
      final box = await Hive.openBox<Article>(HiveArticleRepository.boxName);
      await box.put(
        'legacy',
        Article(
          id: 'legacy',
          url: 'https://example.com/legacy',
          title: 'Legacy',
          source: SourcePlatform.web,
          summary: '**摘要**\n\n旧版 Markdown 摘要。',
          updatedAt: originalUpdatedAt,
        ),
      );
      await box.close();

      final repository = HiveArticleRepository();
      await repository.init();

      final migrated = repository.getById('legacy');
      expect(migrated?.summary, isNull);
      expect(migrated?.memory?.kind, MemoryKind.legacyMarkdown);
      expect(migrated?.memory?.body, contains('旧版 Markdown 摘要'));
      expect(migrated?.updatedAt, originalUpdatedAt);
    },
  );

  test(
    'repository init migrates legacy full text and remains idempotent',
    () async {
      final box = await Hive.openBox<Article>(HiveArticleRepository.boxName);
      await box.put(
        'full-text',
        Article(
          id: 'full-text',
          url: 'https://example.com/full-text',
          title: 'Full text',
          source: SourcePlatform.web,
          summary: '完整正文',
          isFullText: true,
          localMimeType: 'text/markdown',
        ),
      );
      await box.close();

      final firstRepository = HiveArticleRepository();
      await firstRepository.init();
      final first = firstRepository.getById('full-text');
      expect(first?.memory?.kind, MemoryKind.fullText);
      expect(first?.memory?.format, 'markdown');
      expect(first?.summary, isNull);

      await Hive.box<Article>(HiveArticleRepository.boxName).close();
      final secondRepository = HiveArticleRepository();
      await secondRepository.init();
      final second = secondRepository.getById('full-text');

      expect(second?.memory?.toJson(), first?.memory?.toJson());
      expect(second?.summary, isNull);
    },
  );

  test(
    'repository remains readable when migration state cannot be opened',
    () async {
      final box = await Hive.openBox<Article>(HiveArticleRepository.boxName);
      await box.put(
        'legacy',
        Article(
          id: 'legacy',
          url: 'https://example.com/legacy',
          title: 'Legacy',
          source: SourcePlatform.web,
          summary: '仍可读取的旧摘要',
        ),
      );
      await box.close();
      await Hive.openBox<String>('data_migrations');

      final repository = HiveArticleRepository();
      await repository.init();

      expect(repository.getById('legacy')?.summary, '仍可读取的旧摘要');
    },
  );
}
