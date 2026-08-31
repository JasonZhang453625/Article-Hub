import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/models/chat_message_record.dart';
import '../../data/models/chat_attachment.dart';
import '../../data/models/chat_thread.dart';
import '../../data/models/ai_thinking_level.dart';
import '../../data/repositories/chat_repository.dart';
import '../../data/services/hosted_agent_service.dart';
import 'attachment_providers.dart';
import 'article_providers.dart';
import 'auth_provider.dart';

final chatRepositoryProvider = FutureProvider<ChatRepository>((ref) async {
  await ref.watch(hiveInitProvider.future);
  final repository = HiveChatRepository();
  await repository.init();
  return repository;
});

typedef HostedAgentRunCanceller =
    Future<void> Function(String runId, {String? expectedOwnerUserId});
typedef HostedAgentRunDeleter =
    Future<void> Function(String runId, {String? expectedOwnerUserId});
typedef HostedAgentRunLookupResolver =
    Future<HostedAgentRunLookup> Function(
      String idempotencyKey, {
      String? expectedOwnerUserId,
    });

/// A control-plane client, intentionally distinct from the stateful hosted
/// Agent stream observer in `ai_providers.dart`.
final hostedAgentRunCancellerProvider = Provider<HostedAgentRunCanceller>((
  ref,
) {
  final control = HostedAgentControlService(
    getSession: () => ref.read(currentSessionProvider),
    refreshSession: () => ref.read(authControllerProvider.notifier).refresh(),
  );
  return control.cancelRun;
});

final hostedAgentRunDeleterProvider = Provider<HostedAgentRunDeleter>((ref) {
  final control = HostedAgentControlService(
    getSession: () => ref.read(currentSessionProvider),
    refreshSession: () => ref.read(authControllerProvider.notifier).refresh(),
  );
  return control.deleteRun;
});

final hostedAgentRunLookupProvider = Provider<HostedAgentRunLookupResolver>((
  ref,
) {
  final control = HostedAgentControlService(
    getSession: () => ref.read(currentSessionProvider),
    refreshSession: () => ref.read(authControllerProvider.notifier).refresh(),
  );
  return control.lookupRunByIdempotencyKey;
});

final chatSessionsProvider =
    StateNotifierProvider<ChatSessionsNotifier, AsyncValue<ChatSessionState>>((
      ref,
    ) {
      return ChatSessionsNotifier(ref);
    });

/// Session-level web-search toggle for the RAG chat. Defaults to OFF so the
/// local-first / privacy-first contract is never silently broken; the user
/// opts into live web search per conversation from the input bar.
///
/// Lives for the app session only — it is not persisted.
final chatWebSearchEnabledProvider = StateProvider<bool>((ref) => false);

/// Session-level thinking strength selected from the chat tools sheet.
/// Provider-specific request mapping happens in the AI transport layer.
final chatThinkingLevelProvider = StateProvider<AiThinkingLevel>(
  (ref) => AiThinkingLevel.none,
);

/// Session-level explicit selection from the backend's active official Pi
/// Skill catalog. Null preserves the Admin default for older clients and until
/// the user opens the picker; an empty set intentionally disables all Skills.
final chatSelectedSkillNamesProvider = StateProvider<Set<String>?>((ref) {
  // Skill selections belong to the authenticated backend catalog, so an
  // account switch must not carry names into the next user's requests.
  ref.watch(currentSessionProvider)?.user.id;
  return null;
});

class ChatSessionState {
  final List<ChatThread> threads;
  final String? activeThreadId;
  final List<ChatMessageRecord> messages;

  const ChatSessionState({
    this.threads = const [],
    this.activeThreadId,
    this.messages = const [],
  });
}

class PersistedUserMessage {
  final String threadId;
  final ChatMessageRecord message;

  const PersistedUserMessage({required this.threadId, required this.message});
}

class ChatSessionsNotifier extends StateNotifier<AsyncValue<ChatSessionState>> {
  final Ref _ref;
  final Uuid _uuid;
  late final Future<void> _loadFuture;
  ChatRepository? _repository;
  int _navigationRevision = 0;
  final Set<String> _activeServerRunCreates = {};

  ChatSessionsNotifier(this._ref, {Uuid uuid = const Uuid()})
    : _uuid = uuid,
      super(const AsyncValue.loading()) {
    _loadFuture = _load();
  }

  Future<void> _load() async {
    try {
      final repository = await _ref.read(chatRepositoryProvider.future);
      _repository = repository;
      final threads = repository.getThreads();
      final activeThreadId = threads.isEmpty ? null : threads.first.id;
      final persistedMessages = activeThreadId == null
          ? const <ChatMessageRecord>[]
          : repository.getMessages(activeThreadId);

      // Hydrate the visible conversation before waiting for recovery writes.
      // This keeps local chat history responsive after an app restart, while
      // still converting an orphaned in-flight generation to a retryable
      // state in the background.
      final messages = _recoverMessagesInMemory(persistedMessages);
      state = AsyncValue.data(
        ChatSessionState(
          threads: List.unmodifiable(threads),
          activeThreadId: activeThreadId,
          messages: List.unmodifiable(messages),
        ),
      );

      // Thread/message deletion spans separate Hive boxes and attachment
      // files. Repository tombstones make it crash-resumable; file cleanup is
      // retried in the background without delaying chat hydration.
      unawaited(_cleanupPendingThreadDeletions(repository));
      unawaited(_retryPendingMessageRunCancellations(repository));

      // Persist recovery for every thread without delaying the first frame of
      // the active conversation. The in-memory state above is authoritative
      // for the immediate UI; this write makes the recovery durable for the
      // next process restart.
      unawaited(_persistInterruptedMessages(threads));
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }

  Future<void> _cleanupPendingThreadDeletions(ChatRepository repository) async {
    for (final deletion in repository.getPendingThreadDeletions()) {
      if (!deletion.dataDeleted) continue;
      await _cleanupPendingThreadDeletion(repository, deletion);
    }
  }

  Future<void> _cleanupPendingThreadDeletion(
    ChatRepository repository,
    PendingChatThreadDeletion deletion, {
    String? ownerUserId,
  }) async {
    var attachmentCleanupCompleted = true;
    if (deletion.attachmentIds.isNotEmpty) {
      try {
        await _ref
            .read(chatAttachmentServiceProvider)
            .deletePersistedIds(deletion.attachmentIds);
      } catch (_) {
        attachmentCleanupCompleted = false;
      }
    }

    await _reconcileDeletionLookups(
      repository,
      deletion,
      ownerUserId: ownerUserId,
    );
    final afterLookups = _pendingDeletion(repository, deletion.threadId);
    for (final runId in afterLookups?.aiRunIdsToCancel ?? const <String>[]) {
      final expectedOwner = afterLookups?.aiRunOwnerUserIds[runId];
      final currentOwner = _ref.read(currentSessionProvider)?.user.id;
      if (expectedOwner == null || currentOwner != expectedOwner) {
        // Unknown legacy ownership and another signed-in account both retain
        // the tombstone. A 404 under the wrong bearer is not proof that the
        // original owner's run disappeared.
        continue;
      }
      try {
        await _ref.read(hostedAgentRunDeleterProvider)(
          runId,
          expectedOwnerUserId: expectedOwner,
        );
        await repository.completeAiRunCancellation(deletion.threadId, runId);
      } catch (_) {
        // The tombstone retains this run id. A lifecycle resume or the next
        // process start retries the idempotent backend cancellation.
      }
    }

    final current = _pendingDeletion(repository, deletion.threadId);
    if (!attachmentCleanupCompleted ||
        current == null ||
        !current.dataDeleted ||
        !current.canAcknowledge ||
        current.aiRunIdsToCancel.isNotEmpty ||
        current.aiRunLookups.isNotEmpty) {
      return;
    }
    try {
      await repository.completeThreadDeletion(
        current.threadId,
        expectedRevision: current.revision,
      );
    } catch (_) {
      // A late onRunCreated callback may have advanced the tombstone revision
      // or appended another run. Keeping it is safe and retryable.
    }
  }

  Future<void> _reconcileDeletionLookups(
    ChatRepository repository,
    PendingChatThreadDeletion deletion, {
    String? ownerUserId,
  }) async {
    if (deletion.aiRunLookups.isEmpty) return;
    final activeOwnerUserId =
        ownerUserId ?? _ref.read(currentSessionProvider)?.user.id;
    if (activeOwnerUserId == null || activeOwnerUserId.trim().isEmpty) return;
    for (final lookup in deletion.aiRunLookups) {
      if (lookup.ownerUserId != activeOwnerUserId) continue;
      if (_activeServerRunCreates.contains(
        _serverRunCreateIdentity(lookup.ownerUserId, lookup.requestKey),
      )) {
        // A foreground POST still owns this key. Removing the tombstone after
        // a transient 404 would lose the only crash-recovery handle for a
        // server run whose 202 response has not arrived yet.
        continue;
      }
      try {
        final found = await _lookupWithNotFoundBackoff(
          lookup.requestKey,
          ownerUserId: lookup.ownerUserId,
          stillCurrent: () =>
              _ref.read(currentSessionProvider)?.user.id == lookup.ownerUserId,
        );
        if (_ref.read(currentSessionProvider)?.user.id != lookup.ownerUserId) {
          continue;
        }
        await repository.resolveAiRunLookup(
          deletion.threadId,
          ownerUserId: lookup.ownerUserId,
          requestKey: lookup.requestKey,
          runId: found?.runId,
        );
      } on HostedAgentLookupException {
        // Authentication and transport failures retain the tombstone key.
        // The same account can retry on lifecycle resume or next startup.
      }
    }
  }

  PendingChatThreadDeletion? _pendingDeletion(
    ChatRepository repository,
    String threadId,
  ) {
    for (final deletion in repository.getPendingThreadDeletions()) {
      if (deletion.threadId == threadId) return deletion;
    }
    return null;
  }

  List<ChatMessageRecord> _recoverMessagesInMemory(
    List<ChatMessageRecord> messages,
  ) {
    return messages
        .map(
          (message) =>
              message.status == ChatMessageStatus.sending &&
                  message.aiRunId == null &&
                  !_isAmbiguousHostedCreate(message)
              ? message.copyWith(status: ChatMessageStatus.interrupted)
              : message,
        )
        .toList(growable: false);
  }

  Future<void> _persistInterruptedMessages(List<ChatThread> threads) async {
    try {
      for (final thread in threads) {
        for (final message in _repo.getMessages(thread.id)) {
          if (message.status != ChatMessageStatus.sending ||
              message.aiRunId != null ||
              _isAmbiguousHostedCreate(message)) {
            continue;
          }
          await _repo.putMessage(
            message.copyWith(status: ChatMessageStatus.interrupted),
          );
        }
      }
    } catch (_) {
      // The recovered in-memory state is already visible. A later load will
      // retry this best-effort status write if Hive was temporarily busy.
    }
  }

  /// Marks any [ChatMessageStatus.sending] message in [threadId] as
  /// interrupted (persisting the change) and returns the recovered list.
  Future<List<ChatMessageRecord>> _recoverInterrupted(String threadId) async {
    final messages = _repo.getMessages(threadId);
    final recovered = _recoverMessagesInMemory(messages);
    for (var index = 0; index < messages.length; index++) {
      if (messages[index].status == ChatMessageStatus.sending &&
          messages[index].aiRunId == null &&
          !_isAmbiguousHostedCreate(messages[index])) {
        await _repo.putMessage(recovered[index]);
      }
    }
    return recovered;
  }

  /// Returns hosted generations that can be resumed after a process restart.
  ///
  /// A local BYOK request has no server task to reconnect to, so only records
  /// with a durable [ChatMessageRecord.aiRunId] are returned.
  Future<List<ChatMessageRecord>> pendingServerMessages({
    String? ownerUserId,
    String? ownerDeviceId,
  }) async {
    await _ensureLoaded();
    final pending = <ChatMessageRecord>[];
    for (final thread in _repo.getThreads()) {
      pending.addAll(
        _repo
            .getMessages(thread.id)
            .where(
              (message) =>
                  message.role == ChatMessageRole.assistant &&
                  message.status == ChatMessageStatus.sending &&
                  message.aiRunId != null &&
                  message.errorCode != 'hosted_cancel_requested',
            ),
      );
    }
    if (!pending.any((message) => message.aiRunOwnerUserId != null)) {
      return List.unmodifiable(pending);
    }
    return List.unmodifiable(
      pending.where(
        (message) =>
            message.aiRunOwnerUserId == null ||
            message.aiRunOwnerUserId == ownerUserId &&
                (!message.usesDeviceClientTools ||
                    message.aiRunOwnerDeviceId == ownerDeviceId),
      ),
    );
  }

  /// Returns the repository-backed message snapshot for exactly one thread.
  ///
  /// Durable run recovery spans every thread, while [ChatSessionState.messages]
  /// contains only the currently visible thread. Recovery finalizers must use
  /// this method so provenance never leaks between active and background chats.
  Future<List<ChatMessageRecord>> messagesForThread(String threadId) async {
    await _ensureLoaded();
    if (_repo.getThread(threadId) == null) return const [];
    return List.unmodifiable(_repo.getMessages(threadId));
  }

  /// All locally-known v3 attempts, including terminal records. The global
  /// client-tool host compares this ledger with its run-scoped Hive stores so
  /// deleted/stopped runs can be revoked after a process restart.
  Future<List<ChatMessageRecord>> clientToolAttempts() async {
    await _ensureLoaded();
    final attempts = <ChatMessageRecord>[];
    for (final thread in _repo.getThreads()) {
      attempts.addAll(
        _repo
            .getMessages(thread.id)
            .where(
              (message) =>
                  message.role == ChatMessageRole.assistant &&
                  message.aiRunId?.trim().isNotEmpty == true &&
                  message.usesDeviceClientTools,
            ),
      );
    }
    return List.unmodifiable(attempts);
  }

  /// Resolves creates whose server response may have been lost after the
  /// backend accepted the stable idempotency key. Returns true when at least
  /// one transient failure remains and the caller should schedule a retry.
  Future<bool> reconcileAmbiguousServerRuns({
    String? ownerUserId,
    String? ownerDeviceId,
  }) async {
    await _ensureLoaded();
    final ambiguous = <ChatMessageRecord>[];
    for (final thread in _repo.getThreads()) {
      ambiguous.addAll(
        _repo.getMessages(thread.id).where(_isAmbiguousHostedCreate),
      );
    }
    if (ambiguous.isEmpty) return false;
    if (ownerUserId == null || ownerUserId.trim().isEmpty) return false;
    final expectedOwnerUserId = ownerUserId.trim();
    final expectedOwnerDeviceId = ownerDeviceId?.trim();
    bool ownerStillCurrent(ChatMessageRecord message) {
      if (!message.usesDeviceClientTools) return true;
      final current = _ref.read(currentSessionProvider);
      if (current == null || current.user.id != expectedOwnerUserId) {
        return false;
      }
      return current.device.id == expectedOwnerDeviceId;
    }

    var retryNeeded = false;
    final pending = ambiguous.where(
      (message) =>
          message.aiRunOwnerUserId == ownerUserId &&
          (!message.usesDeviceClientTools ||
              message.aiRunOwnerDeviceId == ownerDeviceId),
    );
    for (final message in pending) {
      final requestKey = message.aiRunRequestKey!;
      if (_activeServerRunCreates.contains(
        _serverRunCreateIdentity(ownerUserId, requestKey),
      )) {
        // The normal foreground POST has not settled. It is not an ambiguous
        // create yet, so a fast global-host lookup must not turn a delayed
        // 202 into a false hosted_run_not_found.
        continue;
      }
      try {
        final found = await _lookupWithNotFoundBackoff(
          requestKey,
          ownerUserId: expectedOwnerUserId,
          stillCurrent: () => ownerStillCurrent(message),
        );
        if (!ownerStillCurrent(message)) continue;
        if (found == null) {
          final updated = await _repo.completeAiRunReconciliationNotFound(
            messageId: message.id,
            expectedRequestKey: requestKey,
            ownerUserId: expectedOwnerUserId,
          );
          if (updated != null) _replacePersistedMessageInState(updated);
          continue;
        }
        final attached =
            message.usesDeviceClientTools && _repo is ClientToolChatRepository
            ? await (_repo as ClientToolChatRepository)
                  .attachAiRunClientToolsToPendingMessage(
                    messageId: message.id,
                    expectedRequestKey: requestKey,
                    expectedOwnerUserId: expectedOwnerUserId,
                    expectedOwnerDeviceId: message.aiRunOwnerDeviceId!,
                    expectedProtocolVersion: message.aiRunProtocolVersion!,
                    expectedClientToolsVersion:
                        message.aiRunClientToolsVersion!,
                    expectedKnowledgeMode: message.aiRunKnowledgeMode!,
                    runId: found.runId,
                  )
            : await _repo.attachAiRunToPendingMessage(
                messageId: message.id,
                expectedRequestKey: requestKey,
                expectedOwnerUserId: expectedOwnerUserId,
                runId: found.runId,
              );
        if (attached == null) {
          // A local CAS winner superseded this attempt. Do not bind the run to
          // a newer retry; compensate with idempotent cancellation instead.
          try {
            await _ref.read(hostedAgentRunCancellerProvider)(
              found.runId,
              expectedOwnerUserId: expectedOwnerUserId,
            );
          } catch (_) {
            retryNeeded = true;
          }
          continue;
        }
        _replacePersistedMessageInState(attached);
        if (attached.errorCode == 'hosted_cancel_requested') {
          final cancelled = await requestServerRunCancellation(
            messageId: attached.id,
            expectedRequestKey: requestKey,
            runId: found.runId,
          );
          if (!cancelled) retryNeeded = true;
        }
      } on HostedAgentLookupException catch (error) {
        // Repeated 404 is returned as null above. Every thrown lookup failure
        // is uncertain, so preserve the sending/Stop marker for a later retry.
        retryNeeded =
            retryNeeded ||
            (!error.accountMismatch && (error.retryable || !error.notFound));
      } catch (_) {
        retryNeeded = true;
      }
    }
    return retryNeeded;
  }

  Future<HostedAgentRunLookup?> _lookupWithNotFoundBackoff(
    String requestKey, {
    required String ownerUserId,
    bool Function()? stillCurrent,
  }) async {
    const notFoundBackoff = [
      Duration(milliseconds: 250),
      Duration(milliseconds: 750),
    ];
    for (var attempt = 0; attempt <= notFoundBackoff.length; attempt++) {
      if (stillCurrent != null && !stillCurrent()) return null;
      try {
        final found = await _ref.read(hostedAgentRunLookupProvider)(
          requestKey,
          expectedOwnerUserId: ownerUserId,
        );
        if (stillCurrent != null && !stillCurrent()) return null;
        return found;
      } on HostedAgentLookupException catch (error) {
        if (!error.notFound) rethrow;
        if (attempt == notFoundBackoff.length) return null;
        await Future<void>.delayed(notFoundBackoff[attempt]);
        if (stillCurrent != null && !stillCurrent()) return null;
      }
    }
    return null;
  }

  bool _isAmbiguousHostedCreate(ChatMessageRecord message) {
    return message.role == ChatMessageRole.assistant &&
        message.hasUnresolvedAiRunCreate;
  }

  bool isPendingServerRun({required String messageId, required String runId}) {
    final message = _repo.getMessage(messageId);
    return message?.aiRunId == runId &&
        message?.status == ChatMessageStatus.sending;
  }

  bool containsThread(String threadId) => _repo.getThread(threadId) != null;

  /// Atomically persists the server id only if [messageId] is still the same
  /// local generation attempt. This is the commit point between onRunCreated
  /// and thread deletion/retry.
  Future<ChatMessageRecord?> attachServerRun({
    required String messageId,
    required String? expectedRequestKey,
    required String? expectedOwnerUserId,
    String? expectedOwnerDeviceId,
    int? expectedProtocolVersion,
    int? expectedClientToolsVersion,
    String? expectedKnowledgeMode,
    required String runId,
  }) async {
    await _ensureLoaded();
    final usesClientTools =
        expectedOwnerDeviceId != null &&
        expectedProtocolVersion != null &&
        expectedClientToolsVersion != null &&
        expectedKnowledgeMode != null;
    final updated = usesClientTools && _repo is ClientToolChatRepository
        ? await (_repo as ClientToolChatRepository)
              .attachAiRunClientToolsToPendingMessage(
                messageId: messageId,
                expectedRequestKey: expectedRequestKey,
                expectedOwnerUserId: expectedOwnerUserId,
                expectedOwnerDeviceId: expectedOwnerDeviceId,
                expectedProtocolVersion: expectedProtocolVersion,
                expectedClientToolsVersion: expectedClientToolsVersion,
                expectedKnowledgeMode: expectedKnowledgeMode,
                runId: runId,
              )
        : await _repo.attachAiRunToPendingMessage(
            messageId: messageId,
            expectedRequestKey: expectedRequestKey,
            expectedOwnerUserId: expectedOwnerUserId,
            runId: runId,
          );
    if (updated == null) return null;
    _replacePersistedMessageInState(updated);
    return updated;
  }

  /// Repository CAS immediately before `POST /ai/runs`.
  Future<ChatMessageRecord?> markServerRunCreateStarted({
    required String messageId,
    required String expectedRequestKey,
    required String ownerUserId,
  }) async {
    await _ensureLoaded();
    final identity = _serverRunCreateIdentity(ownerUserId, expectedRequestKey);
    _activeServerRunCreates.add(identity);
    try {
      final updated = await _repo.markAiRunCreateStarted(
        messageId: messageId,
        expectedRequestKey: expectedRequestKey,
        ownerUserId: ownerUserId,
      );
      if (updated == null) {
        _activeServerRunCreates.remove(identity);
      } else {
        _replacePersistedMessageInState(updated);
      }
      return updated;
    } catch (_) {
      _activeServerRunCreates.remove(identity);
      rethrow;
    }
  }

  Future<ChatMessageRecord?> markClientToolRunCreateStarted({
    required String messageId,
    required String expectedRequestKey,
    required String ownerUserId,
    required String ownerDeviceId,
    required int protocolVersion,
    required int clientToolsVersion,
    required String knowledgeMode,
  }) async {
    await _ensureLoaded();
    if (_repo is! ClientToolChatRepository) return null;
    final identity = _serverRunCreateIdentity(ownerUserId, expectedRequestKey);
    _activeServerRunCreates.add(identity);
    try {
      final updated = await (_repo as ClientToolChatRepository)
          .markAiRunClientToolsCreateStarted(
            messageId: messageId,
            expectedRequestKey: expectedRequestKey,
            ownerUserId: ownerUserId,
            ownerDeviceId: ownerDeviceId,
            protocolVersion: protocolVersion,
            clientToolsVersion: clientToolsVersion,
            knowledgeMode: knowledgeMode,
          );
      if (updated == null) {
        _activeServerRunCreates.remove(identity);
      } else {
        _replacePersistedMessageInState(updated);
      }
      return updated;
    } catch (_) {
      _activeServerRunCreates.remove(identity);
      rethrow;
    }
  }

  /// Releases the in-process foreground-create gate after the POST stream has
  /// either attached a run id or become genuinely ambiguous. Deleted-thread
  /// tombstones held back by the gate are retried immediately.
  Future<void> finishServerRunCreate({
    required String ownerUserId,
    required String requestKey,
  }) async {
    _activeServerRunCreates.remove(
      _serverRunCreateIdentity(ownerUserId, requestKey),
    );
    await _ensureLoaded();
    try {
      await _cleanupPendingThreadDeletions(_repo);
    } catch (_) {
      // Tombstones remain durable and startup/lifecycle recovery retries them.
    }
  }

  static String _serverRunCreateIdentity(String ownerUserId, String key) =>
      '${ownerUserId.trim()}\u0000${key.trim()}';

  Future<ChatMessageRecord?> markRunCancellationRequested({
    required String messageId,
    required String? expectedRequestKey,
  }) async {
    await _ensureLoaded();
    final updated = await _repo.requestAiRunCancellation(
      messageId: messageId,
      expectedRequestKey: expectedRequestKey,
    );
    if (updated != null) _replacePersistedMessageInState(updated);
    return updated;
  }

  Future<ChatMessageRecord?> completeUncreatedRunCancellation({
    required String messageId,
    required String? expectedRequestKey,
  }) async {
    await _ensureLoaded();
    final updated = await _repo.completeUncreatedAiRunCancellation(
      messageId: messageId,
      expectedRequestKey: expectedRequestKey,
    );
    if (updated != null) _replacePersistedMessageInState(updated);
    return updated;
  }

  /// Marks a live message as locally stopped, sends the idempotent server
  /// cancellation, and only then records the terminal local state. A failed
  /// control request leaves `hosted_cancel_requested` persisted for retry.
  Future<bool> requestServerRunCancellation({
    required String messageId,
    required String? expectedRequestKey,
    required String runId,
  }) async {
    await _ensureLoaded();
    var current = _repo.getMessage(messageId);
    if (current == null ||
        current.aiRunRequestKey != expectedRequestKey ||
        current.aiRunId != runId) {
      return false;
    }
    if (current.errorCode != 'hosted_cancel_requested') {
      current = await _repo.requestAiRunCancellation(
        messageId: messageId,
        expectedRequestKey: expectedRequestKey,
      );
      if (current == null || current.aiRunId != runId) return false;
      _replacePersistedMessageInState(current);
    }

    try {
      final expectedOwner = current.aiRunOwnerUserId;
      final currentOwner = _ref.read(currentSessionProvider)?.user.id;
      if (expectedOwner == null || currentOwner != expectedOwner) return false;
      await _ref.read(hostedAgentRunCancellerProvider)(
        runId,
        expectedOwnerUserId: expectedOwner,
      );
    } catch (_) {
      return false;
    }

    final latest = _repo.getMessage(messageId);
    if (latest == null ||
        latest.aiRunRequestKey != expectedRequestKey ||
        latest.aiRunId != runId ||
        latest.errorCode != 'hosted_cancel_requested') {
      return true;
    }
    final cancelled = latest.copyWith(
      status: ChatMessageStatus.interrupted,
      errorCode: 'hosted_run_cancelled',
    );
    try {
      await _repo.putMessage(cancelled);
    } on StateError {
      return true;
    }
    _replacePersistedMessageInState(cancelled);
    return true;
  }

  /// Retries message-level Stop requests after auth/network recovery.
  Future<void> retryPendingRunCancellations() async {
    await _ensureLoaded();
    await _retryPendingMessageRunCancellations(_repo);
    await _cleanupPendingThreadDeletions(_repo);
  }

  Future<void> _retryPendingMessageRunCancellations(
    ChatRepository repository,
  ) async {
    final pending = <ChatMessageRecord>[];
    for (final thread in repository.getThreads()) {
      pending.addAll(
        repository
            .getMessages(thread.id)
            .where(
              (message) =>
                  message.role == ChatMessageRole.assistant &&
                  message.errorCode == 'hosted_cancel_requested' &&
                  message.aiRunId != null,
            ),
      );
    }
    for (final message in pending) {
      final expectedOwner = message.aiRunOwnerUserId;
      if (expectedOwner == null ||
          _ref.read(currentSessionProvider)?.user.id != expectedOwner) {
        continue;
      }
      try {
        await requestServerRunCancellation(
          messageId: message.id,
          expectedRequestKey: message.aiRunRequestKey,
          runId: message.aiRunId!,
        );
      } catch (_) {
        // Preserve the marker and continue with other runs. A later lifecycle
        // signal or process start retries this one independently.
      }
    }
  }

  /// Persists a run that arrived after its thread was deleted, then immediately
  /// attempts the same crash-resumable tombstone cleanup used on app startup.
  Future<void> queueDeletedThreadRunCancellation({
    required String threadId,
    required String runId,
    String? ownerUserId,
    String? requestKey,
  }) async {
    await _ensureLoaded();
    final resolved = ownerUserId == null || requestKey == null
        ? null
        : await _repo.resolveAiRunLookup(
            threadId,
            ownerUserId: ownerUserId,
            requestKey: requestKey,
            runId: runId,
          );
    final deletion = resolved?.aiRunIdsToCancel.contains(runId) == true
        ? resolved!
        : await _repo.queueAiRunCancellation(
            threadId,
            runId,
            ownerUserId: ownerUserId,
          );
    if (deletion.dataDeleted) {
      await _cleanupPendingThreadDeletion(
        _repo,
        deletion,
        ownerUserId: ownerUserId,
      );
    }
  }

  Future<void> startNewThread() async {
    await _ensureLoaded();
    _navigationRevision++;
    state = AsyncValue.data(
      ChatSessionState(
        threads: List.unmodifiable(_repo.getThreads()),
        activeThreadId: null,
        messages: const [],
      ),
    );
  }

  Future<void> selectThread(String threadId) async {
    await _ensureLoaded();
    // Even selecting the currently visible thread is a navigation intent: it
    // must cancel an older asynchronous selection that has not committed yet.
    final navigationRevision = ++_navigationRevision;
    final current = _current;
    if (current.activeThreadId == threadId) return;
    if (_repo.getThread(threadId) == null) return;
    final messages = await _recoverInterrupted(threadId);
    if (navigationRevision != _navigationRevision ||
        _repo.getThread(threadId) == null) {
      return;
    }
    state = AsyncValue.data(
      ChatSessionState(
        threads: List.unmodifiable(_repo.getThreads()),
        activeThreadId: threadId,
        messages: List.unmodifiable(messages),
      ),
    );
  }

  Future<PersistedUserMessage> addUserMessage(
    String content, {
    List<ChatAttachment> attachments = const [],
  }) async {
    await _ensureLoaded();
    final current = _current;
    final initialActiveThreadId = current.activeThreadId;
    final initialNavigationRevision = _navigationRevision;
    final now = DateTime.now().toUtc();
    final existingThread = initialActiveThreadId == null
        ? null
        : _repo.getThread(initialActiveThreadId);
    final thread =
        existingThread ??
        ChatThread(
          id: _uuid.v4(),
          title: chatTitleFromMessage(content),
          createdAt: now,
          updatedAt: now,
          lastMessagePreview: chatPreviewFromMessage(content),
        );
    if (existingThread == null) await _repo.putThread(thread);

    final message = ChatMessageRecord(
      id: _uuid.v4(),
      threadId: thread.id,
      role: ChatMessageRole.user,
      content: content,
      createdAt: now,
      attachments: List.unmodifiable(attachments),
    );
    try {
      await _repo.putMessage(message);
    } catch (error, stackTrace) {
      if (existingThread == null) {
        try {
          await _repo.deleteThread(thread.id);
        } catch (_) {
          // Preserve the original message-write failure. A later repository
          // load can surface any empty thread left by a failed cleanup.
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    }

    ChatThread? persistedThread;
    try {
      persistedThread = existingThread == null
          ? _repo.getThread(thread.id)
          : await _repo.updateThreadIfExists(
              thread.id,
              activityAt: now,
              lastMessagePreview: chatPreviewFromMessage(content),
            );
    } catch (error, stackTrace) {
      try {
        await _repo.deleteMessage(message.id);
      } catch (_) {
        // Preserve the thread-update failure; message cleanup is best-effort.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    if (persistedThread == null || _repo.getThread(thread.id) == null) {
      await _repo.deleteMessage(message.id);
      throw StateError('Chat thread was deleted while adding its message.');
    }

    // Navigation may have changed during either Hive write. Preserve the
    // user's latest selection instead of restoring the snapshot from before
    // the await; only auto-select a newly-created/current thread when the
    // selection itself has not changed.
    final latest = _current;
    final shouldActivate =
        _navigationRevision == initialNavigationRevision &&
        latest.activeThreadId == initialActiveThreadId;
    final activeThreadId = shouldActivate ? thread.id : latest.activeThreadId;
    if (shouldActivate && activeThreadId != latest.activeThreadId) {
      _navigationRevision++;
    }
    final messages = activeThreadId == thread.id
        ? latest.activeThreadId == thread.id
              ? [
                  ...latest.messages.where((item) => item.id != message.id),
                  message,
                ]
              : [message]
        : latest.messages;
    state = AsyncValue.data(
      ChatSessionState(
        threads: List.unmodifiable(_repo.getThreads()),
        activeThreadId: activeThreadId,
        messages: List.unmodifiable(messages),
      ),
    );
    return PersistedUserMessage(threadId: thread.id, message: message);
  }

  Future<ChatMessageRecord> addAssistantMessage({
    required String threadId,
    required String content,
    List<String> articleIds = const [],
    List<String> weakArticleIds = const [],
    String? method,
    String? logId,
    bool isNoResult = false,
    String? query,
    ChatMessageStatus status = ChatMessageStatus.completed,
    String? errorCode,
  }) async {
    await _ensureLoaded();
    if (_repo.getThread(threadId) == null) {
      throw StateError('Cannot add a message to a missing chat thread.');
    }
    final now = DateTime.now().toUtc();
    final message = ChatMessageRecord(
      id: _uuid.v4(),
      threadId: threadId,
      role: ChatMessageRole.assistant,
      content: content,
      createdAt: now,
      articleIds: List.unmodifiable(articleIds),
      weakArticleIds: List.unmodifiable(weakArticleIds),
      method: method,
      logId: logId,
      isNoResult: isNoResult,
      query: query,
      status: status,
      errorCode: errorCode,
    );
    await _repo.putMessage(message);
    ChatThread? persistedThread;
    try {
      persistedThread = await _repo.updateThreadIfExists(
        threadId,
        activityAt: now,
        lastMessagePreview: chatPreviewFromMessage(content),
      );
    } catch (error, stackTrace) {
      try {
        await _repo.deleteMessage(message.id);
      } catch (_) {
        // Preserve the thread-update failure; message cleanup is best-effort.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    if (persistedThread == null || _repo.getThread(threadId) == null) {
      await _repo.deleteMessage(message.id);
      throw StateError('Chat thread was deleted while adding its message.');
    }
    final latest = _current;
    final messages = latest.activeThreadId == threadId
        ? [...latest.messages.where((item) => item.id != message.id), message]
        : latest.messages;
    state = AsyncValue.data(
      ChatSessionState(
        threads: List.unmodifiable(_repo.getThreads()),
        activeThreadId: latest.activeThreadId,
        messages: List.unmodifiable(messages),
      ),
    );
    return message;
  }

  Future<ChatMessageRecord> addPendingMessage({
    required String threadId,
    required String query,
  }) async {
    await _ensureLoaded();
    final now = DateTime.now().toUtc();
    final message = ChatMessageRecord(
      id: _uuid.v4(),
      threadId: threadId,
      role: ChatMessageRole.assistant,
      content: '',
      createdAt: now,
      query: query,
      status: ChatMessageStatus.sending,
      aiRunRequestKey: _uuid.v4(),
    );
    await _repo.putMessage(message);
    if (_repo.getThread(threadId) == null) {
      await _repo.deleteMessage(message.id);
      throw StateError('Chat thread was deleted while adding its message.');
    }
    final latest = _current;
    final messages = latest.activeThreadId == threadId
        ? [...latest.messages.where((item) => item.id != message.id), message]
        : latest.messages;
    state = AsyncValue.data(
      ChatSessionState(
        threads: List.unmodifiable(_repo.getThreads()),
        activeThreadId: latest.activeThreadId,
        messages: List.unmodifiable(messages),
      ),
    );
    return message;
  }

  /// Upserts [updated] and refreshes in-memory state. Used to turn a pending
  /// (sending) message into the final answer, an error, or an interruption.
  Future<void> updateMessage(ChatMessageRecord updated) async {
    await _ensureLoaded();
    if (_repo.getThread(updated.threadId) == null) return;
    try {
      await _repo.putMessage(updated);
    } on StateError {
      if (_repo.getThread(updated.threadId) == null) return;
      rethrow;
    }
    if (_repo.getThread(updated.threadId) == null) return;

    _replacePersistedMessageInState(updated);
  }

  void _replacePersistedMessageInState(ChatMessageRecord updated) {
    // State may have changed while Hive was writing (for example the user
    // switched or deleted a thread). Re-read it instead of restoring the stale
    // snapshot captured before the await.
    final current = _current;
    final messages = current.activeThreadId == updated.threadId
        ? current.messages
              .map((message) => message.id == updated.id ? updated : message)
              .toList(growable: false)
        : current.messages;
    state = AsyncValue.data(
      ChatSessionState(
        threads: current.threads,
        activeThreadId: current.activeThreadId,
        messages: List.unmodifiable(messages),
      ),
    );
  }

  /// Best-effort UI fallback when Hive rejects a final answer update.
  ///
  /// The durable write has already failed in that case, so keeping the
  /// in-memory placeholder in `sending` would leave an endless typing bubble.
  /// On the next app start the persisted placeholder is recovered as
  /// `interrupted` by [_recoverInterrupted].
  void replaceMessageInMemory(ChatMessageRecord updated) {
    final current = state.valueOrNull;
    if (current == null || current.activeThreadId != updated.threadId) return;
    final messages = current.messages
        .map((message) => message.id == updated.id ? updated : message)
        .toList(growable: false);
    state = AsyncValue.data(
      ChatSessionState(
        threads: current.threads,
        activeThreadId: current.activeThreadId,
        messages: List.unmodifiable(messages),
      ),
    );
  }

  Future<void> updateFeedback(String messageId, int feedback) async {
    await _ensureLoaded();
    final existing = _repo.getMessage(messageId);
    if (existing == null) return;
    final updated = existing.copyWith(feedback: feedback);
    try {
      await _repo.putMessage(updated);
    } on StateError {
      if (_repo.getThread(existing.threadId) == null) return;
      rethrow;
    }
    final latest = _current;
    final messages = latest.activeThreadId == existing.threadId
        ? latest.messages
              .map((message) => message.id == messageId ? updated : message)
              .toList(growable: false)
        : latest.messages;
    state = AsyncValue.data(
      ChatSessionState(
        threads: List.unmodifiable(_repo.getThreads()),
        activeThreadId: latest.activeThreadId,
        messages: List.unmodifiable(messages),
      ),
    );
  }

  Future<void> renameThread(String threadId, String title) async {
    await _ensureLoaded();
    final normalized = title.trim();
    if (normalized.isEmpty) return;
    final updated = await _repo.updateThreadIfExists(
      threadId,
      title: normalized,
    );
    if (updated == null) return;
    final latest = _current;
    state = AsyncValue.data(
      ChatSessionState(
        threads: List.unmodifiable(_repo.getThreads()),
        activeThreadId: latest.activeThreadId,
        messages: latest.messages,
      ),
    );
  }

  Future<void> setThreadPinned(String threadId, bool isPinned) async {
    await _ensureLoaded();
    final updated = await _repo.updateThreadIfExists(
      threadId,
      isPinned: isPinned,
    );
    if (updated == null) return;
    final latest = _current;
    state = AsyncValue.data(
      ChatSessionState(
        threads: List.unmodifiable(_repo.getThreads()),
        activeThreadId: latest.activeThreadId,
        messages: latest.messages,
      ),
    );
  }

  Future<void> deleteThread(String threadId, {String? ownerUserId}) async {
    await _ensureLoaded();
    final deletionNavigationRevision = _current.activeThreadId == threadId
        ? ++_navigationRevision
        : _navigationRevision;
    final deletion = await _repo.deleteThread(threadId);

    final current = _current;
    final threads = _repo.getThreads();
    final activeThreadMissing =
        current.activeThreadId != null &&
        _repo.getThread(current.activeThreadId!) == null;
    final mustSelectReplacement =
        current.activeThreadId == threadId || activeThreadMissing;
    final nextThreadId = mustSelectReplacement && threads.isNotEmpty
        ? threads.first.id
        : mustSelectReplacement
        ? null
        : current.activeThreadId;
    final messages = mustSelectReplacement
        ? nextThreadId == null
              ? const <ChatMessageRecord>[]
              : _recoverMessagesInMemory(_repo.getMessages(nextThreadId))
        : current.messages;
    state = AsyncValue.data(
      ChatSessionState(
        threads: List.unmodifiable(threads),
        activeThreadId: nextThreadId,
        messages: List.unmodifiable(messages),
      ),
    );

    // Attachment deletion and remote Agent cancellation can both be slow. The
    // thread is already absent from local history; the retained tombstone
    // makes both operations idempotent across process restarts.
    await _cleanupPendingThreadDeletion(
      _repo,
      deletion,
      ownerUserId: ownerUserId,
    );
    if (!mustSelectReplacement ||
        deletionNavigationRevision != _navigationRevision ||
        nextThreadId == null) {
      return;
    }
    try {
      final messages = await _recoverInterrupted(nextThreadId);
      if (deletionNavigationRevision != _navigationRevision ||
          _current.activeThreadId != nextThreadId ||
          _repo.getThread(nextThreadId) == null) {
        return;
      }
      state = AsyncValue.data(
        ChatSessionState(
          threads: List.unmodifiable(_repo.getThreads()),
          activeThreadId: nextThreadId,
          messages: List.unmodifiable(messages),
        ),
      );
    } catch (_) {
      // The visible state already contains the in-memory recovery. A future
      // select/load retries the best-effort persistence.
    }
  }

  Future<void> _ensureLoaded() async {
    await _loadFuture;
    if (_repository == null) {
      throw StateError('Local chat storage is unavailable.');
    }
  }

  ChatRepository get _repo {
    final repository = _repository;
    if (repository == null) {
      throw StateError('Local chat storage is unavailable.');
    }
    return repository;
  }

  ChatSessionState get _current {
    final current = state.valueOrNull;
    if (current == null) {
      throw StateError('Local chat state is unavailable.');
    }
    return current;
  }
}
