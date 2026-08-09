import '../../config/backend_config.dart';
import '../models/ai_image_input.dart';
import '../models/ai_thinking_level.dart';
import 'ai_service.dart';
import 'auth_service.dart';

enum HostedAiPurpose {
  chat,
  summary;

  String get pathSegment => name;
}

/// Hosted AI gateway: requests are proxied through the Memora backend, which
/// holds its own model credentials. The client only needs a valid account
/// session; no user-supplied API key is required.
///
/// The backend exposes purpose-specific OpenAI-compatible endpoints under
/// `/ai/chat/v1/chat/completions` and `/ai/summary/v1/chat/completions`, so this
/// class can reuse [AiService]'s request building, chunking and structured
/// parsing while the server applies independent quotas.
class HostedAiService implements AiGateway, MultimodalAiGateway {
  final AuthSession? Function() _getSession;
  final Future<AuthSession?> Function() _refreshSession;
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
    this.timeout = AiService.defaultTimeout,
    this.thinkingLevel = AiThinkingLevel.none,
  }) : _getSession = getSession,
       _refreshSession = refreshSession;

  @override
  bool get isConfigured =>
      BackendConfig.isConfigured && model.trim().isNotEmpty;

  @override
  void Function(int totalTokens)? onTokensUsed;

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
    lastError = null;
    lastStatusCode = null;
    final session = await _freshSession();
    if (session == null) return const AiSummaryResult();
    var ai = _aiFor(session);
    var result = await ai.summarizeWithTitle(
      title,
      content,
      languageHint: languageHint,
    );
    final retry = await _retryAfterUnauthorized(ai);
    if (retry != null) {
      ai = retry;
      result = await ai.summarizeWithTitle(
        title,
        content,
        languageHint: languageHint,
      );
    }
    _capture(ai);
    return result;
  }

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
