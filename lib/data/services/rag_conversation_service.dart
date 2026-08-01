import 'package:uuid/uuid.dart';

export 'chat_context_window.dart' show ChatContextWindow, RagConversationTurn;

import '../models/passage.dart';
import 'chat_context_window.dart';
import 'prompt_service.dart';
import 'rag_citation.dart';
import 'rag_context_builder.dart';
import 'retrieval_log_service.dart';
import 'retrieval_service.dart';

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

class RagConversationRequest {
  final String question;
  final List<RagConversationTurn> history;
  final List<Article> articles;
  final bool knowledgeOnly;
  final bool detailedAnswer;
  final String languageHint;
  final int contextTokenBudget;
  final int contextWindowTokens;

  const RagConversationRequest({
    required this.question,
    this.history = const [],
    required this.articles,
    required this.knowledgeOnly,
    required this.detailedAnswer,
    required this.languageHint,
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

  const RagConversationResult({
    required this.outcome,
    this.answer,
    this.error,
    required this.rewrittenQuery,
    this.citedIds = const [],
    this.weakArticleIds = const [],
    required this.method,
    required this.logId,
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

  RagConversationService({
    required RagRetrieve retrieve,
    required RagCompletion complete,
    required RagSaveLog saveLog,
    required PromptService promptService,
    RagContextBuilder contextBuilder = const RagContextBuilder(),
    ChatContextWindow contextWindow = const ChatContextWindow(),
    HistoryAwareQueryRewriter? queryRewriter,
  }) : _retrieve = retrieve,
       _complete = complete,
       _saveLog = saveLog,
       _prompts = promptService,
       _contextBuilder = contextBuilder,
       _contextWindow = contextWindow,
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

    final candidateIds = retrieval.candidateIds.isNotEmpty
        ? retrieval.candidateIds
        : retrieval.articles.map((article) => article.id).toList();
    if (retrieval.articles.isEmpty && request.knowledgeOnly) {
      await _writeLog(
        logId: logId,
        question: question,
        rewrittenQuery: rewrittenQuery,
        retrieval: retrieval,
        candidateIds: candidateIds,
        citedIds: const [],
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
      final knowledgeRulePath = request.knowledgeOnly
          ? 'chat/knowledge_only.txt'
          : retrieval.articles.isEmpty
          ? 'chat/knowledge_general.txt'
          : 'chat/knowledge_hybrid.txt';
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
      final baseUserMessage = await _prompts.load('chat/user.txt', {
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
          retrieval: retrieval,
          candidateIds: candidateIds,
          citedIds: const [],
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
      final context = _contextBuilder.build(
        query: rewrittenQuery,
        candidates: retrieval.articles,
        tokenBudget: effectiveContextBudget,
      );
      final userMessage = await _prompts.load('chat/user.txt', {
        'context': context.text,
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
          retrieval: retrieval,
          candidateIds: candidateIds,
          citedIds: const [],
        );
        return RagConversationResult(
          outcome: RagConversationOutcome.error,
          error: 'empty response',
          rewrittenQuery: rewrittenQuery,
          method: retrieval.method.name,
          logId: logId,
        );
      }

      final citedIds = extractValidCitations(
        response: response,
        citationMap: context.citationMap,
        validIds: request.articles.map((article) => article.id).toSet(),
      );
      await _writeLog(
        logId: logId,
        question: question,
        rewrittenQuery: rewrittenQuery,
        retrieval: retrieval,
        candidateIds: candidateIds,
        citedIds: citedIds,
      );
      return RagConversationResult(
        outcome: RagConversationOutcome.answer,
        answer: response,
        rewrittenQuery: rewrittenQuery,
        citedIds: List.unmodifiable(citedIds),
        method: retrieval.method.name,
        logId: logId,
      );
    } catch (error) {
      await _writeLog(
        logId: logId,
        question: question,
        rewrittenQuery: rewrittenQuery,
        retrieval: retrieval,
        candidateIds: candidateIds,
        citedIds: const [],
      );
      return RagConversationResult(
        outcome: RagConversationOutcome.error,
        error: error.toString(),
        rewrittenQuery: rewrittenQuery,
        method: retrieval.method.name,
        logId: logId,
      );
    }
  }

  Future<void> _writeLog({
    required String logId,
    required String question,
    required String rewrittenQuery,
    required RetrievalResult retrieval,
    required List<String> candidateIds,
    required List<String> citedIds,
  }) async {
    try {
      await _saveLog(
        RetrievalLog(
          id: logId,
          query: question,
          rewrittenQuery: rewrittenQuery == question ? null : rewrittenQuery,
          method: retrieval.method.name,
          candidateIds: candidateIds,
          citedIds: citedIds,
          durationMs: retrieval.duration.inMilliseconds,
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
