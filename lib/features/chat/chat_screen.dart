import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../../config/routes.dart';
import '../../data/models/passage.dart';
import '../../data/services/ai_service.dart';
import '../../data/services/embedding_service.dart';
import '../../data/services/rag_citation.dart';
import '../../data/services/retrieval_log_service.dart';
import '../../data/services/retrieval_service.dart';
import '../../shared/providers/locale_provider.dart';
import '../../shared/providers/passage_providers.dart';
import '../../shared/providers/settings_providers.dart';
import 'chat_message.dart';
import 'chat_bubble.dart';
import 'chat_empty_state.dart';
import 'chat_input_bar.dart';
import 'chat_settings_sheet.dart';
import 'chat_typing_indicator.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];
  bool _loading = false;

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send([String? overrideQuery]) async {
    final query = overrideQuery ?? _controller.text.trim();
    if (query.isEmpty || _loading) return;

    if (overrideQuery == null) _controller.clear();
    setState(() {
      _messages.add(ChatMessage(role: MessageRole.user, text: query));
      _loading = true;
    });
    _scrollToBottom();

    final settings = ref.read(settingsProvider).valueOrNull;
    if (settings == null ||
        settings.aiBaseUrl.trim().isEmpty ||
        settings.aiApiKey.trim().isEmpty) {
      final s = ref.read(stringsProvider);
      setState(() {
        _messages.add(ChatMessage(role: MessageRole.assistant, text: s.configureAiFirst));
        _loading = false;
      });
      _scrollToBottom();
      return;
    }

    final articles = ref.read(articlesProvider).valueOrNull ?? [];
    final completedArticles = articles
        .where((a) =>
            a.processingStatus == ProcessingStatus.completed &&
            a.summary != null &&
            a.summary!.isNotEmpty)
        .toList();

    if (completedArticles.isEmpty) {
      final s = ref.read(stringsProvider);
      setState(() {
        _messages.add(ChatMessage(
          role: MessageRole.assistant,
          text: s.knowledgeBaseEmpty,
          isNoResult: true,
        ));
        _loading = false;
      });
      _scrollToBottom();
      return;
    }

    final retrieval = ref.read(retrievalServiceProvider);
    RetrievalResult result;

    if (retrieval != null) {
      result = await retrieval.retrieve(query, completedArticles);
    } else {
      result = await RetrievalService(
        embedding: ref.read(embeddingServiceProvider) ??
            EmbeddingService(baseUrl: '', apiKey: '', model: ''),
        index: ref.read(indexServiceProvider),
      ).retrieve(query, completedArticles);
    }

    final candidates = result.articles;
    final logId = const Uuid().v4();

    if (candidates.isEmpty && settings.chatKnowledgeSourceIndex == 0) {
      final logService = ref.read(retrievalLogServiceProvider);
      await logService.save(RetrievalLog(
        id: logId,
        query: query,
        method: result.method.name,
        candidateIds: [],
        durationMs: result.duration.inMilliseconds,
      ));

      final weakCandidates = _getWeakCandidates(query, completedArticles);
      final s = ref.read(stringsProvider);

      setState(() {
        _messages.add(ChatMessage(
          role: MessageRole.assistant,
          text: s.notEnoughInfo,
          isNoResult: true,
          weakArticleIds: weakCandidates.map((a) => a.id).toList(),
          logId: logId,
          query: query,
        ));
        _loading = false;
      });
      _scrollToBottom();
      return;
    }

    const maxContextPerArticle = 600;
    final contextBuffer = StringBuffer();
    final citationMap = buildCitationMap(candidates.map((a) => a.id).toList());
    for (int i = 0; i < candidates.length; i++) {
      final a = candidates[i];
      contextBuffer.writeln('[${i + 1}] ${a.title}');
      final summary = (a.summary ?? '').trim();
      if (summary.isNotEmpty) {
        contextBuffer.writeln(
            'Summary: ${summary.length > maxContextPerArticle ? '${summary.substring(0, maxContextPerArticle)}...' : summary}');
      }
      contextBuffer.writeln('Tags: ${a.tags.join(", ")}');
      contextBuffer.writeln();
    }

    final ai = AiService(
      baseUrl: settings.aiBaseUrl,
      apiKey: settings.aiApiKey,
      model: settings.aiModel,
    );
    final langHint = aiLanguagePrompt(settings.languageIndex);

    try {
      final knowledgeRule = settings.chatKnowledgeSourceIndex == 0
          ? 'You MUST answer based ONLY on the provided article summaries below.\n'
              '- If the answer is clearly found in the summaries, provide it with citations\n'
              '- If only partial information exists, answer what you can and note what\'s missing\n'
              '- If none of the summaries address the question, say exactly that and suggest what information would be needed\n'
              '- NEVER use your own knowledge to fill gaps — this is a hard rule'
          : candidates.isEmpty
              ? 'No relevant articles were found in the knowledge base for this question. '
                  'Answer using your general knowledge. Be thorough and factual.'
              : 'Primarily use the provided article summaries. When the summaries '
                  'don\'t cover the topic, you may supplement with your general '
                  'knowledge, but prefix that portion with "Based on general knowledge:". '
                  'Always cite article numbers [1], [2] when referencing knowledge base content.';

      final lengthRule = settings.chatAnswerLengthIndex == 0
          ? 'Keep answers concise — 2-3 sentences per point, use bullet points when possible.'
          : 'Provide detailed explanations. Include examples, context, and reasoning when relevant.';

      final systemPrompt =
          'You are a personal knowledge assistant answering questions based on saved articles.\n\n'
          '$knowledgeRule\n\n'
          '$lengthRule\n\n'
          'Citation rules:\n'
          '- Cite relevant article numbers in brackets: [1], [2]\n'
          '- Only cite articles that directly support or contradict your answer\n'
          '- If you\'re unsure about a citation, do not include it\n'
          '- If multiple articles support the same point, group them: [1,3]\n\n'
          'Format rules:\n'
          '- Start with the answer, then list supporting citations\n'
          '- For information gaps, say: "关于X，当前知识库中没有足够信息"\n'
          '${langHint.isNotEmpty ? "\n$langHint" : ""}';

      final userMessage =
          'Knowledge base context:\n${contextBuffer.toString()}\n---\n'
          'Question: $query';

      final history = <Map<String, String>>[];
      final recentMessages = _messages.length > 10
          ? _messages.sublist(_messages.length - 10)
          : _messages;
      for (final msg in recentMessages) {
        if (msg.text.isEmpty) continue;
        history.add({
          'role': msg.role == MessageRole.user ? 'user' : 'assistant',
          'content': msg.text,
        });
      }

      final response = await ai.chat(
        systemPrompt: systemPrompt,
        userMessage: userMessage,
        history: history,
        maxTokens: settings.chatAnswerLengthIndex == 0 ? 1000 : 2500,
      );

      if (response == null || response.isEmpty) {
        final s = ref.read(stringsProvider);
        setState(() {
          _messages.add(ChatMessage(
            role: MessageRole.assistant,
            text: '${s.aiError}: empty response',
            articleIds: candidates.map((a) => a.id).toList(),
            method: result.method.name,
            logId: logId,
          ));
          _loading = false;
        });
      } else {
        final validIds = articles.map((a) => a.id).toSet();
        final filteredCited = extractValidCitations(
          response: response,
          citationMap: citationMap,
          validIds: validIds,
        );

        final displayIds = filteredCited.isEmpty
            ? candidates.map((a) => a.id).toList()
            : filteredCited;

        setState(() {
          _messages.add(ChatMessage(
            role: MessageRole.assistant,
            text: response,
            articleIds: displayIds,
            method: result.method.name,
            logId: logId,
          ));
          _loading = false;
        });

        final logService = ref.read(retrievalLogServiceProvider);
        await logService.save(RetrievalLog(
          id: logId,
          query: query,
          method: result.method.name,
          candidateIds: result.candidateIds,
          citedIds: filteredCited,
          durationMs: result.duration.inMilliseconds,
        ));
      }
    } catch (e) {
      final s = ref.read(stringsProvider);
      setState(() {
        _messages.add(ChatMessage(
          role: MessageRole.assistant,
          text: '${s.aiError}: $e',
          articleIds: candidates.map((a) => a.id).toList(),
          method: result.method.name,
          logId: logId,
        ));
        _loading = false;
      });
    }
    _scrollToBottom();
  }

  List<Article> _getWeakCandidates(String query, List<Article> articles) {
    final lower = query.toLowerCase();
    final words =
        lower.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return [];

    final scored = <({Article article, int score})>[];
    for (final article in articles) {
      int score = 0;
      final titleLower = article.title.toLowerCase();
      final summaryLower = (article.summary ?? '').toLowerCase();
      final tagsLower = article.tags.map((t) => t.toLowerCase()).toList();

      for (final word in words) {
        if (titleLower.contains(word)) score += 2;
        if (summaryLower.contains(word)) score += 1;
        if (tagsLower.any((t) => t.contains(word))) score += 1;
      }
      if (score > 0) scored.add((article: article, score: score));
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(3).map((s) => s.article).toList();
  }

  void _showChatSettings() {
    final settings = ref.read(settingsProvider).valueOrNull;
    if (settings == null) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChatSettingsSheet(
        answerLength: settings.chatAnswerLengthIndex,
        knowledgeSource: settings.chatKnowledgeSourceIndex,
        onChanged: (answerLength, knowledgeSource) {
          ref.read(settingsProvider.notifier).setChatAnswerLength(answerLength);
          ref.read(settingsProvider.notifier).setChatKnowledgeSource(knowledgeSource);
        },
      ),
    );
  }

  void _onFeedback(String? logId, int feedback) {
    if (logId == null) return;
    ref.read(retrievalLogServiceProvider).updateFeedback(logId, feedback);
  }

  void _onCitationClick(String? logId, String articleId) {
    if (logId == null) return;
    ref.read(retrievalLogServiceProvider).recordCitationClick(logId, articleId);
  }

  @override
  Widget build(BuildContext context) {
    final articles = ref.watch(articlesProvider).valueOrNull ?? [];
    final hasKnowledge = articles.any(
      (a) =>
          a.processingStatus == ProcessingStatus.completed &&
          a.summary != null,
    );
    final s = ref.watch(stringsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(s.tabChat),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune_rounded),
            tooltip: 'Chat Settings',
            onPressed: _showChatSettings,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            children: [
              Expanded(
                child: _messages.isEmpty
                    ? ChatEmptyState(hasKnowledge: hasKnowledge, s: s)
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        itemCount: _messages.length + (_loading ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == _messages.length) {
                            return const ChatTypingIndicator();
                          }
                          return ChatBubble(
                            message: _messages[index],
                            articles: articles,
                            onFeedback: (feedback) =>
                                _onFeedback(_messages[index].logId, feedback),
                            onCitationClick: (articleId) =>
                                _onCitationClick(_messages[index].logId, articleId),
                            onSuggestionTap: _send,
                            onBrowseKnowledge: () {
                              context.go(AppRoutes.knowledge);
                            },
                          );
                        },
                      ),
              ),
              ChatInputBar(
                controller: _controller,
                loading: _loading,
                s: s,
                onSend: () => _send(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
