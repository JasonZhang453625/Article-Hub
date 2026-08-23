import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import '../../config/backend_config.dart';
import 'auth_service.dart';
import 'hosted_agent_service.dart';
import 'hosted_task_run_store.dart';

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

/// Builds a compact operation key without exposing article content in the HTTP
/// header. Content is intentionally excluded: the persisted logical generation
/// and side-store binding keep a running task stable even when a page changes
/// before a process-death recovery.
Future<String> buildHostedTaskOperationKey({
  required String articleId,
  required String stage,
  required String generation,
  required String model,
  required String language,
}) async {
  final material = jsonEncode({
    'version': 2,
    'articleId': articleId,
    'stage': stage,
    'generation': generation,
    'model': model,
    'language': language,
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

class HostedTaskOperationContext {
  final String articleId;
  final String generation;
  final String stage;
  final String? planDigest;

  const HostedTaskOperationContext({
    required this.articleId,
    required this.generation,
    required this.stage,
    this.planDigest,
  });

  HostedTaskOperationContext withPlanDigest(String digest) =>
      HostedTaskOperationContext(
        articleId: articleId,
        generation: generation,
        stage: stage,
        planDigest: digest,
      );

  HostedTaskOperationContext child(String childStage) =>
      HostedTaskOperationContext(
        articleId: articleId,
        generation: generation,
        stage: childStage,
        planDigest: planDigest,
      );
}

abstract interface class HostedTaskGateway {
  Future<HostedTaskRunResult> run({
    required HostedTaskProfile profile,
    required Map<String, dynamic> input,
    required String idempotencyKey,
    HostedTaskOperationContext? operation,
  });
}

/// Lets a typed consumer reject a completed result after profile-level parsing.
///
/// The durable binding must become non-replayable before the caller retries,
/// otherwise a malformed completed result would be fetched forever.
abstract interface class HostedTaskResultInvalidator {
  Future<void> invalidateResult({
    required HostedTaskRunResult result,
    required String idempotencyKey,
    HostedTaskOperationContext? operation,
  });
}

abstract interface class HostedTaskRequestPreflight {
  int get maxBodyBytes;

  void validateRequest({
    required HostedTaskProfile profile,
    required Map<String, dynamic> input,
  });
}

/// Client for protocol-v4, server-owned, durable Memora Pi task profiles.
///
/// The request contains only the selected immutable profile, model, and typed
/// input. The backend owns the system prompt, result schema, tools, quota, and
/// Pi runtime. A stable Idempotency-Key is mandatory so an ambiguous 202 can be
/// reconciled without creating a second logical run.
class HostedTaskRunService
    implements
        HostedTaskGateway,
        HostedTaskRequestPreflight,
        HostedTaskResultInvalidator {
  static const Duration defaultRequestTimeout = Duration(seconds: 15);
  static const Duration defaultRunTimeout = Duration(minutes: 3);
  static const Duration defaultPollInterval = Duration(seconds: 1);
  static const Duration defaultMaxPollInterval = Duration(seconds: 4);

  final AuthSession? Function() _getSession;
  final Future<AuthSession?> Function() _refreshSession;
  final String model;
  final Duration requestTimeout;
  final Duration runTimeout;
  final Duration pollInterval;
  final Duration maxPollInterval;
  @override
  final int maxBodyBytes;
  final HostedTaskRunStore? runStore;
  final double Function() _jitterSource;
  final Future<void> Function(Duration) _delay;
  final void Function(int totalTokens)? onTokensUsed;

  HostedTaskRunService({
    required AuthSession? Function() getSession,
    required Future<AuthSession?> Function() refreshSession,
    required this.model,
    this.requestTimeout = defaultRequestTimeout,
    this.runTimeout = defaultRunTimeout,
    this.pollInterval = defaultPollInterval,
    this.maxPollInterval = defaultMaxPollInterval,
    required this.maxBodyBytes,
    this.runStore,
    double Function()? jitterSource,
    Future<void> Function(Duration)? delay,
    this.onTokensUsed,
  }) : _getSession = getSession,
       _refreshSession = refreshSession,
       _jitterSource = jitterSource ?? _defaultJitter,
       _delay = delay ?? _defaultDelay;

  bool get isConfigured =>
      BackendConfig.isConfigured && model.trim().isNotEmpty;

  @override
  Future<HostedTaskRunResult> run({
    required HostedTaskProfile profile,
    required Map<String, dynamic> input,
    required String idempotencyKey,
    HostedTaskOperationContext? operation,
  }) async {
    final logicalKey = _validIdempotencyKey(idempotencyKey);
    final body = _requestBody(profile, input);
    if (!isConfigured) {
      throw const HostedTaskRunException(
        code: 'hosted_tasks_not_configured',
        message: 'Hosted Pi tasks are not configured.',
        retryable: true,
      );
    }
    var session = await _freshSession();
    final ownerUserId = session.user.id;
    final scopeHash = await _scopeHash(session);
    final inputDigest = await _sha256(body);
    var binding = operation == null
        ? await runStore?.readBinding(scopeHash, logicalKey)
        : await runStore?.readBindingForOperation(
            scopeHash: scopeHash,
            articleId: operation.articleId,
            generation: operation.generation,
            stage: operation.stage,
          );
    final key =
        binding?.idempotencyKey ??
        (operation == null || runStore == null
            ? logicalKey
            : await _effectiveOperationKey(logicalKey, inputDigest));
    if (binding != null) {
      try {
        _validateBinding(binding, profile, operation);
      } on HostedTaskRunException {
        await _markBindingAbandoned(scopeHash, binding);
        rethrow;
      }
      final boundRunId = binding.runId?.trim();
      if (boundRunId != null && boundRunId.isNotEmpty) {
        try {
          final fetched = await _fetchWithAuth(
            boundRunId,
            session,
            expectedOwnerUserId: ownerUserId,
          );
          session = fetched.session;
          binding = await _persistSnapshot(
            scopeHash,
            binding,
            fetched.snapshot,
          );
          return _waitForResult(
            fetched.snapshot,
            profile,
            session,
            expectedOwnerUserId: ownerUserId,
            scopeHash: scopeHash,
            binding: binding,
          );
        } on TimeoutException {
          throw HostedTaskRunException(
            code: 'task_observation_timeout',
            message: 'Hosted Pi task is still running. Resume it later.',
            retryable: true,
            runId: boundRunId,
          );
        } on http.ClientException {
          throw HostedTaskRunException(
            code: 'task_observation_failed',
            message: 'Hosted Pi task could not be observed. Resume it later.',
            retryable: true,
            runId: boundRunId,
          );
        } on _TaskHttpException catch (error) {
          throw _fromHttp(error, runId: boundRunId);
        }
      }
      if (binding.inputDigest != inputDigest) {
        return _resumeChangedAmbiguousCreate(
          binding,
          profile,
          session,
          scopeHash: scopeHash,
          expectedOwnerUserId: ownerUserId,
        );
      }
      late final _TaskSnapshot recovered;
      try {
        recovered = await _reconcileAmbiguousCreate(
          key,
          profile,
          expectedOwnerUserId: ownerUserId,
          replay: () =>
              _replayCreate(body, key, expectedOwnerUserId: ownerUserId),
        );
      } on HostedTaskRunException catch (error) {
        if (!error.retryable) {
          await _markBindingAbandoned(scopeHash, binding);
        }
        rethrow;
      }
      binding = await _persistSnapshot(scopeHash, binding, recovered);
      return _waitForResult(
        recovered,
        profile,
        session,
        expectedOwnerUserId: ownerUserId,
        scopeHash: scopeHash,
        binding: binding,
      );
    } else {
      binding = HostedTaskRunBinding(
        idempotencyKey: key,
        profile: profile.wireName,
        model: model.trim(),
        inputDigest: inputDigest,
        planDigest: operation?.planDigest,
        articleId: operation?.articleId,
        generation: operation?.generation,
        stage: operation?.stage ?? profile.wireName,
        runId: null,
        state: HostedTaskBindingState.creating,
        updatedAt: DateTime.now().toUtc(),
      );
      await runStore?.writeBinding(scopeHash, binding);
    }

    _TaskSnapshot snapshot;
    try {
      final created = await _createWithAuth(
        body,
        key,
        session,
        expectedOwnerUserId: ownerUserId,
      );
      snapshot = created.snapshot;
      session = created.session;
    } on _TaskHttpException catch (error) {
      final failure = _fromHttp(error);
      if (!failure.retryable) {
        await _markBindingAbandoned(scopeHash, binding);
      }
      throw failure;
    } on TimeoutException {
      try {
        snapshot = await _reconcileAmbiguousCreate(
          key,
          profile,
          expectedOwnerUserId: ownerUserId,
          replay: () =>
              _replayCreate(body, key, expectedOwnerUserId: ownerUserId),
        );
      } on HostedTaskRunException catch (error) {
        if (!error.retryable) {
          await _markBindingAbandoned(scopeHash, binding);
        }
        rethrow;
      }
    } on http.ClientException {
      try {
        snapshot = await _reconcileAmbiguousCreate(
          key,
          profile,
          expectedOwnerUserId: ownerUserId,
          replay: () =>
              _replayCreate(body, key, expectedOwnerUserId: ownerUserId),
        );
      } on HostedTaskRunException catch (error) {
        if (!error.retryable) {
          await _markBindingAbandoned(scopeHash, binding);
        }
        rethrow;
      }
    }
    binding = await _persistSnapshot(scopeHash, binding, snapshot);
    return _waitForResult(
      snapshot,
      profile,
      session,
      expectedOwnerUserId: ownerUserId,
      scopeHash: scopeHash,
      binding: binding,
    );
  }

  Future<HostedTaskRunResult> resume(
    String runId, {
    required HostedTaskProfile profile,
  }) async {
    var session = await _freshSession();
    final ownerUserId = session.user.id;
    final scopeHash = await _scopeHash(session);
    try {
      final fetched = await _fetchWithAuth(
        runId,
        session,
        expectedOwnerUserId: ownerUserId,
      );
      session = fetched.session;
      return _waitForResult(
        fetched.snapshot,
        profile,
        session,
        expectedOwnerUserId: ownerUserId,
        scopeHash: scopeHash,
      );
    } on TimeoutException {
      throw HostedTaskRunException(
        code: 'task_observation_timeout',
        message: 'Hosted Pi task is still running. Resume it later.',
        retryable: true,
        runId: runId,
      );
    } on http.ClientException {
      throw HostedTaskRunException(
        code: 'task_observation_failed',
        message: 'Hosted Pi task could not be observed. Resume it later.',
        retryable: true,
        runId: runId,
      );
    } on _TaskHttpException catch (error) {
      throw _fromHttp(error, runId: runId);
    }
  }

  @override
  void validateRequest({
    required HostedTaskProfile profile,
    required Map<String, dynamic> input,
  }) {
    _requestBody(profile, input);
  }

  Future<bool> hasReplayableBindings({
    required String articleId,
    required String generation,
  }) async {
    final store = runStore;
    if (store == null) return false;
    final session = await _freshSession();
    return store.hasReplayableBindings(
      scopeHash: await _scopeHash(session),
      articleId: articleId,
      generation: generation,
    );
  }

  Future<void> finalizeGeneration({
    required String articleId,
    required String generation,
  }) async {
    final store = runStore;
    if (store == null) return;
    final session = await _freshSession();
    await store.finalizeGeneration(
      scopeHash: await _scopeHash(session),
      articleId: articleId,
      generation: generation,
    );
  }

  @override
  Future<void> invalidateResult({
    required HostedTaskRunResult result,
    required String idempotencyKey,
    HostedTaskOperationContext? operation,
  }) async {
    final store = runStore;
    if (store == null) return;
    final session = await _freshSession();
    final scopeHash = await _scopeHash(session);
    final binding = operation == null
        ? await store.readBinding(
            scopeHash,
            _validIdempotencyKey(idempotencyKey),
          )
        : await store.readBindingForOperation(
            scopeHash: scopeHash,
            articleId: operation.articleId,
            generation: operation.generation,
            stage: operation.stage,
          );
    if (binding == null || binding.runId?.trim() != result.runId.trim()) {
      return;
    }
    await _markBindingAbandoned(scopeHash, binding);
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
    required String scopeHash,
    HostedTaskRunBinding? binding,
  }) async {
    var snapshot = initial;
    var session = initialSession;
    final deadline = DateTime.now().add(runTimeout);
    var pollAttempt = 0;
    while (true) {
      if (binding != null) {
        binding = await _persistSnapshot(scopeHash, binding, snapshot);
      }
      HostedTaskRunResult? terminal;
      try {
        terminal = _terminalResult(snapshot, profile);
      } on HostedTaskRunException {
        if (binding != null && snapshot.status == 'completed') {
          await _markBindingAbandoned(scopeHash, binding);
        }
        rethrow;
      }
      if (terminal != null) {
        final tokens = terminal.totalTokens;
        if (tokens != null && tokens > 0) {
          final firstObservation =
              await runStore?.recordTokenUsage(
                scopeHash,
                terminal.runId,
                tokens,
              ) ??
              true;
          if (firstObservation) onTokensUsed?.call(tokens);
        }
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
        await _delay(_pollDelay(pollAttempt));
      }
      pollAttempt++;
      try {
        final fetched = await _fetchWithAuth(
          snapshot.runId,
          session,
          expectedOwnerUserId: expectedOwnerUserId,
        );
        snapshot = fetched.snapshot;
        session = fetched.session;
      } on _TaskHttpException catch (error) {
        final failure = _fromHttp(error, runId: snapshot.runId);
        if (!failure.retryable || !DateTime.now().isBefore(deadline)) {
          throw failure;
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
    final existing = await _lookupAmbiguousCreate(
      idempotencyKey,
      profile,
      expectedOwnerUserId: expectedOwnerUserId,
    );
    return existing ?? replay();
  }

  Future<_TaskSnapshot?> _lookupAmbiguousCreate(
    String idempotencyKey,
    HostedTaskProfile profile, {
    required String expectedOwnerUserId,
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
        final snapshot = (await _fetchWithAuth(
          lookup.runId,
          session,
          expectedOwnerUserId: expectedOwnerUserId,
        )).snapshot;
        _validateTask(snapshot, profile);
        return snapshot;
      } on HostedAgentLookupException catch (error) {
        if (error.notFound && attempt < 2) {
          await _delay(_reconciliationDelay(attempt));
          continue;
        }
        if (error.notFound) return null;
        if (error.retryable && attempt < 2) {
          await _delay(_reconciliationDelay(attempt));
          continue;
        }
        throw HostedTaskRunException(
          code: 'task_reconciliation_failed',
          message: error.message,
          statusCode: error.statusCode,
          retryable: error.retryable,
        );
      } on TimeoutException {
        if (attempt < 2) {
          await _delay(_reconciliationDelay(attempt));
          continue;
        }
        throw const HostedTaskRunException(
          code: 'task_reconciliation_timeout',
          message: 'Hosted Pi task reconciliation timed out. Retry later.',
          retryable: true,
        );
      } on http.ClientException {
        if (attempt < 2) {
          await _delay(_reconciliationDelay(attempt));
          continue;
        }
        throw const HostedTaskRunException(
          code: 'task_reconciliation_failed',
          message: 'Hosted Pi task reconciliation failed. Retry later.',
          retryable: true,
        );
      } on _TaskHttpException catch (error) {
        final failure = _fromHttp(error);
        if (failure.retryable && attempt < 2) {
          await _delay(_reconciliationDelay(attempt));
          continue;
        }
        throw failure;
      }
    }
    return null;
  }

  Future<HostedTaskRunResult> _resumeChangedAmbiguousCreate(
    HostedTaskRunBinding binding,
    HostedTaskProfile profile,
    AuthSession session, {
    required String scopeHash,
    required String expectedOwnerUserId,
  }) async {
    final snapshot = await _lookupAmbiguousCreate(
      binding.idempotencyKey,
      profile,
      expectedOwnerUserId: expectedOwnerUserId,
    );
    if (snapshot == null) {
      await runStore?.writeBinding(
        scopeHash,
        binding.copyWith(
          state: HostedTaskBindingState.abandoned,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      throw const HostedTaskRunException(
        code: 'task_input_changed_during_recovery',
        message:
            'The article changed while task creation was being reconciled. '
            'Retry to start a new generation.',
        retryable: true,
      );
    }
    final persisted = await _persistSnapshot(scopeHash, binding, snapshot);
    return _waitForResult(
      snapshot,
      profile,
      session,
      expectedOwnerUserId: expectedOwnerUserId,
      scopeHash: scopeHash,
      binding: persisted,
    );
  }

  Future<_TaskSnapshot> _replayCreate(
    String body,
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
      return (await _createWithAuth(
        body,
        idempotencyKey,
        session,
        expectedOwnerUserId: expectedOwnerUserId,
      )).snapshot;
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
    } on _TaskHttpException catch (error) {
      throw _fromHttp(error);
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

  Future<({_TaskSnapshot snapshot, AuthSession session})> _createWithAuth(
    String body,
    String idempotencyKey,
    AuthSession session, {
    required String expectedOwnerUserId,
  }) async {
    try {
      return (
        snapshot: await _create(body, idempotencyKey, session),
        session: session,
      );
    } on _TaskHttpException catch (error) {
      if (error.statusCode != 401) rethrow;
      final refreshed = await _refreshForOwner(expectedOwnerUserId);
      return (
        snapshot: await _create(body, idempotencyKey, refreshed),
        session: refreshed,
      );
    }
  }

  Future<({_TaskSnapshot snapshot, AuthSession session})> _fetchWithAuth(
    String runId,
    AuthSession session, {
    required String expectedOwnerUserId,
  }) async {
    try {
      return (snapshot: await _fetch(runId, session), session: session);
    } on _TaskHttpException catch (error) {
      if (error.statusCode != 401) rethrow;
      final refreshed = await _refreshForOwner(expectedOwnerUserId);
      return (snapshot: await _fetch(runId, refreshed), session: refreshed);
    }
  }

  Future<_TaskSnapshot> _create(
    String body,
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
        ..body = body,
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

  String _requestBody(HostedTaskProfile profile, Map<String, dynamic> input) {
    if (maxBodyBytes <= 0) {
      throw const HostedTaskRunException(
        code: 'hosted_task_limit_invalid',
        message: 'Hosted Pi task request limits are unavailable.',
        retryable: true,
      );
    }
    final body = jsonEncode({
      'task': profile.wireName,
      'task_version': hostedTaskProfileVersion,
      'model': model.trim(),
      'input': input,
    });
    final encodedBytes = utf8.encode(body).length;
    if (encodedBytes > maxBodyBytes) {
      throw HostedTaskRunException(
        code: 'hosted_task_request_too_large',
        message:
            'Hosted Pi task request is $encodedBytes bytes; the server limit '
            'is $maxBodyBytes bytes.',
        statusCode: 413,
        retryable: false,
      );
    }
    return body;
  }

  Future<String> _scopeHash(AuthSession session) => _sha256(
    'hosted-task-scope-v1\u0000${session.user.id}\u0000${session.device.id}',
  );

  static Future<String> _effectiveOperationKey(
    String logicalKey,
    String inputDigest,
  ) async {
    final digest = await _sha256(
      'hosted-task-effective-key-v1\u0000$logicalKey\u0000$inputDigest',
    );
    return 'memora-task-v4-$digest';
  }

  static Future<String> _sha256(String value) async {
    final digest = await Sha256().hash(utf8.encode(value));
    return _hex(digest.bytes);
  }

  void _validateBinding(
    HostedTaskRunBinding binding,
    HostedTaskProfile profile,
    HostedTaskOperationContext? operation,
  ) {
    final operationMatches =
        operation == null ||
        (binding.articleId == operation.articleId &&
            binding.generation == operation.generation &&
            binding.stage == operation.stage);
    final expectedPlanDigest = operation?.planDigest;
    final planMatches =
        expectedPlanDigest == null || binding.planDigest == expectedPlanDigest;
    if (binding.profile != profile.wireName ||
        binding.model != model.trim() ||
        !operationMatches ||
        !planMatches) {
      throw HostedTaskRunException(
        code: !planMatches
            ? 'hosted_task_summary_plan_mismatch'
            : 'hosted_task_binding_mismatch',
        message: !planMatches
            ? 'The article changed during hosted Pi summarization. Retry to '
                  'start a consistent summary plan.'
            : 'Hosted Pi task recovery metadata does not match the request.',
        retryable: !planMatches,
        runId: binding.runId,
      );
    }
  }

  Future<HostedTaskRunBinding> _persistSnapshot(
    String scopeHash,
    HostedTaskRunBinding binding,
    _TaskSnapshot snapshot,
  ) async {
    final updated = binding.copyWith(
      runId: snapshot.runId,
      state: switch (snapshot.status) {
        'queued' => HostedTaskBindingState.queued,
        'running' => HostedTaskBindingState.running,
        'waiting_client' => HostedTaskBindingState.waitingClient,
        'completed' => HostedTaskBindingState.completed,
        'failed' => HostedTaskBindingState.failed,
        'cancelled' => HostedTaskBindingState.cancelled,
        _ => HostedTaskBindingState.abandoned,
      },
      updatedAt: DateTime.now().toUtc(),
    );
    await runStore?.writeBinding(scopeHash, updated);
    return updated;
  }

  Future<void> _markBindingAbandoned(
    String scopeHash,
    HostedTaskRunBinding binding,
  ) {
    return runStore?.writeBinding(
          scopeHash,
          binding.copyWith(
            state: HostedTaskBindingState.abandoned,
            updatedAt: DateTime.now().toUtc(),
          ),
        ) ??
        Future<void>.value();
  }

  Duration _pollDelay(int attempt) {
    if (pollInterval <= Duration.zero) return Duration.zero;
    final maximum = maxPollInterval < pollInterval
        ? pollInterval
        : maxPollInterval;
    final exponent = attempt.clamp(0, 10);
    final multiplier = pow(2, exponent).toDouble();
    final rawMilliseconds = pollInterval.inMilliseconds * multiplier;
    final cappedMilliseconds = min(
      rawMilliseconds,
      maximum.inMilliseconds.toDouble(),
    );
    final jitter = 0.8 + (_jitterSource().clamp(0.0, 1.0) * 0.4);
    return Duration(
      milliseconds: max(1, (cappedMilliseconds * jitter).round()),
    );
  }

  Duration _reconciliationDelay(int attempt) {
    final multiplier = pow(2, attempt.clamp(0, 5)).toDouble();
    final jitter = 0.8 + (_jitterSource().clamp(0.0, 1.0) * 0.4);
    return Duration(milliseconds: max(1, (150 * multiplier * jitter).round()));
  }

  static final Random _random = Random.secure();
  static double _defaultJitter() => _random.nextDouble();
  static Future<void> _defaultDelay(Duration duration) =>
      Future<void>.delayed(duration);

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
