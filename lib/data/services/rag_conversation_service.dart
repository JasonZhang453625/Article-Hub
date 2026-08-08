import 'dart:developer' as developer;

import 'package:uuid/uuid.dart';

export 'chat_context_window.dart' show ChatContextWindow, RagConversationTurn;

import '../models/passage.dart';
import 'chat_context_window.dart';
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

typedef RagCompletionError = String? Function();

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

  /// When true (and a web search backend is configured), local retrieval and
  /// live web search run together and both may contribute evidence.
  final bool webSearch;
  final int contextTokenBudget;
  final int contextWindowTokens;

  const RagConversationRequest({
    required this.question,
    this.history = const [],
    required this.articles,
    required this.knowledgeOnly,
    required this.detailedAnswer,
    required this.languageHint,
    this.webSearch = false,
    this.contextTokenBudget = 2200,
    this.contextWindowTokens = ChatContextWindow.defaultContextWindowTokens,
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
  });
}

class HistoryAwareQueryRewriter {
  final RagCompletion _complete;
  final PromptService _prompts;
  final ChatContextWindow _contextWindow;

  const HistoryAwareQueryRewriter({
    required RagCompletion complete,
    required PromptService promptService,
    ChatContextWindow contextWindow = const ChatContextWindow(),
  }) : _complete = complete,
       _prompts = promptService,
       _contextWindow = contextWindow;

  Future<String> rewrite({
    required String question,
    required List<RagConversationTurn> history,
  }) async {
    final original = question.trim();
    if (original.isEmpty || history.isEmpty) return original;

    try {
      final systemPrompt = await _prompts.load('chat/query_rewrite.txt');
      final recent = _contextWindow.selectRecentCompleteTurns(
        history,
        tokenBudget: 1200,
      );
      if (recent.isEmpty) return original;
      final transcript = recent
          .where((turn) => turn.content.trim().isNotEmpty)
          .map((turn) => '${turn.role}: ${turn.content.trim()}')
          .join('\n');
      final response = await _complete(
        systemPrompt: systemPrompt,
        userMessage:
            'Conversation:\n$transcript\n\nLatest question:\n$original',
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
  final RagCompletionError? _completionError;
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
    RagCompletionError? completionError,
    required RagSaveLog saveLog,
    required PromptService promptService,
    RagContextBuilder contextBuilder = const RagContextBuilder(),
    ChatContextWindow contextWindow = const ChatContextWindow(),
    HistoryAwareQueryRewriter? queryRewriter,
    RagWebSearch? webSearch,
    int webTopK = 5,
  }) : _retrieve = retrieve,
       _complete = complete,
       _completeStream = completeStream,
       _completionError = completionError,
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
  }) async {
    final question = request.question.trim();
    final logId = const Uuid().v4();
    final rewrittenQuery = await _queryRewriter.rewrite(
      question: question,
      history: request.history,
    );

    // Start both operations before awaiting either one. Dart futures are
    // eager, so local retrieval and Tavily overlap instead of running in
    // sequence.
    final retrievalStopwatch = Stopwatch()..start();
    final retrievalFuture = _attemptRetrieval(rewrittenQuery, request.articles);
    final webFuture = request.webSearch && _webSearch != null
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

    if (retrievalAttempt.result == null && webResults.isEmpty) {
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

    if (!useLocalContext && !useWebContext && request.knowledgeOnly) {
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
      final webKnowledgeRule = useWebContext
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
      final userMessage = await _prompts.load(userPromptPath, {
        'context': contextText,
        'question': question,
      });
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
        history: history.map((turn) => turn.toMessage()).toList(),
        maxTokens: maxTokens,
        temperature: 0.3,
        onDelta: onDelta,
      );

      final completionError = _completionError?.call()?.trim();
      if (response == null ||
          response.trim().isEmpty ||
          completionError != null && completionError.isNotEmpty) {
        await _writeLog(
          logId: logId,
          question: question,
          rewrittenQuery: rewrittenQuery,
          method: method,
          candidateIds: candidateIds,
          citedIds: const [],
          webCandidateUrls: webUrls,
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
          method: method,
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
        urls: webUrls,
      );
      await _writeLog(
        logId: logId,
        question: question,
        rewrittenQuery: rewrittenQuery,
        method: method,
        candidateIds: candidateIds,
        citedIds: citedIds,
        webCandidateUrls: webUrls,
        webCitedUrls: citedWebUrls,
        durationMs: retrievalStopwatch.elapsed.inMilliseconds,
      );
      return RagConversationResult(
        outcome: RagConversationOutcome.answer,
        answer: response,
        rewrittenQuery: rewrittenQuery,
        citedIds: List.unmodifiable(citedIds),
        method: method,
        logId: logId,
        webUrls: List.unmodifiable(citedWebUrls),
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

  Future<String?> _completeWithProgress({
    required String systemPrompt,
    required String userMessage,
    required List<Map<String, String>> history,
    required double temperature,
    required int maxTokens,
    void Function(String delta)? onDelta,
  }) async {
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
