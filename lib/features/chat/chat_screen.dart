import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../config/routes.dart';
import '../../data/models/chat_message_record.dart';
import '../../data/models/passage.dart';
import '../../data/services/rag_conversation_service.dart';
import '../../shared/providers/chat_providers.dart';
import '../../shared/providers/locale_provider.dart';
import '../../shared/providers/passage_providers.dart';
import '../../shared/providers/settings_providers.dart';
import 'chat_message.dart';
import 'chat_bubble.dart';
import 'chat_empty_state.dart';
import 'chat_history_sheet.dart';
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

    final chatState = ref.read(chatSessionsProvider).valueOrNull;
    if (chatState == null) return;
    final history = chatState.messages
        .where(
          (message) =>
              message.status == ChatMessageStatus.completed &&
              message.role != ChatMessageRole.system &&
              message.content.trim().isNotEmpty,
        )
        .map(
          (message) => RagConversationTurn(
            role: message.role == ChatMessageRole.user ? 'user' : 'assistant',
            content: message.content,
          ),
        )
        .toList();

    if (overrideQuery == null) _controller.clear();
    setState(() {
      _loading = true;
    });
    final sessions = ref.read(chatSessionsProvider.notifier);
    late final PersistedUserMessage persistedUser;
    try {
      persistedUser = await sessions.addUserMessage(query);
    } catch (error) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
      return;
    }
    _scrollToBottom();

    final settings = ref.read(settingsProvider).valueOrNull;
    final s = ref.read(stringsProvider);
    if (settings == null ||
        settings.aiBaseUrl.trim().isEmpty ||
        settings.aiApiKey.trim().isEmpty) {
      await sessions.addAssistantMessage(
        threadId: persistedUser.threadId,
        content: s.configureAiFirst,
        status: ChatMessageStatus.failed,
        errorCode: 'ai_not_configured',
      );
      _finishLoading();
      return;
    }

    final conversation = ref.read(ragConversationServiceProvider);
    if (conversation == null) {
      await sessions.addAssistantMessage(
        threadId: persistedUser.threadId,
        content: s.configureAiFirst,
        status: ChatMessageStatus.failed,
        errorCode: 'ai_unavailable',
      );
      _finishLoading();
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
      await sessions.addAssistantMessage(
        threadId: persistedUser.threadId,
        content: s.knowledgeBaseEmpty,
        isNoResult: true,
        query: query,
      );
      _finishLoading();
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
      switch (result.outcome) {
        case RagConversationOutcome.answer:
          await sessions.addAssistantMessage(
            threadId: persistedUser.threadId,
            content: result.answer ?? '',
            articleIds: result.citedIds,
            method: result.method,
            logId: result.logId,
          );
          break;
        case RagConversationOutcome.noResult:
          await sessions.addAssistantMessage(
            threadId: persistedUser.threadId,
            content: s.notEnoughInfo,
            isNoResult: true,
            weakArticleIds: result.weakArticleIds,
            method: result.method,
            logId: result.logId,
            query: query,
          );
          break;
        case RagConversationOutcome.error:
          await sessions.addAssistantMessage(
            threadId: persistedUser.threadId,
            content: '${s.aiError}: ${result.error ?? 'unknown error'}',
            method: result.method,
            logId: result.logId,
            status: ChatMessageStatus.failed,
            errorCode: 'rag_error',
          );
          break;
      }
    } catch (error) {
      await sessions.addAssistantMessage(
        threadId: persistedUser.threadId,
        content: '${s.aiError}: $error',
        status: ChatMessageStatus.failed,
        errorCode: 'unexpected_error',
      );
    }
    _finishLoading();
  }

  void _finishLoading() {
    if (mounted) {
      setState(() => _loading = false);
      _scrollToBottom();
    }
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

  void _onFeedback(String messageId, String? logId, int feedback) {
    unawaited(
      ref
          .read(chatSessionsProvider.notifier)
          .updateFeedback(messageId, feedback),
    );
    if (logId != null) {
      unawaited(
        ref.read(retrievalLogServiceProvider).updateFeedback(logId, feedback),
      );
    }
  }

  void _onCitationClick(String? logId, String articleId) {
    if (logId == null) return;
    ref.read(retrievalLogServiceProvider).recordCitationClick(logId, articleId);
  }

  void _showChatHistory() {
    final chatState = ref.read(chatSessionsProvider).valueOrNull;
    if (chatState == null) return;
    final sessions = ref.read(chatSessionsProvider.notifier);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ChatHistorySheet(
        threads: chatState.threads,
        activeThreadId: chatState.activeThreadId,
        s: ref.read(stringsProvider),
        onNewThread: () async {
          await sessions.startNewThread();
          _controller.clear();
        },
        onSelectThread: (threadId) async {
          await sessions.selectThread(threadId);
          _scrollToBottom();
        },
        onDeleteThread: sessions.deleteThread,
      ),
    );
  }

  Future<void> _startNewThread() async {
    await ref.read(chatSessionsProvider.notifier).startNewThread();
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final articles = ref.watch(articlesProvider).valueOrNull ?? [];
    final hasKnowledge = articles.any(
      (a) => a.processingStatus == ProcessingStatus.completed && a.hasMemory,
    );
    final s = ref.watch(stringsProvider);
    final chatAsync = ref.watch(chatSessionsProvider);
    final chatState = chatAsync.valueOrNull;
    final messages =
        chatState?.messages
            .map(ChatMessage.fromRecord)
            .toList(growable: false) ??
        const <ChatMessage>[];
    final chatUnavailable = chatAsync.hasError || chatAsync.isLoading;

    return Scaffold(
      appBar: AppBar(
        title: Text(s.tabChat),
        actions: [
          IconButton(
            icon: const Icon(Icons.history_rounded),
            tooltip: s.chatHistory,
            onPressed: _loading || chatState == null ? null : _showChatHistory,
          ),
          IconButton(
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: s.chatNew,
            onPressed: _loading || chatState == null ? null : _startNewThread,
          ),
          IconButton(
            icon: const Icon(Icons.tune_rounded),
            tooltip: s.chatSettings,
            onPressed: _showChatSettings,
          ),
        ],
      ),
      body: Column(
        children: [
              Expanded(
                child: chatAsync.isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : chatAsync.hasError
                    ? Center(child: Text(s.failedToLoad))
                    : messages.isEmpty
                    ? ChatEmptyState(hasKnowledge: hasKnowledge, s: s)
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        itemCount: messages.length + (_loading ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == messages.length) {
                            return const ChatTypingIndicator();
                          }
                          return ChatBubble(
                            message: messages[index],
                            articles: articles,
                            onFeedback: (feedback) => _onFeedback(
                              messages[index].id,
                              messages[index].logId,
                              feedback,
                            ),
                            onCitationClick: (articleId) => _onCitationClick(
                              messages[index].logId,
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
                loading: _loading || chatUnavailable,
                s: s,
                onSend: () => _send(),
              ),
            ],
      ),
    );
  }
}
