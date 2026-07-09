import 'package:hive_flutter/hive_flutter.dart';

import '../models/filter_group.dart';
import '../models/folder.dart';
import '../models/passage.dart';
import '../models/settings.dart';
import '../repositories/passage_repository.dart';
import 'index_service.dart';
import 'sync_crypto_service.dart';
import 'sync_outbox_service.dart';

class SyncApplyResult {
  final int applied;
  final int skippedSelf;
  final int skippedConflicts;
  final int skippedUnsupported;

  const SyncApplyResult({
    required this.applied,
    required this.skippedSelf,
    required this.skippedConflicts,
    required this.skippedUnsupported,
  });
}

class SyncApplyService {
  static const String _foldersBoxName = 'folders';
  static const String _filterGroupsBoxName = 'filter_groups';
  static const String _settingsBoxName = 'app_settings';
  static const String _settingsKey = 'settings';
  static const String _vectorIndexBoxName = 'vector_index';

  final SyncCryptoService crypto;
  final SyncOutboxService outbox;

  const SyncApplyService({required this.crypto, required this.outbox});

  Future<SyncApplyResult> applyEvents(
    Iterable<dynamic> rawEvents, {
    String? localDeviceId,
  }) async {
    await _ensureHive();

    var applied = 0;
    var skippedSelf = 0;
    var skippedConflicts = 0;
    var skippedUnsupported = 0;

    for (final raw in rawEvents) {
      if (raw is! Map) {
        skippedUnsupported++;
        continue;
      }
      final event = Map<String, dynamic>.from(raw);
      final collection = _stringValue(event, ['collection']);
      final itemId = _stringValue(event, ['itemId', 'item_id']);
      final op = _stringValue(event, ['op', 'operation']) ?? 'upsert';
      if (collection == null || itemId == null) {
        skippedUnsupported++;
        continue;
      }

      if (!_isSupportedCollection(collection)) {
        skippedUnsupported++;
        continue;
      }

      final deviceId = _stringValue(event, [
        'deviceId',
        'device_id',
        'originDeviceId',
        'origin_device_id',
      ]);
      if (localDeviceId != null && deviceId == localDeviceId) {
        skippedSelf++;
        continue;
      }

      final hasLocalPending = await outbox.hasPendingChange(
        collection: collection,
        itemId: itemId,
      );
      if (hasLocalPending) {
        skippedConflicts++;
        continue;
      }

      if (op == SyncOperation.delete.name) {
        await _applyDelete(collection, itemId);
      } else {
        final payload = await _decodePayload(event);
        await _applyUpsert(collection, itemId, payload);
      }
      applied++;
    }

    return SyncApplyResult(
      applied: applied,
      skippedSelf: skippedSelf,
      skippedConflicts: skippedConflicts,
      skippedUnsupported: skippedUnsupported,
    );
  }

  Future<void> _ensureHive() async {
    try {
      await Hive.initFlutter();
    } catch (_) {
      // Hive may already be initialized by the app or a test harness.
    }
    if (!Hive.isAdapterRegistered(Article.typeId)) {
      Hive.registerAdapter(ArticleAdapter());
    }
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(SourcePlatformAdapter());
    }
    if (!Hive.isAdapterRegistered(AppSettings.typeId)) {
      Hive.registerAdapter(AppSettingsAdapter());
    }
    if (!Hive.isAdapterRegistered(FilterGroup.typeId)) {
      Hive.registerAdapter(FilterGroupAdapter());
    }
    if (!Hive.isAdapterRegistered(Folder.typeId)) {
      Hive.registerAdapter(FolderAdapter());
    }
    if (!Hive.isAdapterRegistered(IndexRecordAdapter().typeId)) {
      Hive.registerAdapter(IndexRecordAdapter());
    }
  }

  bool _isSupportedCollection(String collection) {
    return collection == SyncCollections.articles ||
        collection == SyncCollections.folders ||
        collection == SyncCollections.filterGroups ||
        collection == SyncCollections.appSettings;
  }

  Future<Map<String, dynamic>> _decodePayload(Map<String, dynamic> event) {
    final payload = event['payload'];
    if (payload is Map) {
      return Future.value(Map<String, dynamic>.from(payload));
    }

    final ciphertext = _stringValue(event, ['ciphertext']);
    final nonce = _stringValue(event, ['nonce']);
    final aad = _stringValue(event, ['aad']);
    final contentHash = _stringValue(event, ['contentHash', 'content_hash']);
    if (ciphertext == null ||
        nonce == null ||
        aad == null ||
        contentHash == null) {
      throw const SyncApplyException('Encrypted sync payload is incomplete.');
    }

    return crypto.decryptJson(
      EncryptedSyncPayload(
        ciphertext: ciphertext,
        nonce: nonce,
        aad: aad,
        contentHash: contentHash,
      ),
    );
  }

  Future<void> _applyUpsert(
    String collection,
    String itemId,
    Map<String, dynamic> payload,
  ) async {
    switch (collection) {
      case SyncCollections.articles:
        final article = Article.fromJson(payload);
        if (article.id != itemId) {
          throw const SyncApplyException('Article sync item id mismatch.');
        }
        final box = await Hive.openBox<Article>(HiveArticleRepository.boxName);
        await box.put(article.id, article);
        return;
      case SyncCollections.folders:
        final folder = Folder.fromJson(payload);
        if (folder.id != itemId) {
          throw const SyncApplyException('Folder sync item id mismatch.');
        }
        final box = await Hive.openBox<Folder>(_foldersBoxName);
        await box.put(folder.id, folder);
        return;
      case SyncCollections.filterGroups:
        final group = FilterGroup.fromJson(payload);
        if (group.id != itemId) {
          throw const SyncApplyException('Filter group sync item id mismatch.');
        }
        final box = await Hive.openBox<FilterGroup>(_filterGroupsBoxName);
        await box.put(group.id, group);
        return;
      case SyncCollections.appSettings:
        final incoming = AppSettings.fromJson(payload);
        final box = await Hive.openBox<AppSettings>(_settingsBoxName);
        final current = box.get(_settingsKey);
        final merged = incoming.copyWith(
          aiApiKey: current?.aiApiKey ?? '',
          embeddingApiKey: current?.embeddingApiKey ?? '',
        );
        await box.put(_settingsKey, merged);
        return;
      default:
        throw SyncApplyException('Unsupported sync collection: $collection.');
    }
  }

  Future<void> _applyDelete(String collection, String itemId) async {
    switch (collection) {
      case SyncCollections.articles:
        final articles = await Hive.openBox<Article>(
          HiveArticleRepository.boxName,
        );
        await articles.delete(itemId);
        final index = await Hive.openBox<IndexRecord>(_vectorIndexBoxName);
        await index.delete(itemId);
        return;
      case SyncCollections.folders:
        final box = await Hive.openBox<Folder>(_foldersBoxName);
        await box.delete(itemId);
        return;
      case SyncCollections.filterGroups:
        final box = await Hive.openBox<FilterGroup>(_filterGroupsBoxName);
        await box.delete(itemId);
        return;
      case SyncCollections.appSettings:
        final box = await Hive.openBox<AppSettings>(_settingsBoxName);
        await box.delete(_settingsKey);
        return;
      default:
        throw SyncApplyException('Unsupported sync collection: $collection.');
    }
  }

  String? _stringValue(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is String && value.isNotEmpty) return value;
    }
    return null;
  }
}

class SyncApplyException implements Exception {
  final String message;

  const SyncApplyException(this.message);

  @override
  String toString() => message;
}
