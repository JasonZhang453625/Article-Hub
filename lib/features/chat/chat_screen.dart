import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../config/routes.dart';
import '../../data/models/passage.dart';
import '../../data/services/rag_conversation_service.dart';
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

    final previousMessages = _messages.length > 10
        ? _messages.sublist(_messages.length - 10)
        : List<ChatMessage>.of(_messages);
    final history = previousMessages
        .where((message) => message.text.trim().isNotEmpty)
        .map(
          (message) => RagConversationTurn(
            role: message.role == MessageRole.user ? 'user' : 'assistant',
            content: message.text,
          ),
        )
        .toList();

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
        _messages.add(
          ChatMessage(role: MessageRole.assistant, text: s.configureAiFirst),
        );
        _loading = false;
      });
      _scrollToBottom();
      return;
    }

    final conversation = ref.read(ragConversationServiceProvider);
    if (conversation == null) {
      final s = ref.read(stringsProvider);
      setState(() {
        _messages.add(
          ChatMessage(role: MessageRole.assistant, text: s.configureAiFirst),
        );
        _loading = false;
      });
      _scrollToBottom();
      return;
    }

    final articles = ref.read(articlesProvider).valueOrNull ?? [];
    final completedArticles = articles
        .where(
          (a) =>
              a.processingStatus == ProcessingStatus.completed && a.hasMemory,
        )
        .toList();

    if (completedArticles.isEmpty) {
      final s = ref.read(stringsProvider);
      setState(() {
        _messages.add(
          ChatMessage(
            role: MessageRole.assistant,
            text: s.knowledgeBaseEmpty,
            isNoResult: true,
          ),
        );
        _loading = false;
      });
      _scrollToBottom();
      return;
    }

    try {
      final result = await conversation.ask(
        RagConversationRequest(
          question: query,
          history: history,
          articles: completedArticles,
          knowledgeOnly: settings.chatKnowledgeSourceIndex == 0,
          detailedAnswer: settings.chatAnswerLengthIndex == 1,
          languageHint: aiLanguagePrompt(settings.languageIndex),
        ),
      );
      if (!mounted) return;

      final s = ref.read(stringsProvider);
      final message = switch (result.outcome) {
        RagConversationOutcome.answer => ChatMessage(
          role: MessageRole.assistant,
          text: result.answer ?? '',
          articleIds: result.citedIds,
          method: result.method,
          logId: result.logId,
        ),
        RagConversationOutcome.noResult => ChatMessage(
          role: MessageRole.assistant,
          text: s.notEnoughInfo,
          isNoResult: true,
          weakArticleIds: result.weakArticleIds,
          method: result.method,
          logId: result.logId,
          query: query,
        ),
        RagConversationOutcome.error => ChatMessage(
          role: MessageRole.assistant,
          text: '${s.aiError}: ${result.error ?? 'unknown error'}',
          method: result.method,
          logId: result.logId,
        ),
      };

      setState(() {
        _messages.add(message);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      final s = ref.read(stringsProvider);
      setState(() {
        _messages.add(
          ChatMessage(
            role: MessageRole.assistant,
            text: '${s.aiError}: $error',
          ),
        );
        _loading = false;
      });
    }
    _scrollToBottom();
  }

  void _showChatSettings() {
    final settings = ref.read(settingsProvider).valueOrNull;
    if (settings == null) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChatSettingsSheet(
        s: ref.read(stringsProvider),
        answerLength: settings.chatAnswerLengthIndex,
        knowledgeSource: settings.chatKnowledgeSourceIndex,
        onChanged: (answerLength, knowledgeSource) {
          ref.read(settingsProvider.notifier).setChatAnswerLength(answerLength);
          ref
              .read(settingsProvider.notifier)
              .setChatKnowledgeSource(knowledgeSource);
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
      (a) => a.processingStatus == ProcessingStatus.completed && a.hasMemory,
    );
    final s = ref.watch(stringsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(s.tabChat),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune_rounded),
            tooltip: s.chatSettings,
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
                          horizontal: 16,
                          vertical: 12,
                        ),
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
                            onCitationClick: (articleId) => _onCitationClick(
                              _messages[index].logId,
                              articleId,
                            ),
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
