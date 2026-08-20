import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import '../../config/backend_config.dart';
import 'auth_service.dart';
import 'hosted_agent_service.dart';

const int hostedTaskProtocolVersion = 4;
const int hostedTaskProfileVersion = 1;
const int hostedTaskResultSchemaVersion = 1;

enum HostedTaskProfile {
  retrievalRewrite('retrieval.rewrite'),
  summaryChunk('summary.chunk'),
  summaryFinal('summary.final'),
  memoryTags('memory.tags'),
  memoryFolder('memory.folder');

  final String wireName;

  const HostedTaskProfile(this.wireName);
}

enum HostedTaskRewriteLanguage {
  followQuestion('follow-question'),
  zhCn('zh-CN'),
  en('en');

  final String wireName;

  const HostedTaskRewriteLanguage(this.wireName);
}

enum HostedTaskSummaryLanguage {
  followSource('follow-source'),
  zhCn('zh-CN'),
  en('en');

  final String wireName;

  const HostedTaskSummaryLanguage(this.wireName);
}

HostedTaskRewriteLanguage hostedTaskRewriteLanguageForIndex(int index) {
  return switch (index) {
    1 => HostedTaskRewriteLanguage.zhCn,
    2 => HostedTaskRewriteLanguage.en,
    _ => HostedTaskRewriteLanguage.followQuestion,
  };
}

HostedTaskSummaryLanguage hostedTaskSummaryLanguageForIndex(int index) {
  return switch (index) {
    1 => HostedTaskSummaryLanguage.zhCn,
    2 => HostedTaskSummaryLanguage.en,
    _ => HostedTaskSummaryLanguage.followSource,
  };
}

/// Builds a compact stable operation key without exposing article content in
/// the HTTP header. The generation anchor must come from persisted article
/// state so a process restart can reconcile the same logical stage run.
Future<String> buildHostedTaskOperationKey({
  required String articleId,
  required String stage,
  required String generation,
  required String model,
  required String language,
  required String content,
}) async {
  final contentDigest = await Sha256().hash(utf8.encode(content));
  final material = jsonEncode({
    'version': 1,
    'articleId': articleId,
    'stage': stage,
    'generation': generation,
    'model': model,
    'language': language,
    'contentSha256': _hex(contentDigest.bytes),
  });
  final digest = await Sha256().hash(utf8.encode(material));
  return 'memora-task-v4-${_hex(digest.bytes)}';
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

class HostedTaskRunResult {
  final String runId;
  final HostedTaskProfile profile;
  final int profileVersion;
  final int resultSchemaVersion;
  final Map<String, dynamic> result;
  final int? totalTokens;

  const HostedTaskRunResult({
    required this.runId,
    required this.profile,
    required this.profileVersion,
    required this.resultSchemaVersion,
    required this.result,
    this.totalTokens,
  });
}

class HostedTaskRunException implements Exception {
  final String code;
  final String message;
  final int? statusCode;
  final bool retryable;
  final String? runId;

  const HostedTaskRunException({
    required this.code,
    required this.message,
    this.statusCode,
    required this.retryable,
    this.runId,
  });

  @override
  String toString() => message;
}

abstract interface class HostedTaskGateway {
  Future<HostedTaskRunResult> run({
    required HostedTaskProfile profile,
    required Map<String, dynamic> input,
    required String idempotencyKey,
  });
}

/// Client for protocol-v4, server-owned, durable Memora Pi task profiles.
///
/// The request contains only the selected immutable profile, model, and typed
/// input. The backend owns the system prompt, result schema, tools, quota, and
/// Pi runtime. A stable Idempotency-Key is mandatory so an ambiguous 202 can be
/// reconciled without creating a second logical run.
class HostedTaskRunService implements HostedTaskGateway {
  static const Duration defaultRequestTimeout = Duration(seconds: 15);
  static const Duration defaultRunTimeout = Duration(minutes: 3);
  static const Duration defaultPollInterval = Duration(milliseconds: 350);

  final AuthSession? Function() _getSession;
  final Future<AuthSession?> Function() _refreshSession;
  final String model;
  final Duration requestTimeout;
  final Duration runTimeout;
  final Duration pollInterval;
  final void Function(int totalTokens)? onTokensUsed;

  const HostedTaskRunService({
    required AuthSession? Function() getSession,
    required Future<AuthSession?> Function() refreshSession,
    required this.model,
    this.requestTimeout = defaultRequestTimeout,
    this.runTimeout = defaultRunTimeout,
    this.pollInterval = defaultPollInterval,
    this.onTokensUsed,
  }) : _getSession = getSession,
       _refreshSession = refreshSession;

  bool get isConfigured =>
      BackendConfig.isConfigured && model.trim().isNotEmpty;

  @override
  Future<HostedTaskRunResult> run({
    required HostedTaskProfile profile,
    required Map<String, dynamic> input,
    required String idempotencyKey,
  }) async {
    final key = _validIdempotencyKey(idempotencyKey);
    if (!isConfigured) {
      throw const HostedTaskRunException(
        code: 'hosted_tasks_not_configured',
        message: 'Hosted Pi tasks are not configured.',
        retryable: true,
      );
    }
    var session = await _freshSession();
    final ownerUserId = session.user.id;
    _TaskSnapshot snapshot;
    try {
      snapshot = await _create(profile, input, key, session);
    } on _TaskHttpException catch (error) {
      if (error.statusCode != 401) throw _fromHttp(error);
      session = await _refreshForOwner(ownerUserId);
      try {
        snapshot = await _create(profile, input, key, session);
      } on _TaskHttpException catch (retryError) {
        throw _fromHttp(retryError);
      }
    } on TimeoutException {
      snapshot = await _reconcileAmbiguousCreate(
        key,
        profile,
        expectedOwnerUserId: ownerUserId,
        replay: () => _replayCreate(
          profile,
          input,
          key,
          expectedOwnerUserId: ownerUserId,
        ),
      );
    } on http.ClientException {
      snapshot = await _reconcileAmbiguousCreate(
        key,
        profile,
        expectedOwnerUserId: ownerUserId,
        replay: () => _replayCreate(
          profile,
          input,
          key,
          expectedOwnerUserId: ownerUserId,
        ),
      );
    }
    return _waitForResult(
      snapshot,
      profile,
      session,
      expectedOwnerUserId: ownerUserId,
    );
  }

  Future<HostedTaskRunResult> resume(
    String runId, {
    required HostedTaskProfile profile,
  }) async {
    var session = await _freshSession();
    final ownerUserId = session.user.id;
    _TaskSnapshot snapshot;
    try {
      snapshot = await _fetch(runId, session);
    } on _TaskHttpException catch (error) {
      if (error.statusCode != 401) throw _fromHttp(error, runId: runId);
      session = await _refreshForOwner(ownerUserId);
      try {
        snapshot = await _fetch(runId, session);
      } on _TaskHttpException catch (retryError) {
        throw _fromHttp(retryError, runId: runId);
      }
    }
    return _waitForResult(
      snapshot,
      profile,
      session,
      expectedOwnerUserId: ownerUserId,
    );
  }

  Future<HostedAgentRunLookup> reconcile(String idempotencyKey) async {
    final session = await _freshSession();
    return HostedAgentControlService(
      getSession: _getSession,
      refreshSession: _refreshSession,
      timeout: requestTimeout,
    ).lookupRunByIdempotencyKey(
      _validIdempotencyKey(idempotencyKey),
      expectedOwnerUserId: session.user.id,
    );
  }

  Future<void> cancel(String runId) async {
    final session = await _freshSession();
    await HostedAgentControlService(
      getSession: _getSession,
      refreshSession: _refreshSession,
      timeout: requestTimeout,
    ).cancelRun(runId, expectedOwnerUserId: session.user.id);
  }

  Future<HostedTaskRunResult> _waitForResult(
    _TaskSnapshot initial,
    HostedTaskProfile profile,
    AuthSession initialSession, {
    required String expectedOwnerUserId,
  }) async {
    var snapshot = initial;
    var session = initialSession;
    final deadline = DateTime.now().add(runTimeout);
    while (true) {
      final terminal = _terminalResult(snapshot, profile);
      if (terminal != null) {
        final tokens = terminal.totalTokens;
        if (tokens != null && tokens > 0) onTokensUsed?.call(tokens);
        return terminal;
      }
      if (snapshot.isTerminal) throw _terminalFailure(snapshot);
      if (!DateTime.now().isBefore(deadline)) {
        throw HostedTaskRunException(
          code: 'task_observation_timeout',
          message: 'Hosted Pi task is still running. It can be resumed later.',
          retryable: true,
          runId: snapshot.runId,
        );
      }
      if (pollInterval > Duration.zero) {
        await Future<void>.delayed(pollInterval);
      }
      try {
        snapshot = await _fetch(snapshot.runId, session);
      } on _TaskHttpException catch (error) {
        if (error.statusCode != 401) {
          throw _fromHttp(error, runId: snapshot.runId);
        }
        session = await _refreshForOwner(expectedOwnerUserId);
        try {
          snapshot = await _fetch(snapshot.runId, session);
        } on _TaskHttpException catch (retryError) {
          throw _fromHttp(retryError, runId: snapshot.runId);
        }
      } on TimeoutException {
        if (!DateTime.now().isBefore(deadline)) {
          throw HostedTaskRunException(
            code: 'task_observation_timeout',
            message:
                'Hosted Pi task is still running. It can be resumed later.',
            retryable: true,
            runId: snapshot.runId,
          );
        }
      } on http.ClientException {
        if (!DateTime.now().isBefore(deadline)) {
          throw HostedTaskRunException(
            code: 'task_observation_failed',
            message: 'Hosted Pi task could not be observed. Resume it later.',
            retryable: true,
            runId: snapshot.runId,
          );
        }
      }
    }
  }

  Future<_TaskSnapshot> _reconcileAmbiguousCreate(
    String idempotencyKey,
    HostedTaskProfile profile, {
    required String expectedOwnerUserId,
    required Future<_TaskSnapshot> Function() replay,
  }) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final lookup =
            await HostedAgentControlService(
              getSession: _getSession,
              refreshSession: _refreshSession,
              timeout: requestTimeout,
            ).lookupRunByIdempotencyKey(
              idempotencyKey,
              expectedOwnerUserId: expectedOwnerUserId,
            );
        final session = await _freshSession();
        final snapshot = await _fetch(lookup.runId, session);
        _validateTask(snapshot, profile);
        return snapshot;
      } on HostedAgentLookupException catch (error) {
        if (error.notFound && attempt < 2) {
          await Future<void>.delayed(
            Duration(milliseconds: 150 * (attempt + 1)),
          );
          continue;
        }
        if (error.notFound) return replay();
        throw HostedTaskRunException(
          code: 'task_reconciliation_failed',
          message: error.message,
          statusCode: error.statusCode,
          retryable: error.retryable,
        );
      }
    }
    return replay();
  }

  Future<_TaskSnapshot> _replayCreate(
    HostedTaskProfile profile,
    Map<String, dynamic> input,
    String idempotencyKey, {
    required String expectedOwnerUserId,
  }) async {
    var session = await _freshSession();
    if (session.user.id != expectedOwnerUserId) {
      throw const HostedTaskRunException(
        code: 'hosted_task_account_changed',
        message: 'The hosted Pi task account changed during reconciliation.',
        statusCode: 401,
        retryable: false,
      );
    }
    try {
      return await _create(profile, input, idempotencyKey, session);
    } on _TaskHttpException catch (error) {
      if (error.statusCode != 401) throw _fromHttp(error);
      session = await _refreshForOwner(expectedOwnerUserId);
      try {
        return await _create(profile, input, idempotencyKey, session);
      } on _TaskHttpException catch (retryError) {
        throw _fromHttp(retryError);
      }
    } on TimeoutException {
      throw const HostedTaskRunException(
        code: 'task_create_ambiguous',
        message:
            'Hosted Pi task creation is still ambiguous. Reconcile it later.',
        retryable: true,
      );
    } on http.ClientException {
      throw const HostedTaskRunException(
        code: 'task_create_ambiguous',
        message:
            'Hosted Pi task creation is still ambiguous. Reconcile it later.',
        retryable: true,
      );
    }
  }

  Future<AuthSession> _freshSession() async {
    var session = _getSession();
    if (session == null || !session.hasValidAccessToken) {
      session = await _refreshSession();
    }
    if (session == null) {
      throw const HostedTaskRunException(
        code: 'hosted_task_auth_required',
        message: 'Sign in to use hosted Pi tasks.',
        statusCode: 401,
        retryable: true,
      );
    }
    if (session.user.id.trim().isEmpty || session.device.id.trim().isEmpty) {
      throw const HostedTaskRunException(
        code: 'hosted_task_identity_invalid',
        message: 'The hosted Pi task identity is invalid.',
        statusCode: 401,
        retryable: false,
      );
    }
    return session;
  }

  Future<AuthSession> _refreshForOwner(String expectedOwnerUserId) async {
    final refreshed = await _refreshSession();
    if (refreshed == null || refreshed.user.id != expectedOwnerUserId) {
      throw const HostedTaskRunException(
        code: 'hosted_task_auth_expired',
        message: 'Your session has expired. Sign in again.',
        statusCode: 401,
        retryable: true,
      );
    }
    return refreshed;
  }

  Future<_TaskSnapshot> _create(
    HostedTaskProfile profile,
    Map<String, dynamic> input,
    String idempotencyKey,
    AuthSession session,
  ) {
    return _sendSnapshot(
      http.Request('POST', BackendConfig.uri('/ai/tasks/runs'))
        ..headers.addAll({
          'Authorization': 'Bearer ${session.accessToken}',
          'Accept': 'application/json',
          'Content-Type': 'application/json; charset=utf-8',
          'Idempotency-Key': idempotencyKey,
        })
        ..body = jsonEncode({
          'task': profile.wireName,
          'task_version': hostedTaskProfileVersion,
          'model': model.trim(),
          'input': input,
        }),
      acceptedStatuses: const {200, 202},
    );
  }

  Future<_TaskSnapshot> _fetch(String runId, AuthSession session) {
    final encoded = Uri.encodeComponent(runId.trim());
    return _sendSnapshot(
      http.Request('GET', BackendConfig.uri('/ai/runs/$encoded'))
        ..headers.addAll({
          'Authorization': 'Bearer ${session.accessToken}',
          'Accept': 'application/json',
        }),
      acceptedStatuses: const {200},
    );
  }

  Future<_TaskSnapshot> _sendSnapshot(
    http.Request request, {
    required Set<int> acceptedStatuses,
  }) async {
    final client = http.Client();
    try {
      final response = await client.send(request).timeout(requestTimeout);
      final body = await response.stream.bytesToString().timeout(
        requestTimeout,
      );
      if (!acceptedStatuses.contains(response.statusCode)) {
        throw _TaskHttpException(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Hosted Pi task returned invalid JSON.');
      }
      return _TaskSnapshot.fromJson(decoded);
    } finally {
      client.close();
    }
  }

  HostedTaskRunResult? _terminalResult(
    _TaskSnapshot snapshot,
    HostedTaskProfile profile,
  ) {
    if (snapshot.status != 'completed') return null;
    _validateTask(snapshot, profile);
    final result = snapshot.result;
    if (result == null ||
        result['schemaVersion'] != hostedTaskResultSchemaVersion) {
      throw HostedTaskRunException(
        code: 'invalid_task_result',
        message: 'Hosted Pi task returned an invalid typed result.',
        retryable: true,
        runId: snapshot.runId,
      );
    }
    return HostedTaskRunResult(
      runId: snapshot.runId,
      profile: profile,
      profileVersion: hostedTaskProfileVersion,
      resultSchemaVersion: hostedTaskResultSchemaVersion,
      result: Map<String, dynamic>.unmodifiable(result),
      totalTokens: snapshot.totalTokens,
    );
  }

  void _validateTask(_TaskSnapshot snapshot, HostedTaskProfile profile) {
    if (snapshot.taskId != profile.wireName ||
        snapshot.taskVersion != hostedTaskProfileVersion ||
        snapshot.resultSchemaVersion != hostedTaskResultSchemaVersion) {
      throw HostedTaskRunException(
        code: 'task_profile_mismatch',
        message: 'Hosted Pi task result does not match the requested profile.',
        retryable: false,
        runId: snapshot.runId,
      );
    }
  }

  HostedTaskRunException _terminalFailure(_TaskSnapshot snapshot) {
    return HostedTaskRunException(
      code:
          snapshot.errorCode ??
          (snapshot.status == 'cancelled' ? 'task_cancelled' : 'task_failed'),
      message:
          snapshot.errorMessage ??
          (snapshot.status == 'cancelled'
              ? 'Hosted Pi task was cancelled.'
              : 'Hosted Pi task failed.'),
      retryable: false,
      runId: snapshot.runId,
    );
  }

  HostedTaskRunException _fromHttp(_TaskHttpException error, {String? runId}) {
    final decoded = _decodeError(error.body);
    final code = decoded.$1;
    final message = decoded.$2;
    final status = error.statusCode;
    return HostedTaskRunException(
      code: code,
      message: message,
      statusCode: status,
      retryable:
          status == 401 ||
          status == 408 ||
          status == 425 ||
          status == 429 ||
          status >= 500,
      runId: runId,
    );
  }

  static (String, String) _decodeError(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final raw = decoded['error'];
        if (raw is Map) {
          return (
            (raw['code'] ?? 'hosted_task_http_error').toString(),
            (raw['message'] ?? raw['error'] ?? 'Hosted Pi task failed.')
                .toString(),
          );
        }
        return (
          (decoded['code'] ?? 'hosted_task_http_error').toString(),
          (decoded['message'] ?? decoded['error'] ?? 'Hosted Pi task failed.')
              .toString(),
        );
      }
    } catch (_) {}
    return ('hosted_task_http_error', 'Hosted Pi task request failed.');
  }

  static String _validIdempotencyKey(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > 128) {
      throw const HostedTaskRunException(
        code: 'invalid_idempotency_key',
        message: 'Hosted Pi tasks require a 1-128 character Idempotency-Key.',
        retryable: false,
      );
    }
    return normalized;
  }
}

class _TaskSnapshot {
  static const Set<String> _statuses = {
    'queued',
    'running',
    'waiting_client',
    'completed',
    'failed',
    'cancelled',
  };

  final String runId;
  final String status;
  final String? taskId;
  final int? taskVersion;
  final int? resultSchemaVersion;
  final Map<String, dynamic>? result;
  final String? errorCode;
  final String? errorMessage;
  final int? totalTokens;

  const _TaskSnapshot({
    required this.runId,
    required this.status,
    required this.taskId,
    required this.taskVersion,
    required this.resultSchemaVersion,
    required this.result,
    required this.errorCode,
    required this.errorMessage,
    required this.totalTokens,
  });

  bool get isTerminal =>
      status == 'completed' || status == 'failed' || status == 'cancelled';

  factory _TaskSnapshot.fromJson(Map<String, dynamic> json) {
    final runId = (json['id'] ?? json['runId'] ?? '').toString().trim();
    final status = (json['status'] ?? '').toString().trim();
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(runId) ||
        !_statuses.contains(status)) {
      throw const FormatException('Hosted Pi task returned an invalid run.');
    }
    final task = json['task'];
    final taskMap = task is Map ? Map<String, dynamic>.from(task) : null;
    final rawResult = json['result'];
    final result = rawResult is Map
        ? Map<String, dynamic>.from(rawResult)
        : null;
    final error = json['error'];
    final errorMap = error is Map ? Map<String, dynamic>.from(error) : null;
    final usage = json['usage'];
    final usageMap = usage is Map ? Map<String, dynamic>.from(usage) : null;
    return _TaskSnapshot(
      runId: runId,
      status: status,
      taskId: taskMap?['id']?.toString(),
      taskVersion: (taskMap?['version'] as num?)?.toInt(),
      resultSchemaVersion: (taskMap?['resultSchemaVersion'] as num?)?.toInt(),
      result: result,
      errorCode: errorMap?['code']?.toString(),
      errorMessage: errorMap?['message']?.toString(),
      totalTokens: (usageMap?['totalTokens'] as num?)?.toInt(),
    );
  }
}

class _TaskHttpException implements Exception {
  final int statusCode;
  final String body;

  const _TaskHttpException(this.statusCode, this.body);
}
