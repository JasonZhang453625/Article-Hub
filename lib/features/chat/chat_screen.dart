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
import '../../data/services/chat_attachment_pipeline.dart';
import '../../data/services/chat_attachment_service.dart';
import '../../data/services/hosted_agent_service.dart';
import '../../data/services/rag_citation.dart';
import '../../data/services/rag_conversation_service.dart';
import '../../shared/providers/chat_providers.dart';
import '../../shared/providers/attachment_providers.dart';
import '../../shared/providers/locale_provider.dart';
import '../../shared/providers/passage_providers.dart';
import '../../shared/providers/pipeline_provider.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/utils/ai_error_messages.dart';
import '../../shared/utils/locale_strings.dart';
import '../../shared/utils/snackbar_helpers.dart';
import 'chat_message.dart';
import 'chat_bubble.dart';
import 'chat_empty_state.dart';
import 'chat_history_drawer.dart';
import 'chat_input_bar.dart';
import 'chat_settings_sheet.dart';
import 'chat_tools_sheet.dart';

enum _ChatToolAction { image, file, skill }

class _AnswerRunControl {
  final int localRunId;
  String? threadId;
  String? messageId;
  String? requestKey;
  String? serverRunId;
  bool cancelRequested = false;
  bool agentRequestStarted = false;
  bool durableRunExpected = false;

  _AnswerRunControl(this.localRunId);
}

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with WidgetsBindingObserver {
  final _controller = TextEditingController();
  final _inputFocusNode = FocusNode(debugLabel: 'chat-input');
  final _toolsParkingFocusNode = FocusNode(
    debugLabel: 'chat-tools-parking',
    skipTraversal: true,
  );
  final _scrollController = ScrollController();
  bool _loading = false;
  bool _keyboardWasOpen = false;
  final List<ChatAttachmentDraft> _attachmentDrafts = [];

  /// Whether the jump-to-bottom button should be visible: true when the
  /// list has content below the viewport, false when already at the bottom.
  bool _showJumpToBottom = false;

  /// Monotonic token identifying the current answer run. A late result from an
  /// older run must never overwrite a newer retry.
  int _answerRunId = 0;
  final Map<int, _AnswerRunControl> _answerRunControls = {};

  /// Hosted server runs are resumed one at a time because the service keeps
  /// the latest event/source metadata on the instance.
  static const int _maxPendingServerRunResumeRetries = 3;
  bool _resumingServerRuns = false;
  bool _pendingServerRunResumeRequested = false;
  int _pendingServerRunResumeFailures = 0;
  Timer? _pendingServerRunResumeRetryTimer;
  final Set<String> _liveServerRunIds = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _schedulePendingServerRunResume();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pendingServerRunResumeRetryTimer?.cancel();
    if (_attachmentDrafts.isNotEmpty) {
      unawaited(
        ref
            .read(chatAttachmentServiceProvider)
            .discardDrafts(List.of(_attachmentDrafts)),
      );
    }
    _controller.dispose();
    _inputFocusNode.dispose();
    _toolsParkingFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _pickImageAttachments() {
    return _pickAttachments(images: true);
  }

  Future<void> _pickFileAttachments() {
    return _pickAttachments(images: false);
  }

  Future<void> _pickAttachments({required bool images}) async {
    if (images && !ref.read(chatModelSupportsImageInputProvider)) {
      showAppSnackBar(
        context,
        message: ref.read(stringsProvider).chatAttachmentVisionRequired,
      );
      return;
    }
    final service = ref.read(chatAttachmentServiceProvider);
    final remainingSlots = maxChatAttachments - _attachmentDrafts.length;
    final usedBytes = _attachmentDrafts.fold<int>(
      0,
      (total, draft) => total + draft.attachment.byteLength,
    );
    if (remainingSlots <= 0) {
      showAppSnackBar(
        context,
        message: ref.read(stringsProvider).chatAttachmentTooMany,
      );
      return;
    }
    try {
      final picked = images
          ? await service.pickImages(
              remainingSlots: remainingSlots,
              remainingBytes: maxChatAttachmentTotalBytes - usedBytes,
            )
          : await service.pickFiles(
              remainingSlots: remainingSlots,
              remainingBytes: maxChatAttachmentTotalBytes - usedBytes,
            );
      if (!mounted) {
        await service.discardDrafts(picked);
        return;
      }
      if (picked.isNotEmpty) {
        setState(() => _attachmentDrafts.addAll(picked));
      }
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: _localizedAttachmentError(ref.read(stringsProvider), error),
      );
    }
  }

  void _removeAttachment(ChatAttachmentDraft draft) {
    setState(() => _attachmentDrafts.remove(draft));
    unawaited(
      ref
          .read(chatAttachmentServiceProvider)
          .discardDraft(draft)
          .catchError((_) {}),
    );
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
      _schedulePendingServerRunResume();
    }
  }

  Future<void> _send([String? overrideQuery]) async {
    final typedQuery = overrideQuery ?? _controller.text.trim();
    final drafts = List<ChatAttachmentDraft>.of(_attachmentDrafts);
    if (typedQuery.isEmpty && drafts.isEmpty ||
        _loading ||
        _resumingServerRuns) {
      return;
    }
    final s = ref.read(stringsProvider);
    final query = typedQuery.isEmpty
        ? s.chatAttachmentDefaultPrompt
        : typedQuery;

    // Dismiss the keyboard as soon as a message is sent.
    FocusScope.of(context).unfocus();

    final chatState = ref.read(chatSessionsProvider).valueOrNull;
    if (chatState == null) return;
    final history = _completedHistory(chatState.messages);

    setState(() {
      _loading = true;
      _attachmentDrafts.removeWhere(drafts.contains);
    });
    final runId = ++_answerRunId;
    final runControl = _AnswerRunControl(runId);
    _answerRunControls[runId] = runControl;
    final sessions = ref.read(chatSessionsProvider.notifier);
    ChatMessageRecord? pending;
    PersistedUserMessage? persistedUser;
    try {
      persistedUser = await sessions.addUserMessage(
        query,
        attachments: drafts
            .map((draft) => draft.attachment)
            .toList(growable: false),
      );
      runControl.threadId = persistedUser.threadId;
      if (mounted) {
        if (overrideQuery == null) _controller.clear();
      }
      pending = await sessions.addPendingMessage(
        threadId: persistedUser.threadId,
        query: query,
      );
      runControl
        ..messageId = pending.id
        ..requestKey = pending.aiRunRequestKey;
      if (runControl.cancelRequested || runId != _answerRunId) {
        await _finishUnstartedCancellation(runControl);
        return;
      }
      await _runAnswer(
        pending: pending,
        userMessage: persistedUser.message,
        history: history,
        runControl: runControl,
      );
    } catch (error, stackTrace) {
      if (persistedUser == null && mounted && drafts.isNotEmpty) {
        setState(() => _attachmentDrafts.insertAll(0, drafts));
      }
      _handleRunFailure(
        pending: pending,
        error: error,
        stackTrace: stackTrace,
        runId: runId,
      );
    } finally {
      _answerRunControls.remove(runId);
      _finishLoading(runId);
    }
  }

  /// Re-runs an answer on its original message, without duplicating the user
  /// question or creating a second assistant bubble.
  Future<void> _retry(ChatMessage message) async {
    final query = message.query ?? '';
    if (query.isEmpty || _loading || _resumingServerRuns) return;
    final chatState = ref.read(chatSessionsProvider).valueOrNull;
    if (chatState == null) return;
    final record = _findMessage(chatState.messages, message.id);
    if (record == null ||
        record.role != ChatMessageRole.assistant ||
        record.errorCode == 'hosted_cancel_requested') {
      return;
    }
    final recordIndex = chatState.messages.indexOf(record);
    ChatMessageRecord? sourceUserMessage;
    for (var index = recordIndex - 1; index >= 0; index--) {
      final candidate = chatState.messages[index];
      if (candidate.role == ChatMessageRole.user) {
        sourceUserMessage = candidate;
        break;
      }
    }
    if (sourceUserMessage == null) return;
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
    final retried = record.retrying(aiRunRequestKey: const Uuid().v4());
    final runControl = _AnswerRunControl(runId)
      ..threadId = retried.threadId
      ..messageId = retried.id
      ..requestKey = retried.aiRunRequestKey;
    _answerRunControls[runId] = runControl;
    try {
      await ref.read(chatSessionsProvider.notifier).updateMessage(retried);
      if (runControl.cancelRequested || runId != _answerRunId) {
        await _finishUnstartedCancellation(runControl);
        return;
      }
      await _runAnswer(
        pending: retried,
        userMessage: sourceUserMessage,
        history: history,
        runControl: runControl,
      );
    } catch (error, stackTrace) {
      _handleRunFailure(
        pending: retried,
        error: error,
        stackTrace: stackTrace,
        runId: runId,
      );
    } finally {
      _answerRunControls.remove(runId);
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
    required ChatMessageRecord userMessage,
    required List<RagConversationTurn> history,
    required _AnswerRunControl runControl,
  }) async {
    final runId = runControl.localRunId;
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

    var preparedAttachments = const PreparedChatAttachments();
    if (userMessage.attachments.isNotEmpty) {
      try {
        preparedAttachments = await ref
            .read(chatAttachmentPipelineProvider)
            .prepare(
              attachments: userMessage.attachments,
              useNativeImageInput: ref.read(
                chatModelSupportsImageInputProvider,
              ),
              cachedTextContext: userMessage.attachmentContext,
              cachedIncludesImageUnderstanding:
                  userMessage.attachmentContextIncludesImages,
            );
        final preparedContext = preparedAttachments.textContext.trim();
        if (preparedContext.isNotEmpty &&
            (preparedContext != userMessage.attachmentContext ||
                preparedAttachments.includesImageUnderstanding !=
                    userMessage.attachmentContextIncludesImages)) {
          await sessions.updateMessage(
            userMessage.copyWith(
              attachmentContext: preparedContext,
              attachmentContextIncludesImages:
                  preparedAttachments.includesImageUnderstanding,
            ),
          );
        }
      } catch (error) {
        if (runControl.cancelRequested || runId != _answerRunId) {
          await _finishUnstartedCancellation(runControl);
          return;
        }
        await finish(
          pending.copyWith(
            content: _localizedAttachmentError(s, error),
            status: ChatMessageStatus.failed,
            errorCode: 'attachment_preparation_failed',
          ),
        );
        return;
      }
    }

    // With an empty knowledge base, web search (explicitly enabled) is still
    // a valid source — only block when the user expects local-only answers.
    if (completedArticles.isEmpty &&
        activeSettings.chatKnowledgeSourceIndex == 0 &&
        !ref.read(chatWebSearchEnabledProvider) &&
        userMessage.attachments.isEmpty) {
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
    String? liveServerRunId;

    bool durableRunStillPending() {
      if (liveServerRunId == null) return false;
      final status = ref.read(hostedAgentServiceProvider)?.lastRunStatus;
      return status != 'completed' &&
          status != 'failed' &&
          status != 'cancelled';
    }

    Future<void> keepDurableRunPending(String partialAnswer) async {
      final hostedAgent = ref.read(hostedAgentServiceProvider);
      await finish(
        activePending.copyWith(
          content: partialAnswer.isEmpty
              ? activePending.content
              : partialAnswer,
          status: ChatMessageStatus.sending,
          aiRunEventSeq: hostedAgent?.lastEventSeq ?? 0,
          webUrls: hostedAgent?.lastWebUrls ?? activePending.webUrls,
        ),
      );
    }

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
        if (runControl.cancelRequested || runId != _answerRunId) return;
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

    if (runControl.cancelRequested || runId != _answerRunId) {
      await _finishUnstartedCancellation(runControl);
      return;
    }
    runControl.durableRunExpected =
        ref.read(hostedAgentServiceProvider) != null &&
        preparedAttachments.imageInputs.isEmpty;
    runControl.agentRequestStarted = true;

    try {
      final result = await conversation.askWithProgress(
        RagConversationRequest(
          question: pending.query ?? '',
          history: history,
          articles: completedArticles,
          knowledgeOnly: activeSettings.chatKnowledgeSourceIndex == 0,
          detailedAnswer: activeSettings.chatAnswerLengthIndex == 1,
          languageHint: aiChatLanguagePrompt(activeSettings.languageIndex),
          webSearch: ref.read(chatWebSearchEnabledProvider),
          thinkingLevel: ref.read(chatThinkingLevelProvider),
          attachmentContext: preparedAttachments.textContext,
          imageInputs: preparedAttachments.imageInputs,
        ),
        onDelta: publishDelta,
        onAgentEvent: publishAgentEvent,
        onRunCreated: (serverRunId) async {
          runControl.serverRunId = serverRunId;
          liveServerRunId = serverRunId;
          _liveServerRunIds.add(serverRunId);
          final attached = await sessions.attachServerRun(
            messageId: pending.id,
            expectedRequestKey: pending.aiRunRequestKey,
            runId: serverRunId,
          );
          if (attached == null) {
            // Delete/retry won the repository CAS. Never resurrect or
            // overwrite that state: persist a deletion compensation when the
            // thread is gone, otherwise cancel this superseded run directly.
            runControl.cancelRequested = true;
            try {
              if (!sessions.containsThread(pending.threadId)) {
                await sessions.queueDeletedThreadRunCancellation(
                  threadId: pending.threadId,
                  runId: serverRunId,
                );
              } else {
                await ref.read(hostedAgentRunCancellerProvider)(serverRunId);
              }
            } catch (error, stackTrace) {
              developer.log(
                'late hosted run cancellation failed',
                name: 'memora.chat',
                error: error,
                stackTrace: stackTrace,
              );
            }
            return;
          }
          activePending = attached;
          // Persisting the server id is the onRunCreated commit point. If Stop
          // raced with it, the request marker is also CAS-protected and is
          // retried after process restart until the backend acknowledges it.
          if (runControl.cancelRequested || runId != _answerRunId) {
            await sessions.requestServerRunCancellation(
              messageId: pending.id,
              expectedRequestKey: pending.aiRunRequestKey,
              runId: serverRunId,
            );
          }
        },
        idempotencyKey: pending.aiRunRequestKey ?? pending.id,
      );
      await partialPersistChain;
      if (runId != _answerRunId) {
        // This run was superseded by a newer retry while
        // the request was in flight — discard its outcome.
        if (runControl.serverRunId == null) {
          await _finishUnstartedCancellation(runControl);
        }
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
          if (durableRunStillPending()) {
            await keepDurableRunPending(answer);
            break;
          }
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
      if (runId != _answerRunId) {
        if (runControl.serverRunId == null) {
          await _finishUnstartedCancellation(runControl);
        }
        return;
      }
      final answer = streamedAnswer.toString().trim();
      if (durableRunStillPending()) {
        await keepDurableRunPending(answer);
        return;
      }
      final friendlyError = localizedAiErrorMessage(s, error);
      await finish(
        activePending.copyWith(
          content: answer.isEmpty ? friendlyError : '$answer\n\n$friendlyError',
          status: ChatMessageStatus.failed,
          errorCode: 'unexpected_error',
        ),
      );
    } finally {
      final serverRunId = liveServerRunId;
      if (serverRunId != null) {
        _liveServerRunIds.remove(serverRunId);
        _schedulePendingServerRunResume();
      }
    }
  }

  /// Queues a durable-run recovery attempt without ever running it beside a
  /// live answer request. Keeping the request latched is important: settings
  /// and authentication can still be loading on the first frame, and a live
  /// POST has no server run id until its create response arrives.
  void _schedulePendingServerRunResume() {
    if (!mounted) return;
    // A real lifecycle/provider/live-run transition is a fresh signal. Let it
    // retry immediately even if an earlier automatic backoff was exhausted.
    _pendingServerRunResumeRetryTimer?.cancel();
    _pendingServerRunResumeRetryTimer = null;
    _pendingServerRunResumeFailures = 0;
    _pendingServerRunResumeRequested = true;
    unawaited(_resumePendingServerRuns());
  }

  void _schedulePendingServerRunResumeRetry() {
    if (!mounted ||
        _pendingServerRunResumeRetryTimer != null ||
        _pendingServerRunResumeFailures >= _maxPendingServerRunResumeRetries) {
      return;
    }
    _pendingServerRunResumeFailures++;
    final delay = Duration(
      milliseconds: 300 * (1 << (_pendingServerRunResumeFailures - 1)),
    );
    _pendingServerRunResumeRetryTimer = Timer(delay, () {
      _pendingServerRunResumeRetryTimer = null;
      if (!mounted) return;
      unawaited(_resumePendingServerRuns());
    });
  }

  Future<void> _resumePendingServerRuns() async {
    if (!mounted || _resumingServerRuns || !_pendingServerRunResumeRequested) {
      return;
    }
    // [_loading] is set before any persistence or network await in send/retry,
    // closing the window before onRunCreated can add a server id. The queued
    // request is deliberately retained and drained by [_finishLoading].
    if (_loading || _liveServerRunIds.isNotEmpty) return;
    final hostedAgent = ref.read(hostedAgentServiceProvider);
    // The provider is temporarily null while settings/auth are loading. A
    // provider listener in build will retry when it becomes available.
    if (hostedAgent == null) return;

    _resumingServerRuns = true;
    _pendingServerRunResumeRequested = false;
    var recoveryFailed = false;
    try {
      final sessions = ref.read(chatSessionsProvider.notifier);
      await sessions.retryPendingRunCancellations();
      final pending = await sessions.pendingServerMessages();
      for (final message in pending) {
        final runId = message.aiRunId;
        if (!mounted ||
            runId == null ||
            runId.trim().isEmpty ||
            _liveServerRunIds.contains(runId)) {
          continue;
        }
        try {
          await _resumeOneServerRun(
            message,
            runId: runId,
            hostedAgent: hostedAgent,
          );
        } catch (_) {
          // One unavailable or locally unpersistable run must not starve the
          // other conversations in this recovery batch. _resumeOneServerRun
          // already logs the precise failure and leaves this message pending.
          recoveryFailed = true;
        }
      }
      if (recoveryFailed) {
        _pendingServerRunResumeRequested = true;
        _schedulePendingServerRunResumeRetry();
      } else {
        _pendingServerRunResumeFailures = 0;
        _pendingServerRunResumeRetryTimer?.cancel();
        _pendingServerRunResumeRetryTimer = null;
      }
    } catch (error, stackTrace) {
      recoveryFailed = true;
      _pendingServerRunResumeRequested = true;
      _schedulePendingServerRunResumeRetry();
      developer.log(
        'failed to resume hosted chat runs',
        name: 'memora.chat',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _resumingServerRuns = false;
      if (mounted && _pendingServerRunResumeRequested && !recoveryFailed) {
        unawaited(_resumePendingServerRuns());
      }
    }
  }

  Future<void> _resumeOneServerRun(
    ChatMessageRecord message, {
    required String runId,
    required HostedAgentService hostedAgent,
  }) async {
    final sessions = ref.read(chatSessionsProvider.notifier);
    final buffer = StringBuffer(message.content);

    bool isStillCurrent() {
      return sessions.isPendingServerRun(messageId: message.id, runId: runId);
    }

    try {
      await for (final delta in hostedAgent.resumeStream(
        runId,
        afterEventSeq: message.aiRunEventSeq ?? 0,
      )) {
        if (!isStillCurrent()) return;
        if (delta.isEmpty) continue;
        if (hostedAgent.lastChunkIsFullAnswer) buffer.clear();
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
      if (hostedAgent.lastRunStatus == 'failed' ||
          hostedAgent.lastRunStatus == 'cancelled') {
        final friendly = localizedAiErrorMessage(
          s,
          hostedAgent.lastError ?? 'Hosted Agent failed.',
        );
        await sessions.updateMessage(
          message.copyWith(
            content: answer.isEmpty ? friendly : '$answer\n\n$friendly',
            status: ChatMessageStatus.failed,
            errorCode: hostedAgent.lastRunStatus == 'cancelled'
                ? 'hosted_run_cancelled'
                : 'hosted_run_failed',
            aiRunEventSeq: hostedAgent.lastEventSeq,
          ),
        );
        return;
      }
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
      final citedWebUrls = extractValidWebCitations(
        response: answer,
        urls: hostedAgent.lastWebUrls,
      );
      await sessions.updateMessage(
        message.copyWith(
          content: answer,
          status: ChatMessageStatus.completed,
          webUrls: citedWebUrls,
          method: citedWebUrls.isEmpty
              ? message.method
              : (message.method ?? 'web'),
          aiRunEventSeq: hostedAgent.lastEventSeq,
        ),
      );
    } on HostedAgentResumeException catch (error, stackTrace) {
      developer.log(
        'hosted chat run resume failed',
        name: 'memora.chat',
        error: error,
        stackTrace: stackTrace,
      );
      if (!isStillCurrent()) return;
      if (error.retryable) rethrow;
      final friendly = localizedAiErrorMessage(
        ref.read(stringsProvider),
        error,
      );
      await sessions.updateMessage(
        message.copyWith(
          content: buffer.isEmpty
              ? friendly
              : '${buffer.toString()}\n\n$friendly',
          status: ChatMessageStatus.failed,
          errorCode: error.statusCode == 404
              ? 'hosted_run_not_found'
              : 'hosted_run_failed',
          aiRunEventSeq: hostedAgent.lastEventSeq,
        ),
      );
    } catch (error, stackTrace) {
      // Local persistence failures and unexpected client errors are not
      // evidence that the durable server run failed. Keep the persisted run
      // pending and let the outer bounded backoff retry it.
      developer.log(
        'hosted chat run persistence/recovery failed',
        name: 'memora.chat',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
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
        .map((message) {
          final attachmentContext = message.attachmentContext?.trim() ?? '';
          final content =
              message.role == ChatMessageRole.user &&
                  attachmentContext.isNotEmpty
              ? '${message.content}\n\nAttached material from that turn:\n$attachmentContext'
              : message.content;
          return RagConversationTurn(
            role: message.role == ChatMessageRole.user ? 'user' : 'assistant',
            content: content,
          );
        })
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

  Future<void> _stopGeneration() async {
    if (!_loading) return;
    final stoppingRunId = _answerRunId;
    final control = _answerRunControls[stoppingRunId];
    if (control == null) return;

    control.cancelRequested = true;
    // Invalidate every UI/result callback before the first persistence or
    // network await. The still-running future retains [control] so a late
    // onRunCreated callback can attach-and-cancel or tombstone the server run.
    _answerRunId++;
    // A HostedAgentService observer intentionally carries `last*` state for
    // one run. Give any subsequent send a fresh observer while the cancelled
    // stream drains on its captured instance, so late terminal events cannot
    // contaminate the next answer's status or citations.
    ref.invalidate(hostedAgentServiceProvider);
    if (mounted) setState(() => _loading = false);

    final messageId = control.messageId;
    if (messageId == null) return;
    final sessions = ref.read(chatSessionsProvider.notifier);
    await sessions.markRunCancellationRequested(
      messageId: messageId,
      expectedRequestKey: control.requestKey,
    );
    final serverRunId = control.serverRunId;
    if (serverRunId != null) {
      await sessions.requestServerRunCancellation(
        messageId: messageId,
        expectedRequestKey: control.requestKey,
        runId: serverRunId,
      );
    } else if (!control.agentRequestStarted || !control.durableRunExpected) {
      await sessions.completeUncreatedRunCancellation(
        messageId: messageId,
        expectedRequestKey: control.requestKey,
      );
    }
  }

  Future<void> _finishUnstartedCancellation(_AnswerRunControl control) async {
    final messageId = control.messageId;
    if (messageId == null) return;
    final sessions = ref.read(chatSessionsProvider.notifier);
    await sessions.markRunCancellationRequested(
      messageId: messageId,
      expectedRequestKey: control.requestKey,
    );
    final serverRunId = control.serverRunId;
    if (serverRunId != null) {
      await sessions.requestServerRunCancellation(
        messageId: messageId,
        expectedRequestKey: control.requestKey,
        runId: serverRunId,
      );
      return;
    }
    await sessions.completeUncreatedRunCancellation(
      messageId: messageId,
      expectedRequestKey: control.requestKey,
    );
  }

  void _finishLoading(int runId) {
    // Only the current run may release the loading flag; a stale run must not
    // unlock the input while a retry is already in progress.
    if (runId != _answerRunId) return;
    if (mounted) {
      setState(() => _loading = false);
      _schedulePendingServerRunResume();
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

  Future<void> _showChatTools() async {
    final restoreInputFocus = _inputFocusNode.hasFocus;
    if (restoreInputFocus) {
      _toolsParkingFocusNode.requestFocus();
    } else {
      FocusScope.of(context).unfocus();
    }
    final navigator = Navigator.of(context);
    final localizations = MaterialLocalizations.of(context);
    final route = ModalBottomSheetRoute<_ChatToolAction>(
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
      backgroundColor: Colors.transparent,
      modalBarrierColor: Colors.black54,
      barrierLabel: localizations.scrimLabel,
      barrierOnTapHint: localizations.scrimOnTapHint(
        localizations.bottomSheetLabel,
      ),
      isScrollControlled: true,
      requestFocus: false,
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
            onAddImage: () => Navigator.of(context).pop(_ChatToolAction.image),
            onAddFile: () => Navigator.of(context).pop(_ChatToolAction.file),
            onOpenSkills: () =>
                Navigator.of(context).pop(_ChatToolAction.skill),
          );
        },
      ),
    );
    final action = await navigator.push(route);
    await route.completed;
    if (!mounted) return;
    switch (action) {
      case _ChatToolAction.image:
        await _pickImageAttachments();
        break;
      case _ChatToolAction.file:
        await _pickFileAttachments();
        break;
      case _ChatToolAction.skill:
        showAppSnackBar(
          context,
          message: ref.read(stringsProvider).chatToolsSkillComingSoon,
        );
        break;
      case null:
        break;
    }
    if (mounted && restoreInputFocus) {
      _inputFocusNode.requestFocus();
    }
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
    final record = ref
        .read(chatSessionsProvider)
        .valueOrNull
        ?.messages
        .where((message) => message.id == messageId)
        .firstOrNull;
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
    if (record != null) {
      unawaited(
        ref
            .read(conversationFeedbackServiceProvider)
            .submit(
              messageId: record.id,
              threadId: record.threadId,
              feedback: feedback,
              retrievalLogId: record.logId ?? logId,
              method: record.method,
              isNoResult: record.isNoResult,
            ),
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

  Future<void> _deleteThread(String threadId) async {
    final controls = _answerRunControls.values
        .where((control) => control.threadId == threadId)
        .toList(growable: false);
    for (final control in controls) {
      control.cancelRequested = true;
    }
    if (controls.any((control) => control.localRunId == _answerRunId)) {
      _answerRunId++;
      ref.invalidate(hostedAgentServiceProvider);
      if (mounted) setState(() => _loading = false);
    }

    final sessions = ref.read(chatSessionsProvider.notifier);
    // Persist Stop intent before the repository deletion. If onRunCreated won
    // first, deleteThread captures its run id in the tombstone; if deletion
    // wins, the callback's atomic attach fails and queues the late id there.
    for (final control in controls) {
      final messageId = control.messageId;
      if (messageId == null) continue;
      await sessions.markRunCancellationRequested(
        messageId: messageId,
        expectedRequestKey: control.requestKey,
      );
    }
    await sessions.deleteThread(threadId);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<HostedAgentService?>(hostedAgentServiceProvider, (
      previous,
      next,
    ) {
      if (next != null && !identical(previous, next)) {
        _schedulePendingServerRunResume();
      }
    });
    ref.listen<AsyncValue<ChatSessionState>>(chatSessionsProvider, (
      previous,
      next,
    ) {
      if (next.hasValue && previous?.hasValue != true) {
        _schedulePendingServerRunResume();
      }
    });
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
    final chatUnavailable = chatAsync.hasError || chatAsync.isLoading;
    // Browsing tools and chat history is safe while an answer is in flight:
    // the pending record is persisted by id, so switching views does not
    // cancel or overwrite the active run.
    final drawerEnabled = chatState != null;
    final brightness = Theme.of(context).brightness;
    final topInset = MediaQuery.paddingOf(context).top;

    return Focus(
      focusNode: _toolsParkingFocusNode,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
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
                  enabled: drawerEnabled,
                  onNewThread: _startNewThread,
                  onSelectThread: _selectThread,
                  onDeleteThread: _deleteThread,
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
                                    // first bubble stops 12px below the visible
                                    // bottom of the two floating top buttons:
                                    // 8 top + 48 Material surface + 12 gap.
                                    padding: EdgeInsets.fromLTRB(
                                      16,
                                      topInset + 68,
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
                                  surfaceKey: const ValueKey(
                                    'chat-jump-surface',
                                  ),
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
                    focusNode: _inputFocusNode,
                    loading: _loading || chatUnavailable,
                    s: s,
                    attachments: _attachmentDrafts,
                    onRemoveAttachment: _removeAttachment,
                    onSend: () => _send(),
                    onStop: _loading
                        ? () => unawaited(_stopGeneration())
                        : null,
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
                left: 0,
                right: 0,
                child: Padding(
                  // Match ChatInputBar's horizontal frame, including when the
                  // content row reaches its 760px desktop width cap. The lower
                  // tools button adds its own intentional 2px left offset.
                  padding: const EdgeInsets.only(left: 16, right: 8),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Builder(
                            builder: (drawerContext) => _ChatTopButton(
                              surfaceKey: const ValueKey(
                                'chat-sidebar-surface',
                              ),
                              buttonKey: const ValueKey('chat-sidebar-button'),
                              icon: Icons.menu_rounded,
                              tooltip: s.chatHistory,
                              onPressed: drawerEnabled
                                  ? () =>
                                        Scaffold.of(drawerContext).openDrawer()
                                  : null,
                            ),
                          ),
                          _ChatTopButton(
                            surfaceKey: const ValueKey('chat-settings-surface'),
                            buttonKey: const ValueKey('chat-settings-button'),
                            icon: Icons.tune_rounded,
                            tooltip: s.chatSettings,
                            onPressed: _showChatSettings,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _localizedAttachmentError(LocaleStrings s, Object error) {
  if (error is! ChatAttachmentException) {
    return localizedAiErrorMessage(s, error);
  }
  final message = switch (error.code) {
    'too_many' => s.chatAttachmentTooMany,
    'too_large' || 'total_too_large' => s.chatAttachmentTooLarge,
    'unsupported_type' => s.chatAttachmentUnsupported,
    'chat_model_no_image_input' => s.chatAttachmentVisionRequired,
    'pdf_no_text' => s.chatAttachmentPdfNoText,
    _ => s.chatAttachmentReadFailed,
  };
  final fileName = error.fileName?.trim() ?? '';
  return fileName.isEmpty ? message : '$message ($fileName)';
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox.square(
      dimension: 48,
      child: Center(
        child: Material(
          key: surfaceKey,
          color: isDark ? Colors.black : Colors.white,
          shape: isDark
              ? const CircleBorder(side: BorderSide(color: Color(0xFFB8C0C8)))
              : const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: IconButton(
            key: buttonKey,
            icon: Icon(icon),
            tooltip: tooltip,
            onPressed: onPressed,
            style: IconButton.styleFrom(
              foregroundColor: isDark
                  ? const Color(0xFFF1F3F5)
                  : const Color(0xFF10273F),
              disabledForegroundColor: isDark
                  ? const Color(0xFF929AA2)
                  : const Color(0xFF8FA3B1),
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
