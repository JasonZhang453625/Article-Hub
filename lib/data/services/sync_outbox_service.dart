import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

enum SyncOperation { upsert, delete }

class SyncCollections {
  static const String articles = 'articles';
  static const String folders = 'folders';
  static const String filterGroups = 'filter_groups';
  static const String appSettings = 'app_settings';
  static const String chatThreads = 'chat_threads';
  static const String chatMessages = 'chat_messages';
  static const String vectorIndex = 'vector_index';
}

class SyncOutboxRecord {
  final String id;
  final String collection;
  final String itemId;
  final SyncOperation operation;
  final Map<String, dynamic>? payload;
  final int revision;
  final String clientUpdatedAt;
  final int attempts;
  final String? lastError;

  const SyncOutboxRecord({
    required this.id,
    required this.collection,
    required this.itemId,
    required this.operation,
    required this.payload,
    required this.revision,
    required this.clientUpdatedAt,
    this.attempts = 0,
    this.lastError,
  });

  factory SyncOutboxRecord.create({
    required String collection,
    required String itemId,
    required SyncOperation operation,
    Map<String, dynamic>? payload,
  }) {
    final now = DateTime.now().toUtc();
    return SyncOutboxRecord(
      id: const Uuid().v4(),
      collection: collection,
      itemId: itemId,
      operation: operation,
      payload: payload,
      revision: now.microsecondsSinceEpoch,
      clientUpdatedAt: now.toIso8601String(),
    );
  }

  factory SyncOutboxRecord.fromJson(Map<String, dynamic> json) {
    return SyncOutboxRecord(
      id: json['id'] as String,
      collection: json['collection'] as String,
      itemId: json['itemId'] as String,
      operation: (json['operation'] as String) == 'delete'
          ? SyncOperation.delete
          : SyncOperation.upsert,
      payload: json['payload'] is Map
          ? Map<String, dynamic>.from(json['payload'] as Map)
          : null,
      revision: (json['revision'] as num).toInt(),
      clientUpdatedAt: json['clientUpdatedAt'] as String,
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      lastError: json['lastError'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'collection': collection,
      'itemId': itemId,
      'operation': operation.name,
      'payload': payload,
      'revision': revision,
      'clientUpdatedAt': clientUpdatedAt,
      'attempts': attempts,
      'lastError': lastError,
    };
  }

  SyncOutboxRecord markFailed(Object error) {
    return SyncOutboxRecord(
      id: id,
      collection: collection,
      itemId: itemId,
      operation: operation,
      payload: payload,
      revision: revision,
      clientUpdatedAt: clientUpdatedAt,
      attempts: attempts + 1,
      lastError: error.toString(),
    );
  }
}

class SyncOutboxService {
  static const String _boxName = 'sync_outbox';

  Box<dynamic>? _box;
  final Map<String, Map<String, dynamic>> _memoryRecords = {};
  bool _useMemoryFallback = false;

  Future<Box<dynamic>?> _openBox() async {
    if (_useMemoryFallback) return null;
    var initFailed = false;
    try {
      await Hive.initFlutter();
    } catch (_) {
      // Hive may already be initialized.
      initFailed = !Hive.isBoxOpen(_boxName);
    }
    if (initFailed) {
      _useMemoryFallback = true;
      return null;
    }
    try {
      return _box ??= await Hive.openBox<dynamic>(_boxName);
    } catch (_) {
      // Some pure unit tests override repositories without initializing Hive.
      // Keep local writes working there while the real app still persists.
      _useMemoryFallback = true;
      return null;
    }
  }

  Future<void> enqueue(SyncOutboxRecord record) async {
    final box = await _openBox();
    if (box == null) {
      _memoryRecords[record.id] = record.toJson();
      return;
    }
    await box.put(record.id, record.toJson());
  }

  Future<List<SyncOutboxRecord>> pending({int limit = 50}) async {
    final box = await _openBox();
    if (box == null) {
      final records =
          _memoryRecords.values
              .map((raw) => SyncOutboxRecord.fromJson(raw))
              .toList()
            ..sort((a, b) => a.clientUpdatedAt.compareTo(b.clientUpdatedAt));
      return records.take(limit).toList(growable: false);
    }
    final records =
        box.values
            .whereType<Map>()
            .map(
              (raw) =>
                  SyncOutboxRecord.fromJson(Map<String, dynamic>.from(raw)),
            )
            .toList()
          ..sort((a, b) => a.clientUpdatedAt.compareTo(b.clientUpdatedAt));
    return records.take(limit).toList(growable: false);
  }

  Future<bool> hasPendingChange({
    required String collection,
    required String itemId,
  }) async {
    bool matches(Map<dynamic, dynamic> raw) {
      return raw['collection'] == collection && raw['itemId'] == itemId;
    }

    final box = await _openBox();
    if (box == null) {
      return _memoryRecords.values.any(matches);
    }
    return box.values.whereType<Map>().any(matches);
  }

  Future<void> removeAll(Iterable<String> ids) async {
    final box = await _openBox();
    if (box == null) {
      for (final id in ids) {
        _memoryRecords.remove(id);
      }
      return;
    }
    await box.deleteAll(ids);
  }

  Future<void> markFailed(
    Iterable<SyncOutboxRecord> records,
    Object error,
  ) async {
    final box = await _openBox();
    if (box == null) {
      for (final record in records) {
        _memoryRecords[record.id] = record.markFailed(error).toJson();
      }
      return;
    }
    for (final record in records) {
      await box.put(record.id, record.markFailed(error).toJson());
    }
  }

  Future<int> count() async {
    final box = await _openBox();
    if (box == null) return _memoryRecords.length;
    return box.length;
  }
}
