import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/settings.dart';
import 'package:memora/data/models/source_platform.dart';
import 'package:memora/data/repositories/passage_repository.dart';
import 'package:memora/data/services/sync_apply_service.dart';
import 'package:memora/data/services/sync_crypto_service.dart';
import 'package:memora/data/services/sync_outbox_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late SyncCryptoService crypto;
  late SyncOutboxService outbox;
  late SyncApplyService applier;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('memora_sync_apply_test_');
    Hive.init(tempDir.path);
    crypto = SyncCryptoService();
    outbox = SyncOutboxService();
    applier = SyncApplyService(crypto: crypto, outbox: outbox);
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('applies encrypted article upsert and delete events', () async {
    final article = Article(
      id: 'article-1',
      url: 'https://example.com/a',
      title: 'Remote article',
      source: SourcePlatform.web,
      tags: const ['sync'],
    );

    final upsertEvent = await _encryptedEvent(
      crypto,
      collection: SyncCollections.articles,
      itemId: article.id,
      payload: article.toJson(),
    );

    final upsertResult = await applier.applyEvents([upsertEvent]);
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

  test('preserves local API keys when applying synced settings', () async {
    final settingsBox = await Hive.openBox<AppSettings>('app_settings');
    await settingsBox.put(
      'settings',
      AppSettings(
        aiApiKey: 'sk-local-ai',
        embeddingApiKey: 'sk-local-embedding',
      ),
    );

    final incoming = AppSettings(fontSize: 18, aiBaseUrl: 'https://ai.example');
    final event = await _encryptedEvent(
      crypto,
      collection: SyncCollections.appSettings,
      itemId: 'settings',
      payload: incoming.toJson(),
    );

    final result = await applier.applyEvents([event]);
    expect(result.applied, 1);

    final restored = settingsBox.get('settings')!;
    expect(restored.fontSize, 18);
    expect(restored.aiBaseUrl, 'https://ai.example');
    expect(restored.aiApiKey, 'sk-local-ai');
    expect(restored.embeddingApiKey, 'sk-local-embedding');
  });

  test(
    'skips remote events when the same item has local pending changes',
    () async {
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
      final event = await _encryptedEvent(
        crypto,
        collection: SyncCollections.articles,
        itemId: remote.id,
        payload: remote.toJson(),
      );

      final result = await applier.applyEvents([event]);
      expect(result.applied, 0);
      expect(result.skippedConflicts, 1);
      expect(articleBox.get('article-2')?.title, 'Local title');
    },
  );
}

Future<Map<String, dynamic>> _encryptedEvent(
  SyncCryptoService crypto, {
  required String collection,
  required String itemId,
  required Map<String, dynamic> payload,
}) async {
  const revision = 123;
  final encrypted = await crypto.encryptJson(
    payload,
    collection: collection,
    itemId: itemId,
    revision: revision,
  );
  return {
    'collection': collection,
    'itemId': itemId,
    'op': SyncOperation.upsert.name,
    'revision': revision,
    'ciphertext': encrypted.ciphertext,
    'nonce': encrypted.nonce,
    'aad': encrypted.aad,
    'contentHash': encrypted.contentHash,
  };
}
