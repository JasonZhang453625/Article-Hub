import 'package:hive_flutter/hive_flutter.dart';

import '../models/filter_group.dart';
import '../models/folder.dart';
import '../models/passage.dart';
import '../models/settings.dart';
import '../repositories/passage_repository.dart';
import 'index_service.dart';
import 'sync_conflict_service.dart';
import 'sync_outbox_service.dart';
import 'sync_payload_policy.dart';
import 'sync_protocol.dart';
import 'sync_shadow_service.dart';

class SyncApplyResult {
  final int applied;
  final int skippedSelf;
  final int skippedConflicts;
  final int conflicts;
  final int skippedUnsupported;

  const SyncApplyResult({
    required this.applied,
    required this.skippedSelf,
    required this.skippedConflicts,
    this.conflicts = 0,
    required this.skippedUnsupported,
  });
}

class SyncApplyService {
  static const String _foldersBoxName = 'folders';
  static const String _filterGroupsBoxName = 'filter_groups';
  static const String _settingsBoxName = 'app_settings';
  static const String _settingsKey = 'settings';
  static const String _vectorIndexBoxName = 'vector_index';

  final SyncOutboxService outbox;
  final SyncShadowService shadow;
  final SyncConflictService conflictService;

  SyncApplyService({
    required this.outbox,
    SyncShadowService? shadow,
    SyncConflictService? conflicts,
  }) : shadow = shadow ?? SyncShadowService(),
       conflictService = conflicts ?? SyncConflictService();

  Future<SyncApplyResult> applyEvents(
    Iterable<dynamic> rawEvents, {
    String? localDeviceId,
    String? accountId,
  }) async {
    await _ensureHive();

    var applied = 0;
    var skippedSelf = 0;
    var skippedConflicts = 0;
    var conflicts = 0;
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
      final entityRevision = _entityRevision(event);
      final hasExplicitEntityRevision =
          event.containsKey('entityRevision') ||
          event.containsKey('serverRevision');
      final payload = op == SyncOperation.delete.name
          ? null
          : await _decodePayload(
              event,
              accountId: accountId,
              collection: collection,
              itemId: itemId,
            );
      if (op != SyncOperation.delete.name && payload == null) {
        skippedUnsupported++;
        continue;
      }

      if (localDeviceId != null && deviceId == localDeviceId) {
        await _storeShadowIfNewer(
          accountId: accountId,
          collection: collection,
          itemId: itemId,
          entityRevision: entityRevision,
          serverSeq: _intValue(event['serverSeq']),
          payload: payload,
          deleted: op == SyncOperation.delete.name,
          deviceId: deviceId,
        );
        skippedSelf++;
        continue;
      }

      final localRecords = await outbox.forEntity(
        accountId: accountId ?? '',
        collection: collection,
        itemId: itemId,
      );
      final uploadableRecords = localRecords
          .where((record) => record.status != SyncOutboxStatus.conflict)
          .toList(growable: false);
      final localMutation = uploadableRecords.isEmpty
          ? null
          : uploadableRecords.last;

      if (localMutation != null) {
        final isNewProtocolConflict =
            accountId != null &&
            hasExplicitEntityRevision &&
            entityRevision > localMutation.baseEntityRevision;
        if (isNewProtocolConflict) {
          final resolved = await _handleIncomingConflict(
            accountId: accountId,
            collection: collection,
            itemId: itemId,
            entityRevision: entityRevision,
            serverSeq: _intValue(event['serverSeq']),
            deviceId: deviceId,
            payload: payload,
            deleted: op == SyncOperation.delete.name,
            localMutation: localMutation,
          );
          if (resolved) {
            applied++;
          } else {
            skippedConflicts++;
            conflicts++;
          }
          continue;
        }

        // A new device may receive history that is already included in its
        // local mutation's base revision. It is safe to advance the shadow,
        // but never overwrite the user's newer local value.
        if (accountId == null || !hasExplicitEntityRevision) {
          skippedConflicts++;
        }
        await _storeShadowIfNewer(
          accountId: accountId,
          collection: collection,
          itemId: itemId,
          entityRevision: entityRevision,
          serverSeq: _intValue(event['serverSeq']),
          payload: payload,
          deleted: op == SyncOperation.delete.name,
          deviceId: deviceId,
        );
        continue;
      }

      if (op == SyncOperation.delete.name) {
        await _applyDelete(collection, itemId);
      } else {
        await _applyUpsert(collection, itemId, payload!);
      }
      await _storeShadowIfNewer(
        accountId: accountId,
        collection: collection,
        itemId: itemId,
        entityRevision: entityRevision,
        serverSeq: _intValue(event['serverSeq']),
        payload: payload,
        deleted: op == SyncOperation.delete.name,
        deviceId: deviceId,
      );
      applied++;
    }

    return SyncApplyResult(
      applied: applied,
      skippedSelf: skippedSelf,
      skippedConflicts: skippedConflicts,
      conflicts: conflicts,
      skippedUnsupported: skippedUnsupported,
    );
  }

  Future<bool> _handleIncomingConflict({
    required String? accountId,
    required String collection,
    required String itemId,
    required int entityRevision,
    required int serverSeq,
    required String? deviceId,
    required Map<String, dynamic>? payload,
    required bool deleted,
    required SyncOutboxRecord localMutation,
  }) async {
    if (accountId == null) return false;

    await _storeShadowIfNewer(
      accountId: accountId,
      collection: collection,
      itemId: itemId,
      entityRevision: entityRevision,
      serverSeq: serverSeq,
      payload: payload,
      deleted: deleted,
      deviceId: deviceId,
    );

    final canMerge =
        !deleted &&
        localMutation.operation == SyncOperation.upsert &&
        localMutation.payload != null &&
        payload != null;
    if (canMerge) {
      final merge = threeWayMerge(
        base: localMutation.basePayload ?? const <String, dynamic>{},
        local: localMutation.payload!,
        remote: payload,
      );
      if (!merge.hasConflicts) {
        await _applyUpsert(collection, itemId, merge.merged);
        await outbox.removeAll([localMutation.id]);
        final changedPaths = jsonChangedPaths(payload, merge.merged);
        if (changedPaths.isNotEmpty) {
          await outbox.enqueue(
            SyncOutboxRecord.create(
              accountId: accountId,
              collection: collection,
              itemId: itemId,
              operation: SyncOperation.upsert,
              payload: merge.merged,
              baseEntityRevision: entityRevision,
              basePayload: payload,
              changedPaths: changedPaths,
            ),
          );
        }
        return true;
      }

      await _recordConflict(
        accountId: accountId,
        collection: collection,
        itemId: itemId,
        entityRevision: entityRevision,
        serverSeq: serverSeq,
        deviceId: deviceId,
        remotePayload: payload,
        remoteDeleted: deleted,
        localMutation: localMutation,
        conflictPaths: merge.conflictPaths,
      );
      return false;
    }

    await _recordConflict(
      accountId: accountId,
      collection: collection,
      itemId: itemId,
      entityRevision: entityRevision,
      serverSeq: serverSeq,
      deviceId: deviceId,
      remotePayload: payload,
      remoteDeleted: deleted,
      localMutation: localMutation,
      conflictPaths: const [r'$'],
    );
    return false;
  }

  Future<void> _recordConflict({
    required String accountId,
    required String collection,
    required String itemId,
    required int entityRevision,
    required int serverSeq,
    required String? deviceId,
    required Map<String, dynamic>? remotePayload,
    required bool remoteDeleted,
    required SyncOutboxRecord localMutation,
    required List<String> conflictPaths,
  }) async {
    final conflict = SyncConflictRecord.create(
      accountId: accountId,
      collection: collection,
      itemId: itemId,
      localMutationId: localMutation.id,
      baseEntityRevision: localMutation.baseEntityRevision,
      remoteEntityRevision: entityRevision,
      remoteServerSeq: serverSeq,
      basePayload: localMutation.basePayload,
      localPayload: localMutation.payload,
      remotePayload: remotePayload,
      localDeleted: localMutation.operation == SyncOperation.delete,
      remoteDeleted: remoteDeleted,
      conflictPaths: conflictPaths,
    );
    await conflictService.record(conflict);
    await outbox.markConflict(localMutation, conflict.id);
  }

  Future<void> _storeShadowIfNewer({
    required String? accountId,
    required String collection,
    required String itemId,
    required int entityRevision,
    required int serverSeq,
    required Map<String, dynamic>? payload,
    required bool deleted,
    required String? deviceId,
  }) async {
    if (accountId == null) return;
    final current = await shadow.get(
      accountId: accountId,
      collection: collection,
      itemId: itemId,
    );
    if (current != null && entityRevision < current.entityRevision) return;
    await shadow.put(
      SyncShadow(
        accountId: accountId,
        collection: collection,
        itemId: itemId,
        entityRevision: entityRevision,
        serverSeq: serverSeq,
        payload: payload,
        deleted: deleted,
        deviceId: deviceId,
      ),
    );
  }

  int _entityRevision(Map<String, dynamic> event) {
    for (final key in const [
      'entityRevision',
      'serverRevision',
      'serverSeq',
      'revision',
    ]) {
      final value = event[key];
      if (value is num) return value.toInt();
      final parsed = int.tryParse(value?.toString() ?? '');
      if (parsed != null) return parsed;
    }
    return 0;
  }

  int _intValue(dynamic value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<void> applyResolvedPayload({
    required String collection,
    required String itemId,
    required Map<String, dynamic> payload,
  }) async {
    await _ensureHive();
    await _applyUpsert(collection, itemId, payload);
  }

  Future<void> applyResolvedDelete({
    required String collection,
    required String itemId,
  }) async {
    await _ensureHive();
    await _applyDelete(collection, itemId);
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

  Future<Map<String, dynamic>?> _decodePayload(
    Map<String, dynamic> event, {
    required String? accountId,
    required String collection,
    required String itemId,
  }) async {
    final payload = event['payload'];
    if (payload is! Map) return null;

    final decoded = Map<String, dynamic>.from(payload);
    final unwrapped = accountId == null
        ? decoded
        : SyncProtocol.unwrapPayload(
            decoded,
            accountId: accountId,
            collection: collection,
            itemId: itemId,
          );
    return SyncPayloadPolicy.sanitize(collection, unwrapped);
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
          chatAiApiKey: current?.chatAiApiKey ?? '',
          imageAiApiKey: current?.imageAiApiKey ?? '',
          embeddingApiKey: current?.embeddingApiKey ?? '',
          tavilyApiKey: current?.tavilyApiKey ?? '',
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
        // Settings are a local singleton whose provider credentials are
        // device-private. A remote/legacy tombstone must not erase them.
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
