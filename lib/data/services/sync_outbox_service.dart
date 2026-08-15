import 'dart:async';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

import 'sync_payload_policy.dart';

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
    final sanitizedPayload = SyncPayloadPolicy.sanitize(collection, payload);
    final sanitizedBasePayload = SyncPayloadPolicy.sanitize(
      collection,
      basePayload,
    );
    return SyncOutboxRecord(
      id: const Uuid().v4(),
      accountId: accountId,
      collection: collection,
      itemId: itemId,
      operation: operation,
      payload: sanitizedPayload,
      revision: now.microsecondsSinceEpoch,
      clientUpdatedAt: now.toIso8601String(),
      baseEntityRevision: baseEntityRevision,
      basePayload: sanitizedBasePayload,
      changedPaths: SyncPayloadPolicy.sanitizeChangedPaths(
        collection,
        changedPaths,
      ),
    );
  }

  factory SyncOutboxRecord.fromJson(Map<String, dynamic> json) {
    final collection = json['collection'] as String;
    final payload = json['payload'] is Map
        ? Map<String, dynamic>.from(json['payload'] as Map)
        : null;
    final basePayload = json['basePayload'] is Map
        ? Map<String, dynamic>.from(json['basePayload'] as Map)
        : null;
    return SyncOutboxRecord(
      id: json['id'] as String,
      accountId: json['accountId'] as String?,
      collection: collection,
      itemId: json['itemId'] as String,
      operation: (json['operation'] as String) == 'delete'
          ? SyncOperation.delete
          : SyncOperation.upsert,
      payload: SyncPayloadPolicy.sanitize(collection, payload),
      revision: (json['revision'] as num).toInt(),
      clientUpdatedAt: json['clientUpdatedAt'] as String,
      baseEntityRevision: (json['baseEntityRevision'] as num?)?.toInt() ?? 0,
      basePayload: SyncPayloadPolicy.sanitize(collection, basePayload),
      changedPaths: SyncPayloadPolicy.sanitizeChangedPaths(
        collection,
        (json['changedPaths'] as List?)?.whereType<String>() ?? const [],
      ),
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
      'payload': SyncPayloadPolicy.sanitize(collection, payload),
      'revision': revision,
      'clientUpdatedAt': clientUpdatedAt,
      'baseEntityRevision': baseEntityRevision,
      'basePayload': SyncPayloadPolicy.sanitize(collection, basePayload),
      'changedPaths': SyncPayloadPolicy.sanitizeChangedPaths(
        collection,
        changedPaths,
      ),
      'status': status.name,
      'conflictId': conflictId,
      'attempts': attempts,
      'lastError': lastError,
    };
  }

  SyncOutboxRecord markFailed(Object _) {
    return copyWith(
      status: SyncOutboxStatus.failed,
      // The transient exception is still returned to the caller. Persisting
      // arbitrary server text here could copy a legacy echoed credential into
      // Hive, so the durable record keeps only a non-sensitive summary.
      lastError: 'Sync attempt failed.',
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
      payload: SyncPayloadPolicy.sanitize(
        incoming.collection,
        incoming.payload,
      ),
      revision: incoming.revision,
      clientUpdatedAt: incoming.clientUpdatedAt,
      baseEntityRevision: baseEntityRevision,
      basePayload: SyncPayloadPolicy.sanitize(
        incoming.collection,
        basePayload ?? incoming.basePayload,
      ),
      changedPaths: SyncPayloadPolicy.sanitizeChangedPaths(
        incoming.collection,
        {...changedPaths, ...incoming.changedPaths},
      ),
      status: SyncOutboxStatus.pending,
      conflictId: null,
      attempts: attempts,
      lastError: null,
    );
  }

  SyncOutboxRecord reissueSanitized({required String replacementId}) {
    final now = DateTime.now().toUtc();
    return SyncOutboxRecord(
      id: replacementId,
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
  Future<void> _mutationTail = Future<void>.value();

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

  Future<void> enqueue(SyncOutboxRecord record) {
    return _serialize<void>(() => _enqueueUnlocked(record));
  }

  Future<void> _enqueueUnlocked(SyncOutboxRecord record) async {
    final box = await _openBox();
    if (box == null) {
      final mergeable = _memoryRecords.entries
          .where((entry) => _isMergeable(entry.value, record))
          .toList(growable: false);
      final merged = mergeable.isEmpty
          ? record
          : SyncOutboxRecord.fromJson(
              Map<String, dynamic>.from(mergeable.first.value),
            ).withLatestPayload(record);
      for (final entry in mergeable) {
        _memoryRecords.remove(entry.key);
      }
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
    final merged = mergeable.isEmpty
        ? record
        : SyncOutboxRecord.fromJson(
            Map<String, dynamic>.from(mergeable.first.value as Map),
          ).withLatestPayload(record);
    // Commit the merged/new value before pruning superseded keys. A process
    // death can temporarily leave a duplicate, but can no longer erase the
    // only durable mutation.
    await box.put(merged.id, merged.toJson());
    for (final entry in mergeable) {
      if (entry.key != merged.id) await box.delete(entry.key);
    }
    _notify();
  }

  Future<List<SyncOutboxRecord>> pending({
    required String accountId,
    int limit = 50,
  }) {
    return _serialize<List<SyncOutboxRecord>>(() async {
      final records =
          (await _normalizedRecordsUnlocked())
              .where((record) => _belongsTo(record, accountId))
              .where((record) => record.status != SyncOutboxStatus.conflict)
              .toList()
            ..sort((a, b) => a.clientUpdatedAt.compareTo(b.clientUpdatedAt));
      return records.take(limit).toList(growable: false);
    });
  }

  /// Atomically selects and marks the exact records that may be sent.
  ///
  /// Once a record is claimed its `attempts` value is non-zero, so a local
  /// edit for the same entity must receive a new id instead of mutating the
  /// payload behind an in-flight idempotency key.
  Future<List<SyncOutboxRecord>> claimPending({
    required String accountId,
    int limit = 50,
  }) {
    return _serialize<List<SyncOutboxRecord>>(() async {
      final records =
          (await _normalizedRecordsUnlocked())
              .where((record) => _belongsTo(record, accountId))
              .where((record) => record.status != SyncOutboxStatus.conflict)
              .toList()
            ..sort((a, b) => a.clientUpdatedAt.compareTo(b.clientUpdatedAt));
      final selected = records.take(limit).toList(growable: false);
      if (selected.isEmpty) return const [];

      final box = await _openBox();
      final claimed = <SyncOutboxRecord>[];
      for (final candidate in selected) {
        final raw = box == null
            ? _memoryRecords[candidate.id]
            : box.get(candidate.id);
        if (raw is! Map) continue;
        try {
          final current = SyncOutboxRecord.fromJson(
            Map<String, dynamic>.from(raw),
          );
          if (current.status == SyncOutboxStatus.conflict) continue;
          final updated = current.markAttempted();
          if (box == null) {
            _memoryRecords[updated.id] = updated.toJson();
          } else {
            await box.put(updated.id, updated.toJson());
          }
          claimed.add(updated);
        } catch (_) {
          // A malformed entry is left untouched and cannot enter the wire.
        }
      }
      if (claimed.isNotEmpty) _notify();
      return List.unmodifiable(claimed);
    });
  }

  Future<bool> hasPendingChange({
    required String accountId,
    required String collection,
    required String itemId,
  }) {
    return _serialize<bool>(() async {
      return (await _normalizedRecordsUnlocked()).any(
        (record) =>
            _belongsTo(record, accountId) &&
            record.collection == collection &&
            record.itemId == itemId &&
            record.status != SyncOutboxStatus.conflict,
      );
    });
  }

  Future<List<SyncOutboxRecord>> forEntity({
    required String accountId,
    required String collection,
    required String itemId,
  }) {
    return _serialize<List<SyncOutboxRecord>>(() async {
      return (await _normalizedRecordsUnlocked())
          .where(
            (record) =>
                _belongsTo(record, accountId) &&
                record.collection == collection &&
                record.itemId == itemId,
          )
          .toList()
        ..sort((a, b) => a.clientUpdatedAt.compareTo(b.clientUpdatedAt));
    });
  }

  Future<List<SyncOutboxRecord>> _normalizedRecordsUnlocked() async {
    final box = await _openBox();
    final entries = box == null
        ? Map<dynamic, dynamic>.from(_memoryRecords).entries.toList()
        : box.toMap().entries.toList();
    final records = <String, SyncOutboxRecord>{};

    for (final entry in entries) {
      final raw = entry.value;
      if (raw is! Map) continue;
      try {
        final json = Map<String, dynamic>.from(raw);
        final collection = json['collection'] as String;
        final rawPayload = json['payload'] is Map
            ? Map<String, dynamic>.from(json['payload'] as Map)
            : null;
        final rawBasePayload = json['basePayload'] is Map
            ? Map<String, dynamic>.from(json['basePayload'] as Map)
            : null;
        final payloadHadSecrets = SyncPayloadPolicy.containsSecrets(
          collection,
          rawPayload,
        );
        final storedSecrets =
            payloadHadSecrets ||
            SyncPayloadPolicy.containsSecrets(collection, rawBasePayload);
        var record = SyncOutboxRecord.fromJson(json);

        // Changing a payload under an already-attempted clientEventId can
        // violate the server's idempotency check when the previous response
        // was lost. Reissue only records whose wire payload was changed by the
        // migration; basePayload is local merge metadata and is never sent.
        if (payloadHadSecrets &&
            record.attempts > 0 &&
            record.status != SyncOutboxStatus.conflict) {
          var replacementId = json['sanitizedReplacementId'] is String
              ? (json['sanitizedReplacementId'] as String).trim()
              : '';
          if (replacementId.isEmpty || replacementId == record.id) {
            replacementId = const Uuid().v4();
            json['sanitizedReplacementId'] = replacementId;
            // Persist the migration intent first. A crash can now retry the
            // same replacement id instead of losing or duplicating the event.
            if (box == null) {
              _memoryRecords[entry.key.toString()] = json;
            } else {
              await box.put(entry.key, json);
            }
          }

          final replacementRaw = box == null
              ? _memoryRecords[replacementId]
              : box.get(replacementId);
          if (replacementRaw is Map) {
            record = SyncOutboxRecord.fromJson(
              Map<String, dynamic>.from(replacementRaw),
            );
          } else {
            record = record.reissueSanitized(replacementId: replacementId);
            if (box == null) {
              _memoryRecords[record.id] = record.toJson();
            } else {
              await box.put(record.id, record.toJson());
            }
          }
          if (box == null) {
            _memoryRecords.remove(entry.key);
          } else if (entry.key != record.id) {
            await box.delete(entry.key);
          }
          records[record.id] = record;
          continue;
        }

        if (storedSecrets) {
          if (box == null) {
            _memoryRecords[record.id] = record.toJson();
            if (entry.key != record.id) _memoryRecords.remove(entry.key);
          } else {
            await box.put(record.id, record.toJson());
            if (entry.key != record.id) await box.delete(entry.key);
          }
        }
        records[record.id] = record;
      } catch (_) {
        // Ignore malformed historical entries; they must not block sync.
      }
    }
    return records.values.toList(growable: false);
  }

  Future<void> markConflict(SyncOutboxRecord record, String conflictId) {
    return _serialize<void>(() async {
      final box = await _openBox();
      final raw = box == null ? _memoryRecords[record.id] : box.get(record.id);
      if (raw is! Map) return;
      final current = SyncOutboxRecord.fromJson(Map<String, dynamic>.from(raw));
      if (!_isSameClaim(current, record) ||
          current.status == SyncOutboxStatus.conflict) {
        return;
      }
      final updated = current.markConflict(conflictId).toJson();
      if (box == null) {
        _memoryRecords[record.id] = updated;
      } else {
        await box.put(record.id, updated);
      }
      _notify();
    });
  }

  Future<void> removeAll(Iterable<String> ids) {
    return _serialize<void>(() async {
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
    });
  }

  Future<void> markFailed(Iterable<SyncOutboxRecord> records, Object error) {
    return _serialize<void>(() async {
      final box = await _openBox();
      for (final record in records) {
        final raw = box == null
            ? _memoryRecords[record.id]
            : box.get(record.id);
        if (raw is! Map) continue;
        final current = SyncOutboxRecord.fromJson(
          Map<String, dynamic>.from(raw),
        );
        if (!_isSameClaim(current, record) ||
            current.status == SyncOutboxStatus.conflict) {
          continue;
        }
        final updated = current.markFailed(error).toJson();
        if (box == null) {
          _memoryRecords[record.id] = updated;
        } else {
          await box.put(record.id, updated);
        }
      }
      _notify();
    });
  }

  Future<int> count({String? accountId}) {
    return _serialize<int>(() async {
      final records = await _normalizedRecordsUnlocked();
      if (accountId == null) return records.length;
      return records.where((record) => _belongsTo(record, accountId)).length;
    });
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

  bool _isSameClaim(SyncOutboxRecord current, SyncOutboxRecord claimed) {
    return current.id == claimed.id &&
        current.revision == claimed.revision &&
        current.clientUpdatedAt == claimed.clientUpdatedAt &&
        current.attempts == claimed.attempts;
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _mutationTail.then<T>((_) => operation());
    _mutationTail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }
}
