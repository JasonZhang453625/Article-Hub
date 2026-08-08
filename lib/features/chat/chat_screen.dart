import 'dart:async';
import 'dart:developer' as developer;

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
import '../../shared/utils/ai_error_messages.dart';
import '../../shared/widgets/delayed_reveal.dart';
import 'chat_message.dart';
import 'chat_bubble.dart';
import 'chat_empty_state.dart';
import 'chat_history_drawer.dart';
import 'chat_input_bar.dart';
import 'chat_settings_sheet.dart';
import 'chat_tools_sheet.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with WidgetsBindingObserver {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  bool _loading = false;
  bool _keyboardWasOpen = false;

  /// Monotonic token identifying the current answer run. A late result from an
  /// older run must never overwrite a newer retry.
  int _answerRunId = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // When the keyboard collapses (e.g. system back button) the input field
    // would otherwise keep focus forever — dismiss it explicitly.
    if (!mounted) return;
    final viewInsets = View.of(context).viewInsets.bottom;
    if (viewInsets == 0 && _keyboardWasOpen) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    _keyboardWasOpen = viewInsets > 0;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _loading) {
      // Do not mark the answer as interrupted here. When the activity is
      // merely covered by another app, the Dart future may still complete in
      // the background. If Android kills the process instead, the persisted
      // `sending` record is recovered by ChatSessionsNotifier on the next
      // launch. Transport failures are handled by AiService's retry path.
      _scrollToBottom();
    }
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

    // Dismiss the keyboard as soon as a message is sent.
    FocusScope.of(context).unfocus();

    final chatState = ref.read(chatSessionsProvider).valueOrNull;
    if (chatState == null) return;
    final history = _completedHistory(chatState.messages);

    if (overrideQuery == null) _controller.clear();
    setState(() {
      _loading = true;
    });
    final runId = ++_answerRunId;
    final sessions = ref.read(chatSessionsProvider.notifier);
    ChatMessageRecord? pending;
    try {
      final persistedUser = await sessions.addUserMessage(query);
      pending = await sessions.addPendingMessage(
        threadId: persistedUser.threadId,
        query: query,
      );
      _scrollToBottom();
      await _runAnswer(pending: pending, history: history, runId: runId);
    } catch (error, stackTrace) {
      _handleRunFailure(
        pending: pending,
        error: error,
        stackTrace: stackTrace,
        runId: runId,
      );
    } finally {
      _finishLoading(runId);
    }
  }

  /// Re-runs an answer on its original message, without duplicating the user
  /// question or creating a second assistant bubble.
  Future<void> _retry(ChatMessage message) async {
    final query = message.query ?? '';
    if (query.isEmpty || _loading) return;
    final chatState = ref.read(chatSessionsProvider).valueOrNull;
    if (chatState == null) return;
    final record = _findMessage(chatState.messages, message.id);
    if (record == null || record.role != ChatMessageRole.assistant) return;
    final retryHistoryMessages = chatState.messages
        .where((item) => item.id != record.id)
        .toList();
    // The user question immediately before this assistant record is passed
    // separately as [pending.query], so it must not be duplicated in history.
    if (retryHistoryMessages.isNotEmpty &&
        retryHistoryMessages.last.role == ChatMessageRole.user &&
        retryHistoryMessages.last.content == query) {
      retryHistoryMessages.removeLast();
    }
    final history = _completedHistory(retryHistoryMessages);

    setState(() {
      _loading = true;
    });
    final runId = ++_answerRunId;
    final retried = record.retrying();
    try {
      await ref.read(chatSessionsProvider.notifier).updateMessage(retried);
      _scrollToBottom();
      await _runAnswer(pending: retried, history: history, runId: runId);
    } catch (error, stackTrace) {
      _handleRunFailure(
        pending: retried,
        error: error,
        stackTrace: stackTrace,
        runId: runId,
      );
    } finally {
      _finishLoading(runId);
    }
  }

  /// Runs the RAG pipeline and writes the outcome back onto [pending].
  ///
  /// [runId] identifies this specific answer run. If the widget started a
  /// newer run (retry) in the meantime, this run's result and loading-flag
  /// reset are discarded.
  Future<void> _runAnswer({
    required ChatMessageRecord pending,
    required List<RagConversationTurn> history,
    required int runId,
  }) async {
    final sessions = ref.read(chatSessionsProvider.notifier);
    final settings = ref.read(settingsProvider).valueOrNull;
    final s = ref.read(stringsProvider);
    Future<void> finish(ChatMessageRecord updated) =>
        sessions.updateMessage(updated);

    if (settings == null || ref.read(chatAiGatewayProvider) == null) {
      await finish(
        pending.copyWith(
          content: s.configureAiFirst,
          status: ChatMessageStatus.failed,
          errorCode: 'ai_not_configured',
        ),
      );
      return;
    }
    final activeSettings = settings;

    final conversation = ref.read(ragConversationServiceProvider);
    if (conversation == null) {
      await finish(
        pending.copyWith(
          content: s.configureAiFirst,
          status: ChatMessageStatus.failed,
          errorCode: 'ai_unavailable',
        ),
      );
      return;
    }

    final articles = ref.read(articlesProvider).valueOrNull ?? [];
    final completedArticles = articles
        .where(
          (a) =>
              a.processingStatus == ProcessingStatus.completed && a.hasMemory,
        )
        .toList();

    // With an empty knowledge base, web search (explicitly enabled) is still
    // a valid source — only block when the user expects local-only answers.
    if (completedArticles.isEmpty &&
        activeSettings.chatKnowledgeSourceIndex == 0 &&
        !ref.read(chatWebSearchEnabledProvider)) {
      await finish(
        pending.copyWith(
          content: s.knowledgeBaseEmpty,
          isNoResult: true,
          query: pending.query,
          status: ChatMessageStatus.completed,
        ),
      );
      return;
    }

    final streamedAnswer = StringBuffer();
    var lastPartialPersist = DateTime.fromMillisecondsSinceEpoch(0);
    var partialPersistChain = Future<void>.value();

    void publishDelta(String delta) {
      if (!mounted || runId != _answerRunId || delta.isEmpty) return;
      streamedAnswer.write(delta);
      final partial = pending.copyWith(
        content: streamedAnswer.toString(),
        status: ChatMessageStatus.sending,
      );
      // Update the visible bubble for every delta, but throttle durable writes
      // so a long answer does not turn Hive into a per-token queue.
      sessions.replaceMessageInMemory(partial);
      _scrollToBottom();

      final now = DateTime.now();
      if (now.difference(lastPartialPersist) <
          const Duration(milliseconds: 250)) {
        return;
      }
      lastPartialPersist = now;
      partialPersistChain = partialPersistChain.then((_) async {
        try {
          await sessions.updateMessage(partial);
        } catch (_) {
          // The final write below is authoritative. A transient partial-write
          // failure should not stop the current stream from reaching the UI.
        }
      });
    }

    try {
      final result = await conversation.askWithProgress(
        RagConversationRequest(
          question: pending.query ?? '',
          history: history,
          articles: completedArticles,
          knowledgeOnly: activeSettings.chatKnowledgeSourceIndex == 0,
          detailedAnswer: activeSettings.chatAnswerLengthIndex == 1,
          languageHint: aiLanguagePrompt(activeSettings.languageIndex),
          webSearch: ref.read(chatWebSearchEnabledProvider),
        ),
        onDelta: publishDelta,
      );
      await partialPersistChain;
      if (runId != _answerRunId) {
        // This run was superseded by a newer retry while
        // the request was in flight — discard its outcome.
        return;
      }
      switch (result.outcome) {
        case RagConversationOutcome.answer:
          await finish(
            pending.copyWith(
              content: result.answer ?? streamedAnswer.toString(),
              articleIds: result.citedIds,
              webUrls: result.webUrls,
              method: result.method,
              logId: result.logId,
              status: ChatMessageStatus.completed,
            ),
          );
          break;
        case RagConversationOutcome.noResult:
          await finish(
            pending.copyWith(
              content: s.notEnoughInfo,
              isNoResult: true,
              weakArticleIds: result.weakArticleIds,
              method: result.method,
              logId: result.logId,
              query: pending.query,
              status: ChatMessageStatus.completed,
            ),
          );
          break;
        case RagConversationOutcome.error:
          final answer = (result.answer ?? streamedAnswer.toString()).trim();
          final friendlyError = localizedAiErrorMessage(s, result.error);
          await finish(
            pending.copyWith(
              content: answer.isEmpty
                  ? friendlyError
                  : '$answer\n\n$friendlyError',
              method: result.method,
              logId: result.logId,
              status: ChatMessageStatus.failed,
              errorCode: 'rag_error',
            ),
          );
          break;
      }
    } catch (error) {
      await partialPersistChain;
      if (runId != _answerRunId) return;
      final friendlyError = localizedAiErrorMessage(s, error);
      final answer = streamedAnswer.toString().trim();
      await finish(
        pending.copyWith(
          content: answer.isEmpty ? friendlyError : '$answer\n\n$friendlyError',
          status: ChatMessageStatus.failed,
          errorCode: 'unexpected_error',
        ),
      );
    }
  }

  List<RagConversationTurn> _completedHistory(
    List<ChatMessageRecord> messages,
  ) {
    return messages
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
  }

  ChatMessageRecord? _findMessage(List<ChatMessageRecord> messages, String id) {
    for (final message in messages) {
      if (message.id == id) return message;
    }
    return null;
  }

  void _handleRunFailure({
    required ChatMessageRecord? pending,
    required Object error,
    required StackTrace stackTrace,
    required int runId,
  }) {
    if (runId != _answerRunId || !mounted) return;
    developer.log(
      'chat answer run failed outside the normal RAG error path',
      name: 'memora.chat',
      error: error,
      stackTrace: stackTrace,
    );
    final s = ref.read(stringsProvider);
    final friendlyMessage = localizedAiErrorMessage(s, error);
    if (pending != null) {
      ref
          .read(chatSessionsProvider.notifier)
          .replaceMessageInMemory(
            pending.copyWith(
              content: friendlyMessage,
              status: ChatMessageStatus.failed,
              errorCode: 'local_persistence_error',
            ),
          );
    }
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(friendlyMessage)));
    }
  }

  void _finishLoading(int runId) {
    // Only the current run may release the loading flag; a stale run must not
    // unlock the input while a retry is already in progress.
    if (runId != _answerRunId) return;
    if (mounted) {
      setState(() => _loading = false);
      _scrollToBottom();
    }
  }

  void _showChatTools() {
    FocusScope.of(context).unfocus();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      isScrollControlled: true,
      builder: (_) => ChatToolsSheet(
        s: ref.read(stringsProvider),
        webSearchEnabled: ref.read(chatWebSearchEnabledProvider),
        webSearchAvailable: ref.read(webSearchConfiguredProvider),
        onToggleWebSearch: () =>
            ref.read(chatWebSearchEnabledProvider.notifier).state = !ref.read(
              chatWebSearchEnabledProvider,
            ),
      ),
    );
  }

  void _showChatSettings() {
    final settings = ref.read(settingsProvider).valueOrNull;
    if (settings == null) return;

    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black54,
        barrierDismissible: true,
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 240),
        pageBuilder: (_, _, _) => ChatSettingsSheet(
          s: ref.read(stringsProvider),
          answerLength: settings.chatAnswerLengthIndex,
          knowledgeSource: settings.chatKnowledgeSourceIndex,
          onChanged: (answerLength, knowledgeSource) => ref
              .read(settingsProvider.notifier)
              .setChatPreferences(
                answerLength: answerLength,
                knowledgeSource: knowledgeSource,
              ),
        ),
        transitionsBuilder: (_, animation, _, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return AnimatedBuilder(
            animation: curved,
            builder: (context, _) => Align(
              alignment: Alignment.bottomCenter,
              child: FractionalTranslation(
                translation: Offset(0, 1 - curved.value),
                child: child,
              ),
            ),
          );
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

  Future<void> _startNewThread() async {
    await ref.read(chatSessionsProvider.notifier).startNewThread();
    _controller.clear();
  }

  Future<void> _selectThread(String threadId) async {
    await ref.read(chatSessionsProvider.notifier).selectThread(threadId);
    _scrollToBottom();
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
    final activeThreadTitle = _activeThreadTitle(chatState, s.tabChat);
    final drawerEnabled = !_loading && chatState != null;

    return Scaffold(
      // The outer shell Scaffold resizes for the keyboard (default), which
      // pins the NavigationBar to the screen bottom so it stays hidden
      // behind the keyboard instead of floating up with it. ChatScreen
      // disables its own resize to avoid double-compressing the layout.
      resizeToAvoidBottomInset: false,
      drawerEnableOpenDragGesture: drawerEnabled,
      drawer: chatState == null
          ? null
          : ChatHistoryDrawer(
              threads: chatState.threads,
              activeThreadId: chatState.activeThreadId,
              s: s,
              enabled: !_loading,
              onNewThread: _startNewThread,
              onSelectThread: _selectThread,
              onDeleteThread: ref
                  .read(chatSessionsProvider.notifier)
                  .deleteThread,
            ),
      appBar: AppBar(
        leading: Builder(
          builder: (drawerContext) => IconButton(
            key: const ValueKey('chat-sidebar-button'),
            icon: const Icon(Icons.menu_rounded),
            tooltip: s.chatHistory,
            onPressed: drawerEnabled
                ? () {
                    FocusScope.of(context).unfocus();
                    Scaffold.of(drawerContext).openDrawer();
                  }
                : null,
          ),
        ),
        title: Text(activeThreadTitle, overflow: TextOverflow.ellipsis),
        actions: [
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
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      final revealDelayMs = index > 7 ? 210 : index * 30;
                      return DelayedReveal(
                        key: ValueKey('chat-message-reveal-${message.id}'),
                        delayMs: revealDelayMs,
                        duration: const Duration(milliseconds: 380),
                        beginOffset: const Offset(0, 0.025),
                        child: ChatBubble(
                          key: ValueKey('chat-bubble-${message.id}'),
                          message: message,
                          articles: articles,
                          onFeedback: (feedback) =>
                              _onFeedback(message.id, message.logId, feedback),
                          onCitationClick: (articleId) =>
                              _onCitationClick(message.logId, articleId),
                          onSuggestionTap: _send,
                          onRetry: _retry,
                          onBrowseKnowledge: () {
                            context.go(AppRoutes.knowledge);
                          },
                        ),
                      );
                    },
                  ),
          ),
          ChatInputBar(
            controller: _controller,
            loading: _loading || chatUnavailable,
            s: s,
            onSend: () => _send(),
            onOpenTools: _showChatTools,
          ),
        ],
      ),
    );
  }

  String _activeThreadTitle(ChatSessionState? state, String fallback) {
    final activeThreadId = state?.activeThreadId;
    if (activeThreadId == null) return fallback;
    for (final thread in state!.threads) {
      if (thread.id == activeThreadId) return thread.title;
    }
    return fallback;
  }
}
