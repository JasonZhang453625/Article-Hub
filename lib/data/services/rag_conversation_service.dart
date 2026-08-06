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

  /// When true (and a web search backend is configured), the conversation
  /// may fall back to live web search when local retrieval finds nothing
  /// relevant. Local results always win — the web is only a fallback.
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
  /// order. Empty unless the web fallback was used.
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
    required RagSaveLog saveLog,
    required PromptService promptService,
    RagContextBuilder contextBuilder = const RagContextBuilder(),
    ChatContextWindow contextWindow = const ChatContextWindow(),
    HistoryAwareQueryRewriter? queryRewriter,
    RagWebSearch? webSearch,
    int webTopK = 5,
  }) : _retrieve = retrieve,
       _complete = complete,
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

  Future<RagConversationResult> ask(RagConversationRequest request) async {
    final question = request.question.trim();
    final logId = const Uuid().v4();
    final rewrittenQuery = await _queryRewriter.rewrite(
      question: question,
      history: request.history,
    );

    // 1. Local retrieval — and, when web search is enabled, a live web
    //    search runs in parallel so the fallback adds no extra latency.
    RetrievalResult retrieval;
    try {
      retrieval = await _retrieve(rewrittenQuery, request.articles);
    } catch (error) {
      return RagConversationResult(
        outcome: RagConversationOutcome.error,
        error: error.toString(),
        rewrittenQuery: rewrittenQuery,
        method: RetrievalMethod.none.name,
        logId: logId,
      );
    }

    final webStopwatch = Stopwatch();
    List<WebSearchResult> webResults = const [];
    if (request.webSearch && _webSearch != null) {
      webStopwatch.start();
      try {
        webResults = await _webSearch(rewrittenQuery, topK: _webTopK);
      } catch (error) {
        developer.log('web search failed: $error', name: 'memora.rag');
      }
      webStopwatch.stop();
    }

    final candidateIds = retrieval.candidateIds.isNotEmpty
        ? retrieval.candidateIds
        : retrieval.articles.map((article) => article.id).toList();

    // 2. Local results win — the web is only a fallback when local
    //    retrieval found nothing relevant.
    final useLocalContext = retrieval.articles.isNotEmpty;
    final useWebContext = !useLocalContext && webResults.isNotEmpty;

    if (!useLocalContext && !useWebContext && request.knowledgeOnly) {
      await _writeLog(
        logId: logId,
        question: question,
        rewrittenQuery: rewrittenQuery,
        method: RetrievalMethod.none.name,
        candidateIds: candidateIds,
        citedIds: const [],
        durationMs: retrieval.duration.inMilliseconds,
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
      // Web fallback uses a dedicated mode: snippets are the evidence and
      // citations are [wN] URL references. Otherwise the existing
      // local/hybrid contract applies unchanged.
      final knowledgeRulePath = useWebContext
          ? 'chat/knowledge_web.txt'
          : request.knowledgeOnly
          ? 'chat/knowledge_only.txt'
          : 'chat/knowledge_hybrid.txt';
      final userPromptPath = useWebContext
          ? 'chat/user_web.txt'
          : 'chat/user.txt';
      final lengthRulePath = request.detailedAnswer
          ? 'chat/length_detailed.txt'
          : 'chat/length_concise.txt';
      final knowledgeRule = await _prompts.load(knowledgeRulePath);
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
          method: retrieval.method.name,
          candidateIds: candidateIds,
          citedIds: const [],
          durationMs: retrieval.duration.inMilliseconds,
        );
        return RagConversationResult(
          outcome: RagConversationOutcome.error,
          error: 'message exceeds the configured context window',
          rewrittenQuery: rewrittenQuery,
          method: retrieval.method.name,
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
        final built = _buildWebContext(
          webResults,
          tokenBudget: effectiveContextBudget,
        );
        contextText = built.text;
        citationMap = const {};
        webUrls = built.urls;
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
      final response = await _complete(
        systemPrompt: systemPrompt,
        userMessage: userMessage,
        history: history.map((turn) => turn.toMessage()).toList(),
        maxTokens: maxTokens,
        temperature: 0.3,
      );

      if (response == null || response.trim().isEmpty) {
        await _writeLog(
          logId: logId,
          question: question,
          rewrittenQuery: rewrittenQuery,
          method: useWebContext ? 'web' : retrieval.method.name,
          candidateIds: candidateIds,
          citedIds: const [],
          webCandidateUrls: useWebContext ? webUrls : const [],
          webCitedUrls: const [],
          durationMs: webStopwatch.elapsed.inMilliseconds,
        );
        return RagConversationResult(
          outcome: RagConversationOutcome.error,
          error: 'empty response',
          rewrittenQuery: rewrittenQuery,
          method: useWebContext ? 'web' : retrieval.method.name,
          logId: logId,
        );
      }

      final citedIds = useWebContext
          ? const <String>[]
          : extractValidCitations(
              response: response,
              citationMap: citationMap,
              validIds: request.articles.map((article) => article.id).toSet(),
            );
      final citedWebUrls = useWebContext
          ? extractValidWebCitations(response: response, urls: webUrls)
          : const <String>[];
      await _writeLog(
        logId: logId,
        question: question,
        rewrittenQuery: rewrittenQuery,
        method: useWebContext ? 'web' : retrieval.method.name,
        candidateIds: candidateIds,
        citedIds: citedIds,
        webCandidateUrls: useWebContext ? webUrls : const [],
        webCitedUrls: citedWebUrls,
        durationMs: webStopwatch.elapsed.inMilliseconds,
      );
      return RagConversationResult(
        outcome: RagConversationOutcome.answer,
        answer: response,
        rewrittenQuery: rewrittenQuery,
        citedIds: List.unmodifiable(citedIds),
        method: useWebContext ? 'web' : retrieval.method.name,
        logId: logId,
        webUrls: List.unmodifiable(citedWebUrls),
      );
    } catch (error) {
      await _writeLog(
        logId: logId,
        question: question,
        rewrittenQuery: rewrittenQuery,
        method: useWebContext ? 'web' : retrieval.method.name,
        candidateIds: candidateIds,
        citedIds: const [],
        webCandidateUrls: useWebContext
            ? webResults.map((result) => result.url).toList()
            : const [],
        webCitedUrls: const [],
        durationMs: webStopwatch.elapsed.inMilliseconds,
      );
      return RagConversationResult(
        outcome: RagConversationOutcome.error,
        error: error.toString(),
        rewrittenQuery: rewrittenQuery,
        method: useWebContext ? 'web' : retrieval.method.name,
        logId: logId,
      );
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

List<String> _weakCandidates(String query, List<Article> articles) {
  final ranked = const RagEvidenceReranker().rerank(query, articles);
  return ranked
      .where((item) => item.score > (1 / (item.originalRank + 1)) + 0.001)
      .take(3)
      .map((item) => item.article.id)
      .toList();
}
