import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

import '../../config/backend_config.dart';
import '../models/ai_image_input.dart';
import '../models/ai_thinking_level.dart';
import '../models/memory_document.dart';
import 'ai_service.dart';
import 'auth_service.dart';
import 'hosted_task_run_service.dart';

enum HostedAiPurpose {
  chat,
  summary;

  String get pathSegment => name;
}

/// Hosted AI gateway: requests are proxied through the Memora backend, which
/// holds its own model credentials. The client only needs a valid account
/// session; no user-supplied API key is required.
///
/// Legacy chat completion still uses the purpose-specific compatible route.
/// Summary, query rewrite, tags, and folder selection use immutable protocol-
/// v4 task profiles through [HostedTaskGateway]; BYOK remains on [AiService].
class HostedAiService implements AiGateway, MultimodalAiGateway {
  static const int _taskChunkSize = 12000;

  final AuthSession? Function() _getSession;
  final Future<AuthSession?> Function() _refreshSession;
  final HostedTaskGateway? _taskGateway;
  final String model;
  final HostedAiPurpose purpose;
  final Duration timeout;

  @override
  String? lastError;

  int? lastStatusCode;

  @override
  AiThinkingLevel thinkingLevel;

  HostedAiService({
    required AuthSession? Function() getSession,
    required Future<AuthSession?> Function() refreshSession,
    required this.model,
    required this.purpose,
    HostedTaskGateway? taskGateway,
    this.timeout = AiService.defaultTimeout,
    this.thinkingLevel = AiThinkingLevel.none,
  }) : _getSession = getSession,
       _refreshSession = refreshSession,
       _taskGateway = taskGateway;

  @override
  bool get isConfigured =>
      BackendConfig.isConfigured && model.trim().isNotEmpty;

  @override
  void Function(int totalTokens)? onTokensUsed;

  Future<bool> hasReplayableTaskGeneration({
    required String articleId,
    required String generation,
  }) async {
    final gateway = _taskGateway;
    if (gateway is! HostedTaskRunService) return false;
    return gateway.hasReplayableBindings(
      articleId: articleId,
      generation: generation,
    );
  }

  Future<void> finalizeTaskGeneration({
    required String articleId,
    required String generation,
  }) async {
    final gateway = _taskGateway;
    if (gateway is! HostedTaskRunService) return;
    await gateway.finalizeGeneration(
      articleId: articleId,
      generation: generation,
    );
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
    return session;
  }

  AiService _aiFor(AuthSession session) {
    final ai = AiService(
      baseUrl: BackendConfig.uri('/ai/${purpose.pathSegment}').toString(),
      apiKey: session.accessToken,
      model: model,
      timeout: timeout,
      thinkingLevel: thinkingLevel,
    );
    ai.onTokensUsed = onTokensUsed;
    return ai;
  }

  void _capture(AiService ai) {
    lastError = ai.lastError;
    lastStatusCode = ai.lastStatusCode;
  }

  Future<AiService?> _retryAfterUnauthorized(AiService attempted) async {
    _capture(attempted);
    if (attempted.lastStatusCode != 401) return null;
    final refreshed = await _refreshSession();
    if (refreshed == null) {
      lastError = 'Your session has expired. Sign in again.';
      lastStatusCode = 401;
      return null;
    }
    return _aiFor(refreshed);
  }

  @override
  Future<AiSummaryResult> summarizeWithTitle(
    String title,
    String content, {
    String languageHint = '',
  }) async {
    if (_taskGateway == null) {
      lastError = 'Hosted Pi summary tasks are unavailable.';
      lastStatusCode = null;
      return const AiSummaryResult();
    }
    return summarizeWithTitleTask(
      title,
      content,
      language: _summaryLanguageFromHint(languageHint),
    );
  }

  /// Protocol-v4 hosted summary path. BYOK callers keep using [AiService].
  Future<AiSummaryResult> summarizeWithTitleTask(
    String title,
    String content, {
    required HostedTaskSummaryLanguage language,
    String? operationKey,
    HostedTaskOperationContext? operation,
  }) async {
    lastError = null;
    lastStatusCode = null;
    final gateway = _taskGateway;
    if (gateway == null) {
      lastError = 'Hosted Pi summary tasks are unavailable.';
      return const AiSummaryResult();
    }
    final normalizedContent = content.trim();
    if (normalizedContent.isEmpty) {
      lastError = 'Article content is empty.';
      return const AiSummaryResult();
    }

    try {
      final chunkCount = (normalizedContent.length / _taskChunkSize).ceil();
      if (chunkCount > 1000) {
        lastError = 'Article is too long for hosted Pi summarization.';
        return const AiSummaryResult();
      }
      final planDigest = await _summaryPlanDigest(
        title: title,
        content: normalizedContent,
        language: language,
        chunkCount: chunkCount,
      );
      final summaryOperation = operation?.withPlanDigest(planDigest);
      final chunkInputs = <Map<String, dynamic>>[];
      for (var index = 0; index < chunkCount; index++) {
        final start = index * _taskChunkSize;
        final end = (start + _taskChunkSize).clamp(0, normalizedContent.length);
        final input = <String, dynamic>{
          if (title.trim().isNotEmpty) 'title': _limit(title.trim(), 2000),
          'content': normalizedContent.substring(start, end),
          'chunkIndex': index,
          'chunkCount': chunkCount,
          'language': language.wireName,
        };
        _preflight(gateway, HostedTaskProfile.summaryChunk, input);
        chunkInputs.add(input);
      }
      _preflightSummaryFinalPlan(
        gateway,
        title: title,
        chunkCount: chunkCount,
        language: language,
      );
      final chunkSummaries = <String>[];
      for (var index = 0; index < chunkCount; index++) {
        final idempotencyKey = _taskKey(
          'summary-chunk-$index',
          operationKey: operationKey,
        );
        final childOperation = summaryOperation?.child('summary.chunk.$index');
        final summary = await _runValidatedTask<String>(
          gateway: gateway,
          profile: HostedTaskProfile.summaryChunk,
          idempotencyKey: idempotencyKey,
          input: chunkInputs[index],
          operation: childOperation,
          validate: (task) => _requiredResultString(task, 'summaryMarkdown'),
        );
        chunkSummaries.add(summary);
      }

      final finalKey = _taskKey('summary-final', operationKey: operationKey);
      return await _runValidatedTask<AiSummaryResult>(
        gateway: gateway,
        profile: HostedTaskProfile.summaryFinal,
        idempotencyKey: finalKey,
        input: {
          if (title.trim().isNotEmpty) 'title': _limit(title.trim(), 2000),
          'chunks': chunkSummaries,
          'language': language.wireName,
        },
        operation: summaryOperation?.child('summary.final'),
        validate: _parseSummaryFinal,
      );
    } on HostedTaskRunException catch (error) {
      _captureTaskError(error);
      return const AiSummaryResult();
    } on FormatException catch (error) {
      lastError = error.message;
      return const AiSummaryResult();
    } catch (error) {
      lastError = 'Hosted Pi summary failed: $error';
      return const AiSummaryResult();
    }
  }

  Future<String?> rewriteQueryTask({
    required String question,
    required List<Map<String, String>> conversation,
    required HostedTaskRewriteLanguage language,
  }) async {
    final gateway = _taskGateway;
    if (gateway == null) {
      lastError = 'Hosted Pi query-rewrite task is unavailable.';
      return null;
    }
    try {
      final input = <String, dynamic>{
        'question': _limit(question.trim(), 8000),
        if (conversation.isNotEmpty)
          'conversation': conversation
              .take(20)
              .map(
                (message) => {
                  'role': message['role'] == 'assistant' ? 'assistant' : 'user',
                  'content': _limit((message['content'] ?? '').trim(), 8000),
                },
              )
              .where((message) => message['content']!.isNotEmpty)
              .toList(growable: false),
        'language': language.wireName,
      };
      _preflight(gateway, HostedTaskProfile.retrievalRewrite, input);
      return await _runValidatedTask<String>(
        gateway: gateway,
        profile: HostedTaskProfile.retrievalRewrite,
        idempotencyKey: _taskKey('retrieval-rewrite'),
        input: input,
        validate: (task) => _requiredResultString(task, 'query'),
      );
    } on HostedTaskRunException catch (error) {
      _captureTaskError(error);
      return null;
    } on FormatException catch (error) {
      lastError = error.message;
      return null;
    }
  }

  Future<List<String>> generateTagsTask({
    required String title,
    required String summary,
    required String content,
    required List<String> existingTags,
    required HostedTaskSummaryLanguage language,
    String? operationKey,
    HostedTaskOperationContext? operation,
  }) async {
    final gateway = _taskGateway;
    if (gateway == null) {
      throw const HostedTaskRunException(
        code: 'hosted_tasks_unavailable',
        message: 'Hosted Pi tag task is unavailable.',
        retryable: true,
      );
    }
    final input = <String, dynamic>{
      if (title.trim().isNotEmpty) 'title': _limit(title.trim(), 2000),
      if (summary.trim().isNotEmpty) 'summary': _limit(summary.trim(), 500000),
      if (content.trim().isNotEmpty) 'content': _limit(content.trim(), 500000),
      if (existingTags.isNotEmpty)
        'existingTags': existingTags
            .map((tag) => _limit(tag.trim(), 80))
            .where((tag) => tag.isNotEmpty)
            .take(200)
            .toList(growable: false),
      'language': language.wireName,
    };
    _preflight(gateway, HostedTaskProfile.memoryTags, input);
    final idempotencyKey = _taskKey('memory-tags', operationKey: operationKey);
    final childOperation = operation?.child('memory.tags');
    return _runValidatedTask<List<String>>(
      gateway: gateway,
      profile: HostedTaskProfile.memoryTags,
      idempotencyKey: idempotencyKey,
      input: input,
      operation: childOperation,
      validate: (task) {
        final raw = task.result['tags'];
        if (raw is! List || raw.any((tag) => tag is! String)) {
          throw const FormatException(
            'Hosted Pi tag task returned invalid tags.',
          );
        }
        return raw
            .cast<String>()
            .map((tag) => tag.trim())
            .where((tag) => tag.isNotEmpty)
            .take(12)
            .toList(growable: false);
      },
    );
  }

  Future<String?> suggestFolderTask({
    required String title,
    required String summary,
    required List<String> tags,
    required List<HostedTaskFolderCandidate> folders,
    required HostedTaskSummaryLanguage language,
    String? operationKey,
    HostedTaskOperationContext? operation,
  }) async {
    final gateway = _taskGateway;
    if (gateway == null) {
      throw const HostedTaskRunException(
        code: 'hosted_tasks_unavailable',
        message: 'Hosted Pi folder task is unavailable.',
        retryable: true,
      );
    }
    final input = <String, dynamic>{
      if (title.trim().isNotEmpty) 'title': _limit(title.trim(), 2000),
      if (summary.trim().isNotEmpty) 'summary': _limit(summary.trim(), 500000),
      if (tags.isNotEmpty)
        'tags': tags
            .map((tag) => _limit(tag.trim(), 80))
            .where((tag) => tag.isNotEmpty)
            .take(200)
            .toList(growable: false),
      'folders': folders
          .where(
            (folder) =>
                folder.id.trim().isNotEmpty && folder.name.trim().isNotEmpty,
          )
          .take(5000)
          .map(
            (folder) => {
              'id': _limit(folder.id.trim(), 200),
              'name': _limit(folder.name.trim(), 500),
            },
          )
          .toList(growable: false),
      'language': language.wireName,
    };
    _preflight(gateway, HostedTaskProfile.memoryFolder, input);
    final idempotencyKey = _taskKey(
      'memory-folder',
      operationKey: operationKey,
    );
    final childOperation = operation?.child('memory.folder');
    return _runValidatedTask<String?>(
      gateway: gateway,
      profile: HostedTaskProfile.memoryFolder,
      idempotencyKey: idempotencyKey,
      input: input,
      operation: childOperation,
      validate: (task) {
        final folderId = task.result['folderId'];
        if (folderId == null) return null;
        if (folderId is! String || folderId.trim().isEmpty) {
          throw const FormatException(
            'Hosted Pi folder task returned an invalid folder id.',
          );
        }
        return folderId.trim();
      },
    );
  }

  Future<String> _summaryPlanDigest({
    required String title,
    required String content,
    required HostedTaskSummaryLanguage language,
    required int chunkCount,
  }) async {
    final material = jsonEncode({
      'version': 1,
      'model': model.trim(),
      'title': title.trim(),
      'content': content,
      'language': language.wireName,
      'profiles': [
        {
          'id': HostedTaskProfile.summaryChunk.wireName,
          'version': hostedTaskProfileVersion,
          'resultSchemaVersion': hostedTaskResultSchemaVersion,
        },
        {
          'id': HostedTaskProfile.summaryFinal.wireName,
          'version': hostedTaskProfileVersion,
          'resultSchemaVersion': hostedTaskResultSchemaVersion,
        },
      ],
      'chunking': {
        'algorithm': 'utf16-code-units',
        'maxCodeUnits': _taskChunkSize,
        'chunkCount': chunkCount,
      },
    });
    final digest = await Sha256().hash(utf8.encode(material));
    return digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<T> _runValidatedTask<T>({
    required HostedTaskGateway gateway,
    required HostedTaskProfile profile,
    required String idempotencyKey,
    required Map<String, dynamic> input,
    HostedTaskOperationContext? operation,
    required T Function(HostedTaskRunResult task) validate,
  }) async {
    final task = await gateway.run(
      profile: profile,
      idempotencyKey: idempotencyKey,
      input: input,
      operation: operation,
    );
    try {
      return validate(task);
    } on FormatException catch (error) {
      if (gateway is HostedTaskResultInvalidator) {
        final invalidator = gateway as HostedTaskResultInvalidator;
        await invalidator.invalidateResult(
          result: task,
          idempotencyKey: idempotencyKey,
          operation: operation,
        );
      }
      throw HostedTaskRunException(
        code: 'invalid_task_result',
        message: error.message,
        retryable: true,
        runId: task.runId,
      );
    }
  }

  static AiSummaryResult _parseSummaryFinal(HostedTaskRunResult finalTask) {
    final generatedTitle = _requiredResultString(finalTask, 'title');
    final overview = _requiredResultString(finalTask, 'overview');
    final rawConclusion = finalTask.result['conclusion'];
    if (rawConclusion is! String) {
      throw const FormatException(
        'Hosted Pi summary.final task returned invalid conclusion.',
      );
    }
    final rawPoints = finalTask.result['keyPoints'];
    if (rawPoints is! List || rawPoints.isEmpty) {
      throw const FormatException(
        'Hosted Pi summary.final task returned invalid keyPoints.',
      );
    }
    final keyPoints = <MemoryKeyPoint>[];
    for (final rawPoint in rawPoints) {
      if (rawPoint is! Map) {
        throw const FormatException(
          'Hosted Pi summary.final task returned an invalid key point.',
        );
      }
      final point = Map<String, dynamic>.from(rawPoint);
      final topic = point['topic'];
      final pointContent = point['content'];
      if (topic is! String ||
          topic.trim().isEmpty ||
          pointContent is! String ||
          pointContent.trim().isEmpty) {
        throw const FormatException(
          'Hosted Pi summary.final task returned an invalid key point.',
        );
      }
      keyPoints.add(
        MemoryKeyPoint(
          id: 'kp_${const Uuid().v4()}',
          order: keyPoints.length + 1,
          topic: topic.trim(),
          content: pointContent.trim(),
        ),
      );
    }
    final memory = MemoryDocument.ai(
      overview: overview,
      keyPoints: keyPoints,
      conclusion: rawConclusion.trim(),
    );
    return AiSummaryResult(title: generatedTitle, memory: memory);
  }

  static HostedTaskSummaryLanguage _summaryLanguageFromHint(String hint) {
    final normalized = hint.trim().toLowerCase();
    if (normalized.contains('must respond in chinese')) {
      return HostedTaskSummaryLanguage.zhCn;
    }
    if (normalized.contains('must respond in english')) {
      return HostedTaskSummaryLanguage.en;
    }
    return HostedTaskSummaryLanguage.followSource;
  }

  static void _preflight(
    HostedTaskGateway gateway,
    HostedTaskProfile profile,
    Map<String, dynamic> input,
  ) {
    if (gateway is! HostedTaskRequestPreflight) return;
    final preflight = gateway as HostedTaskRequestPreflight;
    preflight.validateRequest(profile: profile, input: input);
  }

  void _preflightSummaryFinalPlan(
    HostedTaskGateway gateway, {
    required String title,
    required int chunkCount,
    required HostedTaskSummaryLanguage language,
  }) {
    if (gateway is! HostedTaskRequestPreflight) return;
    final preflight = gateway as HostedTaskRequestPreflight;
    final emptyChunks = List<String>.filled(chunkCount, '', growable: false);
    final emptyBody = jsonEncode({
      'task': HostedTaskProfile.summaryFinal.wireName,
      'task_version': hostedTaskProfileVersion,
      'model': model.trim(),
      'input': {
        if (title.trim().isNotEmpty) 'title': _limit(title.trim(), 2000),
        'chunks': emptyChunks,
        'language': language.wireName,
      },
    });
    // summary.chunk's protocol-v1 result allows 20,000 UTF-16 code units.
    // JSON escapes a control code unit as six ASCII bytes (`\\u00xx`), which
    // is a stricter bound than raw UTF-8. Adding that expansion to the exact
    // empty envelope guarantees summary.final can fit before any paid chunk.
    const worstChunkUtf8Bytes = 20000 * 6;
    final worstCaseBytes =
        utf8.encode(emptyBody).length + (chunkCount * worstChunkUtf8Bytes);
    if (worstCaseBytes > preflight.maxBodyBytes) {
      throw HostedTaskRunException(
        code: 'hosted_task_request_too_large',
        message:
            'Hosted Pi summary would require up to $worstCaseBytes bytes; '
            'the server limit is ${preflight.maxBodyBytes} bytes.',
        statusCode: 413,
        retryable: false,
      );
    }
  }

  static String _requiredResultString(HostedTaskRunResult task, String field) {
    final value = task.result[field];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException(
        'Hosted Pi ${task.profile.wireName} task returned invalid $field.',
      );
    }
    return value.trim();
  }

  void _captureTaskError(HostedTaskRunException error) {
    lastError = error.message;
    lastStatusCode = error.statusCode;
  }

  static String _taskKey(String purpose, {String? operationKey}) {
    final stable = operationKey?.trim();
    if (stable == null || stable.isEmpty) {
      return 'memora-$purpose-${const Uuid().v4()}';
    }
    final key = '$stable-$purpose';
    if (key.length > 128) {
      throw const FormatException('Hosted Pi task operation key is too long.');
    }
    return key;
  }

  static String _limit(String value, int maxLength) =>
      value.length <= maxLength ? value : value.substring(0, maxLength);

  @override
  Future<String?> chat({
    required String systemPrompt,
    required String userMessage,
    List<Map<String, String>> history = const [],
    double temperature = 0.3,
    int maxTokens = 800,
  }) async {
    lastError = null;
    lastStatusCode = null;
    final session = await _freshSession();
    if (session == null) return null;
    var ai = _aiFor(session);
    var result = await ai.chat(
      systemPrompt: systemPrompt,
      userMessage: userMessage,
      history: history,
      temperature: temperature,
      maxTokens: maxTokens,
    );
    final retry = await _retryAfterUnauthorized(ai);
    if (retry != null) {
      ai = retry;
      result = await ai.chat(
        systemPrompt: systemPrompt,
        userMessage: userMessage,
        history: history,
        temperature: temperature,
        maxTokens: maxTokens,
      );
    }
    _capture(ai);
    return result;
  }

  @override
  Stream<String> chatStream({
    required String systemPrompt,
    required String userMessage,
    List<Map<String, String>> history = const [],
    double temperature = 0.3,
    int maxTokens = 800,
  }) async* {
    lastError = null;
    lastStatusCode = null;
    final session = await _freshSession();
    if (session == null) return;

    var ai = _aiFor(session);
    var emitted = false;
    await for (final chunk in ai.chatStream(
      systemPrompt: systemPrompt,
      userMessage: userMessage,
      history: history,
      temperature: temperature,
      maxTokens: maxTokens,
    )) {
      emitted = true;
      yield chunk;
    }

    // A 401 can arrive before the first SSE delta. Refresh once and replay the
    // request in that case. Never replay after content has reached the UI,
    // otherwise the answer would be duplicated.
    final retry = await _retryAfterUnauthorized(ai);
    if (retry != null && !emitted) {
      ai = retry;
      await for (final chunk in ai.chatStream(
        systemPrompt: systemPrompt,
        userMessage: userMessage,
        history: history,
        temperature: temperature,
        maxTokens: maxTokens,
      )) {
        emitted = true;
        yield chunk;
      }
    }
    _capture(ai);
  }

  @override
  Stream<String> chatStreamWithImages({
    required String systemPrompt,
    required String userMessage,
    required List<AiImageInput> images,
    List<Map<String, String>> history = const [],
    double temperature = 0.3,
    int maxTokens = 800,
  }) async* {
    lastError = null;
    lastStatusCode = null;
    final session = await _freshSession();
    if (session == null) return;

    var ai = _aiFor(session);
    var emitted = false;
    await for (final chunk in ai.chatStreamWithImages(
      systemPrompt: systemPrompt,
      userMessage: userMessage,
      images: images,
      history: history,
      temperature: temperature,
      maxTokens: maxTokens,
    )) {
      emitted = true;
      yield chunk;
    }

    final retry = await _retryAfterUnauthorized(ai);
    if (retry != null && !emitted) {
      ai = retry;
      await for (final chunk in ai.chatStreamWithImages(
        systemPrompt: systemPrompt,
        userMessage: userMessage,
        images: images,
        history: history,
        temperature: temperature,
        maxTokens: maxTokens,
      )) {
        emitted = true;
        yield chunk;
      }
    }
    _capture(ai);
  }
}

class HostedTaskFolderCandidate {
  final String id;
  final String name;

  const HostedTaskFolderCandidate({required this.id, required this.name});
}
