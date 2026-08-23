import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:uuid/uuid.dart';

export 'chat_context_window.dart' show ChatContextWindow, RagConversationTurn;

import '../models/ai_image_input.dart';
import '../models/ai_text_attachment_input.dart';
import '../models/passage.dart';
import '../models/ai_thinking_level.dart';
import 'chat_context_window.dart';
import 'hosted_agent_service.dart';
import 'hosted_task_run_service.dart';
import 'prompt_service.dart';
import 'rag_citation.dart';
import 'rag_context_builder.dart';
import 'retrieval_log_service.dart';
import 'retrieval_service.dart';
import 'web_search_service.dart';

typedef RagRetrieve =
    Future<RetrievalResult> Function(String query, List<Article> articles);

typedef RagCompletion =
    Future<String?> Function({
      required String systemPrompt,
      required String userMessage,
      List<Map<String, String>> history,
      double temperature,
      int maxTokens,
    });

typedef RagCompletionStream =
    Stream<String> Function({
      required String systemPrompt,
      required String userMessage,
      List<Map<String, String>> history,
      double temperature,
      int maxTokens,
    });

typedef RagMultimodalCompletionStream =
    Stream<String> Function({
      required String systemPrompt,
      required String userMessage,
      required List<AiImageInput> images,
      List<Map<String, String>> history,
      double temperature,
      int maxTokens,
    });

typedef RagAgentCompletionStream =
    Stream<String> Function({
      required String systemPrompt,
      required String userMessage,
      List<Map<String, String>> history,
      double temperature,
      int maxTokens,
      required bool webSearch,
      void Function(HostedAgentEvent event)? onEvent,
    });

typedef RagAgentCompletionStreamWithRun =
    Stream<String> Function({
      required String systemPrompt,
      required String userMessage,
      required String userQuestion,
      required List<AiImageInput> images,
      List<Map<String, String>> history,
      double temperature,
      int maxTokens,
      required bool webSearch,
      void Function(HostedAgentEvent event)? onEvent,
      FutureOr<void> Function(String runId)? onRunCreated,
      String? idempotencyKey,
    });

typedef RagAgentCompletionStreamWithRunV3 =
    Stream<String> Function({
      required String systemPrompt,
      required String userMessage,
      required String userQuestion,
      required List<AiImageInput> images,
      List<Map<String, String>> history,
      double temperature,
      int maxTokens,
      required bool webSearch,
      required bool localKnowledge,
      String? knowledgeMode,
      void Function(HostedAgentEvent event)? onEvent,
      FutureOr<void> Function(String runId)? onRunCreated,
      String? idempotencyKey,
    });

typedef RagHostedChatRunStream =
    Stream<String> Function({
      required String question,
      required List<Map<String, dynamic>> history,
      required HostedChatKnowledgeMode knowledgeMode,
      required HostedChatLength length,
      required HostedChatLanguage language,
      required bool webSearch,
      required bool localKnowledge,
      required List<AiTextAttachmentInput> attachments,
      required List<AiImageInput> images,
      void Function(HostedAgentEvent event)? onEvent,
      FutureOr<void> Function(String runId)? onRunCreated,
      required String idempotencyKey,
    });

typedef RagCompletionError = String? Function();

typedef RagTaskQueryRewrite =
    Future<String?> Function({
      required String question,
      required List<Map<String, String>> conversation,
      required HostedTaskRewriteLanguage language,
    });

typedef RagAgentLocalCitationResolver =
    Future<List<String>> Function({
      required String runId,
      required String answer,
      required List<HostedAgentLocalSource> sources,
    });

typedef RagSaveLog = Future<void> Function(RetrievalLog log);

typedef RagWebSearch =
    Future<List<WebSearchResult>> Function(String query, {int topK});

class RagConversationRequest {
  final String question;
  final List<RagConversationTurn> history;
  final List<Article> articles;
  final bool knowledgeOnly;
  final bool detailedAnswer;
  final String languageHint;
  final HostedTaskRewriteLanguage rewriteLanguage;

  /// When true (and a web search backend is configured), local retrieval and
  /// live web search run together and both may contribute evidence.
  final bool webSearch;
  final int contextTokenBudget;
  final int contextWindowTokens;
  final AiThinkingLevel thinkingLevel;
  final String attachmentContext;
  final List<AiTextAttachmentInput> textAttachments;
  final List<AiImageInput> imageInputs;
  final HostedChatLanguage chatLanguage;

  /// Private provenance that must keep Web disabled even when the originating
  /// turn is intentionally absent from the selected prompt history, such as
  /// retrying that turn or trimming every completed pair for token budget.
  final bool privateEvidenceContext;

  const RagConversationRequest({
    required this.question,
    this.history = const [],
    required this.articles,
    required this.knowledgeOnly,
    required this.detailedAnswer,
    required this.languageHint,
    this.rewriteLanguage = HostedTaskRewriteLanguage.followQuestion,
    this.webSearch = false,
    this.contextTokenBudget = 2200,
    this.contextWindowTokens = ChatContextWindow.defaultContextWindowTokens,
    this.thinkingLevel = AiThinkingLevel.none,
    this.attachmentContext = '',
    this.textAttachments = const [],
    this.imageInputs = const [],
    this.chatLanguage = HostedChatLanguage.followUser,
    this.privateEvidenceContext = false,
  });
}

enum RagConversationOutcome { answer, noResult, error }

class RagConversationResult {
  final RagConversationOutcome outcome;
  final String? answer;
  final String? error;
  final String rewrittenQuery;
  final List<String> citedIds;
  final List<String> weakArticleIds;
  final String method;
  final String logId;

  /// Web URLs the model actually cited (via `[wN]`) this turn, in candidate
  /// order. Empty when no web evidence was cited.
  final List<String> webUrls;
  final bool privateEvidenceUsed;

  const RagConversationResult({
    required this.outcome,
    this.answer,
    this.error,
    required this.rewrittenQuery,
    this.citedIds = const [],
    this.weakArticleIds = const [],
    required this.method,
    required this.logId,
    this.webUrls = const [],
    this.privateEvidenceUsed = false,
  });
}

class HistoryAwareQueryRewriter {
  final RagCompletion _complete;
  final RagTaskQueryRewrite? _taskRewrite;
  final PromptService _prompts;
  final ChatContextWindow _contextWindow;

  const HistoryAwareQueryRewriter({
    required RagCompletion complete,
    RagTaskQueryRewrite? taskRewrite,
    required PromptService promptService,
    ChatContextWindow contextWindow = const ChatContextWindow(),
  }) : _complete = complete,
       _taskRewrite = taskRewrite,
       _prompts = promptService,
       _contextWindow = contextWindow;

  Future<String> rewrite({
    required String question,
    required List<RagConversationTurn> history,
    HostedTaskRewriteLanguage language =
        HostedTaskRewriteLanguage.followQuestion,
  }) async {
    final original = question.trim();
    if (original.isEmpty || history.isEmpty) return original;

    try {
      final recent = _contextWindow.selectRecentCompleteTurns(
        history,
        tokenBudget: 1200,
      );
      if (recent.isEmpty) return original;
      final transcript = recent
          .where((turn) => turn.content.trim().isNotEmpty)
          .map(
            (turn) => <String, String>{
              'role': turn.role,
              'content': turn.content.trim(),
            },
          )
          .toList(growable: false);
      final taskRewrite = _taskRewrite;
      if (taskRewrite != null) {
        final response = await taskRewrite(
          question: original,
          conversation: transcript,
          language: language,
        );
        final rewritten = _cleanRewrite(response);
        return rewritten ?? original;
      }
      final systemPrompt = await _prompts.load('chat/query_rewrite.txt');
      final response = await _complete(
        systemPrompt: systemPrompt,
        userMessage: jsonEncode({
          'conversation_history': transcript,
          'latest_question': original,
        }),
        history: const [],
        temperature: 0,
        maxTokens: 160,
      );
      final rewritten = _cleanRewrite(response);
      return rewritten ?? original;
    } catch (_) {
      return original;
    }
  }
}

class RagConversationService {
  final RagRetrieve _retrieve;
  final RagCompletion _complete;
  final RagCompletionStream? _completeStream;
  final RagMultimodalCompletionStream? _multimodalCompleteStream;
  final RagAgentCompletionStream? _agentCompleteStream;
  final RagAgentCompletionStreamWithRun? _agentRunStream;
  final RagAgentCompletionStreamWithRunV3? _agentRunStreamV3;
  final RagHostedChatRunStream? _hostedChatRunStream;
  final RagCompletionError? _completionError;
  final RagCompletionError? _agentCompletionError;
  final void Function(AiThinkingLevel level)? _configureThinking;
  final List<String> Function()? _agentWebUrls;
  final String? Function()? _agentRunId;
  final List<HostedAgentLocalSource> Function()? _agentLocalSources;
  final bool Function()? _agentPrivateEvidenceUsed;
  final RagAgentLocalCitationResolver? _resolveAgentLocalCitations;
  final bool _agentClientToolsEnabled;
  final RagSaveLog _saveLog;
  final PromptService _prompts;
  final RagContextBuilder _contextBuilder;
  final ChatContextWindow _contextWindow;
  final HistoryAwareQueryRewriter _queryRewriter;
  final RagWebSearch? _webSearch;
  final int _webTopK;

  RagConversationService({
    required RagRetrieve retrieve,
    required RagCompletion complete,
    RagCompletionStream? completeStream,
    RagMultimodalCompletionStream? multimodalCompleteStream,
    RagAgentCompletionStream? agentCompleteStream,
    RagAgentCompletionStreamWithRun? agentRunStream,
    RagAgentCompletionStreamWithRunV3? agentRunStreamV3,
    RagHostedChatRunStream? hostedChatRunStream,
    RagCompletionError? completionError,
    RagCompletionError? agentCompletionError,
    void Function(AiThinkingLevel level)? configureThinking,
    List<String> Function()? agentWebUrls,
    String? Function()? agentRunId,
    List<HostedAgentLocalSource> Function()? agentLocalSources,
    bool Function()? agentPrivateEvidenceUsed,
    RagAgentLocalCitationResolver? resolveAgentLocalCitations,
    bool agentClientToolsEnabled = false,
    required RagSaveLog saveLog,
    required PromptService promptService,
    RagContextBuilder contextBuilder = const RagContextBuilder(),
    ChatContextWindow contextWindow = const ChatContextWindow(),
    HistoryAwareQueryRewriter? queryRewriter,
    RagTaskQueryRewrite? taskQueryRewrite,
    RagWebSearch? webSearch,
    int webTopK = 5,
  }) : _retrieve = retrieve,
       _complete = complete,
       _completeStream = completeStream,
       _multimodalCompleteStream = multimodalCompleteStream,
       _agentCompleteStream = agentCompleteStream,
       _agentRunStream = agentRunStream,
       _agentRunStreamV3 = agentRunStreamV3,
       _hostedChatRunStream = hostedChatRunStream,
       _completionError = completionError,
       _agentCompletionError = agentCompletionError,
       _configureThinking = configureThinking,
       _agentWebUrls = agentWebUrls,
       _agentRunId = agentRunId,
       _agentLocalSources = agentLocalSources,
       _agentPrivateEvidenceUsed = agentPrivateEvidenceUsed,
       _resolveAgentLocalCitations = resolveAgentLocalCitations,
       _agentClientToolsEnabled = agentClientToolsEnabled,
       _saveLog = saveLog,
       _prompts = promptService,
       _contextBuilder = contextBuilder,
       _contextWindow = contextWindow,
       _webSearch = webSearch,
       _webTopK = webTopK,
       _queryRewriter =
           queryRewriter ??
           HistoryAwareQueryRewriter(
             complete: complete,
             taskRewrite: taskQueryRewrite,
             promptService: promptService,
             contextWindow: contextWindow,
           );

  Future<RagConversationResult> ask(RagConversationRequest request) {
    return askWithProgress(request);
  }

  /// Runs one RAG answer and reports model deltas as they arrive.
  ///
  /// Retrieval, prompt construction, citation validation, and logging remain
  /// exactly-once operations around the streamed completion. Callers that do
  /// not need live text can keep using [ask], which simply omits [onDelta].
  Future<RagConversationResult> askWithProgress(
    RagConversationRequest request, {
    void Function(String delta)? onDelta,
    void Function(HostedAgentEvent event)? onAgentEvent,
    FutureOr<void> Function(String runId)? onRunCreated,
    String? idempotencyKey,
  }) async {
    final question = request.question.trim();
    final logId = const Uuid().v4();
    final hasAttachments =
        request.attachmentContext.trim().isNotEmpty ||
        request.textAttachments.isNotEmpty ||
        request.imageInputs.isNotEmpty;
    if (hasAttachments) {
      _configureThinking?.call(request.thinkingLevel);
      return _askWithAttachments(
        request,
        question: question,
        logId: logId,
        onDelta: onDelta,
        onAgentEvent: onAgentEvent,
        onRunCreated: onRunCreated,
        idempotencyKey: idempotencyKey,
      );
    }

    if (_hostedChatRunStream != null || _agentRunStreamV3 != null) {
      _configureThinking?.call(request.thinkingLevel);
      return _askWithDeviceKnowledge(
        request,
        question: question,
        logId: logId,
        onDelta: onDelta,
        onAgentEvent: onAgentEvent,
        onRunCreated: onRunCreated,
        idempotencyKey: idempotencyKey,
      );
    }

    final privateEvidenceContext =
        request.privateEvidenceContext ||
        request.history.any((turn) => turn.privateEvidence);
    final effectiveWebSearch = request.webSearch && !privateEvidenceContext;

    _configureThinking?.call(AiThinkingLevel.none);
    late final String rewrittenQuery;
    try {
      rewrittenQuery = await _queryRewriter.rewrite(
        question: question,
        history: request.history,
        language: request.rewriteLanguage,
      );
    } finally {
      _configureThinking?.call(request.thinkingLevel);
    }

    // Start both operations before awaiting either one. Dart futures are
    // eager, so local retrieval and Tavily overlap instead of running in
    // sequence.
    final retrievalStopwatch = Stopwatch()..start();
    final retrievalFuture = _attemptRetrieval(rewrittenQuery, request.articles);
    final usesAgentCompletion = _hasAgentCompletion;
    final agentCanSearch = effectiveWebSearch && usesAgentCompletion;
    final webFuture =
        effectiveWebSearch && !agentCanSearch && _webSearch != null
        ? _attemptWebSearch(rewrittenQuery)
        : Future.value((fatalError: null, results: const <WebSearchResult>[]));
    final retrievalAttempt = await retrievalFuture;
    final webAttempt = await webFuture;
    final webResults = webAttempt.results;
    retrievalStopwatch.stop();

    if (webAttempt.fatalError != null) {
      return RagConversationResult(
        outcome: RagConversationOutcome.error,
        error: webAttempt.fatalError.toString(),
        rewrittenQuery: rewrittenQuery,
        method:
            retrievalAttempt.result?.method.name ?? RetrievalMethod.none.name,
        logId: logId,
      );
    }

    if (retrievalAttempt.result == null &&
        webResults.isEmpty &&
        !agentCanSearch) {
      return RagConversationResult(
        outcome: RagConversationOutcome.error,
        error: retrievalAttempt.error.toString(),
        rewrittenQuery: rewrittenQuery,
        method: RetrievalMethod.none.name,
        logId: logId,
      );
    }
    final retrieval =
        retrievalAttempt.result ??
        const RetrievalResult(
          articles: [],
          method: RetrievalMethod.none,
          duration: Duration.zero,
          candidateIds: [],
        );

    final candidateIds = retrieval.candidateIds.isNotEmpty
        ? retrieval.candidateIds
        : retrieval.articles.map((article) => article.id).toList();

    final useLocalContext = retrieval.articles.isNotEmpty;
    final useWebContext = webResults.isNotEmpty;
    final method = _methodFor(
      local: useLocalContext,
      web: useWebContext,
      retrievalMethod: retrieval.method,
    );

    if (!useLocalContext &&
        !useWebContext &&
        request.knowledgeOnly &&
        !agentCanSearch) {
      await _writeLog(
        logId: logId,
        question: question,
        rewrittenQuery: rewrittenQuery,
        method: RetrievalMethod.none.name,
        candidateIds: candidateIds,
        citedIds: const [],
        durationMs: retrievalStopwatch.elapsed.inMilliseconds,
      );
      return RagConversationResult(
        outcome: RagConversationOutcome.noResult,
        rewrittenQuery: rewrittenQuery,
        weakArticleIds: _weakCandidates(rewrittenQuery, request.articles),
        method: retrieval.method.name,
        logId: logId,
      );
    }

    try {
      // The base mode stays authoritative. Web rules are additive, so
      // enabling search cannot silently turn "knowledge + general" into a
      // strict evidence-only mode.
      final knowledgeRulePath = request.knowledgeOnly
          ? 'chat/knowledge_only.txt'
          : 'chat/knowledge_hybrid.txt';
      final userPromptPath = useWebContext
          ? 'chat/user_web.txt'
          : 'chat/user.txt';
      final lengthRulePath = request.detailedAnswer
          ? 'chat/length_detailed.txt'
          : 'chat/length_concise.txt';
      final baseKnowledgeRule = await _prompts.load(knowledgeRulePath);
      final webKnowledgeRule = useWebContext || agentCanSearch
          ? await _prompts.load('chat/knowledge_web.txt')
          : '';
      final knowledgeRule = [
        baseKnowledgeRule,
        if (webKnowledgeRule.isNotEmpty) webKnowledgeRule,
      ].join('\n\n');
      final lengthRule = await _prompts.load(lengthRulePath);
      final systemPrompt = await _prompts.load('chat/system.txt', {
        'knowledgeRule': knowledgeRule,
        'lengthRule': lengthRule,
        'langHint': request.languageHint.isEmpty
            ? ''
            : '\n${request.languageHint}',
      });
      final maxTokens = request.detailedAnswer ? 2500 : 1000;
      final baseUserMessage = await _prompts.load(userPromptPath, {
        'context': '',
        'question': question,
      });
      final fixedTokens = _contextWindow.estimateFixedPromptTokens(
        systemPrompt: systemPrompt,
        userMessage: baseUserMessage,
        maxOutputTokens: maxTokens,
      );
      final availableContextTokens = request.contextWindowTokens - fixedTokens;
      if (availableContextTokens <= 0) {
        await _writeLog(
          logId: logId,
          question: question,
          rewrittenQuery: rewrittenQuery,
          method: method,
          candidateIds: candidateIds,
          citedIds: const [],
          durationMs: retrievalStopwatch.elapsed.inMilliseconds,
        );
        return RagConversationResult(
          outcome: RagConversationOutcome.error,
          error: 'message exceeds the configured context window',
          rewrittenQuery: rewrittenQuery,
          method: method,
          logId: logId,
        );
      }
      final effectiveContextBudget =
          request.contextTokenBudget < availableContextTokens
          ? request.contextTokenBudget
          : availableContextTokens;

      final String contextText;
      final Map<String, String> citationMap;
      final List<String> webUrls;
      if (useWebContext) {
        const localHeading = '## 本地知识库\n';
        const webHeading = '## 联网搜索\n';
        final headingTokens =
            RagContextBuilder.estimateTokens(webHeading) +
            (useLocalContext
                ? RagContextBuilder.estimateTokens(localHeading)
                : 0);
        final bodyBudget = effectiveContextBudget > headingTokens
            ? effectiveContextBudget - headingTokens
            : 0;
        final localBudget = useLocalContext ? (bodyBudget * 3) ~/ 5 : 0;
        final webBudget = useLocalContext
            ? bodyBudget - localBudget
            : bodyBudget;
        final localContext = _contextBuilder.build(
          query: rewrittenQuery,
          candidates: retrieval.articles,
          tokenBudget: localBudget,
        );
        final webContext = _buildWebContext(webResults, tokenBudget: webBudget);
        final sections = <String>[
          if (localContext.text.isNotEmpty) '$localHeading${localContext.text}',
          if (webContext.text.isNotEmpty) '$webHeading${webContext.text}',
        ];
        contextText = sections.join('\n\n');
        citationMap = localContext.citationMap;
        webUrls = webContext.urls;
      } else {
        final context = _contextBuilder.build(
          query: rewrittenQuery,
          candidates: retrieval.articles,
          tokenBudget: effectiveContextBudget,
        );
        contextText = context.text;
        citationMap = context.citationMap;
        webUrls = const [];
      }
      final questionMessage = await _prompts.load(userPromptPath, {
        'context': contextText,
        'question': question,
      });
      final userMessage = questionMessage;
      final history = _contextWindow.selectForPrompt(
        systemPrompt: systemPrompt,
        userMessage: userMessage,
        history: request.history,
        maxOutputTokens: maxTokens,
        contextWindowTokens: request.contextWindowTokens,
      );
      final response = await _completeWithProgress(
        systemPrompt: systemPrompt,
        userMessage: userMessage,
        userQuestion: question,
        history: history.map((turn) => turn.toMessage()).toList(),
        hostedHistory: history
            .map((turn) => turn.toHostedMessage())
            .toList(growable: false),
        forcedPrivateEvidence: privateEvidenceContext,
        maxTokens: maxTokens,
        temperature: 0.3,
        webSearch: effectiveWebSearch,
        localKnowledge: false,
        hostedKnowledgeMode: request.knowledgeOnly
            ? HostedChatKnowledgeMode.only
            : HostedChatKnowledgeMode.hybrid,
        hostedLength: request.detailedAnswer
            ? HostedChatLength.detailed
            : HostedChatLength.concise,
        hostedLanguage: request.chatLanguage,
        textAttachments: const [],
        onDelta: onDelta,
        onAgentEvent: onAgentEvent,
        onRunCreated: onRunCreated,
        idempotencyKey: idempotencyKey,
        images: const [],
      );

      final agentWebUrls = usesAgentCompletion
          ? (_agentWebUrls?.call() ?? const <String>[])
          : const <String>[];
      final effectiveWebUrls = webUrls.isNotEmpty ? webUrls : agentWebUrls;
      final effectiveMethod = _methodFor(
        local: useLocalContext,
        web: effectiveWebUrls.isNotEmpty,
        retrievalMethod: retrieval.method,
      );

      final completionErrorReader = usesAgentCompletion
          ? (_agentCompletionError ?? _completionError)
          : _completionError;
      final rawCompletionError = completionErrorReader?.call()?.trim();
      final hasAnswer = response != null && response.trim().isNotEmpty;
      // Some Agent runs emit all answer deltas and then incorrectly report an
      // empty-response status. That status contradicts the completed text, so
      // do not turn a usable answer into a failed chat bubble. Other provider
      // errors (including a stream interruption after partial output) remain
      // visible to the user.
      final completionError =
          hasAnswer && _isEmptyResponseError(rawCompletionError)
          ? null
          : rawCompletionError;
      if (hasAnswer && completionError == null && rawCompletionError != null) {
        developer.log(
          'Ignoring contradictory empty-response completion error after text',
          name: 'memora.rag',
        );
      }
      if (response == null ||
          response.trim().isEmpty ||
          completionError != null && completionError.isNotEmpty) {
        await _writeLog(
          logId: logId,
          question: question,
          rewrittenQuery: rewrittenQuery,
          method: effectiveMethod,
          candidateIds: candidateIds,
          citedIds: const [],
          webCandidateUrls: effectiveWebUrls,
          webCitedUrls: const [],
          durationMs: retrievalStopwatch.elapsed.inMilliseconds,
        );
        return RagConversationResult(
          outcome: RagConversationOutcome.error,
          answer: response == null || response.trim().isEmpty ? null : response,
          error: completionError == null || completionError.isEmpty
              ? 'empty response'
              : completionError,
          rewrittenQuery: rewrittenQuery,
          method: effectiveMethod,
          logId: logId,
        );
      }

      final citedIds = extractValidCitations(
        response: response,
        citationMap: citationMap,
        validIds: request.articles.map((article) => article.id).toSet(),
      );
      final citedWebUrls = extractValidWebCitations(
        response: response,
        urls: effectiveWebUrls,
      );
      await _writeLog(
        logId: logId,
        question: question,
        rewrittenQuery: rewrittenQuery,
        method: effectiveMethod,
        candidateIds: candidateIds,
        citedIds: citedIds,
        webCandidateUrls: effectiveWebUrls,
        webCitedUrls: citedWebUrls,
        durationMs: retrievalStopwatch.elapsed.inMilliseconds,
      );
      return RagConversationResult(
        outcome: RagConversationOutcome.answer,
        answer: response,
        rewrittenQuery: rewrittenQuery,
        citedIds: List.unmodifiable(citedIds),
        method: effectiveMethod,
        logId: logId,
        webUrls: List.unmodifiable(citedWebUrls),
        privateEvidenceUsed:
            privateEvidenceContext ||
            useLocalContext ||
            (_agentPrivateEvidenceUsed?.call() ?? false),
      );
    } catch (error) {
      await _writeLog(
        logId: logId,
        question: question,
        rewrittenQuery: rewrittenQuery,
        method: method,
        candidateIds: candidateIds,
        citedIds: const [],
        webCandidateUrls: webResults.map((result) => result.url).toList(),
        webCitedUrls: const [],
        durationMs: retrievalStopwatch.elapsed.inMilliseconds,
      );
      return RagConversationResult(
        outcome: RagConversationOutcome.error,
        error: error.toString(),
        rewrittenQuery: rewrittenQuery,
        method: method,
        logId: logId,
      );
    }
  }

  /// Protocol-v3 hosted path. Local evidence remains on the authenticated
  /// current device and is supplied only through local_search/read_article;
  /// no query rewrite, retrieval result, or packed context is uploaded here.
  Future<RagConversationResult> _askWithDeviceKnowledge(
    RagConversationRequest request, {
    required String question,
    required String logId,
    void Function(String delta)? onDelta,
    void Function(HostedAgentEvent event)? onAgentEvent,
    FutureOr<void> Function(String runId)? onRunCreated,
    String? idempotencyKey,
  }) async {
    const method = 'agent';
    if (!_agentClientToolsEnabled && _hostedChatRunStream == null) {
      return RagConversationResult(
        outcome: RagConversationOutcome.error,
        error: 'Hosted Agent device tools are not available.',
        rewrittenQuery: question,
        method: method,
        logId: logId,
      );
    }
    final knowledgeMode = request.knowledgeOnly ? 'only' : 'hybrid';
    try {
      final lengthRule = await _prompts.load(
        request.detailedAnswer
            ? 'chat/length_detailed.txt'
            : 'chat/length_concise.txt',
      );
      final systemPrompt = await _prompts.load('chat/agent_system.txt', {
        'knowledgeMode': knowledgeMode,
        'lengthRule': lengthRule,
        'webRule': request.webSearch
            ? '允许在必要时使用服务端 web_search；只使用实际返回的 [wN] 引用。'
            : '本轮未授权联网搜索，不得声称查询了网络。',
        'langHint': request.languageHint.isEmpty
            ? ''
            : '\n${request.languageHint}',
      });
      final userMessage = '<user_question>\n$question\n</user_question>';
      final maxTokens = request.detailedAnswer ? 2500 : 1000;
      final history = _contextWindow.selectForPrompt(
        systemPrompt: systemPrompt,
        userMessage: userMessage,
        history: request.history,
        maxOutputTokens: maxTokens,
        contextWindowTokens: request.contextWindowTokens,
      );
      final response = await _completeWithProgress(
        systemPrompt: systemPrompt,
        userMessage: userMessage,
        userQuestion: question,
        history: history.map((turn) => turn.toMessage()).toList(),
        hostedHistory: history
            .map((turn) => turn.toHostedMessage())
            .toList(growable: false),
        forcedPrivateEvidence:
            request.privateEvidenceContext ||
            request.history.any((turn) => turn.privateEvidence),
        temperature: 0.3,
        maxTokens: maxTokens,
        webSearch: request.webSearch,
        localKnowledge: _agentClientToolsEnabled,
        knowledgeMode: knowledgeMode,
        hostedKnowledgeMode: request.knowledgeOnly
            ? HostedChatKnowledgeMode.only
            : HostedChatKnowledgeMode.hybrid,
        hostedLength: request.detailedAnswer
            ? HostedChatLength.detailed
            : HostedChatLength.concise,
        hostedLanguage: request.chatLanguage,
        textAttachments: const [],
        onDelta: onDelta,
        onAgentEvent: onAgentEvent,
        onRunCreated: onRunCreated,
        idempotencyKey: idempotencyKey,
        images: const [],
      );
      final completionError = _agentCompletionError?.call()?.trim();
      if (response == null ||
          response.trim().isEmpty ||
          completionError != null && completionError.isNotEmpty) {
        await _writeLog(
          logId: logId,
          question: question,
          rewrittenQuery: question,
          method: method,
        );
        return RagConversationResult(
          outcome: RagConversationOutcome.error,
          answer: response,
          error: completionError?.isNotEmpty == true
              ? completionError
              : 'empty response',
          rewrittenQuery: question,
          method: method,
          logId: logId,
        );
      }
      final webCandidates = _agentWebUrls?.call() ?? const <String>[];
      final citedWebUrls = extractValidWebCitations(
        response: response,
        urls: webCandidates,
      );
      final serverRunId = _agentRunId?.call();
      final localSources = _agentLocalSources?.call() ?? const [];
      final localCitationResolver = _resolveAgentLocalCitations;
      final citedIds = serverRunId == null || localCitationResolver == null
          ? const <String>[]
          : await localCitationResolver(
              runId: serverRunId,
              answer: response,
              sources: localSources,
            );
      final effectiveMethod = citedIds.isNotEmpty && citedWebUrls.isNotEmpty
          ? 'hybrid'
          : citedIds.isNotEmpty
          ? 'local'
          : citedWebUrls.isNotEmpty
          ? 'web'
          : method;
      await _writeLog(
        logId: logId,
        question: question,
        rewrittenQuery: question,
        method: effectiveMethod,
        candidateIds: citedIds,
        citedIds: citedIds,
        webCandidateUrls: webCandidates,
        webCitedUrls: citedWebUrls,
      );
      return RagConversationResult(
        outcome: RagConversationOutcome.answer,
        answer: response,
        rewrittenQuery: question,
        citedIds: List.unmodifiable(citedIds),
        method: effectiveMethod,
        logId: logId,
        webUrls: List.unmodifiable(citedWebUrls),
        privateEvidenceUsed: _agentPrivateEvidenceUsed?.call() ?? false,
      );
    } catch (error) {
      await _writeLog(
        logId: logId,
        question: question,
        rewrittenQuery: question,
        method: method,
      );
      return RagConversationResult(
        outcome: RagConversationOutcome.error,
        error: error.toString(),
        rewrittenQuery: question,
        method: method,
        logId: logId,
      );
    }
  }

  /// Runs the bounded attachment prompt without client-side retrieval or web
  /// prefetch. Hosted Pi runs still receive the user's web-search permission,
  /// so the Agent can invoke its server-side tool when appropriate.
  /// Hosted answers use the durable Pi Agent, including native image blocks;
  /// BYOK answers remain direct model completions. This path deliberately
  /// performs no query rewrite, local retrieval, web search, context packing,
  /// or citation extraction.
  Future<RagConversationResult> _askWithAttachments(
    RagConversationRequest request, {
    required String question,
    required String logId,
    void Function(String delta)? onDelta,
    void Function(HostedAgentEvent event)? onAgentEvent,
    FutureOr<void> Function(String runId)? onRunCreated,
    String? idempotencyKey,
  }) async {
    const method = 'attachment';
    try {
      final usesAgentCompletion =
          _hostedChatRunStream != null ||
          _agentRunStreamV3 != null ||
          _agentRunStream != null ||
          request.imageInputs.isEmpty && _agentCompleteStream != null;
      final agentCanSearch = request.webSearch && usesAgentCompletion;
      final lengthRulePath = request.detailedAnswer
          ? 'chat/length_detailed.txt'
          : 'chat/length_concise.txt';
      final lengthRule = await _prompts.load(lengthRulePath);
      final systemPrompt = await _prompts.load(
        'chat/attachments_direct_system.txt',
        {
          'lengthRule': lengthRule,
          'langHint': request.languageHint.isEmpty
              ? ''
              : '\n${request.languageHint}',
          'toolRule': agentCanSearch
              ? '- 不要执行本地知识库检索。当用户问题需要当前、变动、小众或明确要求的网络信息时，可以使用服务端 web_search；搜索结果必须用 [w1]、[w2] …引用，不得编造引用。'
              : '- 不要执行本地知识库检索或联网搜索，也不要声称使用了未提供给你的资料。',
        },
      );
      final attachmentBlock = await _prompts.load('chat/attachments.txt', {
        'attachments': request.attachmentContext.trim().isEmpty
            ? 'Images are attached to this message.'
            : request.attachmentContext.trim(),
      });
      final userMessage = [
        '<user_question>\n$question\n</user_question>',
        attachmentBlock,
      ].join('\n\n');
      final maxTokens = request.detailedAnswer ? 2500 : 1000;
      final effectiveContextWindow =
          request.contextWindowTokens - request.imageInputs.length * 600;
      final fixedTokens = _contextWindow.estimateFixedPromptTokens(
        systemPrompt: systemPrompt,
        userMessage: userMessage,
        maxOutputTokens: maxTokens,
      );
      if (effectiveContextWindow <= 0 || fixedTokens > effectiveContextWindow) {
        await _writeLog(
          logId: logId,
          question: question,
          rewrittenQuery: question,
          method: method,
        );
        return RagConversationResult(
          outcome: RagConversationOutcome.error,
          error: 'message exceeds the configured context window',
          rewrittenQuery: question,
          method: method,
          logId: logId,
        );
      }

      final history = _contextWindow.selectForPrompt(
        systemPrompt: systemPrompt,
        userMessage: userMessage,
        history: request.history,
        maxOutputTokens: maxTokens,
        contextWindowTokens: effectiveContextWindow,
      );
      final response = await _completeWithProgress(
        systemPrompt: systemPrompt,
        userMessage: userMessage,
        userQuestion: question,
        history: history.map((turn) => turn.toMessage()).toList(),
        hostedHistory: history
            .map((turn) => turn.toHostedMessage())
            .toList(growable: false),
        forcedPrivateEvidence:
            request.privateEvidenceContext ||
            request.history.any((turn) => turn.privateEvidence),
        temperature: 0.3,
        maxTokens: maxTokens,
        webSearch: request.webSearch,
        localKnowledge: false,
        hostedKnowledgeMode: request.knowledgeOnly
            ? HostedChatKnowledgeMode.only
            : HostedChatKnowledgeMode.hybrid,
        hostedLength: request.detailedAnswer
            ? HostedChatLength.detailed
            : HostedChatLength.concise,
        hostedLanguage: request.chatLanguage,
        textAttachments: request.textAttachments,
        onDelta: onDelta,
        onAgentEvent: onAgentEvent,
        onRunCreated: onRunCreated,
        idempotencyKey: idempotencyKey,
        images: request.imageInputs,
        preferLegacyAgent: true,
      );
      final agentWebUrls = usesAgentCompletion
          ? (_agentWebUrls?.call() ?? const <String>[])
          : const <String>[];

      final completionErrorReader = usesAgentCompletion
          ? (_agentCompletionError ?? _completionError)
          : _completionError;
      final rawCompletionError = completionErrorReader?.call()?.trim();
      final hasAnswer = response != null && response.trim().isNotEmpty;
      final completionError =
          hasAnswer && _isEmptyResponseError(rawCompletionError)
          ? null
          : rawCompletionError;
      if (hasAnswer && completionError == null && rawCompletionError != null) {
        developer.log(
          'Ignoring contradictory empty-response completion error after text',
          name: 'memora.chat.attachments',
        );
      }

      if (!hasAnswer || completionError != null && completionError.isNotEmpty) {
        await _writeLog(
          logId: logId,
          question: question,
          rewrittenQuery: question,
          method: method,
          webCandidateUrls: agentWebUrls,
          webCitedUrls: const [],
        );
        return RagConversationResult(
          outcome: RagConversationOutcome.error,
          answer: hasAnswer ? response : null,
          error: completionError == null || completionError.isEmpty
              ? 'empty response'
              : completionError,
          rewrittenQuery: question,
          method: method,
          logId: logId,
        );
      }
      final citedWebUrls = extractValidWebCitations(
        response: response,
        urls: agentWebUrls,
      );
      await _writeLog(
        logId: logId,
        question: question,
        rewrittenQuery: question,
        method: method,
        webCandidateUrls: agentWebUrls,
        webCitedUrls: citedWebUrls,
      );
      return RagConversationResult(
        outcome: RagConversationOutcome.answer,
        answer: response,
        rewrittenQuery: question,
        method: method,
        logId: logId,
        webUrls: List.unmodifiable(citedWebUrls),
        privateEvidenceUsed: _agentPrivateEvidenceUsed?.call() ?? false,
      );
    } catch (error) {
      await _writeLog(
        logId: logId,
        question: question,
        rewrittenQuery: question,
        method: method,
      );
      return RagConversationResult(
        outcome: RagConversationOutcome.error,
        error: error.toString(),
        rewrittenQuery: question,
        method: method,
        logId: logId,
      );
    }
  }

  Future<String?> _completeWithProgress({
    required String systemPrompt,
    required String userMessage,
    required String userQuestion,
    required List<Map<String, String>> history,
    required List<Map<String, dynamic>> hostedHistory,
    required bool forcedPrivateEvidence,
    required double temperature,
    required int maxTokens,
    required bool webSearch,
    required bool localKnowledge,
    String? knowledgeMode,
    required HostedChatKnowledgeMode hostedKnowledgeMode,
    required HostedChatLength hostedLength,
    required HostedChatLanguage hostedLanguage,
    required List<AiTextAttachmentInput> textAttachments,
    void Function(String delta)? onDelta,
    void Function(HostedAgentEvent event)? onAgentEvent,
    FutureOr<void> Function(String runId)? onRunCreated,
    String? idempotencyKey,
    required List<AiImageInput> images,
    bool preferLegacyAgent = false,
  }) async {
    final hostedChatRunStream = _hostedChatRunStream;
    if (hostedChatRunStream != null) {
      final requestKey = idempotencyKey?.trim() ?? '';
      if (requestKey.isEmpty) {
        throw StateError('Hosted chat requires a durable idempotency key.');
      }
      final hasPrivateEvidence =
          forcedPrivateEvidence ||
          textAttachments.isNotEmpty ||
          images.isNotEmpty ||
          hostedHistory.any((message) => message['private_evidence'] == true);
      final buffer = StringBuffer();
      await for (final delta in hostedChatRunStream(
        question: userQuestion,
        history: hostedHistory,
        knowledgeMode: hostedKnowledgeMode,
        length: hostedLength,
        language: hostedLanguage,
        webSearch: webSearch && !hasPrivateEvidence,
        localKnowledge: localKnowledge,
        attachments: textAttachments,
        images: images,
        onEvent: onAgentEvent,
        onRunCreated: onRunCreated,
        idempotencyKey: requestKey,
      )) {
        if (delta.isEmpty) continue;
        buffer.write(delta);
        onDelta?.call(delta);
      }
      final response = buffer.toString();
      return response.trim().isEmpty ? null : response;
    }

    final agentRunStreamV3 = _agentRunStreamV3;
    if (agentRunStreamV3 != null &&
        (!preferLegacyAgent || _agentRunStream == null)) {
      final buffer = StringBuffer();
      await for (final delta in agentRunStreamV3(
        systemPrompt: systemPrompt,
        userMessage: userMessage,
        userQuestion: userQuestion,
        images: images,
        history: history,
        temperature: temperature,
        maxTokens: maxTokens,
        webSearch: webSearch,
        localKnowledge: localKnowledge,
        knowledgeMode: knowledgeMode,
        onEvent: onAgentEvent,
        onRunCreated: onRunCreated,
        idempotencyKey: idempotencyKey,
      )) {
        if (delta.isEmpty) continue;
        buffer.write(delta);
        onDelta?.call(delta);
      }
      final response = buffer.toString();
      return response.trim().isEmpty ? null : response;
    }
    final agentRunStream = _agentRunStream;
    if (agentRunStream != null) {
      if (localKnowledge) {
        throw StateError('Hosted Agent device tools are not negotiated.');
      }
      final buffer = StringBuffer();
      await for (final delta in agentRunStream(
        systemPrompt: systemPrompt,
        userMessage: userMessage,
        userQuestion: userQuestion,
        images: images,
        history: history,
        temperature: temperature,
        maxTokens: maxTokens,
        webSearch: webSearch,
        onEvent: onAgentEvent,
        onRunCreated: onRunCreated,
        idempotencyKey: idempotencyKey,
      )) {
        if (delta.isEmpty) continue;
        buffer.write(delta);
        onDelta?.call(delta);
      }
      final response = buffer.toString();
      return response.trim().isEmpty ? null : response;
    }

    if (images.isNotEmpty) {
      final multimodalStream = _multimodalCompleteStream;
      if (multimodalStream == null) {
        throw StateError('The selected AI gateway cannot receive images.');
      }
      final buffer = StringBuffer();
      await for (final delta in multimodalStream(
        systemPrompt: systemPrompt,
        userMessage: userMessage,
        images: images,
        history: history,
        temperature: temperature,
        maxTokens: maxTokens,
      )) {
        if (delta.isEmpty) continue;
        buffer.write(delta);
        onDelta?.call(delta);
      }
      final response = buffer.toString();
      return response.trim().isEmpty ? null : response;
    }

    final agentStream = _agentCompleteStream;
    if (agentStream != null) {
      final buffer = StringBuffer();
      await for (final delta in agentStream(
        systemPrompt: systemPrompt,
        userMessage: userMessage,
        history: history,
        temperature: temperature,
        maxTokens: maxTokens,
        webSearch: webSearch,
        onEvent: onAgentEvent,
      )) {
        if (delta.isEmpty) continue;
        buffer.write(delta);
        onDelta?.call(delta);
      }
      final response = buffer.toString();
      return response.trim().isEmpty ? null : response;
    }

    final stream = _completeStream;
    if (stream == null) {
      return _complete(
        systemPrompt: systemPrompt,
        userMessage: userMessage,
        history: history,
        temperature: temperature,
        maxTokens: maxTokens,
      );
    }

    final buffer = StringBuffer();
    await for (final delta in stream(
      systemPrompt: systemPrompt,
      userMessage: userMessage,
      history: history,
      temperature: temperature,
      maxTokens: maxTokens,
    )) {
      if (delta.isEmpty) continue;
      buffer.write(delta);
      onDelta?.call(delta);
    }
    final response = buffer.toString();
    return response.trim().isEmpty ? null : response;
  }

  bool get _hasAgentCompletion =>
      _hostedChatRunStream != null ||
      _agentRunStreamV3 != null ||
      _agentRunStream != null ||
      _agentCompleteStream != null;

  Future<({Object? error, RetrievalResult? result})> _attemptRetrieval(
    String query,
    List<Article> articles,
  ) async {
    try {
      return (error: null, result: await _retrieve(query, articles));
    } catch (error) {
      developer.log('local retrieval failed: $error', name: 'memora.rag');
      return (error: error, result: null);
    }
  }

  Future<({Object? fatalError, List<WebSearchResult> results})>
  _attemptWebSearch(String query) async {
    try {
      return (
        fatalError: null,
        results: await _webSearch!(query, topK: _webTopK),
      );
    } on WebSearchException catch (error) {
      if (error.isDailyQuotaExceeded) {
        return (fatalError: error, results: const <WebSearchResult>[]);
      }
      developer.log('web search failed: $error', name: 'memora.rag');
      return (fatalError: null, results: const <WebSearchResult>[]);
    } catch (error) {
      developer.log('web search failed: $error', name: 'memora.rag');
      return (fatalError: null, results: const <WebSearchResult>[]);
    }
  }

  /// Packs web search hits into a bounded context block with [wN] citation
  /// labels, returning the rendered text and the offered URLs in order.
  ({String text, List<String> urls}) _buildWebContext(
    List<WebSearchResult> results, {
    required int tokenBudget,
  }) {
    if (tokenBudget <= 0 || results.isEmpty) {
      return (text: '', urls: const <String>[]);
    }
    final buffer = StringBuffer();
    final urls = <String>[];
    var used = 0;
    for (var i = 0; i < results.length; i++) {
      final result = results[i];
      final header = '[w${i + 1}] ${result.title}\nURL: ${result.url}\n';
      final headerTokens = RagContextBuilder.estimateTokens(header);
      final remaining = tokenBudget - used - headerTokens;
      if (remaining <= 0) break;
      final snippet = _truncateToTokens(result.content.trim(), remaining);
      final block = '$header$snippet\n';
      final blockTokens = RagContextBuilder.estimateTokens(block);
      if (used + blockTokens > tokenBudget) break;
      buffer.writeln(block.trimRight());
      buffer.writeln();
      urls.add(result.url);
      used += blockTokens;
    }
    return (text: buffer.toString().trim(), urls: urls);
  }

  static String _truncateToTokens(String text, int budget) {
    if (budget <= 0 || text.isEmpty) return '';
    var candidate = text;
    while (RagContextBuilder.estimateTokens(candidate) > budget &&
        candidate.isNotEmpty) {
      candidate = candidate
          .substring(0, (candidate.length * 0.75).floor())
          .trim();
    }
    return candidate;
  }

  Future<void> _writeLog({
    required String logId,
    required String question,
    required String rewrittenQuery,
    required String method,
    List<String> candidateIds = const [],
    List<String> citedIds = const [],
    List<String> webCandidateUrls = const [],
    List<String> webCitedUrls = const [],
    int durationMs = 0,
  }) async {
    try {
      await _saveLog(
        RetrievalLog(
          id: logId,
          query: question,
          rewrittenQuery: rewrittenQuery == question ? null : rewrittenQuery,
          method: method,
          candidateIds: candidateIds,
          citedIds: citedIds,
          durationMs: durationMs,
          webCandidateUrls: webCandidateUrls,
          webCitedUrls: webCitedUrls,
        ),
      );
    } catch (_) {
      // Analytics must never block an answer.
    }
  }
}

String? _cleanRewrite(String? response) {
  if (response == null) return null;
  var text = response.trim();
  if (text.startsWith('```') && text.endsWith('```')) {
    final lines = text.split('\n');
    if (lines.length >= 3) text = lines.sublist(1, lines.length - 1).join('\n');
  }
  text = text
      .replaceFirst(
        RegExp(
          r'^(rewritten query|standalone question|改写后的问题)\s*[:：]\s*',
          caseSensitive: false,
        ),
        '',
      )
      .trim();
  if ((text.startsWith('"') && text.endsWith('"')) ||
      (text.startsWith("'") && text.endsWith("'"))) {
    text = text.substring(1, text.length - 1).trim();
  }
  final firstLine = text.split('\n').first.trim();
  if (firstLine.isEmpty || firstLine.length > 500) return null;
  return firstLine;
}

String _methodFor({
  required bool local,
  required bool web,
  required RetrievalMethod retrievalMethod,
}) {
  if (local && web) return '${retrievalMethod.name}+web';
  if (web) return 'web';
  return retrievalMethod.name;
}

List<String> _weakCandidates(String query, List<Article> articles) {
  final ranked = const RagEvidenceReranker().rerank(query, articles);
  return ranked
      .where((item) => item.score > (1 / (item.originalRank + 1)) + 0.001)
      .take(3)
      .map((item) => item.article.id)
      .toList();
}

bool _isEmptyResponseError(String? error) {
  if (error == null) return false;
  final normalized = error.toLowerCase();
  return normalized.contains('empty response') ||
      normalized.contains('content was empty');
}
