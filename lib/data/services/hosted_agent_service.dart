import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../config/backend_config.dart';
import '../models/ai_image_input.dart';
import '../models/ai_thinking_level.dart';
import 'ai_service.dart';
import 'auth_service.dart';

const int maxHostedAgentImages = 4;
const int maxHostedAgentImageBytes = 5 * 1024 * 1024;
const int maxHostedAgentImageTotalBytes = 12 * 1024 * 1024;
const int maxHostedAgentBodyBytes = 18 * 1024 * 1024;
const Set<String> hostedAgentImageMimeTypes = {
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
};

class HostedAgentSource {
  final String id;
  final String title;
  final String url;
  final String content;
  final double score;

  const HostedAgentSource({
    required this.id,
    required this.title,
    required this.url,
    required this.content,
    required this.score,
  });

  factory HostedAgentSource.fromJson(Map<String, dynamic> json) {
    return HostedAgentSource(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      content: (json['content'] ?? '').toString(),
      score: (json['score'] as num?)?.toDouble() ?? 0,
    );
  }
}

class HostedAgentEvent {
  final String type;
  final Map<String, dynamic> data;

  const HostedAgentEvent({required this.type, required this.data});
}

/// A failure while reconnecting to an already-created durable Agent run.
///
/// Retryable failures must never be interpreted as a terminal model outcome:
/// the server run may still be progressing while this device is offline.
class HostedAgentResumeException implements Exception {
  final String message;
  final int? statusCode;
  final bool retryable;

  const HostedAgentResumeException({
    required this.message,
    this.statusCode,
    required this.retryable,
  });

  @override
  String toString() => message;
}

/// A control-plane failure while asking the backend to cancel a durable run.
///
/// Cancellation is deliberately separate from the stream state below. A
/// failed control request must not overwrite `lastError`, `lastRunStatus`, or
/// the event cursor of a concurrently observed [HostedAgentService] run.
class HostedAgentCancelException implements Exception {
  final String message;
  final int? statusCode;
  final bool retryable;

  const HostedAgentCancelException({
    required this.message,
    this.statusCode,
    required this.retryable,
  });

  @override
  String toString() => message;
}

/// Result of the read-only idempotency lookup used after an ambiguous create.
class HostedAgentRunLookup {
  static const Set<String> supportedStatuses = {
    'queued',
    'running',
    'waiting_client',
    'completed',
    'failed',
    'cancelled',
  };

  final String runId;
  final String status;

  const HostedAgentRunLookup({required this.runId, required this.status});

  factory HostedAgentRunLookup.fromJson(Map<String, dynamic> json) {
    final runId = (json['id'] ?? json['runId'] ?? '').toString().trim();
    final status = (json['status'] ?? '').toString().trim();
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(runId) ||
        !supportedStatuses.contains(status)) {
      throw const FormatException(
        'Hosted Agent returned an invalid reconciliation response.',
      );
    }
    return HostedAgentRunLookup(runId: runId, status: status);
  }
}

/// A read-only idempotency lookup failure.
///
/// [notFound] is deliberately separate from [retryable]. A 404 can prove
/// absence only after the caller's short visibility backoff; transport and
/// authentication failures must leave the local attempt pending.
class HostedAgentLookupException implements Exception {
  final String message;
  final int? statusCode;
  final bool retryable;
  final bool notFound;
  final bool accountMismatch;

  const HostedAgentLookupException({
    required this.message,
    this.statusCode,
    required this.retryable,
    this.notFound = false,
    this.accountMismatch = false,
  });

  @override
  String toString() => message;
}

class HostedAgentInputException implements Exception {
  final String code;
  final String message;

  const HostedAgentInputException({required this.code, required this.message});

  @override
  String toString() => message;
}

/// Stateless control-plane client for durable hosted Agent runs.
///
/// Each request owns its HTTP client and all response state stays local to the
/// call. This lets Stop/Delete run concurrently with an SSE stream without
/// resetting or contaminating the stateful [HostedAgentService] observer.
class HostedAgentControlService {
  static const Duration defaultTimeout = Duration(seconds: 10);

  final AuthSession? Function() _getSession;
  final Future<AuthSession?> Function() _refreshSession;
  final Duration timeout;

  const HostedAgentControlService({
    required AuthSession? Function() getSession,
    required Future<AuthSession?> Function() refreshSession,
    this.timeout = defaultTimeout,
  }) : _getSession = getSession,
       _refreshSession = refreshSession;

  /// Finds the run owned by this account and [idempotencyKey] through the
  /// backend's read-only `GET /ai/runs` control endpoint.
  ///
  /// This method never replays `POST /ai/runs`: once a create may have been
  /// accepted, only this lookup can safely resolve the missing 202 response.
  Future<HostedAgentRunLookup> lookupRunByIdempotencyKey(
    String idempotencyKey, {
    String? expectedOwnerUserId,
  }) async {
    final normalizedKey = idempotencyKey.trim();
    if (normalizedKey.isEmpty || normalizedKey.length > 200) {
      throw const HostedAgentLookupException(
        message: 'Hosted Agent reconciliation key is invalid.',
        retryable: false,
      );
    }

    AuthSession? session;
    try {
      session = _getSession();
      if (session == null || !session.hasValidAccessToken) {
        session = await _refreshSession();
      }
    } catch (error) {
      throw HostedAgentLookupException(
        message: 'Hosted Agent authentication failed: $error',
        statusCode: 401,
        retryable: true,
      );
    }
    if (session == null) {
      throw const HostedAgentLookupException(
        message: 'Sign in to reconcile hosted AI.',
        statusCode: 401,
        retryable: true,
      );
    }
    if (expectedOwnerUserId != null && session.user.id != expectedOwnerUserId) {
      throw const HostedAgentLookupException(
        message: 'The hosted AI account does not own this pending attempt.',
        statusCode: 401,
        retryable: false,
        accountMismatch: true,
      );
    }

    var activeSession = session;
    var refreshedAfterUnauthorized = false;
    while (true) {
      try {
        return await _getRunByIdempotencyKey(activeSession, normalizedKey);
      } on _RunHttpException catch (error) {
        if (error.statusCode == 401 && !refreshedAfterUnauthorized) {
          refreshedAfterUnauthorized = true;
          AuthSession? refreshed;
          try {
            refreshed = await _refreshSession();
          } catch (refreshError) {
            throw HostedAgentLookupException(
              message: 'Hosted Agent authentication failed: $refreshError',
              statusCode: 401,
              retryable: true,
            );
          }
          if (refreshed != null) {
            if (expectedOwnerUserId != null &&
                refreshed.user.id != expectedOwnerUserId) {
              throw const HostedAgentLookupException(
                message:
                    'The hosted AI account does not own this pending attempt.',
                statusCode: 401,
                retryable: false,
                accountMismatch: true,
              );
            }
            activeSession = refreshed;
            continue;
          }
        }
        final statusCode = error.statusCode;
        throw HostedAgentLookupException(
          message:
              'HTTP $statusCode: '
              '${HostedAgentService._responseError(error.body)}',
          statusCode: statusCode,
          retryable:
              statusCode == 401 ||
              statusCode == 408 ||
              statusCode == 425 ||
              statusCode == 429 ||
              statusCode >= 500,
          notFound: statusCode == 404,
        );
      } on TimeoutException {
        throw HostedAgentLookupException(
          message:
              'Hosted Agent reconciliation timed out after ${timeout.inSeconds} seconds',
          retryable: true,
        );
      } on http.ClientException catch (error) {
        throw HostedAgentLookupException(
          message: 'Hosted Agent reconciliation request failed: $error',
          retryable: true,
        );
      } on FormatException catch (error) {
        throw HostedAgentLookupException(
          message: error.message,
          retryable: true,
        );
      }
    }
  }

  /// Cancels [runId] through the backend's idempotent
  /// `POST /ai/runs/:runId/cancel` endpoint.
  ///
  /// A 404 is terminal for local cleanup: there is no remaining run owned by
  /// this account that the client can cancel. Transient transport failures are
  /// retried because repeating this control request has no additional side
  /// effect once the server run is terminal.
  Future<void> cancelRun(String runId) async {
    final normalizedRunId = runId.trim();
    if (normalizedRunId.isEmpty) {
      throw const HostedAgentCancelException(
        message: 'Hosted Agent returned no run id.',
        retryable: false,
      );
    }

    AuthSession? session;
    try {
      session = _getSession();
      if (session == null || !session.hasValidAccessToken) {
        session = await _refreshSession();
      }
    } catch (error) {
      throw HostedAgentCancelException(
        message: 'Hosted Agent authentication failed: $error',
        statusCode: 401,
        retryable: true,
      );
    }
    if (session == null) {
      throw const HostedAgentCancelException(
        message: 'Sign in to cancel hosted AI.',
        statusCode: 401,
        retryable: true,
      );
    }

    var activeSession = session;
    var refreshedAfterUnauthorized = false;
    Object? lastFailure;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await _postCancel(activeSession, normalizedRunId);
        return;
      } on _RunHttpException catch (error) {
        if (error.statusCode == 404) return;
        if (error.statusCode == 401 && !refreshedAfterUnauthorized) {
          refreshedAfterUnauthorized = true;
          AuthSession? refreshed;
          try {
            refreshed = await _refreshSession();
          } catch (refreshError) {
            throw HostedAgentCancelException(
              message: 'Hosted Agent authentication failed: $refreshError',
              statusCode: 401,
              retryable: true,
            );
          }
          if (refreshed != null) {
            activeSession = refreshed;
            continue;
          }
        }
        throw HostedAgentCancelException(
          message:
              'HTTP ${error.statusCode}: '
              '${HostedAgentService._responseError(error.body)}',
          statusCode: error.statusCode,
          retryable:
              error.statusCode == 401 ||
              error.statusCode == 408 ||
              error.statusCode == 425 ||
              error.statusCode == 429 ||
              error.statusCode >= 500,
        );
      } on TimeoutException catch (error) {
        lastFailure = error;
      } on http.ClientException catch (error) {
        lastFailure = error;
      }
      if (attempt < 1) {
        await Future<void>.delayed(Duration(milliseconds: 200 * (attempt + 1)));
      }
    }
    throw HostedAgentCancelException(
      message: lastFailure is TimeoutException
          ? 'Hosted Agent cancellation timed out after ${timeout.inSeconds} seconds'
          : 'Hosted Agent cancellation request failed: $lastFailure',
      retryable: true,
    );
  }

  Future<void> _postCancel(AuthSession session, String runId) async {
    final client = http.Client();
    try {
      final encodedRunId = Uri.encodeComponent(runId);
      final request =
          http.Request(
              'POST',
              BackendConfig.uri('/ai/runs/$encodedRunId/cancel'),
            )
            ..headers.addAll({
              'Authorization': 'Bearer ${session.accessToken}',
              'Accept': 'application/json',
            });
      final response = await client.send(request).timeout(timeout);
      final text = await response.stream.bytesToString().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _RunHttpException(response.statusCode, text);
      }
    } finally {
      client.close();
    }
  }

  Future<HostedAgentRunLookup> _getRunByIdempotencyKey(
    AuthSession session,
    String idempotencyKey,
  ) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', BackendConfig.uri('/ai/runs'))
        ..headers.addAll({
          'Authorization': 'Bearer ${session.accessToken}',
          'Accept': 'application/json',
          'Idempotency-Key': idempotencyKey,
        });
      final response = await client.send(request).timeout(timeout);
      final body = await response.stream.bytesToString().timeout(timeout);
      if (response.statusCode != 200) {
        throw _RunHttpException(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException(
          'Hosted Agent returned invalid reconciliation JSON.',
        );
      }
      return HostedAgentRunLookup.fromJson(decoded);
    } finally {
      client.close();
    }
  }
}

/// Client for a durable server-side Agent run.
///
/// A run is created with a short JSON request and then observed through a
/// separate SSE endpoint. The SSE connection is only a view of the run: if
/// the app process dies, the server keeps working and a later call to
/// [resumeStream] reads the persisted run events/result.
class HostedAgentService {
  final AuthSession? Function() _getSession;
  final Future<AuthSession?> Function() _refreshSession;
  final String model;
  final Duration timeout;
  final int maxImages;
  final int maxImageBytes;
  final int maxTotalImageBytes;
  final int maxBodyBytes;
  final Set<String> allowedImageMimeTypes;
  final bool imageInputEnabled;

  String? lastError;
  int? lastStatusCode;
  String? lastRunId;
  int lastEventSeq = 0;
  List<HostedAgentSource> lastSources = const [];
  List<HostedAgentEvent> lastEvents = const [];
  String? lastRunStatus;
  bool lastChunkIsFullAnswer = false;
  bool _lastRunResultWasEmpty = false;
  http.Client? _activeCreateClient;
  bool _createCancelled = false;
  String? _boundOwnerUserId;
  AiThinkingLevel thinkingLevel;

  HostedAgentService({
    required AuthSession? Function() getSession,
    required Future<AuthSession?> Function() refreshSession,
    required this.model,
    this.timeout = AiService.defaultTimeout,
    this.thinkingLevel = AiThinkingLevel.none,
    this.maxImages = maxHostedAgentImages,
    this.maxImageBytes = maxHostedAgentImageBytes,
    this.maxTotalImageBytes = maxHostedAgentImageTotalBytes,
    this.maxBodyBytes = maxHostedAgentBodyBytes,
    this.allowedImageMimeTypes = hostedAgentImageMimeTypes,
    this.imageInputEnabled = false,
  }) : _getSession = getSession,
       _refreshSession = refreshSession;

  bool get isConfigured =>
      BackendConfig.isConfigured && model.trim().isNotEmpty;

  /// Account currently backing this observer. The create coordinator stores
  /// it before POST so a later process can scope idempotency reconciliation.
  String? get currentUserId {
    final owner = _getSession()?.user.id.trim();
    if (owner == null || owner.isEmpty) return null;
    return _boundOwnerUserId ??= owner;
  }

  List<String> get lastWebUrls => lastSources
      .map((source) => source.url.trim())
      .where((url) => url.isNotEmpty)
      .toList(growable: false);

  /// Sends a control-plane cancellation without mutating this stream
  /// observer's `last*` fields. Callers that do not need the observer should
  /// prefer constructing [HostedAgentControlService] directly.
  Future<void> cancelRun(String runId) {
    return HostedAgentControlService(
      getSession: _getSession,
      refreshSession: _refreshSession,
    ).cancelRun(runId);
  }

  /// Stops an in-flight `POST /ai/runs` upload owned by this observer.
  ///
  /// A server run may already have been committed even when its 202 response
  /// has not reached the device. The stable Idempotency-Key remains the source
  /// of truth for subsequent reconciliation; closing this transport only
  /// prevents a superseded large upload from continuing to occupy memory and
  /// a socket in the current process.
  void cancelPendingCreate() {
    _createCancelled = true;
    _activeCreateClient?.close();
  }

  Future<AuthSession?> _freshSession() async {
    var session = _getSession();
    if (session == null) {
      lastError = 'Sign in to use hosted AI.';
      lastStatusCode = 401;
      return null;
    }
    if (!session.hasValidAccessToken) {
      session = await _refreshSession();
      if (session == null) {
        lastError = 'Your session has expired. Sign in again.';
        lastStatusCode = 401;
        return null;
      }
    }
    final boundOwner = _boundOwnerUserId;
    if (boundOwner != null && session.user.id != boundOwner) {
      lastError = 'The hosted AI account changed before the request started.';
      lastStatusCode = 401;
      return null;
    }
    return session;
  }

  void _validateImages(List<AiImageInput> images) {
    if (images.isNotEmpty && !imageInputEnabled) {
      throw const HostedAgentInputException(
        code: 'image_input_not_negotiated',
        message: 'Hosted Agent image input is not available.',
      );
    }
    if (images.length > maxImages) {
      throw HostedAgentInputException(
        code: 'too_many_images',
        message: 'Hosted Agent accepts at most $maxImages images per message.',
      );
    }
    var totalBytes = 0;
    for (final image in images) {
      final mimeType = image.mimeType.trim().toLowerCase();
      if (!allowedImageMimeTypes.contains(mimeType)) {
        throw HostedAgentInputException(
          code: 'unsupported_image_type',
          message: 'Hosted Agent does not support image type $mimeType.',
        );
      }
      if (image.bytes.isEmpty || image.bytes.length > maxImageBytes) {
        throw HostedAgentInputException(
          code: 'image_too_large',
          message:
              'Hosted Agent image ${image.fileName} exceeds the configured limit.',
        );
      }
      totalBytes += image.bytes.length;
    }
    if (totalBytes > maxTotalImageBytes) {
      throw const HostedAgentInputException(
        code: 'images_too_large',
        message: 'Hosted Agent images exceed the configured combined limit.',
      );
    }
  }

  /// Creates a durable hosted run and yields its answer events.
  Stream<String> chatStream({
    required String systemPrompt,
    required String userMessage,
    required String userQuestion,
    List<AiImageInput> images = const [],
    List<Map<String, String>> history = const [],
    double temperature = 0.3,
    int maxTokens = 800,
    bool webSearch = false,
    void Function(HostedAgentEvent event)? onEvent,
    FutureOr<void> Function(String runId)? onRunCreated,
    String? idempotencyKey,
  }) async* {
    _resetRunState();
    if (!isConfigured) {
      lastError = 'Hosted Agent is not configured';
      return;
    }

    var session = await _freshSession();
    if (session == null) return;

    _validateImages(images);
    final userContent = images.isEmpty
        ? userMessage
        : <Map<String, dynamic>>[
            {'type': 'text', 'text': userMessage},
            for (final image in images)
              {
                'type': 'image',
                'data': base64.encode(image.bytes),
                'mimeType': image.mimeType.trim().toLowerCase(),
              },
          ];
    final requestBody = <String, dynamic>{
      'model': model,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        ...history,
        {'role': 'user', 'content': userContent},
      ],
      'user_question': userQuestion,
      'temperature': temperature,
      'max_completion_tokens': maxTokens,
      'stream': true,
      'memora_tools': {'web_search': webSearch},
      if (supportsDeepSeekThinking(model: model))
        ...deepSeekThinkingOptions(thinkingLevel),
    };

    Map<String, dynamic>? created;
    var refreshedCreateSession = false;
    final canReplayCreate = idempotencyKey?.trim().isNotEmpty == true;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (_createCancelled) {
        lastError = 'Hosted Agent request was cancelled.';
        return;
      }
      try {
        created = await _createRun(session!, requestBody, idempotencyKey);
        break;
      } on HostedAgentInputException {
        rethrow;
      } on _RunHttpException catch (error) {
        lastStatusCode = error.statusCode;
        lastError = 'HTTP ${error.statusCode}: ${_responseError(error.body)}';
        if (error.statusCode == 401 && !refreshedCreateSession) {
          refreshedCreateSession = true;
          final refreshed = await _refreshSession();
          if (refreshed != null) {
            session = refreshed;
            lastError = null;
            continue;
          }
        }
        return;
      } on TimeoutException {
        if (_createCancelled) {
          lastError = 'Hosted Agent request was cancelled.';
          return;
        }
        lastError = 'Hosted Agent timed out after ${timeout.inSeconds} seconds';
        if (canReplayCreate && attempt < 2) continue;
        return;
      } on http.ClientException catch (error) {
        if (_createCancelled) {
          lastError = 'Hosted Agent request was cancelled.';
          return;
        }
        lastError = 'Hosted Agent request failed: $error';
        if (canReplayCreate && attempt < 2) continue;
        return;
      } on FormatException catch (error) {
        lastError = 'Hosted Agent returned an invalid response: $error';
        if (canReplayCreate && attempt < 2) continue;
        return;
      } catch (error) {
        if (_createCancelled) {
          lastError = 'Hosted Agent request was cancelled.';
          return;
        }
        lastError = 'Hosted Agent request failed: $error';
        return;
      }
    }

    final runId = (created?['id'] ?? created?['runId'] ?? '').toString();
    if (runId.isEmpty) {
      lastError = 'Hosted Agent returned no run id.';
      return;
    }
    lastRunId = runId;
    lastRunStatus = 'queued';
    await onRunCreated?.call(runId);

    try {
      await for (final delta in _watchRunWithReconnect(
        runId,
        session: session!,
        onEvent: onEvent,
      )) {
        if (delta.isNotEmpty) yield delta;
      }
    } on TimeoutException {
      lastError = 'Hosted Agent timed out after ${timeout.inSeconds} seconds';
    } on _RunHttpException catch (error) {
      lastStatusCode = error.statusCode;
      lastError = 'HTTP ${error.statusCode}: ${_responseError(error.body)}';
    } catch (error) {
      lastError = 'Hosted Agent request failed: $error';
    }
  }

  /// Reconnects to an existing durable run after the app has restarted.
  ///
  /// The snapshot is checked first so a completed answer is restored without
  /// waiting for the event stream. Running jobs then resume from the latest
  /// persisted event sequence.
  Stream<String> resumeStream(
    String runId, {
    int afterEventSeq = 0,
    void Function(HostedAgentEvent event)? onEvent,
  }) async* {
    _resetRunState();
    lastRunId = runId;
    lastEventSeq = afterEventSeq < 0 ? 0 : afterEventSeq;
    if (!isConfigured) {
      lastError = 'Hosted Agent is not configured';
      throw HostedAgentResumeException(message: lastError!, retryable: true);
    }

    AuthSession? session;
    try {
      session = await _freshSession();
    } catch (error) {
      lastError = 'Hosted Agent authentication failed: $error';
      throw HostedAgentResumeException(
        message: lastError!,
        statusCode: lastStatusCode,
        retryable: true,
      );
    }
    if (session == null) {
      throw HostedAgentResumeException(
        message: lastError ?? 'Sign in to resume hosted AI.',
        statusCode: lastStatusCode,
        retryable: true,
      );
    }

    late Map<String, dynamic> snapshot;
    var refreshedSnapshotSession = false;
    while (true) {
      try {
        snapshot = await _fetchRun(session!, runId);
        break;
      } on _RunHttpException catch (error) {
        if (error.statusCode == 401 && !refreshedSnapshotSession) {
          refreshedSnapshotSession = true;
          AuthSession? refreshed;
          try {
            refreshed = await _refreshSession();
          } catch (refreshError) {
            lastError = 'Hosted Agent authentication failed: $refreshError';
            throw HostedAgentResumeException(
              message: lastError!,
              statusCode: 401,
              retryable: true,
            );
          }
          if (refreshed != null) {
            session = refreshed;
            continue;
          }
        }
        throw _resumeHttpFailure(error);
      } on TimeoutException {
        lastError = 'Hosted Agent timed out after ${timeout.inSeconds} seconds';
        throw HostedAgentResumeException(message: lastError!, retryable: true);
      } on HostedAgentResumeException {
        rethrow;
      } catch (error) {
        lastError = 'Hosted Agent request failed: $error';
        throw HostedAgentResumeException(message: lastError!, retryable: true);
      }
    }

    final snapshotSeq = (snapshot['lastEventSeq'] as num?)?.toInt() ?? 0;
    _captureRunSnapshot(snapshot, onEvent: onEvent);

    final status = (snapshot['status'] ?? '').toString();
    final answer = (snapshot['answer'] ?? '').toString();
    if (status == 'completed') {
      if (answer.trim().isNotEmpty) {
        if (snapshotSeq > lastEventSeq) lastEventSeq = snapshotSeq;
        lastChunkIsFullAnswer = true;
        yield answer;
        return;
      }
      // Older workers can publish their completion marker before the durable
      // result/answer. Continue from the snapshot cursor instead of turning a
      // transiently empty completed snapshot into a permanent failed message.
    }
    if (status == 'failed' || status == 'cancelled') {
      if (snapshotSeq > lastEventSeq) lastEventSeq = snapshotSeq;
      return;
    }

    var yieldedFullAnswer = false;
    try {
      await for (final delta in _watchRunWithReconnect(
        runId,
        session: session,
        onEvent: onEvent,
      )) {
        if (delta.isNotEmpty) {
          yieldedFullAnswer = yieldedFullAnswer || lastChunkIsFullAnswer;
          yield delta;
        }
      }
    } on TimeoutException {
      lastError = 'Hosted Agent timed out after ${timeout.inSeconds} seconds';
      throw HostedAgentResumeException(message: lastError!, retryable: true);
    } on _RunHttpException catch (error) {
      // The snapshot succeeded, so an events-endpoint 404 is not enough to
      // declare the durable run missing. Retry from a fresh snapshot first.
      throw _resumeHttpFailure(error, retryNotFound: true);
    } on HostedAgentResumeException {
      rethrow;
    } catch (error) {
      lastError = 'Hosted Agent request failed: $error';
      throw HostedAgentResumeException(message: lastError!, retryable: true);
    }
    // A snapshot is the server's durable high-water mark. A clean EOF, a
    // [DONE] marker, or even an early full-answer frame cannot prove recovery
    // succeeded while events between the persisted cursor and that mark are
    // still missing (notably run.result and its sources).
    if (lastEventSeq < snapshotSeq) {
      lastError = 'Hosted Agent events are not fully available yet.';
      throw HostedAgentResumeException(message: lastError!, retryable: true);
    }
    if (lastRunStatus == 'failed' || lastRunStatus == 'cancelled') return;
    if (lastRunStatus != 'completed') {
      lastError = 'Hosted Agent event stream ended before a terminal result.';
      throw HostedAgentResumeException(message: lastError!, retryable: true);
    }
    if (_lastRunResultWasEmpty || !yieldedFullAnswer) {
      lastError = 'Hosted Agent completed before its answer was available.';
      throw HostedAgentResumeException(message: lastError!, retryable: true);
    }
  }

  HostedAgentResumeException _resumeHttpFailure(
    _RunHttpException error, {
    bool retryNotFound = false,
  }) {
    lastStatusCode = error.statusCode;
    lastError = 'HTTP ${error.statusCode}: ${_responseError(error.body)}';
    final statusCode = error.statusCode;
    return HostedAgentResumeException(
      message: lastError!,
      statusCode: statusCode,
      retryable:
          statusCode == 401 ||
          statusCode == 408 ||
          statusCode == 425 ||
          statusCode == 429 ||
          (statusCode == 404 && retryNotFound) ||
          statusCode >= 500,
    );
  }

  Future<Map<String, dynamic>> _createRun(
    AuthSession session,
    Map<String, dynamic> body,
    String? idempotencyKey,
  ) async {
    final client = http.Client();
    _activeCreateClient = client;
    try {
      if (_createCancelled) {
        throw http.ClientException('Hosted Agent request was cancelled.');
      }
      final encodedBody = utf8.encode(jsonEncode(body));
      if (encodedBody.length > maxBodyBytes) {
        throw const HostedAgentInputException(
          code: 'request_too_large',
          message: 'Hosted Agent request exceeds the advertised body limit.',
        );
      }
      final request = http.Request('POST', BackendConfig.uri('/ai/runs'))
        ..headers.addAll({
          'Authorization': 'Bearer ${session.accessToken}',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          if (idempotencyKey != null && idempotencyKey.trim().isNotEmpty)
            'Idempotency-Key': idempotencyKey.trim(),
        })
        ..bodyBytes = encodedBody;
      final response = await client.send(request).timeout(timeout);
      lastStatusCode = response.statusCode;
      final text = await response.stream.bytesToString().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _RunHttpException(response.statusCode, text);
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Hosted Agent returned invalid run JSON.');
      }
      return decoded;
    } finally {
      if (identical(_activeCreateClient, client)) {
        _activeCreateClient = null;
      }
      client.close();
    }
  }

  Future<Map<String, dynamic>> _fetchRun(
    AuthSession session,
    String runId,
  ) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', BackendConfig.uri('/ai/runs/$runId'))
        ..headers.addAll({
          'Authorization': 'Bearer ${session.accessToken}',
          'Accept': 'application/json',
        });
      final response = await client.send(request).timeout(timeout);
      final text = await response.stream.bytesToString().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _RunHttpException(response.statusCode, text);
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Hosted Agent returned invalid run JSON.');
      }
      return decoded;
    } finally {
      client.close();
    }
  }

  Stream<String> _watchRun(
    String runId, {
    required AuthSession session,
    required int afterEventSeq,
    void Function(HostedAgentEvent event)? onEvent,
  }) async* {
    final client = http.Client();
    try {
      final uri = BackendConfig.uri(
        '/ai/runs/$runId/events',
      ).replace(queryParameters: {'after': '$afterEventSeq'});
      final request = http.Request('GET', uri)
        ..headers.addAll({
          'Authorization': 'Bearer ${session.accessToken}',
          'Accept': 'text/event-stream',
          'Last-Event-ID': '$afterEventSeq',
        });
      final response = await client.send(request).timeout(timeout);
      lastStatusCode = response.statusCode;
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString().timeout(timeout);
        throw _RunHttpException(response.statusCode, body);
      }
      yield* _decodeRunEvents(response, onEvent: onEvent);
    } finally {
      client.close();
    }
  }

  Stream<String> _watchRunWithReconnect(
    String runId, {
    required AuthSession session,
    void Function(HostedAgentEvent event)? onEvent,
  }) async* {
    Object? lastFailure;
    var activeSession = session;
    var refreshedAfterUnauthorized = false;
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        await for (final delta in _watchRun(
          runId,
          session: activeSession,
          afterEventSeq: lastEventSeq,
          onEvent: onEvent,
        )) {
          if (delta.isNotEmpty) yield delta;
        }
        if (_runIsTerminal) return;
        lastFailure = StateError(
          'Hosted Agent event stream ended before completion.',
        );
      } on _RunHttpException catch (error) {
        lastFailure = error;
        if (error.statusCode == 401) {
          if (refreshedAfterUnauthorized) break;
          refreshedAfterUnauthorized = true;
          final refreshed = await _refreshSession();
          if (refreshed == null) break;
          activeSession = refreshed;
          continue;
        }
      } catch (error) {
        lastFailure = error;
      }
      if (attempt == 3 || _runIsTerminal) break;
      await Future<void>.delayed(Duration(milliseconds: 300 * (attempt + 1)));
    }
    if (lastFailure != null) throw lastFailure;
  }

  Stream<String> _decodeRunEvents(
    http.StreamedResponse response, {
    void Function(HostedAgentEvent event)? onEvent,
  }) async* {
    var eventName = 'message';
    var eventId = 0;
    final eventData = StringBuffer();
    var terminal = false;

    Future<List<String>> flush() async {
      if (eventData.isEmpty) return const [];
      final data = eventData.toString().trim();
      eventData.clear();
      final currentEvent = eventName;
      final currentId = eventId;
      eventName = 'message';
      eventId = 0;
      if (data == '[DONE]') {
        terminal = true;
        return const [];
      }
      Map<String, dynamic> decoded;
      try {
        final value = jsonDecode(data);
        if (value is! Map<String, dynamic>) return const [];
        decoded = value;
      } catch (_) {
        return const [];
      }
      final event = _captureRunEvent(
        decoded,
        eventName: currentEvent,
        onEvent: onEvent,
      );
      // Commit the cursor only after the complete JSON event has been parsed
      // and accepted. If a connection ends halfway through `data:`, keeping
      // the previous cursor lets the durable endpoint replay this same id.
      if (currentId > lastEventSeq) lastEventSeq = currentId;
      if (event != null && event.isNotEmpty) return [event];
      return const [];
    }

    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .timeout(timeout)) {
      if (line.startsWith(':')) continue;
      if (line.startsWith('id:')) {
        eventId = int.tryParse(line.substring(3).trim()) ?? 0;
        continue;
      }
      if (line.startsWith('event:')) {
        eventName = line.substring(6).trim();
        continue;
      }
      if (line.startsWith('data:')) {
        eventData.write(line.substring(5).trimLeft());
        eventData.write('\n');
        continue;
      }
      if (line.trim().isEmpty) {
        for (final text in await flush()) {
          yield text;
        }
        if (terminal) break;
      }
    }
    if (eventData.isNotEmpty) {
      for (final text in await flush()) {
        yield text;
      }
    }
    if (!terminal && !_runIsTerminal) {
      throw StateError('Hosted Agent event stream ended before completion.');
    }
  }

  bool _runIsTerminal = false;

  String? _captureRunEvent(
    Map<String, dynamic> decoded, {
    required String eventName,
    void Function(HostedAgentEvent event)? onEvent,
  }) {
    if (decoded.containsKey('choices')) {
      final completion = _completionChunk(decoded);
      if (completion == null) return null;
      lastChunkIsFullAnswer = completion.isFullAnswer;
      if (completion.isFullAnswer && completion.text.trim().isEmpty) {
        return null;
      }
      return completion.text;
    }

    final event = HostedAgentEvent(
      type: (decoded['type'] ?? eventName).toString(),
      data: decoded,
    );
    _captureSources(decoded['sources']);
    if (event.type == 'run.result') {
      _captureSources(decoded['sources']);
      _runIsTerminal = true;
      lastRunStatus = 'completed';
      lastChunkIsFullAnswer = true;
      final answer = (decoded['answer'] ?? '').toString();
      _lastRunResultWasEmpty = answer.trim().isEmpty;
      return _lastRunResultWasEmpty ? null : answer;
    }
    lastEvents = List.unmodifiable([...lastEvents, event]);
    if (event.type == 'run.queued') {
      lastRunStatus = 'queued';
    } else if (event.type == 'run.running') {
      lastRunStatus = 'running';
    } else if (event.type == 'run.failed') {
      lastError = (decoded['error'] ?? 'Hosted Agent failed.').toString();
      _runIsTerminal = true;
      lastRunStatus = 'failed';
    } else if (event.type == 'run.cancelled') {
      lastError = (decoded['error'] ?? 'Hosted Agent was cancelled.')
          .toString();
      _runIsTerminal = true;
      lastRunStatus = 'cancelled';
    } else if (event.type == 'run.completed') {
      // The durable service emits run.result immediately after this event.
    }
    onEvent?.call(event);
    return null;
  }

  void _captureRunSnapshot(
    Map<String, dynamic> decoded, {
    void Function(HostedAgentEvent event)? onEvent,
  }) {
    _captureSources(decoded['sources']);
    final status = (decoded['status'] ?? '').toString();
    if (status.isNotEmpty) lastRunStatus = status;
    if (status == 'failed' || status == 'cancelled') {
      lastError = (decoded['errorMessage'] ?? 'Hosted Agent failed.')
          .toString();
      _runIsTerminal = true;
    } else if (status == 'completed') {
      _runIsTerminal = true;
    }
    final rawError = decoded['error'];
    if (rawError is Map) {
      lastError = (rawError['message'] ?? 'Hosted Agent failed.').toString();
    }
    final event = HostedAgentEvent(type: 'run.snapshot', data: decoded);
    onEvent?.call(event);
  }

  void _captureSources(dynamic rawSources) {
    if (rawSources is! List || rawSources.isEmpty) return;
    lastSources = List.unmodifiable(
      rawSources
          .whereType<Map>()
          .map(
            (source) =>
                HostedAgentSource.fromJson(Map<String, dynamic>.from(source)),
          )
          .where((source) => source.url.trim().isNotEmpty),
    );
  }

  void _resetRunState() {
    _createCancelled = false;
    lastError = null;
    lastStatusCode = null;
    lastRunId = null;
    lastEventSeq = 0;
    lastSources = const [];
    lastEvents = const [];
    lastRunStatus = null;
    lastChunkIsFullAnswer = false;
    _lastRunResultWasEmpty = false;
    _runIsTerminal = false;
  }

  static _CompletionChunk? _completionChunk(Map<String, dynamic> decoded) {
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      return null;
    }
    final choice = Map<String, dynamic>.from(choices.first as Map);
    final delta = choice['delta'];
    if (delta is Map && delta['content'] is String) {
      return _CompletionChunk(
        text: delta['content'] as String,
        isFullAnswer: false,
      );
    }
    final message = choice['message'];
    if (message is Map && message['content'] is String) {
      return _CompletionChunk(
        text: message['content'] as String,
        isFullAnswer: true,
      );
    }
    return null;
  }

  static String _responseError(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map) {
          return (error['message'] ?? error['code'] ?? error).toString();
        }
        return (decoded['message'] ?? error ?? body).toString();
      }
    } catch (_) {
      // Use the response body below.
    }
    final trimmed = body.trim();
    return trimmed.isEmpty ? 'Request failed.' : trimmed;
  }
}

class _RunHttpException implements Exception {
  final int statusCode;
  final String body;

  const _RunHttpException(this.statusCode, this.body);
}

class _CompletionChunk {
  final String text;
  final bool isFullAnswer;

  const _CompletionChunk({required this.text, required this.isFullAnswer});
}
