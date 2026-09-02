import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../config/backend_config.dart';
import '../models/ai_image_input.dart';
import '../models/ai_file_attachment_input.dart';
import '../models/ai_text_attachment_input.dart';
import '../models/ai_thinking_level.dart';
import 'ai_service.dart';
import 'auth_service.dart';

const int maxHostedAgentImages = 4;
const int maxHostedAgentImageBytes = 5 * 1024 * 1024;
const int maxHostedAgentImageTotalBytes = 12 * 1024 * 1024;
const int maxHostedAgentBodyBytes = 18 * 1024 * 1024;
const int maxHostedChatQuestionCharacters = 20000;
const int maxHostedChatHistoryMessages = 20;
const int maxHostedChatHistoryMessageCharacters = 8000;
const int maxHostedChatHistoryCharacters = 120000;
const int maxHostedChatAttachments = 4;
const int maxHostedChatAttachmentIdCharacters = 128;
const int maxHostedChatAttachmentNameCharacters = 256;
const int maxHostedChatAttachmentTextCharacters = 100000;
const int maxHostedChatAttachmentTotalCharacters = 200000;
const int maxHostedAgentFiles = 4;
const int maxHostedAgentFileBytes = 5 * 1024 * 1024;
const int maxHostedAgentFileTotalBytes = 12 * 1024 * 1024;
const int maxHostedAgentSelectedSkills = 100;
const String legacyPrivateAttachmentMarker =
    'Attached material from that turn:';
const Set<String> hostedAgentImageMimeTypes = {
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
};

enum HostedChatKnowledgeMode {
  only('only'),
  hybrid('hybrid');

  final String wireName;

  const HostedChatKnowledgeMode(this.wireName);
}

enum HostedChatLength {
  concise('concise'),
  detailed('detailed');

  final String wireName;

  const HostedChatLength(this.wireName);
}

enum HostedChatLanguage {
  followUser('follow-user'),
  zhCn('zh-CN'),
  en('en');

  final String wireName;

  const HostedChatLanguage(this.wireName);
}

HostedChatLanguage hostedChatLanguageForIndex(int languageIndex) {
  return switch (languageIndex) {
    1 => HostedChatLanguage.zhCn,
    2 => HostedChatLanguage.en,
    _ => HostedChatLanguage.followUser,
  };
}

class HostedAgentSkill {
  final String name;
  final String description;

  const HostedAgentSkill({required this.name, required this.description});

  factory HostedAgentSkill.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final description = json['description'];
    if (name is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(name) ||
        description is! String) {
      throw const FormatException('Hosted Agent returned an invalid Skill.');
    }
    return HostedAgentSkill(name: name, description: description.trim());
  }
}

class HostedAgentSkillCatalog {
  final int resourceRevision;
  final List<HostedAgentSkill> skills;

  const HostedAgentSkillCatalog({
    required this.resourceRevision,
    required this.skills,
  });

  factory HostedAgentSkillCatalog.fromJson(Map<String, dynamic> json) {
    final schemaVersion = json['schemaVersion'];
    final resourceRevision = json['resourceRevision'];
    final rawSkills = json['skills'];
    if (schemaVersion != 1 ||
        resourceRevision is! int ||
        resourceRevision < 0 ||
        rawSkills is! List ||
        rawSkills.any((item) => item is! Map) ||
        rawSkills.length > maxHostedAgentSelectedSkills) {
      throw const FormatException(
        'Hosted Agent returned an invalid Skill catalog.',
      );
    }
    final skills = rawSkills
        .map(
          (item) =>
              HostedAgentSkill.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(growable: false);
    if (skills.map((skill) => skill.name).toSet().length != skills.length) {
      throw const FormatException(
        'Hosted Agent returned duplicate Skill names.',
      );
    }
    return HostedAgentSkillCatalog(
      resourceRevision: resourceRevision,
      skills: skills,
    );
  }
}

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

class HostedAgentLocalSource {
  final String id;
  final String articleRef;

  const HostedAgentLocalSource({required this.id, required this.articleRef});

  factory HostedAgentLocalSource.fromJson(Map<String, dynamic> json) {
    if (json.length != 2 ||
        json['id'] is! String ||
        !RegExp(r'^[1-9]\d{0,5}$').hasMatch(json['id'] as String) ||
        json['articleRef'] is! String ||
        !RegExp(
          r'^ar_[A-Za-z0-9_-]{22,64}$',
        ).hasMatch(json['articleRef'] as String)) {
      throw const FormatException('Invalid local source response.');
    }
    return HostedAgentLocalSource(
      id: json['id'] as String,
      articleRef: json['articleRef'] as String,
    );
  }
}

class HostedAgentEvent {
  final String type;
  final Map<String, dynamic> data;

  const HostedAgentEvent({required this.type, required this.data});
}

/// Process-local wake-up emitted by the durable Agent SSE observer.
///
/// The server event payload is deliberately discarded. Device-tool REST
/// pending remains the sole source of truth for arguments and execution.
class HostedAgentClientToolWake {
  final String runId;

  const HostedAgentClientToolWake(this.runId);
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
  /// This method never replays `POST /ai/chat/runs`: once a create may have been
  /// accepted, only this lookup can safely resolve the missing 202 response.
  Future<HostedAgentRunLookup> lookupRunByIdempotencyKey(
    String idempotencyKey, {
    String? expectedOwnerUserId,
  }) async {
    final normalizedKey = idempotencyKey.trim();
    if (normalizedKey.isEmpty || normalizedKey.length > 128) {
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
  Future<void> cancelRun(String runId, {String? expectedOwnerUserId}) async {
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
    if (expectedOwnerUserId == null ||
        expectedOwnerUserId.trim().isEmpty ||
        session.user.id != expectedOwnerUserId) {
      throw const HostedAgentCancelException(
        message: 'The hosted AI account does not own this pending run.',
        statusCode: 401,
        retryable: false,
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
            if (refreshed.user.id != expectedOwnerUserId) {
              throw const HostedAgentCancelException(
                message: 'The hosted AI account does not own this pending run.',
                statusCode: 401,
                retryable: false,
              );
            }
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

  /// Permanently deletes an owned durable run through the idempotent
  /// `DELETE /ai/runs/:runId` endpoint. The backend fences active execution
  /// before cascading its events and device-tool rows.
  Future<void> deleteRun(String runId, {String? expectedOwnerUserId}) async {
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
        message: 'Sign in to delete hosted AI data.',
        statusCode: 401,
        retryable: true,
      );
    }
    if (expectedOwnerUserId == null ||
        expectedOwnerUserId.trim().isEmpty ||
        session.user.id != expectedOwnerUserId) {
      throw const HostedAgentCancelException(
        message: 'The hosted AI account does not own this run.',
        statusCode: 401,
        retryable: false,
      );
    }

    var activeSession = session;
    var refreshedAfterUnauthorized = false;
    Object? lastFailure;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await _deleteRun(activeSession, normalizedRunId);
        return;
      } on _RunHttpException catch (error) {
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
            if (refreshed.user.id != expectedOwnerUserId) {
              throw const HostedAgentCancelException(
                message: 'The hosted AI account does not own this run.',
                statusCode: 401,
                retryable: false,
              );
            }
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
          ? 'Hosted AI data deletion timed out after ${timeout.inSeconds} seconds'
          : 'Hosted AI data deletion request failed: $lastFailure',
      retryable: true,
    );
  }

  Future<void> _deleteRun(AuthSession session, String runId) async {
    final client = http.Client();
    try {
      final encodedRunId = Uri.encodeComponent(runId);
      final request =
          http.Request('DELETE', BackendConfig.uri('/ai/runs/$encodedRunId'))
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
  final int maxQuestionChars;
  final int maxHistoryMessages;
  final int maxHistoryMessageChars;
  final int maxHistoryChars;
  final int maxAttachments;
  final int maxAttachmentIdChars;
  final int maxAttachmentNameChars;
  final int maxAttachmentTextChars;
  final int maxTotalAttachmentTextChars;
  final int maxFiles;
  final int maxFileBytes;
  final int maxTotalFileBytes;
  final Set<String> allowedImageMimeTypes;
  final bool imageInputEnabled;
  final void Function(HostedAgentClientToolWake wake)? _onClientToolWake;

  String? lastError;
  int? lastStatusCode;
  String? lastRunId;
  int lastEventSeq = 0;
  List<HostedAgentSource> lastSources = const [];
  List<HostedAgentLocalSource> lastLocalSources = const [];
  List<HostedAgentEvent> lastEvents = const [];
  String? lastRunStatus;
  bool lastPrivateEvidenceUsed = false;
  bool lastChunkIsFullAnswer = false;
  bool _lastRunResultWasEmpty = false;
  http.Client? _activeCreateClient;
  bool _createCancelled = false;
  String? _boundOwnerUserId;
  String? _boundOwnerDeviceId;
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
    this.maxQuestionChars = maxHostedChatQuestionCharacters,
    this.maxHistoryMessages = maxHostedChatHistoryMessages,
    this.maxHistoryMessageChars = maxHostedChatHistoryMessageCharacters,
    this.maxHistoryChars = maxHostedChatHistoryCharacters,
    this.maxAttachments = maxHostedChatAttachments,
    this.maxAttachmentIdChars = maxHostedChatAttachmentIdCharacters,
    this.maxAttachmentNameChars = maxHostedChatAttachmentNameCharacters,
    this.maxAttachmentTextChars = maxHostedChatAttachmentTextCharacters,
    this.maxTotalAttachmentTextChars = maxHostedChatAttachmentTotalCharacters,
    this.maxFiles = maxHostedAgentFiles,
    this.maxFileBytes = maxHostedAgentFileBytes,
    this.maxTotalFileBytes = maxHostedAgentFileTotalBytes,
    this.allowedImageMimeTypes = hostedAgentImageMimeTypes,
    this.imageInputEnabled = false,
    void Function(HostedAgentClientToolWake wake)? onClientToolWake,
  }) : _getSession = getSession,
       _refreshSession = refreshSession,
       _onClientToolWake = onClientToolWake;

  bool get isConfigured =>
      BackendConfig.isConfigured && model.trim().isNotEmpty;

  /// Account currently backing this observer. The create coordinator stores
  /// it before POST so a later process can scope idempotency reconciliation.
  String? get currentUserId {
    final session = _getSession();
    if (session == null || !_bindOrValidateSession(session)) return null;
    return _boundOwnerUserId;
  }

  String? get currentDeviceId {
    final session = _getSession();
    if (session == null || !_bindOrValidateSession(session)) return null;
    return _boundOwnerDeviceId;
  }

  List<String> get lastWebUrls => lastSources
      .map((source) => source.url.trim())
      .where((url) => url.isNotEmpty)
      .toList(growable: false);

  /// Sends a control-plane cancellation without mutating this stream
  /// observer's `last*` fields. Callers that do not need the observer should
  /// prefer constructing [HostedAgentControlService] directly.
  Future<void> cancelRun(String runId, {String? expectedOwnerUserId}) {
    return HostedAgentControlService(
      getSession: _getSession,
      refreshSession: _refreshSession,
    ).cancelRun(runId, expectedOwnerUserId: expectedOwnerUserId);
  }

  /// Stops an in-flight `POST /ai/chat/runs` upload owned by this observer.
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

  Future<HostedAgentSkillCatalog> fetchSkillCatalog() async {
    final initialSession = await _freshSession();
    if (initialSession == null) {
      throw HostedAgentInputException(
        code: 'hosted_auth_unavailable',
        message: lastError ?? 'Sign in to use hosted AI.',
      );
    }
    var session = initialSession;
    var refreshed = false;
    while (true) {
      try {
        return await _fetchSkillCatalog(session);
      } on _RunHttpException catch (error) {
        if (error.statusCode == 401 && !refreshed) {
          refreshed = true;
          final next = await _refreshSession();
          if (next != null && _bindOrValidateSession(next)) {
            session = next;
            continue;
          }
        }
        throw HostedAgentInputException(
          code: 'skill_catalog_unavailable',
          message: 'HTTP ${error.statusCode}: ${_responseError(error.body)}',
        );
      } on TimeoutException {
        throw const HostedAgentInputException(
          code: 'skill_catalog_unavailable',
          message: 'Loading Skills timed out.',
        );
      } on http.ClientException catch (error) {
        throw HostedAgentInputException(
          code: 'skill_catalog_unavailable',
          message: 'Loading Skills failed: $error',
        );
      }
    }
  }

  List<String>? _validatedSelectedSkills(List<String>? skills) {
    if (skills == null) return null;
    if (skills.length > maxHostedAgentSelectedSkills) {
      throw const HostedAgentInputException(
        code: 'invalid_skill_selection',
        message: 'Too many Skills were selected.',
      );
    }
    final normalized = skills
        .map((name) => name.trim())
        .toList(growable: false);
    if (normalized.any(
          (name) =>
              !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(name),
        ) ||
        normalized.toSet().length != normalized.length) {
      throw const HostedAgentInputException(
        code: 'invalid_skill_selection',
        message: 'The selected Skill names are invalid.',
      );
    }
    return normalized;
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
    if (!_bindOrValidateSession(session)) return null;
    return session;
  }

  bool _bindOrValidateSession(AuthSession session) {
    final owner = session.user.id.trim();
    final device = session.device.id.trim();
    if (owner.isEmpty || device.isEmpty) {
      lastError = 'The hosted AI session identity is invalid.';
      lastStatusCode = 401;
      return false;
    }
    _boundOwnerUserId ??= owner;
    _boundOwnerDeviceId ??= device;
    if (_boundOwnerUserId != owner || _boundOwnerDeviceId != device) {
      lastError =
          'The hosted AI account or device changed before the request started.';
      lastStatusCode = 401;
      return false;
    }
    return true;
  }

  bool _isCurrentSessionIdentity(AuthSession session) {
    if (!_bindOrValidateSession(session)) return false;
    final current = _getSession();
    return current != null &&
        current.user.id.trim() == _boundOwnerUserId &&
        current.device.id.trim() == _boundOwnerDeviceId;
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

  String _validatedQuestion(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > maxQuestionChars) {
      throw const HostedAgentInputException(
        code: 'invalid_question',
        message: 'Hosted chat question is empty or too large.',
      );
    }
    return normalized;
  }

  ({List<Map<String, dynamic>> messages, bool privateEvidence})
  _validatedHistory(List<Map<String, dynamic>> history) {
    if (history.length.isOdd) {
      throw const HostedAgentInputException(
        code: 'invalid_history',
        message: 'Hosted chat history must contain complete recent turns.',
      );
    }
    final normalized = <Map<String, dynamic>>[];
    for (var index = 0; index < history.length; index++) {
      final message = history[index];
      final expectedRole = index.isEven ? 'user' : 'assistant';
      final rawContent = message['content'];
      final content = rawContent is String ? rawContent.trim() : '';
      if (message.length != 3 ||
          !message.containsKey('role') ||
          !message.containsKey('content') ||
          !message.containsKey('private_evidence') ||
          message['role'] != expectedRole ||
          message['private_evidence'] is! bool ||
          content.isEmpty) {
        throw const HostedAgentInputException(
          code: 'invalid_history',
          message:
              'Hosted chat history must alternate complete user/assistant turns.',
        );
      }
      normalized.add({
        'role': expectedRole,
        'content': content,
        'private_evidence': message['private_evidence'] as bool,
      });
    }

    var stickyPrivateEvidence = false;
    final protected = <Map<String, dynamic>>[];
    for (var index = 0; index < normalized.length; index += 2) {
      final user = normalized[index];
      final assistant = normalized[index + 1];
      final userPrivate = user['private_evidence'] as bool;
      final assistantPrivate = assistant['private_evidence'] as bool;
      if (userPrivate != assistantPrivate) {
        throw const HostedAgentInputException(
          code: 'invalid_history',
          message:
              'Hosted chat private evidence must match within each completed turn.',
        );
      }
      final legacyPrivate =
          (user['content'] as String).contains(legacyPrivateAttachmentMarker) ||
          (assistant['content'] as String).contains(
            legacyPrivateAttachmentMarker,
          );
      stickyPrivateEvidence =
          stickyPrivateEvidence || userPrivate || legacyPrivate;
      protected.add({
        'role': 'user',
        'content': user['content'],
        'private_evidence': stickyPrivateEvidence,
      });
      protected.add({
        'role': 'assistant',
        'content': assistant['content'],
        'private_evidence': stickyPrivateEvidence,
      });
    }
    // The app context window is token-based, while protocol-v4 also advertises
    // strict message/character limits. Keep the newest contiguous complete
    // pairs that satisfy every negotiated wire bound. Private provenance above
    // was computed over the full local history, so dropping an older private
    // pair can never re-enable Web.
    final pairLimit = maxHistoryMessages ~/ 2;
    final selected = <Map<String, dynamic>>[];
    var selectedPairs = 0;
    var selectedCharacters = 0;
    for (var index = protected.length - 2; index >= 0; index -= 2) {
      if (selectedPairs >= pairLimit) break;
      final user = protected[index];
      final assistant = protected[index + 1];
      final userContent = user['content'] as String;
      final assistantContent = assistant['content'] as String;
      final pairCharacters = userContent.length + assistantContent.length;
      if (userContent.length > maxHistoryMessageChars ||
          assistantContent.length > maxHistoryMessageChars ||
          selectedCharacters + pairCharacters > maxHistoryChars) {
        break;
      }
      selected.insertAll(0, [user, assistant]);
      selectedPairs++;
      selectedCharacters += pairCharacters;
    }
    return (
      messages: List.unmodifiable(selected),
      privateEvidence: stickyPrivateEvidence,
    );
  }

  List<Map<String, dynamic>> _legacyHistoryWithProvenance(
    List<Map<String, String>> history,
  ) {
    var stickyPrivateEvidence = false;
    final result = <Map<String, dynamic>>[];
    for (var index = 0; index + 1 < history.length; index += 2) {
      final user = history[index];
      final assistant = history[index + 1];
      stickyPrivateEvidence =
          stickyPrivateEvidence ||
          (user['content'] ?? '').contains(legacyPrivateAttachmentMarker) ||
          (assistant['content'] ?? '').contains(legacyPrivateAttachmentMarker);
      result.add({...user, 'private_evidence': stickyPrivateEvidence});
      result.add({...assistant, 'private_evidence': stickyPrivateEvidence});
    }
    if (history.length.isOdd) {
      final dangling = history.last;
      result.add({...dangling, 'private_evidence': stickyPrivateEvidence});
    }
    return result;
  }

  List<Map<String, String>> _validatedAttachments(
    List<AiTextAttachmentInput> attachments,
  ) {
    if (attachments.length > maxAttachments) {
      throw const HostedAgentInputException(
        code: 'too_many_attachments',
        message: 'Hosted chat has too many text attachments.',
      );
    }
    final ids = <String>{};
    var totalCharacters = 0;
    final normalized = <Map<String, String>>[];
    for (final attachment in attachments) {
      final id = attachment.id.trim();
      final name = attachment.name?.trim();
      final text = attachment.text.trim();
      if (id.isEmpty ||
          id.length > maxAttachmentIdChars ||
          !ids.add(id) ||
          name != null &&
              (name.isEmpty || name.length > maxAttachmentNameChars) ||
          text.isEmpty ||
          text.length > maxAttachmentTextChars) {
        throw const HostedAgentInputException(
          code: 'invalid_attachment',
          message: 'Hosted chat text attachment is invalid.',
        );
      }
      totalCharacters += text.length;
      if (totalCharacters > maxTotalAttachmentTextChars) {
        throw const HostedAgentInputException(
          code: 'attachments_too_large',
          message: 'Hosted chat text attachments are too large.',
        );
      }
      final normalizedAttachment = <String, String>{'id': id, 'text': text};
      if (name != null) normalizedAttachment['name'] = name;
      normalized.add(normalizedAttachment);
    }
    return List.unmodifiable(normalized);
  }

  List<Map<String, dynamic>> _validatedFiles(
    List<AiFileAttachmentInput> files,
  ) {
    if (files.length > maxFiles) {
      throw const HostedAgentInputException(
        code: 'too_many_attachments',
        message: 'Hosted Agent has too many office attachments.',
      );
    }
    const allowedMimeTypes = {
      'application/pdf',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    };
    final ids = <String>{};
    var totalBytes = 0;
    return List.unmodifiable(
      files.map((file) {
        final id = file.id.trim();
        final name = file.name.trim();
        final mimeType = file.mimeType.trim().toLowerCase();
        final extension = switch (mimeType) {
          'application/pdf' => '.pdf',
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document' =>
            '.docx',
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' =>
            '.xlsx',
          _ => '',
        };
        if (id.isEmpty ||
            id.length > maxAttachmentIdChars ||
            !ids.add(id) ||
            name.isEmpty ||
            name.length > maxAttachmentNameChars ||
            name.contains('/') ||
            name.contains(r'\') ||
            extension.isEmpty ||
            !name.toLowerCase().endsWith(extension) ||
            !allowedMimeTypes.contains(mimeType) ||
            file.bytes.isEmpty ||
            file.bytes.length > maxFileBytes ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(file.sha256)) {
          throw const HostedAgentInputException(
            code: 'invalid_attachment',
            message: 'Hosted Agent office attachment is invalid.',
          );
        }
        totalBytes += file.bytes.length;
        if (totalBytes > maxTotalFileBytes) {
          throw const HostedAgentInputException(
            code: 'attachments_too_large',
            message: 'Hosted Agent office attachments are too large.',
          );
        }
        return {
          'id': id,
          'name': name,
          'mimeType': mimeType,
          'data': base64.encode(file.bytes),
          'byteLength': file.bytes.length,
          'sha256': file.sha256,
        };
      }),
    );
  }

  String _validatedIdempotencyKey(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > 128) {
      throw const HostedAgentInputException(
        code: 'invalid_idempotency_key',
        message: 'Hosted chat Idempotency-Key must contain 1-128 characters.',
      );
    }
    return normalized;
  }

  Map<String, String>? _chatThinkingPayload() {
    if (!supportsDeepSeekThinking(model: model)) return null;
    final effort = thinkingLevel.deepSeekReasoningEffort;
    final payload = <String, String>{
      'type': effort == null ? 'disabled' : 'enabled',
    };
    if (effort != null) payload['reasoning_effort'] = effort;
    return payload;
  }

  /// Compatibility wrapper for callers that have not adopted the typed v4
  /// signature yet. The client-authored system/user prompt is never sent.
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
    required String idempotencyKey,
  }) {
    return chatStreamV4(
      question: userQuestion,
      images: images,
      history: _legacyHistoryWithProvenance(history),
      knowledgeMode: HostedChatKnowledgeMode.hybrid,
      length: maxTokens > 1000
          ? HostedChatLength.detailed
          : HostedChatLength.concise,
      language: HostedChatLanguage.followUser,
      webSearch: webSearch,
      localKnowledge: false,
      onEvent: onEvent,
      onRunCreated: onRunCreated,
      idempotencyKey: idempotencyKey,
    );
  }

  Stream<String> chatStreamV3({
    required String systemPrompt,
    required String userMessage,
    required String userQuestion,
    List<AiImageInput> images = const [],
    List<Map<String, String>> history = const [],
    double temperature = 0.3,
    int maxTokens = 800,
    bool webSearch = false,
    bool localKnowledge = false,
    String? knowledgeMode,
    void Function(HostedAgentEvent event)? onEvent,
    FutureOr<void> Function(String runId)? onRunCreated,
    required String idempotencyKey,
  }) {
    final mode = switch (knowledgeMode) {
      'only' => HostedChatKnowledgeMode.only,
      'hybrid' || null => HostedChatKnowledgeMode.hybrid,
      _ => throw const HostedAgentInputException(
        code: 'invalid_knowledge_mode',
        message: 'Hosted Agent local knowledge mode is invalid.',
      ),
    };
    return chatStreamV4(
      question: userQuestion,
      images: images,
      history: _legacyHistoryWithProvenance(history),
      knowledgeMode: mode,
      length: maxTokens > 1000
          ? HostedChatLength.detailed
          : HostedChatLength.concise,
      language: HostedChatLanguage.followUser,
      webSearch: webSearch,
      localKnowledge: localKnowledge,
      onEvent: onEvent,
      onRunCreated: onRunCreated,
      idempotencyKey: idempotencyKey,
    );
  }

  /// Creates a durable protocol-v4 hosted chat run and yields answer events.
  ///
  /// The request is intentionally typed around server-owned `memora.chat@2`.
  /// There is no system-prompt parameter. Historical private evidence is
  /// represented only by pair-equal, monotonic provenance flags.
  Stream<String> chatStreamV4({
    required String question,
    List<Map<String, dynamic>> history = const [],
    required HostedChatKnowledgeMode knowledgeMode,
    required HostedChatLength length,
    required HostedChatLanguage language,
    required bool webSearch,
    required bool localKnowledge,
    List<String>? enabledSkills,
    List<AiTextAttachmentInput> attachments = const [],
    List<AiFileAttachmentInput> files = const [],
    List<AiImageInput> images = const [],
    void Function(HostedAgentEvent event)? onEvent,
    FutureOr<void> Function(String runId)? onRunCreated,
    required String idempotencyKey,
  }) {
    return _chatStreamInternal(
      question: question,
      history: history,
      knowledgeMode: knowledgeMode,
      length: length,
      language: language,
      webSearch: webSearch,
      localKnowledge: localKnowledge,
      enabledSkills: enabledSkills,
      attachments: attachments,
      files: files,
      images: images,
      onEvent: onEvent,
      onRunCreated: onRunCreated,
      idempotencyKey: idempotencyKey,
    );
  }

  Stream<String> _chatStreamInternal({
    required String question,
    required List<Map<String, dynamic>> history,
    required HostedChatKnowledgeMode knowledgeMode,
    required HostedChatLength length,
    required HostedChatLanguage language,
    required bool webSearch,
    required bool localKnowledge,
    required List<String>? enabledSkills,
    required List<AiTextAttachmentInput> attachments,
    required List<AiFileAttachmentInput> files,
    required List<AiImageInput> images,
    void Function(HostedAgentEvent event)? onEvent,
    FutureOr<void> Function(String runId)? onRunCreated,
    required String idempotencyKey,
  }) async* {
    _resetRunState();
    if (!isConfigured) {
      lastError = 'Hosted Agent is not configured';
      return;
    }

    var session = await _freshSession();
    if (session == null) return;

    final normalizedQuestion = _validatedQuestion(question);
    final normalizedHistory = _validatedHistory(history);
    final normalizedAttachments = _validatedAttachments(attachments);
    final normalizedFiles = _validatedFiles(files);
    final normalizedKey = _validatedIdempotencyKey(idempotencyKey);
    _validateImages(images);
    final hasPrivateEvidence =
        normalizedHistory.privateEvidence ||
        normalizedAttachments.isNotEmpty ||
        normalizedFiles.isNotEmpty ||
        images.isNotEmpty;
    final effectiveWebSearch = hasPrivateEvidence ? false : webSearch;
    final normalizedSkills = _validatedSelectedSkills(enabledSkills);
    final thinking = _chatThinkingPayload();
    final requestBody = <String, dynamic>{
      'protocol_version': 4,
      'prompt_spec': 'memora.chat@2',
      'model': model,
      'question': normalizedQuestion,
      'history': normalizedHistory.messages,
      'knowledge_mode': knowledgeMode.wireName,
      'length': length.wireName,
      'language': language.wireName,
      'web_search': effectiveWebSearch,
      'local_knowledge': localKnowledge,
      if (normalizedAttachments.isNotEmpty)
        'attachments': normalizedAttachments,
      if (normalizedFiles.isNotEmpty) 'files': normalizedFiles,
      if (images.isNotEmpty)
        'images': images
            .map(
              (image) => {
                'type': 'image',
                'data': base64.encode(image.bytes),
                'mimeType': image.mimeType.trim().toLowerCase(),
              },
            )
            .toList(growable: false),
    };
    if (normalizedSkills != null) requestBody['skills'] = normalizedSkills;
    if (thinking != null) requestBody['thinking'] = thinking;

    Map<String, dynamic>? created;
    var refreshedCreateSession = false;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (_createCancelled) {
        lastError = 'Hosted Agent request was cancelled.';
        return;
      }
      try {
        created = await _createRun(session!, requestBody, normalizedKey);
        break;
      } on HostedAgentInputException {
        rethrow;
      } on _RunHttpException catch (error) {
        lastStatusCode = error.statusCode;
        lastError = 'HTTP ${error.statusCode}: ${_responseError(error.body)}';
        if (error.statusCode == 401 && !refreshedCreateSession) {
          refreshedCreateSession = true;
          final refreshed = await _refreshSession();
          if (refreshed != null && _bindOrValidateSession(refreshed)) {
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
        if (attempt < 2) continue;
        return;
      } on http.ClientException catch (error) {
        if (_createCancelled) {
          lastError = 'Hosted Agent request was cancelled.';
          return;
        }
        lastError = 'Hosted Agent request failed: $error';
        if (attempt < 2) continue;
        return;
      } on FormatException catch (error) {
        lastError = 'Hosted Agent returned an invalid response: $error';
        if (attempt < 2) continue;
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

    final streamedAnswer = StringBuffer();
    try {
      await for (final delta in _watchRunWithReconnect(
        runId,
        session: session!,
        onEvent: onEvent,
      )) {
        if (delta.isEmpty) continue;
        if (!lastChunkIsFullAnswer) {
          streamedAnswer.write(delta);
          yield delta;
          continue;
        }

        // `run.result.answer` is an authoritative full-frame copy. Current
        // workers send it after the same OpenAI-style completion deltas, so
        // forwarding it unchanged would make every append-only consumer render
        // the answer twice. Emit only a suffix that was not already streamed;
        // a result-only run still yields its complete answer.
        final streamed = streamedAnswer.toString();
        if (streamed.isEmpty) {
          streamedAnswer.write(delta);
          yield delta;
        } else if (delta.startsWith(streamed)) {
          final suffix = delta.substring(streamed.length);
          streamedAnswer
            ..clear()
            ..write(delta);
          if (suffix.isNotEmpty) yield suffix;
        } else {
          // A divergent result violates the append-only stream contract. Keep
          // surfacing the authoritative frame instead of silently losing it.
          streamedAnswer
            ..clear()
            ..write(delta);
          yield delta;
        }
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
            if (!_bindOrValidateSession(refreshed)) {
              throw HostedAgentResumeException(
                message: lastError!,
                statusCode: 401,
                retryable: false,
              );
            }
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
    String idempotencyKey,
  ) async {
    if (!_isCurrentSessionIdentity(session)) {
      throw const HostedAgentInputException(
        code: 'hosted_identity_changed',
        message: 'The hosted AI account or device changed before create.',
      );
    }
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
      final request = http.Request('POST', BackendConfig.uri('/ai/chat/runs'))
        ..headers.addAll({
          'Authorization': 'Bearer ${session.accessToken}',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Idempotency-Key': idempotencyKey,
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

  Future<HostedAgentSkillCatalog> _fetchSkillCatalog(
    AuthSession session,
  ) async {
    if (!_isCurrentSessionIdentity(session)) {
      throw const HostedAgentInputException(
        code: 'hosted_identity_changed',
        message: 'The hosted AI account or device changed.',
      );
    }
    final client = http.Client();
    try {
      final request = http.Request('GET', BackendConfig.uri('/ai/agent/skills'))
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
        throw const FormatException(
          'Hosted Agent returned invalid Skill catalog JSON.',
        );
      }
      return HostedAgentSkillCatalog.fromJson(decoded);
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
          if (!_bindOrValidateSession(refreshed)) {
            throw StateError(lastError!);
          }
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

    final type = (decoded['type'] ?? eventName).toString();
    if (type == 'client_tool.pending') {
      final runId = decoded['runId'];
      if (runId is String && runId == lastRunId && _validRunId(runId)) {
        _onClientToolWake?.call(HostedAgentClientToolWake(runId));
      }
      // A client-tool SSE event is a wake-up only. Do not retain or surface
      // its untrusted payload; the global host fetches authoritative REST.
      return null;
    }

    final event = HostedAgentEvent(
      type: type,
      data: _sanitizePublicEvent(decoded),
    );
    _captureSources(decoded['sources']);
    if (event.type == 'run.result') {
      _captureSources(decoded['sources']);
      _captureLocalSources(decoded['localSources']);
      _capturePrivateEvidenceUsed(decoded['privateEvidenceUsed']);
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
    _captureLocalSources(decoded['localSources']);
    _capturePrivateEvidenceUsed(decoded['privateEvidenceUsed']);
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
    final event = HostedAgentEvent(
      type: 'run.snapshot',
      data: _sanitizePublicEvent(decoded),
    );
    onEvent?.call(event);
  }

  void _capturePrivateEvidenceUsed(dynamic value) {
    if (value == null) {
      lastPrivateEvidenceUsed = false;
      return;
    }
    if (value is! bool) {
      throw const FormatException(
        'Hosted Agent response omitted private-evidence provenance.',
      );
    }
    lastPrivateEvidenceUsed = value;
  }

  void _captureSources(dynamic rawSources) {
    if (rawSources is! List || rawSources.isEmpty) return;
    if (rawSources.any(
      (source) =>
          source is Map &&
          (source.containsKey('articleRef') ||
              source.containsKey('article_ref')),
    )) {
      throw const FormatException(
        'Hosted Agent mixed device references into web sources.',
      );
    }
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

  void _captureLocalSources(dynamic rawSources) {
    if (rawSources == null) return;
    if (rawSources is! List) {
      throw const FormatException('Invalid local source response.');
    }
    final parsed = rawSources
        .map(
          (source) => HostedAgentLocalSource.fromJson(
            Map<String, dynamic>.from(source as Map),
          ),
        )
        .toList(growable: false);
    if (parsed.map((item) => item.id).toSet().length != parsed.length ||
        parsed.map((item) => item.articleRef).toSet().length != parsed.length) {
      throw const FormatException('Duplicate local source response.');
    }
    lastLocalSources = List.unmodifiable(parsed);
  }

  static Map<String, dynamic> _sanitizePublicEvent(Map<String, dynamic> value) {
    dynamic sanitize(dynamic item) {
      if (item is String) {
        return item.replaceAll(
          RegExp(r'\bar_[A-Za-z0-9_-]{22,64}\b'),
          '[device-reference]',
        );
      }
      if (item is List) return item.map(sanitize).toList(growable: false);
      if (item is Map) {
        final result = <String, dynamic>{};
        for (final entry in item.entries) {
          final key = entry.key.toString();
          if (key == 'localSources' ||
              key == 'articleRef' ||
              key == 'article_ref') {
            continue;
          }
          result[key] = sanitize(entry.value);
        }
        return result;
      }
      return item;
    }

    return Map<String, dynamic>.from(sanitize(value) as Map);
  }

  static bool _validRunId(String value) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value);

  void _resetRunState() {
    _createCancelled = false;
    lastError = null;
    lastStatusCode = null;
    lastRunId = null;
    lastEventSeq = 0;
    lastSources = const [];
    lastLocalSources = const [];
    lastEvents = const [];
    lastRunStatus = null;
    lastPrivateEvidenceUsed = false;
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
