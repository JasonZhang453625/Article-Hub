import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../../config/routes.dart';
import '../../data/models/chat_message_record.dart';
import '../../data/models/passage.dart';
import '../../data/models/source_platform.dart';
import '../../data/services/ai_service.dart';
import '../../data/services/hosted_agent_service.dart';
import '../../data/services/rag_conversation_service.dart';
import '../../shared/providers/chat_providers.dart';
import '../../shared/providers/locale_provider.dart';
import '../../shared/providers/passage_providers.dart';
import '../../shared/providers/pipeline_provider.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/utils/ai_error_messages.dart';
import '../../shared/utils/snackbar_helpers.dart';
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

  /// Whether the jump-to-bottom button should be visible: true when the
  /// list has content below the viewport, false when already at the bottom.
  bool _showJumpToBottom = false;

  /// Monotonic token identifying the current answer run. A late result from an
  /// older run must never overwrite a newer retry.
  int _answerRunId = 0;

  /// Hosted server runs are resumed one at a time because the service keeps
  /// the latest event/source metadata on the instance.
  bool _resumingServerRuns = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_resumePendingServerRuns());
    });
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
    if (state == AppLifecycleState.resumed) {
      // Reconnect to a durable hosted run after the OS has paused the app or
      // the network connection has been recreated. The server task itself is
      // independent of this lifecycle callback.
      unawaited(_resumePendingServerRuns());
    }
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
    var activePending = pending;
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
    final toolProgress = <String, String>{};
    var answerStarted = false;
    var lastPartialPersist = DateTime.fromMillisecondsSinceEpoch(0);
    var partialPersistChain = Future<void>.value();

    void publishDelta(String delta) {
      if (!mounted || runId != _answerRunId || delta.isEmpty) return;
      answerStarted = true;
      streamedAnswer.write(delta);
      final partial = activePending.copyWith(
        content: streamedAnswer.toString(),
        status: ChatMessageStatus.sending,
      );
      // Update the visible bubble for every delta, but throttle durable writes
      // so a long answer does not turn Hive into a per-token queue. The page
      // does NOT auto-scroll here: the viewport stays put while text streams
      // in — only the user's own scrolling moves the page.
      sessions.replaceMessageInMemory(partial);

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

    void publishAgentEvent(HostedAgentEvent event) {
      if (!mounted || runId != _answerRunId || answerStarted) return;
      final tool = (event.data['tool'] ?? '').toString().trim();
      if (tool.isEmpty) return;
      final callId = (event.data['callId'] ?? '').toString().trim();
      final key = callId.isEmpty ? '$tool-${toolProgress.length}' : callId;
      switch (event.type) {
        case 'tool.call.started':
          final query = (event.data['query'] ?? '').toString().trim();
          toolProgress[key] = tool == 'web_search'
              ? query.isEmpty
                    ? '🔎 ${s.chatToolSearching}'
                    : '🔎 ${s.chatToolSearching}: $query'
              : '🛠️ ${s.chatToolCalling}: $tool';
          break;
        case 'tool.call.completed':
          final sourceCount = event.data['sourceCount'];
          final sources = sourceCount is num && sourceCount > 0
              ? ' (${sourceCount.toInt()} ${s.chatToolSources})'
              : '';
          toolProgress[key] = '✓ ${s.chatToolCompleted}: $tool$sources';
          break;
        case 'tool.call.failed':
          toolProgress[key] = '⚠️ ${s.chatToolFailed}: $tool';
          break;
        default:
          return;
      }
      sessions.replaceMessageInMemory(
        activePending.copyWith(
          content: toolProgress.values.join('\n'),
          status: ChatMessageStatus.sending,
        ),
      );
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
          thinkingLevel: ref.read(chatThinkingLevelProvider),
        ),
        onDelta: publishDelta,
        onAgentEvent: publishAgentEvent,
        onRunCreated: (serverRunId) async {
          if (runId != _answerRunId) return;
          activePending = activePending.copyWith(
            aiRunId: serverRunId,
            aiRunEventSeq: 0,
            status: ChatMessageStatus.sending,
          );
          // Persist the server id before the first answer event. If Android
          // kills the process immediately afterwards, the next launch can
          // still reconnect instead of treating this as an orphaned request.
          await sessions.updateMessage(activePending);
        },
        idempotencyKey: pending.id,
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
            activePending.copyWith(
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
            activePending.copyWith(
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
            activePending.copyWith(
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
        activePending.copyWith(
          content: answer.isEmpty ? friendlyError : '$answer\n\n$friendlyError',
          status: ChatMessageStatus.failed,
          errorCode: 'unexpected_error',
        ),
      );
    }
  }

  Future<void> _resumePendingServerRuns() async {
    if (!mounted || _resumingServerRuns) return;
    final hostedAgent = ref.read(hostedAgentServiceProvider);
    if (hostedAgent == null) return;

    _resumingServerRuns = true;
    try {
      final sessions = ref.read(chatSessionsProvider.notifier);
      final pending = await sessions.pendingServerMessages();
      for (final message in pending) {
        final runId = message.aiRunId;
        if (!mounted || runId == null || runId.trim().isEmpty) continue;
        await _resumeOneServerRun(
          message,
          runId: runId,
          hostedAgent: hostedAgent,
        );
      }
    } catch (error, stackTrace) {
      developer.log(
        'failed to resume hosted chat runs',
        name: 'memora.chat',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _resumingServerRuns = false;
    }
  }

  Future<void> _resumeOneServerRun(
    ChatMessageRecord message, {
    required String runId,
    required HostedAgentService hostedAgent,
  }) async {
    final sessions = ref.read(chatSessionsProvider.notifier);
    final buffer = StringBuffer();

    bool isStillCurrent() {
      final current = ref.read(chatSessionsProvider).valueOrNull;
      final record = current == null
          ? null
          : _findMessage(current.messages, message.id);
      return record?.aiRunId == runId &&
          record?.status == ChatMessageStatus.sending;
    }

    try {
      await for (final delta in hostedAgent.resumeStream(runId)) {
        if (!isStillCurrent()) return;
        if (delta.isEmpty) continue;
        buffer.write(delta);
        await sessions.updateMessage(
          message.copyWith(
            content: buffer.toString(),
            status: ChatMessageStatus.sending,
            aiRunEventSeq: hostedAgent.lastEventSeq,
            webUrls: hostedAgent.lastWebUrls,
          ),
        );
      }

      if (!isStillCurrent()) return;
      final answer = buffer.toString().trim();
      final s = ref.read(stringsProvider);
      if (answer.isEmpty) {
        final error = localizedAiErrorMessage(
          s,
          hostedAgent.lastError ?? 'Hosted Agent returned an empty answer.',
        );
        await sessions.updateMessage(
          message.copyWith(
            content: error,
            status: ChatMessageStatus.failed,
            errorCode: 'hosted_run_failed',
            aiRunEventSeq: hostedAgent.lastEventSeq,
          ),
        );
        return;
      }
      await sessions.updateMessage(
        message.copyWith(
          content: answer,
          status: ChatMessageStatus.completed,
          webUrls: hostedAgent.lastWebUrls,
          aiRunEventSeq: hostedAgent.lastEventSeq,
        ),
      );
    } catch (error, stackTrace) {
      developer.log(
        'hosted chat run resume failed',
        name: 'memora.chat',
        error: error,
        stackTrace: stackTrace,
      );
      if (!isStillCurrent()) return;
      final friendly = localizedAiErrorMessage(ref.read(stringsProvider), error);
      await sessions.updateMessage(
        message.copyWith(
          content: friendly,
          status: ChatMessageStatus.failed,
          errorCode: 'hosted_run_failed',
          aiRunEventSeq: hostedAgent.lastEventSeq,
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
    }
  }

  /// Updates the jump-to-bottom button's visibility as the user scrolls:
  /// shown whenever the viewport is not at the very bottom of the list.
  void _onListScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final atBottom =
        position.pixels >= position.maxScrollExtent - 1 &&
        position.maxScrollExtent > 0;
    final show = !atBottom && position.maxScrollExtent > 0;
    if (show != _showJumpToBottom) {
      setState(() => _showJumpToBottom = show);
    }
  }

  /// User-triggered scroll to the latest message (jump-to-bottom button).
  void _jumpToBottom() {
    if (!_scrollController.hasClients) return;
    FocusScope.of(context).unfocus();
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  void _showChatTools() {
    FocusScope.of(context).unfocus();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      isScrollControlled: true,
      builder: (_) => Consumer(
        builder: (context, sheetRef, _) {
          final settings = sheetRef.watch(settingsProvider).valueOrNull;
          final hosted = sheetRef.watch(hostedAiEnabledProvider);
          final model = hosted
              ? (settings?.hostedChatModel ?? '')
              : (settings?.chatAiModel ?? '');
          final baseUrl = hosted ? '' : (settings?.chatAiBaseUrl ?? '');
          return ChatToolsSheet(
            s: sheetRef.watch(stringsProvider),
            webSearchEnabled: sheetRef.watch(chatWebSearchEnabledProvider),
            webSearchAvailable: sheetRef.watch(webSearchConfiguredProvider),
            thinkingLevel: sheetRef.watch(chatThinkingLevelProvider),
            thinkingAvailable: supportsDeepSeekThinking(
              model: model,
              baseUrl: baseUrl,
            ),
            onToggleWebSearch: (enabled) =>
                sheetRef.read(chatWebSearchEnabledProvider.notifier).state =
                    enabled,
            onThinkingChanged: (level) =>
                sheetRef.read(chatThinkingLevelProvider.notifier).state = level,
          );
        },
      ),
    );
  }

  void _showChatSettings() {
    final settings = ref.read(settingsProvider).valueOrNull;
    if (settings == null) return;
    FocusScope.of(context).unfocus();

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
                // The sheet itself is half the viewport tall, so moving the
                // full route by half a viewport keeps the entry motion flush
                // with the bottom edge instead of starting a screen away.
                translation: Offset(0, 0.5 * (1 - curved.value)),
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

  /// Saves an assistant answer as a full-text memory: the answer text becomes
  /// the memory body, and the pipeline runs the tags/folder stages (no AI
  /// re-summarization of the answer).
  Future<void> _saveAnswerToMemory(ChatMessage message) async {
    final s = ref.read(stringsProvider);
    final text = message.text.trim();
    if (text.isEmpty) {
      showAppSnackBar(context, message: s.saveAnswerNoContent);
      return;
    }

    final articles = ref.read(articlesProvider).valueOrNull ?? [];
    if (articles.any((a) => a.url == _chatMemoryUrl(message.id))) {
      showAppSnackBar(context, message: s.saveAnswerExists);
      return;
    }

    try {
      final id = const Uuid().v4();
      final title = message.query == null || message.query!.trim().isEmpty
          ? s.appTitle
          : message.query!.trim();
      final article = Article(
        id: id,
        url: _chatMemoryUrl(message.id),
        title: _truncateTitle(title),
        source: SourcePlatform.local,
        isFullText: true,
        processingStatus: ProcessingStatus.pending,
      );
      // Full-text path: inject the answer text directly as the memory body,
      // then run only the tags/folder stages synchronously. Processing before
      // adding keeps the record out of the processing queue (which would try
      // to re-fetch the memora:// URL); when `add` fires the queue scan the
      // article is already completed and gets skipped.
      final processed = await ref
          .read(processingPipelineProvider)
          .processFile(article, text, fullText: true);
      await ref.read(articlesProvider.notifier).add(processed ?? article);
      if (mounted) {
        showAppSnackBar(context, message: s.saveAnswerSuccess);
      }
    } catch (e, st) {
      developer.log(
        'save answer failed: $e',
        name: 'memora.chat',
        error: e,
        stackTrace: st,
      );
      if (mounted) {
        showAppSnackBar(context, message: '${s.saveAnswerFailed}: $e');
      }
    }
  }

  String _chatMemoryUrl(String messageId) => 'memora://chat/$messageId';

  String _truncateTitle(String title) {
    return title.length > 60 ? title.substring(0, 60) : title;
  }

  Future<void> _startNewThread() async {
    await ref.read(chatSessionsProvider.notifier).startNewThread();
    _controller.clear();
  }

  Future<void> _selectThread(String threadId) async {
    await ref.read(chatSessionsProvider.notifier).selectThread(threadId);
  }

  @override
  Widget build(BuildContext context) {
    final articles = ref.watch(articlesProvider).valueOrNull ?? [];
    final articlesById = {for (final article in articles) article.id: article};
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
    final hasPendingServerRun = messages.any(
      (message) => message.isPending && message.id.isNotEmpty,
    );
    if (chatState != null && hasPendingServerRun) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_resumePendingServerRuns());
      });
    }
    final chatUnavailable = chatAsync.hasError || chatAsync.isLoading;
    final drawerEnabled =
        !_loading && !hasPendingServerRun && chatState != null;
    final brightness = Theme.of(context).brightness;
    final topInset = MediaQuery.paddingOf(context).top;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: brightness == Brightness.dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      child: Scaffold(
        // The outer shell Scaffold resizes for the keyboard (default), which
        // pins the NavigationBar to the screen bottom so it stays hidden
        // behind the keyboard instead of floating up with it. ChatScreen
        // disables its own resize to avoid double-compressing the layout.
        resizeToAvoidBottomInset: false,
        // Let the drawer be pulled out by a swipe starting anywhere on screen
        // (edge width 0 → full-width drag), not just the left edge.
        drawerEdgeDragWidth: 0,
        drawerEnableOpenDragGesture: drawerEnabled,
        drawer: chatState == null
            ? null
            : ChatHistoryDrawer(
                threads: chatState.threads,
                activeThreadId: chatState.activeThreadId,
                s: s,
                enabled: !_loading && !hasPendingServerRun,
                onNewThread: _startNewThread,
                onSelectThread: _selectThread,
                onDeleteThread: ref
                    .read(chatSessionsProvider.notifier)
                    .deleteThread,
                onRenameThread: ref
                    .read(chatSessionsProvider.notifier)
                    .renameThread,
                onSetThreadPinned: ref
                    .read(chatSessionsProvider.notifier)
                    .setThreadPinned,
              ),
        body: Stack(
          fit: StackFit.expand,
          children: [
            Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: chatAsync.isLoading
                            ? const Center(child: CircularProgressIndicator())
                            : chatAsync.hasError
                            ? Center(child: Text(s.failedToLoad))
                            : messages.isEmpty
                            ? ChatEmptyState(hasKnowledge: hasKnowledge, s: s)
                            : NotificationListener<ScrollNotification>(
                                onNotification: (notification) {
                                  if (notification.metrics.axis ==
                                      Axis.vertical) {
                                    _onListScroll();
                                  }
                                  return false;
                                },
                                child: ListView.builder(
                                  key: const ValueKey('chat-message-list'),
                                  controller: _scrollController,
                                  // Keep a bounded amount of already-built
                                  // rich message UI around the viewport. This
                                  // avoids reparsing long Markdown answers
                                  // during quick scrolling.
                                  cacheExtent: 800,
                                  // The list still extends behind the top
                                  // fade, but at its minimum scroll extent the
                                  // first bubble stops at the visible bottom
                                  // of the two floating top buttons:
                                  // 8 top offset + 48 Material tap surface.
                                  padding: EdgeInsets.fromLTRB(
                                    16,
                                    topInset + 56,
                                    16,
                                    12,
                                  ),
                                  itemCount: messages.length,
                                  itemBuilder: (context, index) {
                                    final message = messages[index];
                                    return ChatBubble(
                                      key: ValueKey(
                                        'chat-message-reveal-${message.id}',
                                      ),
                                      message: message,
                                      articlesById: articlesById,
                                      onFeedback: (feedback) => _onFeedback(
                                        message.id,
                                        message.logId,
                                        feedback,
                                      ),
                                      onCitationClick: (articleId) =>
                                          _onCitationClick(
                                            message.logId,
                                            articleId,
                                          ),
                                      onSuggestionTap: _send,
                                      onRetry: _retry,
                                      onSave: _saveAnswerToMemory,
                                      onBrowseKnowledge: () {
                                        context.go(AppRoutes.knowledge);
                                      },
                                    );
                                  },
                                ),
                              ),
                      ),
                      // Jump-to-bottom button: centered above the input bar,
                      // shown only while the viewport is not at the bottom.
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 12,
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: AnimatedOpacity(
                            opacity: _showJumpToBottom ? 1 : 0,
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
                            child: IgnorePointer(
                              ignoring: !_showJumpToBottom,
                              child: _ChatTopButton(
                                surfaceKey: const ValueKey('chat-jump-surface'),
                                buttonKey: const ValueKey('chat-jump-button'),
                                icon: Icons.arrow_downward_rounded,
                                tooltip: s.chatJumpToBottom,
                                onPressed: _showJumpToBottom
                                    ? _jumpToBottom
                                    : null,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                ChatInputBar(
                  controller: _controller,
                  loading: _loading || hasPendingServerRun || chatUnavailable,
                  s: s,
                  onSend: () => _send(),
                  onOpenTools: _showChatTools,
                ),
              ],
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: topInset + 88,
              child: _ChatTopFade(brightness: brightness),
            ),
            Positioned(
              top: topInset + 8,
              left: 4,
              child: Builder(
                builder: (drawerContext) => _ChatTopButton(
                  surfaceKey: const ValueKey('chat-sidebar-surface'),
                  buttonKey: const ValueKey('chat-sidebar-button'),
                  icon: Icons.menu_rounded,
                  tooltip: s.chatHistory,
                  onPressed: drawerEnabled
                      ? () {
                          FocusScope.of(context).unfocus();
                          Scaffold.of(drawerContext).openDrawer();
                        }
                      : null,
                ),
              ),
            ),
            Positioned(
              top: topInset + 8,
              right: 4,
              child: _ChatTopButton(
                surfaceKey: const ValueKey('chat-settings-surface'),
                buttonKey: const ValueKey('chat-settings-button'),
                icon: Icons.tune_rounded,
                tooltip: s.chatSettings,
                onPressed: _showChatSettings,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatTopFade extends StatelessWidget {
  final Brightness brightness;

  const _ChatTopFade({required this.brightness});

  @override
  Widget build(BuildContext context) {
    final color = brightness == Brightness.dark ? Colors.black : Colors.white;
    return IgnorePointer(
      child: DecoratedBox(
        key: const ValueKey('chat-top-fade'),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [color, color.withAlpha(242), color.withAlpha(0)],
            stops: const [0, 0.42, 1],
          ),
        ),
      ),
    );
  }
}

class _ChatTopButton extends StatelessWidget {
  final Key surfaceKey;
  final Key buttonKey;
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const _ChatTopButton({
    required this.surfaceKey,
    required this.buttonKey,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 48,
      child: Center(
        child: Material(
          key: surfaceKey,
          color: Colors.white,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: IconButton(
            key: buttonKey,
            icon: Icon(icon),
            tooltip: tooltip,
            onPressed: onPressed,
            style: IconButton.styleFrom(
              foregroundColor: const Color(0xFF10273F),
              disabledForegroundColor: const Color(0xFF8FA3B1),
              minimumSize: const Size.square(40),
              maximumSize: const Size.square(40),
              padding: EdgeInsets.zero,
            ),
          ),
        ),
      ),
    );
  }
}
