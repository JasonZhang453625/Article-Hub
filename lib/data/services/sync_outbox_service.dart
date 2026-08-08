import 'dart:async';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

enum SyncOperation { upsert, delete }

enum SyncOutboxStatus { pending, failed, conflict }

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
  final String? accountId;
  final String collection;
  final String itemId;
  final SyncOperation operation;
  final Map<String, dynamic>? payload;
  final int revision;
  final String clientUpdatedAt;
  final int baseEntityRevision;
  final Map<String, dynamic>? basePayload;
  final List<String> changedPaths;
  final SyncOutboxStatus status;
  final String? conflictId;
  final int attempts;
  final String? lastError;

  const SyncOutboxRecord({
    required this.id,
    required this.accountId,
    required this.collection,
    required this.itemId,
    required this.operation,
    required this.payload,
    required this.revision,
    required this.clientUpdatedAt,
    this.baseEntityRevision = 0,
    this.basePayload,
    this.changedPaths = const [],
    this.status = SyncOutboxStatus.pending,
    this.conflictId,
    this.attempts = 0,
    this.lastError,
  });

  factory SyncOutboxRecord.create({
    String? accountId,
    required String collection,
    required String itemId,
    required SyncOperation operation,
    Map<String, dynamic>? payload,
    int baseEntityRevision = 0,
    Map<String, dynamic>? basePayload,
    List<String> changedPaths = const [],
  }) {
    final now = DateTime.now().toUtc();
    return SyncOutboxRecord(
      id: const Uuid().v4(),
      accountId: accountId,
      collection: collection,
      itemId: itemId,
      operation: operation,
      payload: payload,
      revision: now.microsecondsSinceEpoch,
      clientUpdatedAt: now.toIso8601String(),
      baseEntityRevision: baseEntityRevision,
      basePayload: basePayload,
      changedPaths: changedPaths,
    );
  }

  factory SyncOutboxRecord.fromJson(Map<String, dynamic> json) {
    return SyncOutboxRecord(
      id: json['id'] as String,
      accountId: json['accountId'] as String?,
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
      baseEntityRevision: (json['baseEntityRevision'] as num?)?.toInt() ?? 0,
      basePayload: json['basePayload'] is Map
          ? Map<String, dynamic>.from(json['basePayload'] as Map)
          : null,
      changedPaths:
          (json['changedPaths'] as List?)?.whereType<String>().toList() ??
          const [],
      status: SyncOutboxStatus.values.firstWhere(
        (value) => value.name == json['status'],
        orElse: () => SyncOutboxStatus.pending,
      ),
      conflictId: json['conflictId'] as String?,
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      lastError: json['lastError'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'accountId': accountId,
      'collection': collection,
      'itemId': itemId,
      'operation': operation.name,
      'payload': payload,
      'revision': revision,
      'clientUpdatedAt': clientUpdatedAt,
      'baseEntityRevision': baseEntityRevision,
      'basePayload': basePayload,
      'changedPaths': changedPaths,
      'status': status.name,
      'conflictId': conflictId,
      'attempts': attempts,
      'lastError': lastError,
    };
  }

  SyncOutboxRecord markFailed(Object error) {
    return copyWith(
      attempts: attempts + 1,
      status: SyncOutboxStatus.failed,
      lastError: error.toString(),
    );
  }

  SyncOutboxRecord markAttempted() {
    return copyWith(
      attempts: attempts + 1,
      status: SyncOutboxStatus.pending,
      clearLastError: true,
    );
  }

  SyncOutboxRecord markConflict(String id) {
    return copyWith(status: SyncOutboxStatus.conflict, conflictId: id);
  }

  SyncOutboxRecord withLatestPayload(SyncOutboxRecord incoming) {
    return SyncOutboxRecord(
      id: id,
      accountId: incoming.accountId ?? accountId,
      collection: incoming.collection,
      itemId: incoming.itemId,
      operation: incoming.operation,
      payload: incoming.payload,
      revision: incoming.revision,
      clientUpdatedAt: incoming.clientUpdatedAt,
      baseEntityRevision: baseEntityRevision,
      basePayload: basePayload ?? incoming.basePayload,
      changedPaths: {...changedPaths, ...incoming.changedPaths}.toList(),
      status: SyncOutboxStatus.pending,
      conflictId: null,
      attempts: attempts,
      lastError: null,
    );
  }

  SyncOutboxRecord copyWith({
    int? attempts,
    SyncOutboxStatus? status,
    String? conflictId,
    String? lastError,
    bool clearLastError = false,
  }) {
    return SyncOutboxRecord(
      id: id,
      accountId: accountId,
      collection: collection,
      itemId: itemId,
      operation: operation,
      payload: payload,
      revision: revision,
      clientUpdatedAt: clientUpdatedAt,
      baseEntityRevision: baseEntityRevision,
      basePayload: basePayload,
      changedPaths: changedPaths,
      status: status ?? this.status,
      conflictId: conflictId ?? this.conflictId,
      attempts: attempts ?? this.attempts,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
    );
  }
}

class SyncOutboxService {
  static const String _boxName = 'sync_outbox';

  Box<dynamic>? _box;
  final Map<String, Map<String, dynamic>> _memoryRecords = {};
  final StreamController<void> _changes = StreamController<void>.broadcast();
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
      final mergeable = _memoryRecords.entries
          .where((entry) => _isMergeable(entry.value, record))
          .toList(growable: false);
      for (final entry in mergeable) {
        _memoryRecords.remove(entry.key);
      }
      final merged = mergeable.isEmpty
          ? record
          : SyncOutboxRecord.fromJson(
              Map<String, dynamic>.from(mergeable.first.value),
            ).withLatestPayload(record);
      _memoryRecords[merged.id] = merged.toJson();
      _notify();
      return;
    }
    final mergeable = box
        .toMap()
        .entries
        .where(
          (entry) =>
              entry.value is Map &&
              _isMergeable(entry.value as Map<dynamic, dynamic>, record),
        )
        .toList(growable: false);
    for (final entry in mergeable) {
      await box.delete(entry.key);
    }
    final merged = mergeable.isEmpty
        ? record
        : SyncOutboxRecord.fromJson(
            Map<String, dynamic>.from(mergeable.first.value as Map),
          ).withLatestPayload(record);
    await box.put(merged.id, merged.toJson());
    _notify();
  }

  Future<List<SyncOutboxRecord>> pending({
    required String accountId,
    int limit = 50,
  }) async {
    final box = await _openBox();
    if (box == null) {
      final records =
          _memoryRecords.values
              .map((raw) => SyncOutboxRecord.fromJson(raw))
              .where((record) => _belongsTo(record, accountId))
              .where((record) => record.status != SyncOutboxStatus.conflict)
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
            .where((record) => _belongsTo(record, accountId))
            .where((record) => record.status != SyncOutboxStatus.conflict)
            .toList()
          ..sort((a, b) => a.clientUpdatedAt.compareTo(b.clientUpdatedAt));
    return records.take(limit).toList(growable: false);
  }

  Future<bool> hasPendingChange({
    required String accountId,
    required String collection,
    required String itemId,
  }) async {
    bool matches(Map<dynamic, dynamic> raw) {
      final recordAccountId = raw['accountId'] as String?;
      return (recordAccountId == null || recordAccountId == accountId) &&
          raw['collection'] == collection &&
          raw['itemId'] == itemId &&
          raw['status'] != SyncOutboxStatus.conflict.name;
    }

    final box = await _openBox();
    if (box == null) {
      return _memoryRecords.values.any(matches);
    }
    return box.values.whereType<Map>().any(matches);
  }

  Future<List<SyncOutboxRecord>> forEntity({
    required String accountId,
    required String collection,
    required String itemId,
  }) async {
    final box = await _openBox();
    final rawRecords = box == null
        ? _memoryRecords.values
        : box.values.whereType<Map>();
    return rawRecords
        .map((raw) => SyncOutboxRecord.fromJson(Map<String, dynamic>.from(raw)))
        .where(
          (record) =>
              _belongsTo(record, accountId) &&
              record.collection == collection &&
              record.itemId == itemId,
        )
        .toList()
      ..sort((a, b) => a.clientUpdatedAt.compareTo(b.clientUpdatedAt));
  }

  Future<void> markAttempted(Iterable<SyncOutboxRecord> records) async {
    final box = await _openBox();
    for (final record in records) {
      final updated = record.markAttempted().toJson();
      if (box == null) {
        _memoryRecords[record.id] = updated;
      } else {
        await box.put(record.id, updated);
      }
    }
    _notify();
  }

  Future<void> markConflict(SyncOutboxRecord record, String conflictId) async {
    final box = await _openBox();
    final updated = record.markConflict(conflictId).toJson();
    if (box == null) {
      _memoryRecords[record.id] = updated;
    } else {
      await box.put(record.id, updated);
    }
    _notify();
  }

  Future<void> removeAll(Iterable<String> ids) async {
    final box = await _openBox();
    if (box == null) {
      for (final id in ids) {
        _memoryRecords.remove(id);
      }
      _notify();
      return;
    }
    await box.deleteAll(ids);
    _notify();
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
      _notify();
      return;
    }
    for (final record in records) {
      await box.put(record.id, record.markFailed(error).toJson());
    }
    _notify();
  }

  Future<int> count({String? accountId}) async {
    final box = await _openBox();
    final records = box == null
        ? _memoryRecords.values
        : box.values.whereType<Map>();
    if (accountId == null) return records.length;
    return records.where((raw) {
      final recordAccountId = raw['accountId'] as String?;
      return recordAccountId == null || recordAccountId == accountId;
    }).length;
  }

  Stream<int> watchCount({required String accountId}) async* {
    yield await count(accountId: accountId);
    await for (final _ in _changes.stream) {
      yield await count(accountId: accountId);
    }
  }

  bool _belongsTo(SyncOutboxRecord record, String accountId) {
    return record.accountId == null || record.accountId == accountId;
  }

  bool _isMergeable(Map<dynamic, dynamic> raw, SyncOutboxRecord incoming) {
    final existingAccountId = raw['accountId'] as String?;
    final sameAccount =
        existingAccountId == incoming.accountId ||
        existingAccountId == null ||
        incoming.accountId == null;
    return sameAccount &&
        raw['collection'] == incoming.collection &&
        raw['itemId'] == incoming.itemId &&
        raw['status'] != SyncOutboxStatus.conflict.name &&
        ((raw['attempts'] as num?)?.toInt() ?? 0) == 0;
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }
}
