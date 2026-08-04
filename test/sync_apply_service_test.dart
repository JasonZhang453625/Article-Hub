import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/settings.dart';
import 'package:memora/data/models/source_platform.dart';
import 'package:memora/data/repositories/passage_repository.dart';
import 'package:memora/data/services/sync_apply_service.dart';
import 'package:memora/data/services/sync_outbox_service.dart';
import 'package:memora/data/services/sync_protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late SyncOutboxService outbox;
  late SyncApplyService applier;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('memora_sync_apply_test_');
    Hive.init(tempDir.path);
    outbox = SyncOutboxService();
    applier = SyncApplyService(outbox: outbox);
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('applies plaintext article upsert and delete events', () async {
    final article = Article(
      id: 'article-1',
      url: 'https://example.com/a',
      title: 'Remote article',
      source: SourcePlatform.web,
      tags: const ['sync'],
    );

    final upsertResult = await applier.applyEvents([
      _plainEvent(
        collection: SyncCollections.articles,
        itemId: article.id,
        payload: article.toJson(),
        accountId: 'user-1',
      ),
    ], accountId: 'user-1');
    expect(upsertResult.applied, 1);

    final articleBox = await Hive.openBox<Article>(
      HiveArticleRepository.boxName,
    );
    expect(articleBox.get(article.id)?.title, 'Remote article');

    final deleteResult = await applier.applyEvents([
      {
        'collection': SyncCollections.articles,
        'itemId': article.id,
        'op': SyncOperation.delete.name,
      },
    ]);
    expect(deleteResult.applied, 1);
    expect(articleBox.get(article.id), isNull);
  });

  test('applies AI provider keys from account settings JSON', () async {
    final settingsBox = await Hive.openBox<AppSettings>('app_settings');
    await settingsBox.put(
      'settings',
      AppSettings(
        aiApiKey: 'sk-local-ai',
        embeddingApiKey: 'sk-local-embedding',
      ),
    );

    final incoming = AppSettings(
      fontSize: 18,
      aiBaseUrl: 'https://ai.example',
      aiApiKey: 'sk-remote-ai',
      embeddingApiKey: 'sk-remote-embedding',
    );
    final result = await applier.applyEvents([
      _plainEvent(
        collection: SyncCollections.appSettings,
        itemId: 'settings',
        payload: incoming.toSyncJson(),
        accountId: 'user-1',
      ),
    ], accountId: 'user-1');
    expect(result.applied, 1);

    final restored = settingsBox.get('settings')!;
    expect(restored.fontSize, 18);
    expect(restored.aiBaseUrl, 'https://ai.example');
    expect(restored.aiApiKey, 'sk-remote-ai');
    expect(restored.embeddingApiKey, 'sk-remote-embedding');
  });

  test('legacy plaintext settings without keys preserve local keys', () async {
    final settingsBox = await Hive.openBox<AppSettings>('app_settings');
    await settingsBox.put(
      'settings',
      AppSettings(
        aiApiKey: 'sk-local-ai',
        embeddingApiKey: 'sk-local-embedding',
      ),
    );

    final incoming = AppSettings(fontSize: 17, aiBaseUrl: 'https://legacy.ai');
    await applier.applyEvents([
      _plainEvent(
        collection: SyncCollections.appSettings,
        itemId: 'settings',
        payload: incoming.toJson(),
      ),
    ]);

    final restored = settingsBox.get('settings')!;
    expect(restored.fontSize, 17);
    expect(restored.aiApiKey, 'sk-local-ai');
    expect(restored.embeddingApiKey, 'sk-local-embedding');
  });

  test(
    'skips legacy encrypted events that have no plaintext payload',
    () async {
      final result = await applier.applyEvents([
        {
          'protocolVersion': 2,
          'collection': SyncCollections.articles,
          'itemId': 'legacy-encrypted',
          'op': SyncOperation.upsert.name,
          'legacyEncryptedPayload': 'opaque-old-data',
        },
      ]);

      expect(result.applied, 0);
      expect(result.skippedUnsupported, 1);
    },
  );

  test('skips remote events when the same item has local changes', () async {
    final articleBox = await Hive.openBox<Article>(
      HiveArticleRepository.boxName,
    );
    await articleBox.put(
      'article-2',
      Article(
        id: 'article-2',
        url: 'https://example.com/local',
        title: 'Local title',
        source: SourcePlatform.web,
      ),
    );
    await outbox.enqueue(
      SyncOutboxRecord.create(
        collection: SyncCollections.articles,
        itemId: 'article-2',
        operation: SyncOperation.upsert,
        payload: {'id': 'article-2'},
      ),
    );

    final remote = Article(
      id: 'article-2',
      url: 'https://example.com/remote',
      title: 'Remote title',
      source: SourcePlatform.web,
    );
    final result = await applier.applyEvents([
      _plainEvent(
        collection: SyncCollections.articles,
        itemId: remote.id,
        payload: remote.toJson(),
      ),
    ]);

    expect(result.applied, 0);
    expect(result.skippedConflicts, 1);
    expect(articleBox.get('article-2')?.title, 'Local title');
  });
}

Map<String, dynamic> _plainEvent({
  required String collection,
  required String itemId,
  required Map<String, dynamic> payload,
  String? accountId,
}) {
  return {
    'collection': collection,
    'itemId': itemId,
    'op': SyncOperation.upsert.name,
    'revision': 123,
    'protocolVersion': SyncProtocol.protocolVersion,
    'payloadFormat': SyncProtocol.payloadFormat,
    'payload': accountId == null
        ? payload
        : SyncProtocol.wrapPayload(
            accountId: accountId,
            collection: collection,
            itemId: itemId,
            data: payload,
          ),
  };
}
