import 'dart:async';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

import 'sync_payload_policy.dart';

enum SyncConflictStatus { pending, resolved }

class SyncConflictRecord {
  final String id;
  final String accountId;
  final String collection;
  final String itemId;
  final String localMutationId;
  final int baseEntityRevision;
  final int remoteEntityRevision;
  final int remoteServerSeq;
  final Map<String, dynamic>? basePayload;
  final Map<String, dynamic>? localPayload;
  final Map<String, dynamic>? remotePayload;
  final bool localDeleted;
  final bool remoteDeleted;
  final List<String> conflictPaths;
  final DateTime createdAt;
  final SyncConflictStatus status;

  const SyncConflictRecord({
    required this.id,
    required this.accountId,
    required this.collection,
    required this.itemId,
    required this.localMutationId,
    required this.baseEntityRevision,
    required this.remoteEntityRevision,
    required this.remoteServerSeq,
    required this.basePayload,
    required this.localPayload,
    required this.remotePayload,
    required this.localDeleted,
    required this.remoteDeleted,
    required this.conflictPaths,
    required this.createdAt,
    this.status = SyncConflictStatus.pending,
  });

  factory SyncConflictRecord.create({
    required String accountId,
    required String collection,
    required String itemId,
    required String localMutationId,
    required int baseEntityRevision,
    required int remoteEntityRevision,
    required int remoteServerSeq,
    required Map<String, dynamic>? basePayload,
    required Map<String, dynamic>? localPayload,
    required Map<String, dynamic>? remotePayload,
    required bool localDeleted,
    required bool remoteDeleted,
    required List<String> conflictPaths,
  }) {
    return SyncConflictRecord(
      id: const Uuid().v4(),
      accountId: accountId,
      collection: collection,
      itemId: itemId,
      localMutationId: localMutationId,
      baseEntityRevision: baseEntityRevision,
      remoteEntityRevision: remoteEntityRevision,
      remoteServerSeq: remoteServerSeq,
      basePayload: SyncPayloadPolicy.sanitize(collection, basePayload),
      localPayload: SyncPayloadPolicy.sanitize(collection, localPayload),
      remotePayload: SyncPayloadPolicy.sanitize(collection, remotePayload),
      localDeleted: localDeleted,
      remoteDeleted: remoteDeleted,
      conflictPaths: SyncPayloadPolicy.sanitizeChangedPaths(
        collection,
        conflictPaths,
      ),
      createdAt: DateTime.now().toUtc(),
    );
  }

  factory SyncConflictRecord.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic>? mapValue(dynamic value) {
      return value is Map ? Map<String, dynamic>.from(value) : null;
    }

    final collection = json['collection'] as String;
    return SyncConflictRecord(
      id: json['id'] as String,
      accountId: json['accountId'] as String,
      collection: collection,
      itemId: json['itemId'] as String,
      localMutationId: json['localMutationId'] as String,
      baseEntityRevision: _intValue(json['baseEntityRevision']),
      remoteEntityRevision: _intValue(json['remoteEntityRevision']),
      remoteServerSeq: _intValue(json['remoteServerSeq']),
      basePayload: SyncPayloadPolicy.sanitize(
        collection,
        mapValue(json['basePayload']),
      ),
      localPayload: SyncPayloadPolicy.sanitize(
        collection,
        mapValue(json['localPayload']),
      ),
      remotePayload: SyncPayloadPolicy.sanitize(
        collection,
        mapValue(json['remotePayload']),
      ),
      localDeleted: json['localDeleted'] == true,
      remoteDeleted: json['remoteDeleted'] == true,
      conflictPaths: SyncPayloadPolicy.sanitizeChangedPaths(
        collection,
        (json['conflictPaths'] as List?)?.whereType<String>() ?? const [],
      ),
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now().toUtc(),
      status: SyncConflictStatus.values.firstWhere(
        (value) => value.name == json['status'],
        orElse: () => SyncConflictStatus.pending,
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'accountId': accountId,
      'collection': collection,
      'itemId': itemId,
      'localMutationId': localMutationId,
      'baseEntityRevision': baseEntityRevision,
      'remoteEntityRevision': remoteEntityRevision,
      'remoteServerSeq': remoteServerSeq,
      'basePayload': SyncPayloadPolicy.sanitize(collection, basePayload),
      'localPayload': SyncPayloadPolicy.sanitize(collection, localPayload),
      'remotePayload': SyncPayloadPolicy.sanitize(collection, remotePayload),
      'localDeleted': localDeleted,
      'remoteDeleted': remoteDeleted,
      'conflictPaths': SyncPayloadPolicy.sanitizeChangedPaths(
        collection,
        conflictPaths,
      ),
      'createdAt': createdAt.toIso8601String(),
      'status': status.name,
    };
  }

  SyncConflictRecord copyWith({
    int? remoteEntityRevision,
    int? remoteServerSeq,
    Map<String, dynamic>? remotePayload,
    bool? remoteDeleted,
    List<String>? conflictPaths,
    SyncConflictStatus? status,
  }) {
    return SyncConflictRecord(
      id: id,
      accountId: accountId,
      collection: collection,
      itemId: itemId,
      localMutationId: localMutationId,
      baseEntityRevision: baseEntityRevision,
      remoteEntityRevision: remoteEntityRevision ?? this.remoteEntityRevision,
      remoteServerSeq: remoteServerSeq ?? this.remoteServerSeq,
      basePayload: SyncPayloadPolicy.sanitize(collection, basePayload),
      localPayload: SyncPayloadPolicy.sanitize(collection, localPayload),
      remotePayload: SyncPayloadPolicy.sanitize(
        collection,
        remotePayload ?? this.remotePayload,
      ),
      localDeleted: localDeleted,
      remoteDeleted: remoteDeleted ?? this.remoteDeleted,
      conflictPaths: SyncPayloadPolicy.sanitizeChangedPaths(
        collection,
        conflictPaths ?? this.conflictPaths,
      ),
      createdAt: createdAt,
      status: status ?? this.status,
    );
  }
}

class SyncConflictService {
  static const String _boxName = 'sync_conflicts';

  Box<dynamic>? _box;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  Future<Box<dynamic>> _openBox() async {
    try {
      await Hive.initFlutter();
    } catch (_) {
      // Hive may already be initialized.
    }
    return _box ??= await Hive.openBox<dynamic>(_boxName);
  }

  Future<void> record(SyncConflictRecord conflict) async {
    final box = await _openBox();
    final existing = box.values.whereType<Map>().cast<Map>().firstWhere(
      (raw) =>
          raw['accountId'] == conflict.accountId &&
          raw['collection'] == conflict.collection &&
          raw['itemId'] == conflict.itemId &&
          raw['localMutationId'] == conflict.localMutationId &&
          raw['status'] == SyncConflictStatus.pending.name,
      orElse: () => <String, dynamic>{},
    );
    final value = existing.isEmpty
        ? conflict
        : conflict.copyWith(
            // Preserve the stable conflict id when a newer remote version is
            // observed before the user resolves the conflict.
            remoteEntityRevision: conflict.remoteEntityRevision,
          );
    final key = existing.isEmpty ? conflict.id : existing['id'];
    await box.put(key, value.toJson());
    _notify();
  }

  Future<List<SyncConflictRecord>> pending({String? accountId}) async {
    final box = await _openBox();
    final records = <SyncConflictRecord>[];
    for (final entry in box.toMap().entries) {
      final raw = entry.value;
      if (raw is! Map) continue;
      try {
        final json = Map<String, dynamic>.from(raw);
        final record = SyncConflictRecord.fromJson(json);
        final storedSecrets =
            [
              json['basePayload'],
              json['localPayload'],
              json['remotePayload'],
            ].any(
              (payload) => SyncPayloadPolicy.containsSecrets(
                record.collection,
                payload is Map ? Map<String, dynamic>.from(payload) : null,
              ),
            );
        if (storedSecrets) {
          if (entry.key != record.id) await box.delete(entry.key);
          await box.put(record.id, record.toJson());
        }
        if (record.status != SyncConflictStatus.pending) continue;
        if (accountId != null && record.accountId != accountId) continue;
        records.add(record);
      } catch (_) {
        // Ignore malformed historical entries; they must not block sync.
      }
    }
    records.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return records;
  }

  Future<int> count({String? accountId}) async {
    return (await pending(accountId: accountId)).length;
  }

  Stream<int> watchCount({required String accountId}) async* {
    yield await count(accountId: accountId);
    await for (final _ in _changes.stream) {
      yield await count(accountId: accountId);
    }
  }

  Future<void> markResolved(String id) async {
    final box = await _openBox();
    final raw = box.get(id);
    if (raw is! Map) return;
    final record = SyncConflictRecord.fromJson(Map<String, dynamic>.from(raw));
    await box.put(
      id,
      record.copyWith(status: SyncConflictStatus.resolved).toJson(),
    );
    _notify();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }
}

class JsonMergeResult {
  final Map<String, dynamic> merged;
  final List<String> conflictPaths;

  const JsonMergeResult({required this.merged, required this.conflictPaths});

  bool get hasConflicts => conflictPaths.isNotEmpty;
}

/// Performs a conservative JSON three-way merge. Maps are merged recursively;
/// arrays and scalar values are treated as atomic values so a user's ordered
/// list edit is never silently rewritten.
JsonMergeResult threeWayMerge({
  required Map<String, dynamic> base,
  required Map<String, dynamic> local,
  required Map<String, dynamic> remote,
}) {
  final result = _mergeNode(
    _JsonNode.present(base),
    _JsonNode.present(local),
    _JsonNode.present(remote),
    r'$',
  );
  final value = result.value;
  return JsonMergeResult(
    merged: value is Map
        ? Map<String, dynamic>.from(value)
        : Map<String, dynamic>.from(local),
    conflictPaths: result.conflicts,
  );
}

List<String> jsonChangedPaths(
  Map<String, dynamic>? base,
  Map<String, dynamic>? value,
) {
  if (base == null && value == null) return const [];
  if (base == null || value == null) return const [r'$'];
  return _diffNode(_JsonNode.present(base), _JsonNode.present(value), r'$');
}

class _JsonNode {
  final bool present;
  final dynamic value;

  const _JsonNode(this.present, this.value);

  const _JsonNode.present(dynamic value) : this(true, value);
  const _JsonNode.missing() : this(false, null);
}

class _MergeNode {
  final _JsonNode node;
  final List<String> conflicts;

  const _MergeNode(this.node, this.conflicts);

  dynamic get value => node.present ? _copyJson(node.value) : null;
}

_MergeNode _mergeNode(
  _JsonNode base,
  _JsonNode local,
  _JsonNode remote,
  String path,
) {
  if (_sameNode(local, remote)) return _MergeNode(local, const []);
  if (_sameNode(local, base)) return _MergeNode(remote, const []);
  if (_sameNode(remote, base)) return _MergeNode(local, const []);

  if (local.present &&
      remote.present &&
      local.value is Map &&
      remote.value is Map &&
      (base.value is Map || !base.present)) {
    final baseMap = base.present && base.value is Map
        ? Map<dynamic, dynamic>.from(base.value as Map)
        : const <dynamic, dynamic>{};
    final localMap = Map<dynamic, dynamic>.from(local.value as Map);
    final remoteMap = Map<dynamic, dynamic>.from(remote.value as Map);
    final keys = <dynamic>{
      ...baseMap.keys,
      ...localMap.keys,
      ...remoteMap.keys,
    };
    final merged = <String, dynamic>{};
    final conflicts = <String>[];
    for (final key in keys) {
      if (key is! String) continue;
      final child = _mergeNode(
        baseMap.containsKey(key)
            ? _JsonNode.present(baseMap[key])
            : const _JsonNode.missing(),
        localMap.containsKey(key)
            ? _JsonNode.present(localMap[key])
            : const _JsonNode.missing(),
        remoteMap.containsKey(key)
            ? _JsonNode.present(remoteMap[key])
            : const _JsonNode.missing(),
        '$path.$key',
      );
      if (child.node.present) merged[key] = child.value;
      conflicts.addAll(child.conflicts);
    }
    return _MergeNode(_JsonNode.present(merged), conflicts);
  }

  // Keep the local value visible until the user resolves the conflict.
  return _MergeNode(local, [path]);
}

List<String> _diffNode(_JsonNode left, _JsonNode right, String path) {
  if (_sameNode(left, right)) return const [];
  if (left.present &&
      right.present &&
      left.value is Map &&
      right.value is Map) {
    final leftMap = Map<dynamic, dynamic>.from(left.value as Map);
    final rightMap = Map<dynamic, dynamic>.from(right.value as Map);
    final keys = <dynamic>{...leftMap.keys, ...rightMap.keys};
    final result = <String>[];
    for (final key in keys) {
      if (key is! String) continue;
      result.addAll(
        _diffNode(
          leftMap.containsKey(key)
              ? _JsonNode.present(leftMap[key])
              : const _JsonNode.missing(),
          rightMap.containsKey(key)
              ? _JsonNode.present(rightMap[key])
              : const _JsonNode.missing(),
          '$path.$key',
        ),
      );
    }
    return result;
  }
  return [path];
}

bool _sameNode(_JsonNode left, _JsonNode right) {
  return left.present == right.present &&
      (!left.present || _sameJson(left.value, right.value));
}

bool _sameJson(dynamic left, dynamic right) {
  if (left is num && right is num) return left == right;
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_sameJson(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (!_sameJson(left[i], right[i])) return false;
    }
    return true;
  }
  return left == right;
}

dynamic _copyJson(dynamic value) {
  if (value is Map) {
    return value.map((key, child) => MapEntry(key, _copyJson(child)));
  }
  if (value is List) return value.map(_copyJson).toList();
  return value;
}

int _intValue(dynamic value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
