import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../config/backend_config.dart';
import 'auth_service.dart';
import 'sync_apply_service.dart';
import 'sync_conflict_service.dart';
import 'sync_outbox_service.dart';
import 'sync_payload_policy.dart';
import 'sync_protocol.dart';
import 'sync_shadow_service.dart';
import 'sync_state_service.dart';

class SyncResult {
  final int pushed;
  final int pulled;
  final int applied;
  final int skippedConflicts;
  final int conflicts;
  final int cursor;
  final int processed;

  const SyncResult({
    required this.pushed,
    required this.pulled,
    this.applied = 0,
    this.skippedConflicts = 0,
    this.conflicts = 0,
    this.processed = 0,
    required this.cursor,
  });

  SyncResult combine(SyncResult other) {
    return SyncResult(
      pushed: pushed + other.pushed,
      pulled: pulled + other.pulled,
      applied: applied + other.applied,
      skippedConflicts: skippedConflicts + other.skippedConflicts,
      conflicts: conflicts + other.conflicts,
      processed: processed + other.processed,
      cursor: other.cursor,
    );
  }
}

class SyncService {
  final SyncOutboxService outbox;
  final SyncStateService state;
  final SyncApplyService applier;
  final SyncShadowService shadow;
  final SyncConflictService conflicts;
  final http.Client _client;

  Future<SyncResult>? _activeSync;

  SyncService({
    required this.outbox,
    required this.state,
    required this.applier,
    SyncShadowService? shadow,
    SyncConflictService? conflicts,
    http.Client? client,
  }) : shadow = shadow ?? SyncShadowService(),
       conflicts = conflicts ?? SyncConflictService(),
       _client = client ?? http.Client();

  /// Runs one serialized sync job and drains every currently pending page.
  Future<SyncResult> sync(AuthSession session) async {
    final active = _activeSync;
    if (active != null) return active;

    final operation = _syncAll(session);
    _activeSync = operation;
    try {
      return await operation;
    } finally {
      if (identical(_activeSync, operation)) _activeSync = null;
    }
  }

  Future<SyncResult> _syncAll(AuthSession session) async {
    final pushed = await pushAllPending(session);
    final pulled = await pullAll(session);
    return pushed.combine(pulled);
  }

  Future<SyncResult> pushAllPending(
    AuthSession session, {
    int pageSize = 50,
  }) async {
    var result = SyncResult(
      pushed: 0,
      pulled: 0,
      cursor: await state.cursor(session.user.id),
    );
    while (true) {
      final page = await pushPending(session, limit: pageSize);
      result = result.combine(page);
      if (page.processed == 0) return result;
      final remaining = await outbox.pending(
        accountId: session.user.id,
        limit: 1,
      );
      if (remaining.isEmpty) return result;
    }
  }

  Future<SyncResult> pushPending(AuthSession session, {int limit = 50}) async {
    final accountId = session.user.id;
    final records = await outbox.claimPending(
      accountId: accountId,
      limit: limit,
    );
    if (records.isEmpty) {
      return SyncResult(
        pushed: 0,
        pulled: 0,
        cursor: await state.cursor(accountId),
      );
    }

    try {
      final events = <Map<String, dynamic>>[];
      for (final record in records) {
        final rawPayload =
            SyncPayloadPolicy.sanitize(record.collection, record.payload) ??
            const <String, dynamic>{};
        final payload = record.operation == SyncOperation.delete
            ? null
            : SyncProtocol.wrapPayload(
                accountId: accountId,
                collection: record.collection,
                itemId: record.itemId,
                data: rawPayload,
              );
        events.add({
          'clientEventId': record.id,
          'collection': record.collection,
          'itemId': record.itemId,
          'op': record.operation.name,
          'revision': record.revision,
          'baseEntityRevision': record.baseEntityRevision,
          'protocolVersion': SyncProtocol.protocolVersion,
          'schemaVersion': SyncProtocol.protocolVersion,
          'entitySchemaVersion': SyncProtocol.entitySchemaVersion(rawPayload),
          'payloadFormat': SyncProtocol.payloadFormat,
          'payload': payload,
          'clientUpdatedAt': record.clientUpdatedAt,
        });
      }

      final response = await _client
          .post(
            BackendConfig.uri('/sync/push'),
            headers: _headers(session, json: true),
            body: jsonEncode({
              'protocolVersion': SyncProtocol.protocolVersion,
              'deviceId': session.device.id,
              'baseCursor': await state.cursor(accountId),
              'events': events,
            }),
          )
          .timeout(const Duration(seconds: 30));
      _throwIfFailed(response);

      final decoded = _decodeObject(response);
      final rawResults = decoded['results'];
      final resultsById = <String, Map<String, dynamic>>{};
      if (rawResults is List) {
        for (final raw in rawResults) {
          if (raw is Map && raw['clientEventId'] is String) {
            resultsById[raw['clientEventId'] as String] =
                Map<String, dynamic>.from(raw);
          }
        }
      }

      // The v3 server always returns per-event results. Keep the fallback so
      // a rolling deployment that still returns only aggregate counts cannot
      // silently discard a partial response.
      final legacyAllApplied =
          resultsById.isEmpty &&
          _intValue(decoded['conflicts']) == 0 &&
          _intValue(decoded['accepted']) == records.length;
      var pushed = 0;
      var conflictCount = 0;
      var processed = 0;
      for (final record in records) {
        final result =
            resultsById[record.id] ??
            (legacyAllApplied ? <String, dynamic>{'status': 'applied'} : null);
        if (result == null) {
          throw const SyncApiException('Sync server omitted an event result.');
        }
        final status = result['status']?.toString();
        if (status == 'applied' ||
            status == 'duplicate' ||
            status == 'accepted') {
          await _acknowledgePush(session, record, result);
          await outbox.removeAll([record.id]);
          pushed++;
          processed++;
        } else if (status == 'conflict') {
          final resolvedAutomatically = await _handlePushConflict(
            session,
            record,
            result,
          );
          if (!resolvedAutomatically) conflictCount++;
          processed++;
        } else {
          throw SyncApiException(
            'Sync server returned an unknown mutation result: $status.',
          );
        }
      }

      return SyncResult(
        pushed: pushed,
        pulled: 0,
        conflicts: conflictCount,
        processed: processed,
        cursor: await state.cursor(accountId),
      );
    } catch (error) {
      await outbox.markFailed(records, error);
      rethrow;
    }
  }

  Future<void> _acknowledgePush(
    AuthSession session,
    SyncOutboxRecord record,
    Map<String, dynamic> result,
  ) async {
    final revision = _intValue(
      result['entityRevision'] ?? result['serverRevision'],
      fallback: record.baseEntityRevision + 1,
    );
    final serverSeq = _intValue(result['serverSeq']);
    await shadow.put(
      SyncShadow(
        accountId: session.user.id,
        collection: record.collection,
        itemId: record.itemId,
        entityRevision: revision,
        serverSeq: serverSeq,
        payload: SyncPayloadPolicy.sanitize(record.collection, record.payload),
        deleted: record.operation == SyncOperation.delete,
        deviceId: session.device.id,
      ),
    );
  }

  Future<bool> _handlePushConflict(
    AuthSession session,
    SyncOutboxRecord record,
    Map<String, dynamic> result,
  ) async {
    final current = result['current'];
    final remote = current is Map
        ? Map<String, dynamic>.from(current)
        : <String, dynamic>{};
    final remoteContainedProviderSecrets =
        current is Map &&
        _eventPayloadContainsProviderSecrets(
          remote,
          accountId: session.user.id,
          collection: record.collection,
          itemId: record.itemId,
        );
    final remotePayload = current is Map
        ? _decodeEventPayload(
            remote,
            accountId: session.user.id,
            collection: record.collection,
            itemId: record.itemId,
          )
        : null;
    final remoteDeleted =
        current is! Map ||
        (remote['op']?.toString() == SyncOperation.delete.name) ||
        remote['payload'] == null;
    final remoteRevision = _intValue(
      current is Map
          ? (remote['entityRevision'] ?? remote['serverRevision'])
          : result['entityRevision'],
    );
    final remoteServerSeq = _intValue(
      current is Map ? remote['serverSeq'] : result['serverSeq'],
    );

    await shadow.put(
      SyncShadow(
        accountId: session.user.id,
        collection: record.collection,
        itemId: record.itemId,
        entityRevision: remoteRevision,
        serverSeq: remoteServerSeq,
        payload: remotePayload,
        deleted: remoteDeleted,
        deviceId: current is Map && remote['deviceId'] is String
            ? remote['deviceId'] as String
            : null,
      ),
    );

    if (record.operation != SyncOperation.delete &&
        !remoteDeleted &&
        record.payload != null &&
        remotePayload != null) {
      final merged = threeWayMerge(
        base: record.basePayload ?? const <String, dynamic>{},
        local: record.payload!,
        remote: remotePayload,
      );
      if (!merged.hasConflicts) {
        await applier.applyResolvedPayload(
          collection: record.collection,
          itemId: record.itemId,
          payload: merged.merged,
        );
        await outbox.removeAll([record.id]);
        final changedPaths = jsonChangedPaths(remotePayload, merged.merged);
        if (changedPaths.isNotEmpty || remoteContainedProviderSecrets) {
          await outbox.enqueue(
            SyncOutboxRecord.create(
              accountId: session.user.id,
              collection: record.collection,
              itemId: record.itemId,
              operation: SyncOperation.upsert,
              payload: merged.merged,
              baseEntityRevision: remoteRevision,
              basePayload: remotePayload,
              changedPaths: changedPaths.isEmpty ? const [r'$'] : changedPaths,
            ),
          );
        }
        return true;
      }
    }

    final merge = record.payload != null && remotePayload != null
        ? threeWayMerge(
            base: record.basePayload ?? const <String, dynamic>{},
            local: record.payload!,
            remote: remotePayload,
          )
        : const JsonMergeResult(
            merged: <String, dynamic>{},
            conflictPaths: [r'$'],
          );
    final conflict = SyncConflictRecord.create(
      accountId: session.user.id,
      collection: record.collection,
      itemId: record.itemId,
      localMutationId: record.id,
      baseEntityRevision: record.baseEntityRevision,
      remoteEntityRevision: remoteRevision,
      remoteServerSeq: remoteServerSeq,
      basePayload: record.basePayload,
      localPayload: record.payload,
      remotePayload: remotePayload,
      localDeleted: record.operation == SyncOperation.delete,
      remoteDeleted: remoteDeleted,
      conflictPaths: merge.conflictPaths,
    );
    await conflicts.record(conflict);
    await outbox.markConflict(record, conflict.id);
    return false;
  }

  Future<SyncResult> pullAll(AuthSession session, {int pageSize = 500}) async {
    final accountId = session.user.id;
    var result = SyncResult(
      pushed: 0,
      pulled: 0,
      cursor: await state.cursor(accountId),
    );
    while (true) {
      final page = await pull(session, limit: pageSize);
      result = result.combine(page);
      if (page.pulled < pageSize) return result;
    }
  }

  Future<SyncResult> pull(AuthSession session, {int limit = 500}) async {
    final accountId = session.user.id;
    final cursor = await state.cursor(accountId);
    final response = await _client
        .get(
          BackendConfig.uri('/sync/pull').replace(
            queryParameters: {
              'since': cursor.toString(),
              'limit': limit.toString(),
            },
          ),
          headers: _headers(session),
        )
        .timeout(const Duration(seconds: 30));
    _throwIfFailed(response);

    final decoded = _decodeObject(response);
    final nextCursor = _extractCursor(decoded) ?? cursor;
    final events = _extractEvents(decoded);
    if (nextCursor < cursor || (events.isNotEmpty && nextCursor == cursor)) {
      throw const SyncApiException(
        'Sync server returned events without advancing the cursor.',
      );
    }
    final applyResult = await applier.applyEvents(
      events,
      localDeviceId: session.device.id,
      accountId: accountId,
    );
    await state.setCursor(accountId, nextCursor);

    return SyncResult(
      pushed: 0,
      pulled: events.length,
      applied: applyResult.applied,
      skippedConflicts: applyResult.skippedConflicts,
      conflicts: applyResult.conflicts,
      cursor: nextCursor,
    );
  }

  Future<Map<String, dynamic>> bootstrap(
    AuthSession session, {
    String? cursor,
    int limit = 500,
  }) async {
    final query = <String, String>{'limit': limit.toString()};
    if (cursor != null && cursor.isNotEmpty) query['cursor'] = cursor;
    final response = await _client
        .get(
          BackendConfig.uri('/sync/bootstrap').replace(queryParameters: query),
          headers: _headers(session),
        )
        .timeout(const Duration(seconds: 30));
    _throwIfFailed(response);
    return _decodeObject(response);
  }

  Future<SyncResult> bootstrapAndApply(AuthSession session) async {
    final accountId = session.user.id;
    var result = SyncResult(
      pushed: 0,
      pulled: 0,
      cursor: await state.cursor(accountId),
    );
    String? cursor;
    var snapshotCursor = await state.cursor(accountId);

    while (true) {
      final decoded = await bootstrap(session, cursor: cursor);
      final events = _extractEvents(decoded);
      final applyResult = await applier.applyEvents(
        events,
        localDeviceId: session.device.id,
        accountId: accountId,
      );
      final latest = _extractCursor(decoded, keys: const ['latestCursor']);
      if (latest != null) snapshotCursor = latest;
      result = result.combine(
        SyncResult(
          pushed: 0,
          pulled: events.length,
          applied: applyResult.applied,
          skippedConflicts: applyResult.skippedConflicts,
          conflicts: applyResult.conflicts,
          cursor: snapshotCursor,
        ),
      );

      final hasMore = decoded['hasMore'] == true;
      final next = decoded['nextCursor'];
      if (!hasMore || next is! String || next.isEmpty) break;
      cursor = next;
    }

    await state.setCursor(accountId, snapshotCursor);
    return result;
  }

  Map<String, String> _headers(AuthSession session, {bool json = false}) {
    return {
      'Authorization': 'Bearer ${session.accessToken}',
      'X-Memora-Sync-Protocol': SyncProtocol.protocolVersion.toString(),
      if (json) 'Content-Type': 'application/json',
    };
  }

  Map<String, dynamic>? _decodeEventPayload(
    Map<String, dynamic> event, {
    required String accountId,
    required String collection,
    required String itemId,
  }) {
    final payload = event['payload'];
    if (payload is! Map) return null;
    final unwrapped = SyncProtocol.unwrapPayload(
      Map<String, dynamic>.from(payload),
      accountId: accountId,
      collection: collection,
      itemId: itemId,
    );
    return SyncPayloadPolicy.sanitize(collection, unwrapped);
  }

  bool _eventPayloadContainsProviderSecrets(
    Map<String, dynamic> event, {
    required String accountId,
    required String collection,
    required String itemId,
  }) {
    final payload = event['payload'];
    if (payload is! Map) return false;
    final unwrapped = SyncProtocol.unwrapPayload(
      Map<String, dynamic>.from(payload),
      accountId: accountId,
      collection: collection,
      itemId: itemId,
    );
    return SyncPayloadPolicy.containsSecrets(collection, unwrapped);
  }

  Map<String, dynamic> _decodeObject(http.Response response) {
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is Map<String, dynamic>) return decoded;
    throw const SyncApiException('Invalid sync server response.');
  }

  int? _extractCursor(
    Map<String, dynamic> decoded, {
    List<String> keys = const [
      'nextCursor',
      'serverSeq',
      'latestCursor',
      'cursor',
    ],
  }) {
    for (final key in keys) {
      final value = decoded[key];
      final parsed = int.tryParse(value?.toString() ?? '');
      if (parsed != null) return parsed;
    }
    return null;
  }

  List<dynamic> _extractEvents(Map<String, dynamic> decoded) {
    final value = decoded['events'] ?? decoded['items'] ?? decoded['records'];
    return value is List ? value : const [];
  }

  int _intValue(dynamic value, {int fallback = 0}) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  void _throwIfFailed(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    var message = 'Sync request failed with status ${response.statusCode}.';
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map) {
        final error = decoded['error'];
        message =
            (decoded['message'] ??
                    (error is Map ? error['message'] : error) ??
                    message)
                .toString();
      }
    } catch (_) {
      if (response.body.isNotEmpty) message = response.body;
    }
    throw SyncApiException(message, statusCode: response.statusCode);
  }
}

class SyncApiException implements Exception {
  final String message;
  final int? statusCode;

  const SyncApiException(this.message, {this.statusCode});

  @override
  String toString() => message;
}
