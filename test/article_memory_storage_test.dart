import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:memora/data/models/memory_document.dart';
import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/source_platform.dart';

void main() {
  MemoryDocument memory() => MemoryDocument.ai(
    overview: 'Structured overview.',
    keyPoints: const [
      MemoryKeyPoint(
        id: 'kp-1',
        order: 1,
        topic: 'Storage',
        content: 'Hive stores the JSON-compatible map.',
      ),
    ],
    conclusion: 'Markdown is derived at display time.',
    generation: MemoryGeneration(
      method: 'llm',
      provider: 'openai-compatible',
      model: 'test-model',
      promptVersion: 'full_summary_v1',
      generatedAt: DateTime.utc(2026, 7, 16, 8, 30),
    ),
  );

  test('Article exports and restores the nested schema', () {
    final article = Article(
      id: 'article-1',
      url: 'https://example.com/article',
      title: 'Structured memory',
      source: SourcePlatform.web,
      tags: const ['memory'],
      notes: 'User note',
      isFavorite: true,
      folderId: 'folder-1',
      summaryFeedback: 1,
      processingStatus: ProcessingStatus.completed,
      lastProcessedAt: DateTime.utc(2026, 7, 16, 8, 30),
      memory: memory(),
    );

    final json = article.toJson();

    expect(json['schemaVersion'], 1);
    expect(json['source'], isA<Map>());
    expect((json['source'] as Map)['platform'], 'web');
    expect((json['memory'] as Map)['kind'], 'ai_memory');
    expect((json['userState'] as Map)['notes'], 'User note');
    expect((json['processing'] as Map)['status'], 'completed');
    expect((json['generation'] as Map)['model'], 'test-model');
    expect(json.containsKey('summary'), isFalse);

    final restored = Article.fromJson(json);

    expect(restored.memory?.keyPoints.single.id, 'kp-1');
    expect(restored.memory?.generation?.model, 'test-model');
    expect(restored.notes, 'User note');
    expect(restored.folderId, 'folder-1');
    expect(restored.summaryFeedback, 1);
    expect(restored.hasMemory, isTrue);
    expect(restored.displayMemoryMarkdown, contains('**摘要**'));
    expect(restored.retrievalText, contains('Hive stores'));
  });

  test('legacy flat JSON is converted to structured legacy memory', () {
    final restored = Article.fromJson({
      'id': 'legacy',
      'url': 'https://example.com/legacy',
      'title': 'Legacy article',
      'source': 2,
      'tags': ['legacy'],
      'notes': '',
      'summary': '**摘要**\n\nLegacy Markdown.',
      'isFullText': false,
      'processingStatus': ProcessingStatus.completed.index,
    });

    expect(restored.memory?.kind, MemoryKind.legacyMarkdown);
    expect(restored.memory?.body, contains('Legacy Markdown'));
    expect(restored.summary, isNull);
    expect(restored.hasMemory, isTrue);
    expect(restored.displayMemoryMarkdown, contains('Legacy Markdown'));
    expect(restored.retrievalText, contains('Legacy Markdown'));
  });

  test('copyWith can replace and explicitly clear structured memory', () {
    final article = Article(
      id: 'copy',
      url: 'https://example.com',
      title: 'Copy',
      source: SourcePlatform.web,
      memory: memory(),
    );

    expect(article.copyWith(title: 'Changed').memory, isNotNull);
    expect(article.copyWith(memory: Article.clearValue).memory, isNull);
  });

  test(
    'ArticleAdapter persists the structured map in a new Hive field',
    () async {
      final temp = await Directory.systemTemp.createTemp('memora-memory-hive-');
      Hive.init(temp.path);
      if (!Hive.isAdapterRegistered(Article.typeId)) {
        Hive.registerAdapter(ArticleAdapter());
      }
      if (!Hive.isAdapterRegistered(1)) {
        Hive.registerAdapter(SourcePlatformAdapter());
      }

      try {
        final box = await Hive.openBox<Article>('structured-memory-test');
        await box.put(
          'article-1',
          Article(
            id: 'article-1',
            url: 'https://example.com',
            title: 'Hive',
            source: SourcePlatform.web,
            memory: memory(),
          ),
        );

        final restored = box.get('article-1');
        expect(restored?.memory?.keyPoints.single.id, 'kp-1');
        expect(restored?.summary, isNull);
      } finally {
        await Hive.close();
        await temp.delete(recursive: true);
      }
    },
  );
}
