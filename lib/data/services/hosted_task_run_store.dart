import 'dart:async';

import 'package:hive/hive.dart';

enum HostedTaskBindingState {
  creating,
  queued,
  running,
  waitingClient,
  completed,
  failed,
  cancelled,
  abandoned;

  bool get isReplayable => switch (this) {
    creating || queued || running || waitingClient || completed => true,
    failed || cancelled || abandoned => false,
  };
}

class HostedTaskRunBinding {
  static const int schemaVersion = 1;

  final String idempotencyKey;
  final String profile;
  final String model;
  final String inputDigest;
  final String? planDigest;
  final String? articleId;
  final String? generation;
  final String stage;
  final String? runId;
  final HostedTaskBindingState state;
  final DateTime updatedAt;

  const HostedTaskRunBinding({
    required this.idempotencyKey,
    required this.profile,
    required this.model,
    required this.inputDigest,
    this.planDigest,
    required this.articleId,
    required this.generation,
    required this.stage,
    required this.runId,
    required this.state,
    required this.updatedAt,
  });

  HostedTaskRunBinding copyWith({
    String? runId,
    HostedTaskBindingState? state,
    DateTime? updatedAt,
  }) {
    return HostedTaskRunBinding(
      idempotencyKey: idempotencyKey,
      profile: profile,
      model: model,
      inputDigest: inputDigest,
      planDigest: planDigest,
      articleId: articleId,
      generation: generation,
      stage: stage,
      runId: runId ?? this.runId,
      state: state ?? this.state,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toMap(String scopeHash) => {
    'kind': 'binding',
    'schemaVersion': schemaVersion,
    'scopeHash': scopeHash,
    'idempotencyKey': idempotencyKey,
    'profile': profile,
    'model': model,
    'inputDigest': inputDigest,
    'planDigest': planDigest,
    'articleId': articleId,
    'generation': generation,
    'stage': stage,
    'runId': runId,
    'state': state.name,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  static HostedTaskRunBinding? fromMap(Map<dynamic, dynamic> map) {
    if (map['kind'] != 'binding' ||
        map['schemaVersion'] != schemaVersion ||
        map['idempotencyKey'] is! String ||
        map['profile'] is! String ||
        map['model'] is! String ||
        map['inputDigest'] is! String ||
        map['stage'] is! String ||
        map['state'] is! String ||
        map['updatedAt'] is! String ||
        (map['articleId'] != null && map['articleId'] is! String) ||
        (map['planDigest'] != null && map['planDigest'] is! String) ||
        (map['generation'] != null && map['generation'] is! String) ||
        (map['runId'] != null && map['runId'] is! String)) {
      return null;
    }
    final stateName = map['state'] as String;
    final state = HostedTaskBindingState.values
        .where((candidate) => candidate.name == stateName)
        .firstOrNull;
    final updatedAt = DateTime.tryParse(map['updatedAt'] as String);
    if (state == null || updatedAt == null) return null;
    return HostedTaskRunBinding(
      idempotencyKey: map['idempotencyKey'] as String,
      profile: map['profile'] as String,
      model: map['model'] as String,
      inputDigest: map['inputDigest'] as String,
      planDigest: map['planDigest'] as String?,
      articleId: map['articleId'] as String?,
      generation: map['generation'] as String?,
      stage: map['stage'] as String,
      runId: map['runId'] as String?,
      state: state,
      updatedAt: updatedAt,
    );
  }
}

abstract interface class HostedTaskRunStore {
  Future<HostedTaskRunBinding?> readBinding(
    String scopeHash,
    String idempotencyKey,
  );

  /// Finds the durable key selected for one logical pipeline operation.
  ///
  /// This lookup deliberately does not depend on the current input digest:
  /// after process death, refetched page content may differ while the old run
  /// still has to be observed by its already-bound run id.
  Future<HostedTaskRunBinding?> readBindingForOperation({
    required String scopeHash,
    required String articleId,
    required String generation,
    required String stage,
  });

  Future<void> writeBinding(String scopeHash, HostedTaskRunBinding binding);

  /// Returns true only for the first observation of this run id in the scope.
  Future<bool> recordTokenUsage(
    String scopeHash,
    String runId,
    int totalTokens,
  );

  Future<bool> hasReplayableBindings({
    required String scopeHash,
    required String articleId,
    required String generation,
  });

  Future<void> finalizeGeneration({
    required String scopeHash,
    required String articleId,
    required String generation,
  });

  Future<void> close();
}

/// Durable, metadata-only journal for hosted Pi task recovery.
///
/// Typed task input and article text are deliberately never written here. The
/// input SHA-256 is enough to decide whether an ambiguous create can be safely
/// replayed with the same idempotency key.
class HiveHostedTaskRunStore implements HostedTaskRunStore {
  static const String boxName = 'hosted_pi_task_runs_v1';

  final Future<void>? _initialization;
  Box<Map>? _box;
  Future<Box<Map>>? _opening;
  Future<void> _usageWriteTail = Future<void>.value();

  HiveHostedTaskRunStore({Future<void>? initialization})
    : _initialization = initialization;

  Future<Box<Map>> _open() {
    final existing = _box;
    if (existing != null && existing.isOpen) return Future.value(existing);
    final opening = _opening;
    if (opening != null) return opening;
    final future = (() async {
      try {
        await _initialization;
        final box = await Hive.openBox<Map>(boxName);
        _box = box;
        _opening = null;
        return box;
      } catch (_) {
        _opening = null;
        rethrow;
      }
    })();
    _opening = future;
    return future;
  }

  @override
  Future<HostedTaskRunBinding?> readBinding(
    String scopeHash,
    String idempotencyKey,
  ) async {
    final value = (await _open()).get(_bindingKey(scopeHash, idempotencyKey));
    if (value == null || value['scopeHash'] != scopeHash) return null;
    return HostedTaskRunBinding.fromMap(value);
  }

  @override
  Future<HostedTaskRunBinding?> readBindingForOperation({
    required String scopeHash,
    required String articleId,
    required String generation,
    required String stage,
  }) async {
    HostedTaskRunBinding? latest;
    for (final value in (await _open()).values) {
      if (value['scopeHash'] != scopeHash || value['kind'] != 'binding') {
        continue;
      }
      final binding = HostedTaskRunBinding.fromMap(value);
      if (binding?.articleId != articleId ||
          binding?.generation != generation ||
          binding?.stage != stage) {
        continue;
      }
      if (latest == null || binding!.updatedAt.isAfter(latest.updatedAt)) {
        latest = binding;
      }
    }
    return latest;
  }

  @override
  Future<void> writeBinding(
    String scopeHash,
    HostedTaskRunBinding binding,
  ) async {
    await (await _open()).put(
      _bindingKey(scopeHash, binding.idempotencyKey),
      binding.toMap(scopeHash),
    );
  }

  @override
  Future<bool> recordTokenUsage(
    String scopeHash,
    String runId,
    int totalTokens,
  ) async {
    if (totalTokens <= 0) return false;
    final previous = _usageWriteTail;
    final completion = Completer<void>();
    _usageWriteTail = completion.future;
    await previous;
    try {
      final box = await _open();
      final key = _usageKey(scopeHash, runId);
      if (box.containsKey(key)) return false;
      await box.put(key, {
        'kind': 'usage',
        'schemaVersion': 1,
        'scopeHash': scopeHash,
        'runId': runId,
        'totalTokens': totalTokens,
        'recordedAt': DateTime.now().toUtc().toIso8601String(),
      });
      return true;
    } finally {
      completion.complete();
    }
  }

  @override
  Future<bool> hasReplayableBindings({
    required String scopeHash,
    required String articleId,
    required String generation,
  }) async {
    final box = await _open();
    var foundReplayable = false;
    for (final value in box.values) {
      if (value['scopeHash'] != scopeHash || value['kind'] != 'binding') {
        continue;
      }
      final binding = HostedTaskRunBinding.fromMap(value);
      if (binding?.articleId == articleId &&
          binding?.generation == generation) {
        if (!binding!.state.isReplayable) return false;
        foundReplayable = true;
      }
    }
    return foundReplayable;
  }

  @override
  Future<void> finalizeGeneration({
    required String scopeHash,
    required String articleId,
    required String generation,
  }) async {
    final box = await _open();
    final keys = <dynamic>[];
    for (final key in box.keys) {
      final value = box.get(key);
      if (value == null ||
          value['scopeHash'] != scopeHash ||
          value['kind'] != 'binding') {
        continue;
      }
      final binding = HostedTaskRunBinding.fromMap(value);
      if (binding?.articleId == articleId &&
          binding?.generation == generation) {
        keys.add(key);
      }
    }
    if (keys.isNotEmpty) await box.deleteAll(keys);
  }

  @override
  Future<void> close() async {
    await _usageWriteTail;
    final opening = _opening;
    final box = _box ?? (opening == null ? null : await opening);
    _opening = null;
    _box = null;
    if (box != null && box.isOpen) await box.close();
  }

  static String _bindingKey(String scopeHash, String idempotencyKey) =>
      'binding::$scopeHash::$idempotencyKey';

  static String _usageKey(String scopeHash, String runId) =>
      'usage::$scopeHash::$runId';
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
