import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
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
import '../../shared/providers/passage_providers.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/widgets/delayed_reveal.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final List<_ChatMessage> _messages = [];
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
      _messages.add(_ChatMessage(role: _Role.user, text: query));
      _loading = true;
    });
    _scrollToBottom();

    final settings = ref.read(settingsProvider).valueOrNull;
    if (settings == null ||
        settings.aiBaseUrl.trim().isEmpty ||
        settings.aiApiKey.trim().isEmpty) {
      setState(() {
        _messages.add(_ChatMessage(
          role: _Role.assistant,
          text: 'Please configure your AI provider in Settings first.',
        ));
        _loading = false;
      });
      _scrollToBottom();
      return;
    }

    // Retrieve relevant articles.
    final articles = ref.read(articlesProvider).valueOrNull ?? [];
    final completedArticles = articles
        .where((a) =>
            a.processingStatus == ProcessingStatus.completed &&
            a.summary != null &&
            a.summary!.isNotEmpty)
        .toList();

    if (completedArticles.isEmpty) {
      setState(() {
        _messages.add(_ChatMessage(
          role: _Role.assistant,
          text: 'Your knowledge base is empty. Process some articles first, '
              'then come back to ask questions.',
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
      // No embedding configured — use keyword-only fallback.
      result = await RetrievalService(
        embedding: ref.read(embeddingServiceProvider) ??
            EmbeddingService(baseUrl: '', apiKey: '', model: ''),
        index: ref.read(indexServiceProvider),
      ).retrieve(query, completedArticles);
    }

    final candidates = result.articles;
    final logId = const Uuid().v4();

    if (candidates.isEmpty && settings.chatKnowledgeSourceIndex == 0) {
      // KB Only mode: no candidates → inform the user.
      final logService = ref.read(retrievalLogServiceProvider);
      await logService.save(RetrievalLog(
        id: logId,
        query: query,
        method: result.method.name,
        candidateIds: [],
        durationMs: result.duration.inMilliseconds,
      ));

      final weakCandidates = _getWeakCandidates(query, completedArticles);

      setState(() {
        _messages.add(_ChatMessage(
          role: _Role.assistant,
          text: 'I couldn\'t find enough relevant information in your '
              'knowledge base to answer this question.',
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

    // Build context from candidate summaries.
    // Truncate each article's contribution to avoid exceeding the model's
    // context window. 5 articles × ~600 chars ≈ 3000 chars total, well within
    // typical limits while still giving the model enough material.
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

    // Call AI for RAG answer.
    final ai = AiService(
      baseUrl: settings.aiBaseUrl,
      apiKey: settings.aiApiKey,
      model: settings.aiModel,
    );
    final langHint = aiLanguagePrompt(settings.languageIndex);

    try {
      final knowledgeRule = settings.chatKnowledgeSourceIndex == 0
          ? 'Use ONLY the provided article summaries. If the summaries don\'t '
              'contain enough information, say so clearly — do NOT make up answers.'
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
          'You are a knowledge assistant. $knowledgeRule $lengthRule '
          'When referencing information from the knowledge base, cite the article '
          'number in brackets like [1], [2].'
          '${langHint.isNotEmpty ? "\n$langHint" : ""}';

      final userMessage =
          'Knowledge base context:\n${contextBuffer.toString()}\n---\n'
          'Question: $query';

      // Build conversation history for multi-turn context.
      // Include the last few exchanges to keep the context window manageable.
      final history = <Map<String, String>>[];
      final recentMessages = _messages.length > 10
          ? _messages.sublist(_messages.length - 10)
          : _messages;
      for (final msg in recentMessages) {
        if (msg.text.isEmpty) continue;
        history.add({
          'role': msg.role == _Role.user ? 'user' : 'assistant',
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
        setState(() {
          _messages.add(_ChatMessage(
            role: _Role.assistant,
            text: 'The AI service returned an empty response. Please try again.',
            articleIds: candidates.map((a) => a.id).toList(),
            method: result.method.name,
            logId: logId,
          ));
          _loading = false;
        });
      } else {
        // Extract cited article IDs, filtered to ones that still exist. This
        // guards against the model citing a number outside the candidate set
        // or referencing an article that was deleted mid-session.
        final validIds = articles.map((a) => a.id).toSet();
        final filteredCited = extractValidCitations(
          response: response,
          citationMap: citationMap,
          validIds: validIds,
        );

        // If model cited nothing explicitly, show all candidates.
        final displayIds = filteredCited.isEmpty
            ? candidates.map((a) => a.id).toList()
            : filteredCited;

        setState(() {
          _messages.add(_ChatMessage(
            role: _Role.assistant,
            text: response,
            articleIds: displayIds,
            method: result.method.name,
            logId: logId,
          ));
          _loading = false;
        });

        // Log the retrieval.
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
      setState(() {
        _messages.add(_ChatMessage(
          role: _Role.assistant,
          text: 'Error communicating with AI service: $e',
          articleIds: candidates.map((a) => a.id).toList(),
          method: result.method.name,
          logId: logId,
        ));
        _loading = false;
      });
    }
    _scrollToBottom();
  }

  /// Get weakly related articles for no-result state using simple keyword match
  /// with lower threshold.
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
      builder: (_) => _ChatSettingsSheet(
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chat'),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune_rounded),
            tooltip: 'Chat Settings',
            onPressed: _showChatSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? _EmptyChatState(hasKnowledge: hasKnowledge)
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    itemCount: _messages.length + (_loading ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == _messages.length) {
                        return const _TypingIndicator();
                      }
                      return _ChatBubble(
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
          _InputBar(
            controller: _controller,
            loading: _loading,
            onSend: () => _send(),
          ),
        ],
      ),
    );
  }
}

enum _Role { user, assistant }

class _ChatMessage {
  final _Role role;
  final String text;
  final List<String> articleIds;
  final List<String> weakArticleIds;
  final String? method;
  final String? logId;
  final bool isNoResult;

  /// The query that produced this assistant message — used by the no-result
  /// state to offer broader single-term retries.
  final String? query;

  /// User feedback on this answer: null = not rated, 1 = useful, -1 = not.
  /// Mutated in place when the user taps a feedback button.
  int? feedback;

  _ChatMessage({
    required this.role,
    required this.text,
    this.articleIds = const [],
    this.weakArticleIds = const [],
    this.method,
    this.logId,
    this.isNoResult = false,
    this.query,
  });
}

class _EmptyChatState extends StatelessWidget {
  final bool hasKnowledge;
  const _EmptyChatState({required this.hasKnowledge});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: DelayedReveal(
        delayMs: 100,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withAlpha(80),
            ),
            const SizedBox(height: 16),
            Text(
              'Ask your knowledge base',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                hasKnowledge
                    ? 'Try: "What are the key ideas about AI?" or "Summarize my saved articles on Flutter"'
                    : 'Process some articles first, then come back to ask questions.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatBubble extends ConsumerWidget {
  final _ChatMessage message;
  final List<Article> articles;
  final ValueChanged<int> onFeedback;
  final ValueChanged<String> onCitationClick;
  final ValueChanged<String> onSuggestionTap;
  final VoidCallback onBrowseKnowledge;

  const _ChatBubble({
    required this.message,
    required this.articles,
    required this.onFeedback,
    required this.onCitationClick,
    required this.onSuggestionTap,
    required this.onBrowseKnowledge,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isUser = message.role == _Role.user;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        decoration: BoxDecoration(
          color: isUser
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(18).copyWith(
            bottomRight: isUser ? const Radius.circular(4) : null,
            bottomLeft: !isUser ? const Radius.circular(4) : null,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            isUser
                ? SelectableText(
                    message.text,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onPrimary,
                    ),
                  )
                : MarkdownBody(
                    data: message.text,
                    selectable: true,
                    styleSheet: MarkdownStyleSheet(
                      p: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                      strong: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                      em: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontStyle: FontStyle.italic,
                      ),
                      code: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface,
                        backgroundColor: theme.colorScheme.surfaceContainerHighest,
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                      codeblockDecoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: theme.colorScheme.outline.withValues(alpha: 0.2),
                        ),
                      ),
                      blockquote: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                      blockquoteDecoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            color: theme.colorScheme.primary.withValues(alpha: 0.4),
                            width: 3,
                          ),
                        ),
                      ),
                      listBullet: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                      h1: theme.textTheme.titleLarge?.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                      h2: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                      h3: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                      a: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.primary,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
            if (!isUser && message.articleIds.isNotEmpty) ...[
              const SizedBox(height: 12),
              _CitationChips(
                articleIds: message.articleIds,
                articles: articles,
                onCitationClick: onCitationClick,
              ),
            ],
            if (!isUser && message.isNoResult) ...[
              const SizedBox(height: 12),
              _NoResultActions(
                query: message.query ?? '',
                weakArticleIds: message.weakArticleIds,
                articles: articles,
                onSuggestionTap: onSuggestionTap,
                onBrowseKnowledge: onBrowseKnowledge,
                onCitationClick: onCitationClick,
              ),
            ],
            if (!isUser && !message.isNoResult && message.logId != null) ...[
              const SizedBox(height: 10),
              _FeedbackRow(
                message: message,
                onFeedback: onFeedback,
              ),
            ],
            if (!isUser && message.method != null) ...[
              const SizedBox(height: 6),
              Text(
                'via ${message.method}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant.withAlpha(120),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CitationChips extends StatelessWidget {
  final List<String> articleIds;
  final List<Article> articles;
  final ValueChanged<String> onCitationClick;

  const _CitationChips({
    required this.articleIds,
    required this.articles,
    required this.onCitationClick,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 4,
      runSpacing: 2,
      children: articleIds.map((id) {
        final article = articles.where((a) => a.id == id).firstOrNull;
        if (article == null) return const SizedBox.shrink();
        return ActionChip(
          avatar: Icon(
            article.source.icon,
            size: 14,
            color: article.source.accentColor,
          ),
          label: Text(
            article.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
          onPressed: () {
            onCitationClick(article.id);
            context.push(
              AppRoutes.summaryWithId(article.id),
              extra: article,
            );
          },
        );
      }).toList(),
    );
  }
}

class _FeedbackRow extends StatefulWidget {
  final _ChatMessage message;
  final ValueChanged<int> onFeedback;

  const _FeedbackRow({required this.message, required this.onFeedback});

  @override
  State<_FeedbackRow> createState() => _FeedbackRowState();
}

class _FeedbackRowState extends State<_FeedbackRow> {
  int? _localFeedback;

  int? get _effectiveFeedback => _localFeedback ?? widget.message.feedback;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _FeedbackButton(
          icon: Icons.thumb_up_outlined,
          activeIcon: Icons.thumb_up_rounded,
          isActive: _effectiveFeedback == 1,
          activeColor: colorScheme.primary,
          onTap: () {
            setState(() => _localFeedback = 1);
            widget.message.feedback = 1;
            widget.onFeedback(1);
          },
        ),
        const SizedBox(width: 4),
        _FeedbackButton(
          icon: Icons.thumb_down_outlined,
          activeIcon: Icons.thumb_down_rounded,
          isActive: _effectiveFeedback == -1,
          activeColor: colorScheme.error,
          onTap: () {
            setState(() => _localFeedback = -1);
            widget.message.feedback = -1;
            widget.onFeedback(-1);
          },
        ),
      ],
    );
  }
}

class _FeedbackButton extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final bool isActive;
  final Color activeColor;
  final VoidCallback onTap;

  const _FeedbackButton({
    required this.icon,
    required this.activeIcon,
    required this.isActive,
    required this.activeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: isActive ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(
          isActive ? activeIcon : icon,
          size: 16,
          color: isActive
              ? activeColor
              : Theme.of(context).colorScheme.onSurfaceVariant.withAlpha(150),
        ),
      ),
    );
  }
}

class _NoResultActions extends StatelessWidget {
  final String query;
  final List<String> weakArticleIds;
  final List<Article> articles;
  final ValueChanged<String> onSuggestionTap;
  final VoidCallback onBrowseKnowledge;
  final ValueChanged<String> onCitationClick;

  const _NoResultActions({
    required this.query,
    required this.weakArticleIds,
    required this.articles,
    required this.onSuggestionTap,
    required this.onBrowseKnowledge,
    required this.onCitationClick,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Derive individual broader terms from the original query so the user can
    // retry with a single keyword instead of the full phrase.
    final terms = _rephraseTerms(query);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (terms.isNotEmpty) ...[
          Text(
            'Try a broader term:',
            style: theme.textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final term in terms)
                ActionChip(
                  label: Text(term, style: const TextStyle(fontSize: 11)),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onSuggestionTap(term),
                ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        ActionChip(
          avatar: const Icon(Icons.library_books_outlined, size: 14),
          label: const Text('Browse Knowledge Base',
              style: TextStyle(fontSize: 11)),
          onPressed: onBrowseKnowledge,
        ),
        // Show weak candidates if available
        if (weakArticleIds.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            'Possibly related:',
            style: theme.textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          _CitationChips(
            articleIds: weakArticleIds,
            articles: articles,
            onCitationClick: onCitationClick,
          ),
        ],
      ],
    );
  }

  /// Splits the failed query into individual broader terms (longer than 1 char,
  /// de-duplicated, capped at 4) the user can retry one at a time.
  List<String> _rephraseTerms(String query) {
    final words = query
        .split(RegExp(r'\s+'))
        .map((w) => w.trim())
        .where((w) => w.length > 1)
        .toList();
    final seen = <String>{};
    final unique = <String>[];
    for (final w in words) {
      final key = w.toLowerCase();
      if (seen.add(key)) unique.add(w);
    }
    // Only worth showing if the query had more than one term to narrow from.
    if (unique.length < 2) return const [];
    return unique.take(4).toList();
  }
}

class _TypingIndicator extends StatelessWidget {
  const _TypingIndicator();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(18).copyWith(
            bottomLeft: const Radius.circular(4),
          ),
        ),
        child: const SizedBox(
          width: 40,
          height: 16,
          child: _DotsAnimation(),
        ),
      ),
    );
  }
}

class _DotsAnimation extends StatefulWidget {
  const _DotsAnimation();

  @override
  State<_DotsAnimation> createState() => _DotsAnimationState();
}

class _DotsAnimationState extends State<_DotsAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: List.generate(3, (i) {
            final delay = i * 0.15;
            final t = (_ctrl.value + delay) % 1.0;
            final opacity = (t < 0.5 ? t * 2 : (1 - t) * 2).clamp(0.2, 1.0);
            return Opacity(
              opacity: opacity,
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  shape: BoxShape.circle,
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final bool loading;
  final VoidCallback onSend;

  const _InputBar({
    required this.controller,
    required this.loading,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        left: 16,
        right: 8,
        top: 8,
        bottom: MediaQuery.of(context).viewInsets.bottom + 8,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).dividerColor.withAlpha(40),
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
              decoration: InputDecoration(
                hintText: 'Ask about your knowledge...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: loading ? null : onSend,
            icon: loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send_rounded),
          ),
        ],
      ),
    );
  }
}

class _ChatSettingsSheet extends StatefulWidget {
  final int answerLength;
  final int knowledgeSource;
  final void Function(int answerLength, int knowledgeSource) onChanged;

  const _ChatSettingsSheet({
    required this.answerLength,
    required this.knowledgeSource,
    required this.onChanged,
  });

  @override
  State<_ChatSettingsSheet> createState() => _ChatSettingsSheetState();
}

class _ChatSettingsSheetState extends State<_ChatSettingsSheet> {
  late int _answerLength;
  late int _knowledgeSource;

  @override
  void initState() {
    super.initState();
    _answerLength = widget.answerLength;
    _knowledgeSource = widget.knowledgeSource;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      margin: const EdgeInsets.all(16),
      padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + bottom),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Chat Settings', style: theme.textTheme.titleMedium),
          const SizedBox(height: 20),
          Text('Answer Length', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _SettingsChip(
                  icon: Icons.short_text_rounded,
                  label: 'Short',
                  selected: _answerLength == 0,
                  onTap: () => setState(() => _answerLength = 0),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _SettingsChip(
                  icon: Icons.notes_rounded,
                  label: 'Detailed',
                  selected: _answerLength == 1,
                  onTap: () => setState(() => _answerLength = 1),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text('Knowledge Source', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _SettingsChip(
                  icon: Icons.library_books_rounded,
                  label: 'Knowledge Base Only',
                  selected: _knowledgeSource == 0,
                  onTap: () => setState(() => _knowledgeSource = 0),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _SettingsChip(
                  icon: Icons.public_rounded,
                  label: 'KB + General',
                  selected: _knowledgeSource == 1,
                  onTap: () => setState(() => _knowledgeSource = 1),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () {
                widget.onChanged(_answerLength, _knowledgeSource);
                Navigator.pop(context);
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Apply'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SettingsChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        decoration: BoxDecoration(
          color: selected
              ? colorScheme.primaryContainer
              : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? colorScheme.primary
                : colorScheme.outline.withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 18,
              color: selected
                  ? colorScheme.onPrimaryContainer
                  : colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: selected
                      ? colorScheme.onPrimaryContainer
                      : colorScheme.onSurfaceVariant,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

