import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../config/backend_config.dart';
import 'auth_service.dart';
import 'sync_apply_service.dart';
import 'sync_crypto_service.dart';
import 'sync_outbox_service.dart';
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
}

class SyncService {
  final SyncOutboxService outbox;
  final SyncStateService state;
  final SyncCryptoService crypto;
  final SyncApplyService applier;

  const SyncService({
    required this.outbox,
    required this.state,
    required this.crypto,
    required this.applier,
  });

  Future<SyncResult> sync(AuthSession session) async {
    final pushed = await pushPending(session);
    final pullResult = await pull(session);
    return SyncResult(
      pushed: pushed,
      pulled: pullResult.pulled,
      applied: pullResult.applied,
      skippedConflicts: pullResult.skippedConflicts,
      cursor: pullResult.cursor,
    );
  }

  Future<int> pushPending(AuthSession session, {int limit = 50}) async {
    final records = await outbox.pending(limit: limit);
    if (records.isEmpty) return 0;

    try {
      final events = <Map<String, dynamic>>[];
      for (final record in records) {
        final encrypted = record.operation == SyncOperation.delete
            ? null
            : await crypto.encryptJson(
                record.payload ?? const <String, dynamic>{},
                collection: record.collection,
                itemId: record.itemId,
                revision: record.revision,
              );
        events.add({
          'clientEventId': record.id,
          'collection': record.collection,
          'itemId': record.itemId,
          'op': record.operation.name,
          'revision': record.revision,
          'schemaVersion': 1,
          'ciphertext': encrypted?.ciphertext,
          'nonce': encrypted?.nonce,
          'aad': encrypted?.aad,
          'contentHash': encrypted?.contentHash,
          'clientUpdatedAt': record.clientUpdatedAt,
        });
      }

      final response = await http
          .post(
            BackendConfig.uri('/sync/push'),
            headers: {
              'Authorization': 'Bearer ${session.accessToken}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'deviceId': session.device.id,
              'baseCursor': await state.cursor(),
              'events': events,
            }),
          )
          .timeout(const Duration(seconds: 30));
      _throwIfFailed(response);

      await outbox.removeAll(records.map((record) => record.id));
      final decoded = _decodeObject(response);
      final cursor = _extractCursor(decoded);
      if (cursor != null) await state.setCursor(cursor);
      return records.length;
    } catch (error) {
      await outbox.markFailed(records, error);
      rethrow;
    }
  }

  Future<SyncResult> pull(AuthSession session, {int limit = 500}) async {
    final cursor = await state.cursor();
    final response = await http
        .get(
          BackendConfig.uri('/sync/pull').replace(
            queryParameters: {
              'since': cursor.toString(),
              'limit': limit.toString(),
            },
          ),
          headers: {'Authorization': 'Bearer ${session.accessToken}'},
        )
        .timeout(const Duration(seconds: 30));
    _throwIfFailed(response);

    final decoded = _decodeObject(response);
    final nextCursor = _extractCursor(decoded) ?? cursor;
    final events = _extractEvents(decoded);
    final applyResult = await applier.applyEvents(
      events,
      localDeviceId: session.device.id,
    );
    await state.setCursor(nextCursor);

    return SyncResult(
      pushed: 0,
      pulled: events.length,
      applied: applyResult.applied,
      skippedConflicts: applyResult.skippedConflicts,
      cursor: nextCursor,
    );
  }

  Future<Map<String, dynamic>> bootstrap(AuthSession session) async {
    final response = await http
        .get(
          BackendConfig.uri('/sync/bootstrap'),
          headers: {'Authorization': 'Bearer ${session.accessToken}'},
        )
        .timeout(const Duration(seconds: 30));
    _throwIfFailed(response);
    return _decodeObject(response);
  }

  Future<SyncResult> bootstrapAndApply(AuthSession session) async {
    final decoded = await bootstrap(session);
    final cursor = await state.cursor();
    final nextCursor = _extractCursor(decoded) ?? cursor;
    final events = _extractEvents(decoded);
    final applyResult = await applier.applyEvents(
      events,
      localDeviceId: session.device.id,
    );
    await state.setCursor(nextCursor);
    return SyncResult(
      pushed: 0,
      pulled: events.length,
      applied: applyResult.applied,
      skippedConflicts: applyResult.skippedConflicts,
      cursor: nextCursor,
    );
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
        message = (decoded['message'] ?? decoded['error'] ?? message)
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
