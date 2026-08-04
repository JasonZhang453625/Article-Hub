import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../config/backend_config.dart';
import 'auth_service.dart';
import 'sync_apply_service.dart';
import 'sync_outbox_service.dart';
import 'sync_protocol.dart';
import 'sync_state_service.dart';

class SyncResult {
  final int pushed;
  final int pulled;
  final int applied;
  final int skippedConflicts;
  final int cursor;

  const SyncResult({
    required this.pushed,
    required this.pulled,
    this.applied = 0,
    this.skippedConflicts = 0,
    required this.cursor,
  });

  SyncResult combine(SyncResult other) {
    return SyncResult(
      pushed: pushed + other.pushed,
      pulled: pulled + other.pulled,
      applied: applied + other.applied,
      skippedConflicts: skippedConflicts + other.skippedConflicts,
      cursor: other.cursor,
    );
  }
}

class SyncService {
  final SyncOutboxService outbox;
  final SyncStateService state;
  final SyncApplyService applier;
  final http.Client _client;

  Future<SyncResult>? _activeSync;

  SyncService({
    required this.outbox,
    required this.state,
    required this.applier,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Runs one serialized sync job and drains every currently pending page.
  /// Individual HTTP requests stay bounded, but callers never need to click
  /// repeatedly to process the next 50 records.
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
    return SyncResult(
      pushed: pushed,
      pulled: pulled.pulled,
      applied: pulled.applied,
      skippedConflicts: pulled.skippedConflicts,
      cursor: pulled.cursor,
    );
  }

  Future<int> pushAllPending(AuthSession session, {int pageSize = 50}) async {
    var total = 0;
    while (true) {
      final pushed = await pushPending(session, limit: pageSize);
      total += pushed;
      if (pushed < pageSize) return total;
    }
  }

  Future<int> pushPending(AuthSession session, {int limit = 50}) async {
    final accountId = session.user.id;
    final records = await outbox.pending(accountId: accountId, limit: limit);
    if (records.isEmpty) return 0;

    try {
      final events = <Map<String, dynamic>>[];
      for (final record in records) {
        final rawPayload = record.payload ?? const <String, dynamic>{};
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
          'protocolVersion': SyncProtocol.protocolVersion,
          'schemaVersion': SyncProtocol.protocolVersion,
          'entitySchemaVersion': SyncProtocol.entitySchemaVersion(
            record.payload,
          ),
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

      _decodeObject(response);
      await outbox.removeAll(records.map((record) => record.id));

      // A push acknowledgement must never advance the local read cursor. Only
      // pull/bootstrap can do that after all preceding remote events are read.
      return records.length;
    } catch (error) {
      await outbox.markFailed(records, error);
      rethrow;
    }
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
      cursor: nextCursor,
    );
  }

  Future<Map<String, dynamic>> bootstrap(AuthSession session) async {
    final response = await _client
        .get(BackendConfig.uri('/sync/bootstrap'), headers: _headers(session))
        .timeout(const Duration(seconds: 30));
    _throwIfFailed(response);
    return _decodeObject(response);
  }

  Future<SyncResult> bootstrapAndApply(AuthSession session) async {
    final accountId = session.user.id;
    final decoded = await bootstrap(session);
    final cursor = await state.cursor(accountId);
    final nextCursor = _extractCursor(decoded) ?? cursor;
    final events = _extractEvents(decoded);
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
      cursor: nextCursor,
    );
  }

  Map<String, String> _headers(AuthSession session, {bool json = false}) {
    return {
      'Authorization': 'Bearer ${session.accessToken}',
      'X-Memora-Sync-Protocol': SyncProtocol.protocolVersion.toString(),
      if (json) 'Content-Type': 'application/json',
    };
  }

  Map<String, dynamic> _decodeObject(http.Response response) {
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is Map<String, dynamic>) return decoded;
    throw const SyncApiException('Invalid sync server response.');
  }

  int? _extractCursor(Map<String, dynamic> decoded) {
    final value =
        decoded['nextCursor'] ??
        decoded['serverSeq'] ??
        decoded['latestCursor'] ??
        decoded['cursor'];
    return value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
  }

  List<dynamic> _extractEvents(Map<String, dynamic> decoded) {
    final value = decoded['events'] ?? decoded['items'] ?? decoded['records'];
    return value is List ? value : const [];
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
