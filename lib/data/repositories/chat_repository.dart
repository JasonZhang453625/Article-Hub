import 'package:hive/hive.dart';

import '../models/chat_attachment.dart';
import '../models/chat_message_record.dart';
import '../models/chat_thread.dart';

class PendingAiRunLookup {
  final String ownerUserId;
  final String requestKey;

  const PendingAiRunLookup({
    required this.ownerUserId,
    required this.requestKey,
  });

  String get identity => '$ownerUserId\u0000$requestKey';
}

class PendingChatThreadDeletion {
  final String threadId;
  final List<String> attachmentIds;
  final List<String> aiRunIdsToCancel;

  /// Immutable owner binding for each cancellable run. A run id without an
  /// owner is quarantined rather than acknowledged under whichever account
  /// happens to sign in next.
  final Map<String, String> aiRunOwnerUserIds;
  final List<PendingAiRunLookup> aiRunLookups;
  final bool dataDeleted;
  final int revision;
  final bool canAcknowledge;

  const PendingChatThreadDeletion({
    required this.threadId,
    this.attachmentIds = const [],
    this.aiRunIdsToCancel = const [],
    this.aiRunOwnerUserIds = const {},
    this.aiRunLookups = const [],
    this.dataDeleted = false,
    this.revision = 0,
    this.canAcknowledge = true,
  });
}

abstract class ChatRepository {
  Future<void> init();

  List<ChatThread> getThreads();

  ChatThread? getThread(String id);

  List<ChatMessageRecord> getMessages(String threadId);

  ChatMessageRecord? getMessage(String id);

  Future<void> putThread(ChatThread thread);

  /// Updates selected fields on an existing thread without ever creating it.
  /// Message activity is monotonic: an older completion cannot replace the
  /// preview/timestamp of a newer message.
  Future<ChatThread?> updateThreadIfExists(
    String id, {
    String? title,
    bool? isPinned,
    DateTime? activityAt,
    String? lastMessagePreview,
  });

  Future<void> putMessage(ChatMessageRecord message);

  /// Atomically records the account that is about to authorize this attempt.
  /// A null result means the local attempt was already superseded, stopped,
  /// deleted, or owned by another account, so no create request may be sent.
  Future<ChatMessageRecord?> markAiRunCreateStarted({
    required String messageId,
    required String expectedRequestKey,
    required String ownerUserId,
  });

  /// Atomically binds a newly-created server run to the still-current local
  /// generation attempt. Returning null means the message was deleted,
  /// retried, or otherwise superseded and the caller must cancel [runId].
  Future<ChatMessageRecord?> attachAiRunToPendingMessage({
    required String messageId,
    required String? expectedRequestKey,
    required String? expectedOwnerUserId,
    required String runId,
  });

  /// Completes an ambiguous attempt only after repeated read-only lookups
  /// proved that the backend has no run for its idempotency key.
  Future<ChatMessageRecord?> completeAiRunReconciliationNotFound({
    required String messageId,
    required String expectedRequestKey,
    required String ownerUserId,
  });

  /// Atomically records local Stop intent while preserving a run id that may
  /// have been attached concurrently by onRunCreated.
  Future<ChatMessageRecord?> requestAiRunCancellation({
    required String messageId,
    required String? expectedRequestKey,
  });

  /// Finalizes a Stop that was proven not to have created a server run.
  Future<ChatMessageRecord?> completeUncreatedAiRunCancellation({
    required String messageId,
    required String? expectedRequestKey,
  });

  Future<void> deleteMessage(String id);

  Future<PendingChatThreadDeletion> deleteThread(String id);

  List<PendingChatThreadDeletion> getPendingThreadDeletions();

  /// Adds a late-created run to an existing (or already-acknowledged) thread
  /// deletion tombstone so process restart can retry cancellation.
  Future<PendingChatThreadDeletion> queueAiRunCancellation(
    String threadId,
    String runId, {
    String? ownerUserId,
  });

  /// Removes one successfully-cancelled run from a deletion tombstone.
  Future<PendingChatThreadDeletion?> completeAiRunCancellation(
    String threadId,
    String runId,
  );

  /// Resolves one deleted-thread idempotency lookup. If [runId] is present it
  /// is atomically moved into the durable cancellation set.
  Future<PendingChatThreadDeletion?> resolveAiRunLookup(
    String threadId, {
    required String ownerUserId,
    required String requestKey,
    String? runId,
  });

  Future<void> completeThreadDeletion(
    String id, {
    required int expectedRevision,
  });
}

abstract interface class ClientToolChatRepository {
  Future<ChatMessageRecord?> markAiRunClientToolsCreateStarted({
    required String messageId,
    required String expectedRequestKey,
    required String ownerUserId,
    required String ownerDeviceId,
    required int protocolVersion,
    required int clientToolsVersion,
    required String knowledgeMode,
  });

  Future<ChatMessageRecord?> attachAiRunClientToolsToPendingMessage({
    required String messageId,
    required String? expectedRequestKey,
    required String? expectedOwnerUserId,
    required String expectedOwnerDeviceId,
    required int expectedProtocolVersion,
    required int expectedClientToolsVersion,
    required String expectedKnowledgeMode,
    required String runId,
  });
}

class HiveChatRepository implements ChatRepository, ClientToolChatRepository {
  static const String threadsBoxName = 'chat_threads';
  static const String messagesBoxName = 'chat_messages';
  static const String deletionsBoxName = 'chat_thread_deletions';

  Box<ChatThread>? _threads;
  Box<ChatMessageRecord>? _messages;
  Box<Map>? _deletions;
  Future<void> _threadMutationTail = Future<void>.value();

  @override
  Future<void> init() async {
    _threads ??= await Hive.openBox<ChatThread>(threadsBoxName);
    _messages ??= await Hive.openBox<ChatMessageRecord>(messagesBoxName);
    _deletions ??= await Hive.openBox<Map>(deletionsBoxName);
    await _resumePendingDataDeletions();
  }

  @override
  List<ChatThread> getThreads() {
    final threads = _requireThreads().values
        .where((thread) => !_isThreadTombstoned(thread.id))
        .toList(growable: false);
    return threads.toList()..sort(compareChatThreads);
  }

  @override
  ChatThread? getThread(String id) {
    if (_isThreadTombstoned(id)) return null;
    return _requireThreads().get(id);
  }

  @override
  List<ChatMessageRecord> getMessages(String threadId) {
    if (_isThreadTombstoned(threadId)) return const [];
    final messages = _requireMessages().values
        .where((message) => message.threadId == threadId)
        .toList();
    messages.sort((a, b) {
      final byCreatedAt = a.createdAt.compareTo(b.createdAt);
      if (byCreatedAt != 0) return byCreatedAt;

      // A user message and its immediately-created assistant placeholder can
      // share the same timestamp on devices whose clock only advances by the
      // millisecond. UUIDs are random, so using the id as the first tie-break
      // can move the question below its answer after the conversation reloads.
      final byRole = _messageRoleOrder(
        a.role,
      ).compareTo(_messageRoleOrder(b.role));
      return byRole != 0 ? byRole : a.id.compareTo(b.id);
    });
    return messages;
  }

  @override
  ChatMessageRecord? getMessage(String id) {
    final message = _requireMessages().get(id);
    if (message == null || _isThreadTombstoned(message.threadId)) return null;
    return message;
  }

  @override
  Future<void> putThread(ChatThread thread) {
    return _serializeThreadMutation<void>(() async {
      if (_isThreadTombstoned(thread.id)) {
        throw StateError('Cannot recreate a chat thread pending deletion.');
      }
      await _requireThreads().put(thread.id, thread);
    });
  }

  @override
  Future<ChatThread?> updateThreadIfExists(
    String id, {
    String? title,
    bool? isPinned,
    DateTime? activityAt,
    String? lastMessagePreview,
  }) {
    return _serializeThreadMutation<ChatThread?>(() async {
      final threads = _requireThreads();
      if (_isThreadTombstoned(id)) return null;
      final current = threads.get(id);
      if (current == null) return null;

      var updated = current.copyWith(title: title, isPinned: isPinned);
      if (activityAt != null && !activityAt.isBefore(current.updatedAt)) {
        updated = updated.copyWith(
          updatedAt: activityAt,
          lastMessagePreview: lastMessagePreview,
        );
      }
      await threads.put(id, updated);
      return updated;
    });
  }

  @override
  Future<void> putMessage(ChatMessageRecord message) {
    return _serializeThreadMutation<void>(() async {
      final threads = _requireThreads();
      final messages = _requireMessages();
      if (_isThreadTombstoned(message.threadId) ||
          threads.get(message.threadId) == null) {
        throw StateError('Cannot persist a message for a missing chat thread.');
      }
      await messages.put(message.id, message);
      // Keep the defensive post-check even though repository mutations are
      // serialized: it also guards against an external writer using the Hive
      // boxes directly during a rolling migration.
      if (_isThreadTombstoned(message.threadId) ||
          threads.get(message.threadId) == null) {
        await messages.delete(message.id);
        throw StateError(
          'Chat thread was deleted while persisting its message.',
        );
      }
    });
  }

  @override
  Future<ChatMessageRecord?> markAiRunCreateStarted({
    required String messageId,
    required String expectedRequestKey,
    required String ownerUserId,
  }) {
    return _serializeThreadMutation<ChatMessageRecord?>(() async {
      final normalizedKey = _normalizeLookupValue(expectedRequestKey);
      final normalizedOwner = _normalizeLookupValue(ownerUserId);
      if (normalizedKey == null || normalizedOwner == null) return null;
      final messages = _requireMessages();
      final current = messages.get(messageId);
      if (current == null ||
          _isThreadTombstoned(current.threadId) ||
          _requireThreads().get(current.threadId) == null ||
          current.role != ChatMessageRole.assistant ||
          current.status != ChatMessageStatus.sending ||
          current.errorCode == 'hosted_cancel_requested' ||
          current.aiRunId != null ||
          current.aiRunRequestKey != normalizedKey ||
          (current.aiRunOwnerUserId != null &&
              current.aiRunOwnerUserId != normalizedOwner)) {
        return null;
      }
      if (current.aiRunOwnerUserId == normalizedOwner) return current;
      final updated = current.copyWith(aiRunOwnerUserId: normalizedOwner);
      await messages.put(messageId, updated);
      return updated;
    });
  }

  @override
  Future<ChatMessageRecord?> markAiRunClientToolsCreateStarted({
    required String messageId,
    required String expectedRequestKey,
    required String ownerUserId,
    required String ownerDeviceId,
    required int protocolVersion,
    required int clientToolsVersion,
    required String knowledgeMode,
  }) {
    return _serializeThreadMutation<ChatMessageRecord?>(() async {
      final normalizedKey = _normalizeLookupValue(expectedRequestKey);
      final normalizedOwner = _normalizeLookupValue(ownerUserId);
      final normalizedDevice = _normalizeLookupValue(ownerDeviceId);
      final normalizedMode = knowledgeMode.trim();
      if (normalizedKey == null ||
          normalizedOwner == null ||
          normalizedDevice == null ||
          protocolVersion < 3 ||
          clientToolsVersion != 1 ||
          (normalizedMode != 'only' && normalizedMode != 'hybrid')) {
        return null;
      }
      final messages = _requireMessages();
      final current = messages.get(messageId);
      if (current == null ||
          _isThreadTombstoned(current.threadId) ||
          _requireThreads().get(current.threadId) == null ||
          current.role != ChatMessageRole.assistant ||
          current.status != ChatMessageStatus.sending ||
          current.errorCode == 'hosted_cancel_requested' ||
          current.aiRunId != null ||
          current.aiRunRequestKey != normalizedKey ||
          (current.aiRunOwnerUserId != null &&
              current.aiRunOwnerUserId != normalizedOwner) ||
          (current.aiRunOwnerDeviceId != null &&
              current.aiRunOwnerDeviceId != normalizedDevice) ||
          (current.aiRunProtocolVersion != null &&
              current.aiRunProtocolVersion != protocolVersion) ||
          (current.aiRunClientToolsVersion != null &&
              current.aiRunClientToolsVersion != clientToolsVersion) ||
          (current.aiRunKnowledgeMode != null &&
              current.aiRunKnowledgeMode != normalizedMode)) {
        return null;
      }
      if (current.aiRunOwnerUserId == normalizedOwner &&
          current.aiRunOwnerDeviceId == normalizedDevice &&
          current.aiRunProtocolVersion == protocolVersion &&
          current.aiRunClientToolsVersion == clientToolsVersion &&
          current.aiRunKnowledgeMode == normalizedMode) {
        return current;
      }
      final updated = current.copyWith(
        aiRunOwnerUserId: normalizedOwner,
        aiRunOwnerDeviceId: normalizedDevice,
        aiRunProtocolVersion: protocolVersion,
        aiRunClientToolsVersion: clientToolsVersion,
        aiRunKnowledgeMode: normalizedMode,
      );
      await messages.put(messageId, updated);
      return updated;
    });
  }

  @override
  Future<ChatMessageRecord?> attachAiRunToPendingMessage({
    required String messageId,
    required String? expectedRequestKey,
    required String? expectedOwnerUserId,
    required String runId,
  }) {
    return _serializeThreadMutation<ChatMessageRecord?>(() async {
      final normalizedRunId = _normalizeAiRunId(runId);
      if (normalizedRunId == null) {
        throw ArgumentError.value(
          runId,
          'runId',
          'Invalid hosted Agent run id.',
        );
      }
      final messages = _requireMessages();
      final current = messages.get(messageId);
      if (current == null ||
          _isThreadTombstoned(current.threadId) ||
          _requireThreads().get(current.threadId) == null ||
          current.role != ChatMessageRole.assistant ||
          (current.status != ChatMessageStatus.sending &&
              current.errorCode != 'hosted_cancel_requested') ||
          current.aiRunRequestKey != expectedRequestKey ||
          current.aiRunOwnerUserId != expectedOwnerUserId ||
          (current.aiRunId != null && current.aiRunId != normalizedRunId)) {
        return null;
      }
      if (current.aiRunId == normalizedRunId) return current;
      final updated = current.copyWith(
        aiRunId: normalizedRunId,
        aiRunEventSeq: 0,
      );
      await messages.put(messageId, updated);
      return updated;
    });
  }

  @override
  Future<ChatMessageRecord?> attachAiRunClientToolsToPendingMessage({
    required String messageId,
    required String? expectedRequestKey,
    required String? expectedOwnerUserId,
    required String expectedOwnerDeviceId,
    required int expectedProtocolVersion,
    required int expectedClientToolsVersion,
    required String expectedKnowledgeMode,
    required String runId,
  }) {
    return _serializeThreadMutation<ChatMessageRecord?>(() async {
      final normalizedRunId = _normalizeAiRunId(runId);
      if (normalizedRunId == null) return null;
      final current = _requireMessages().get(messageId);
      if (current == null ||
          _isThreadTombstoned(current.threadId) ||
          _requireThreads().get(current.threadId) == null ||
          current.role != ChatMessageRole.assistant ||
          (current.status != ChatMessageStatus.sending &&
              current.errorCode != 'hosted_cancel_requested') ||
          current.aiRunRequestKey != expectedRequestKey ||
          current.aiRunOwnerUserId != expectedOwnerUserId ||
          current.aiRunOwnerDeviceId != expectedOwnerDeviceId ||
          current.aiRunProtocolVersion != expectedProtocolVersion ||
          current.aiRunClientToolsVersion != expectedClientToolsVersion ||
          current.aiRunKnowledgeMode != expectedKnowledgeMode ||
          (current.aiRunId != null && current.aiRunId != normalizedRunId)) {
        return null;
      }
      if (current.aiRunId == normalizedRunId) return current;
      final updated = current.copyWith(
        aiRunId: normalizedRunId,
        aiRunEventSeq: 0,
      );
      await _requireMessages().put(messageId, updated);
      return updated;
    });
  }

  @override
  Future<ChatMessageRecord?> completeAiRunReconciliationNotFound({
    required String messageId,
    required String expectedRequestKey,
    required String ownerUserId,
  }) {
    return _serializeThreadMutation<ChatMessageRecord?>(() async {
      final messages = _requireMessages();
      final current = messages.get(messageId);
      if (current == null ||
          _isThreadTombstoned(current.threadId) ||
          _requireThreads().get(current.threadId) == null ||
          current.role != ChatMessageRole.assistant ||
          current.aiRunId != null ||
          current.aiRunRequestKey != expectedRequestKey ||
          current.aiRunOwnerUserId != ownerUserId ||
          (current.status != ChatMessageStatus.sending &&
              current.errorCode != 'hosted_cancel_requested')) {
        return null;
      }
      final stopped = current.errorCode == 'hosted_cancel_requested';
      final updated = current.copyWith(
        status: ChatMessageStatus.interrupted,
        errorCode: stopped ? 'hosted_run_cancelled' : 'hosted_run_not_found',
      );
      await messages.put(messageId, updated);
      return updated;
    });
  }

  @override
  Future<ChatMessageRecord?> requestAiRunCancellation({
    required String messageId,
    required String? expectedRequestKey,
  }) {
    return _serializeThreadMutation<ChatMessageRecord?>(() async {
      final messages = _requireMessages();
      final current = messages.get(messageId);
      if (current == null ||
          _isThreadTombstoned(current.threadId) ||
          _requireThreads().get(current.threadId) == null ||
          current.role != ChatMessageRole.assistant ||
          current.aiRunRequestKey != expectedRequestKey ||
          (current.status != ChatMessageStatus.sending &&
              current.errorCode != 'hosted_cancel_requested')) {
        return null;
      }
      if (current.errorCode == 'hosted_cancel_requested') return current;
      final updated = current.copyWith(
        status: ChatMessageStatus.interrupted,
        errorCode: 'hosted_cancel_requested',
      );
      await messages.put(messageId, updated);
      return updated;
    });
  }

  @override
  Future<ChatMessageRecord?> completeUncreatedAiRunCancellation({
    required String messageId,
    required String? expectedRequestKey,
  }) {
    return _serializeThreadMutation<ChatMessageRecord?>(() async {
      final messages = _requireMessages();
      final current = messages.get(messageId);
      if (current == null ||
          _isThreadTombstoned(current.threadId) ||
          _requireThreads().get(current.threadId) == null ||
          current.aiRunRequestKey != expectedRequestKey ||
          current.aiRunId != null ||
          current.errorCode != 'hosted_cancel_requested') {
        return null;
      }
      final updated = current.copyWith(
        status: ChatMessageStatus.interrupted,
        errorCode: 'hosted_run_cancelled',
      );
      await messages.put(messageId, updated);
      return updated;
    });
  }

  @override
  Future<void> deleteMessage(String id) {
    return _serializeThreadMutation<void>(() => _requireMessages().delete(id));
  }

  @override
  Future<PendingChatThreadDeletion> deleteThread(String id) {
    return _serializeThreadMutation<PendingChatThreadDeletion>(
      () => _deleteThreadDataSafely(id),
    );
  }

  @override
  List<PendingChatThreadDeletion> getPendingThreadDeletions() {
    final records = <PendingChatThreadDeletion>[];
    for (final entry in _requireDeletions().toMap().entries) {
      final threadId = entry.key?.toString() ?? '';
      if (threadId.isEmpty) continue;
      try {
        records.add(_decodeDeletionRecord(threadId, entry.value));
      } catch (_) {
        records.add(
          PendingChatThreadDeletion(threadId: threadId, canAcknowledge: false),
        );
      }
    }
    return List.unmodifiable(records);
  }

  @override
  Future<PendingChatThreadDeletion> queueAiRunCancellation(
    String threadId,
    String runId, {
    String? ownerUserId,
  }) {
    return _serializeThreadMutation<PendingChatThreadDeletion>(() async {
      final normalizedRunId = _normalizeAiRunId(runId);
      final normalizedOwner = _normalizeLookupValue(ownerUserId);
      if (normalizedRunId == null) {
        throw ArgumentError.value(
          runId,
          'runId',
          'Invalid hosted Agent run id.',
        );
      }
      final deletions = _requireDeletions();
      var raw = deletions.get(threadId);
      if (raw == null) {
        if (_requireThreads().get(threadId) != null) {
          throw StateError(
            'Cannot create a deletion tombstone for an existing chat thread.',
          );
        }
        await _deleteThreadData(threadId);
        raw = deletions.get(threadId);
      }
      final current = _decodeDeletionRecord(threadId, raw!);
      final runIds = current.aiRunIdsToCancel.toSet()..add(normalizedRunId);
      final runOwners = Map<String, String>.from(current.aiRunOwnerUserIds);
      if (normalizedOwner != null) {
        runOwners[normalizedRunId] = normalizedOwner;
      }
      final canAcknowledge = current.canAcknowledge && normalizedOwner != null;
      final revision = current.revision + 1;
      if (!canAcknowledge) {
        final quarantined = Map<dynamic, dynamic>.from(raw)
          ..['revision'] = revision
          ..['canAcknowledge'] = false
          ..['recoveredAiRunIdsToCancel'] = _sortedAiRunIds(runIds)
          ..['recoveredAiRunCancellations'] = _encodeAiRunCancellations(
            runIds,
            runOwners,
          );
        await deletions.put(threadId, quarantined);
        return PendingChatThreadDeletion(
          threadId: threadId,
          attachmentIds: current.attachmentIds,
          aiRunIdsToCancel: _sortedAiRunIds(runIds),
          aiRunOwnerUserIds: Map.unmodifiable(runOwners),
          aiRunLookups: current.aiRunLookups,
          dataDeleted: current.dataDeleted,
          revision: revision,
          canAcknowledge: false,
        );
      }
      final updated = PendingChatThreadDeletion(
        threadId: threadId,
        attachmentIds: current.attachmentIds,
        aiRunIdsToCancel: _sortedAiRunIds(runIds),
        aiRunOwnerUserIds: Map.unmodifiable(runOwners),
        aiRunLookups: current.aiRunLookups,
        dataDeleted: current.dataDeleted,
        revision: revision,
        canAcknowledge: true,
      );
      await deletions.put(
        threadId,
        _encodeDeletionRecord(
          threadId: threadId,
          attachmentIds: updated.attachmentIds,
          aiRunIdsToCancel: updated.aiRunIdsToCancel,
          aiRunOwnerUserIds: updated.aiRunOwnerUserIds,
          aiRunLookups: updated.aiRunLookups,
          dataDeleted: updated.dataDeleted,
          revision: updated.revision,
          canAcknowledge: true,
        ),
      );
      return updated;
    });
  }

  @override
  Future<PendingChatThreadDeletion?> completeAiRunCancellation(
    String threadId,
    String runId,
  ) {
    return _serializeThreadMutation<PendingChatThreadDeletion?>(() async {
      final normalizedRunId = _normalizeAiRunId(runId);
      if (normalizedRunId == null) return null;
      final deletions = _requireDeletions();
      final raw = deletions.get(threadId);
      if (raw == null) return null;
      final current = _decodeDeletionRecord(threadId, raw);
      if (!current.aiRunIdsToCancel.contains(normalizedRunId)) return current;
      if (!current.canAcknowledge) return current;
      final runIds = current.aiRunIdsToCancel.toSet()..remove(normalizedRunId);
      final runOwners = Map<String, String>.from(current.aiRunOwnerUserIds)
        ..remove(normalizedRunId);
      final updated = PendingChatThreadDeletion(
        threadId: threadId,
        attachmentIds: current.attachmentIds,
        aiRunIdsToCancel: _sortedAiRunIds(runIds),
        aiRunOwnerUserIds: Map.unmodifiable(runOwners),
        aiRunLookups: current.aiRunLookups,
        dataDeleted: current.dataDeleted,
        revision: current.revision + 1,
        canAcknowledge: true,
      );
      await deletions.put(
        threadId,
        _encodeDeletionRecord(
          threadId: threadId,
          attachmentIds: updated.attachmentIds,
          aiRunIdsToCancel: updated.aiRunIdsToCancel,
          aiRunOwnerUserIds: updated.aiRunOwnerUserIds,
          aiRunLookups: updated.aiRunLookups,
          dataDeleted: updated.dataDeleted,
          revision: updated.revision,
          canAcknowledge: true,
        ),
      );
      return updated;
    });
  }

  @override
  Future<PendingChatThreadDeletion?> resolveAiRunLookup(
    String threadId, {
    required String ownerUserId,
    required String requestKey,
    String? runId,
  }) {
    return _serializeThreadMutation<PendingChatThreadDeletion?>(() async {
      final normalizedOwner = _normalizeLookupValue(ownerUserId);
      final normalizedKey = _normalizeLookupValue(requestKey);
      final normalizedRunId = runId == null ? null : _normalizeAiRunId(runId);
      if (normalizedOwner == null ||
          normalizedKey == null ||
          (runId != null && normalizedRunId == null)) {
        return null;
      }
      final deletions = _requireDeletions();
      final raw = deletions.get(threadId);
      if (raw == null) return null;
      final current = _decodeDeletionRecord(threadId, raw);
      if (!current.canAcknowledge) return current;
      final identity = '$normalizedOwner\u0000$normalizedKey';
      if (!current.aiRunLookups.any((item) => item.identity == identity)) {
        return current;
      }
      final lookups = current.aiRunLookups
          .where((item) => item.identity != identity)
          .toList(growable: false);
      final runIds = current.aiRunIdsToCancel.toSet();
      final runOwners = Map<String, String>.from(current.aiRunOwnerUserIds);
      if (normalizedRunId != null) {
        runIds.add(normalizedRunId);
        runOwners[normalizedRunId] = normalizedOwner;
      }
      final updated = PendingChatThreadDeletion(
        threadId: threadId,
        attachmentIds: current.attachmentIds,
        aiRunIdsToCancel: _sortedAiRunIds(runIds),
        aiRunOwnerUserIds: Map.unmodifiable(runOwners),
        aiRunLookups: _sortedAiRunLookups(lookups),
        dataDeleted: current.dataDeleted,
        revision: current.revision + 1,
        canAcknowledge: current.canAcknowledge,
      );
      await deletions.put(
        threadId,
        _encodeDeletionRecord(
          threadId: threadId,
          attachmentIds: updated.attachmentIds,
          aiRunIdsToCancel: updated.aiRunIdsToCancel,
          aiRunOwnerUserIds: updated.aiRunOwnerUserIds,
          aiRunLookups: updated.aiRunLookups,
          dataDeleted: updated.dataDeleted,
          revision: updated.revision,
          canAcknowledge: updated.canAcknowledge,
        ),
      );
      return updated;
    });
  }

  @override
  Future<void> completeThreadDeletion(
    String id, {
    required int expectedRevision,
  }) {
    return _serializeThreadMutation<void>(() async {
      final deletions = _requireDeletions();
      final raw = deletions.get(id);
      if (raw == null) return;
      final current = _decodeDeletionRecord(id, raw);
      if (!current.dataDeleted ||
          !current.canAcknowledge ||
          current.aiRunIdsToCancel.isNotEmpty ||
          current.aiRunLookups.isNotEmpty) {
        throw StateError('Chat thread deletion is not safe to acknowledge.');
      }
      if (current.revision != expectedRevision) {
        throw StateError('Chat thread deletion changed during file cleanup.');
      }
      await deletions.delete(id);
    });
  }

  Future<void> _resumePendingDataDeletions() async {
    final ids = _requireDeletions().keys
        .map((key) => key.toString())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    for (final id in ids) {
      try {
        await _serializeThreadMutation<PendingChatThreadDeletion>(
          () => _deleteThreadDataSafely(id),
        );
      } catch (_) {
        // Keep the tombstone and continue loading other conversations. A
        // later repository initialization retries this idempotent deletion.
      }
    }
  }

  Future<PendingChatThreadDeletion> _deleteThreadDataSafely(String id) {
    final raw = _requireDeletions().get(id);
    if (raw != null) {
      final existing = _decodeDeletionRecord(id, raw);
      if (!existing.canAcknowledge) {
        return _deleteQuarantinedThreadData(id, raw, existing);
      }
    }
    return _deleteThreadData(id);
  }

  Future<PendingChatThreadDeletion> _deleteQuarantinedThreadData(
    String id,
    Map existingRaw,
    PendingChatThreadDeletion existing,
  ) async {
    final threads = _requireThreads();
    final messages = _requireMessages();
    final deletions = _requireDeletions();
    final attachmentIds = existing.attachmentIds.toSet();
    final aiRunIdsToCancel = existing.aiRunIdsToCancel.toSet();
    final aiRunOwnerUserIds = Map<String, String>.from(
      existing.aiRunOwnerUserIds,
    );
    final aiRunLookups = {
      for (final lookup in existing.aiRunLookups) lookup.identity: lookup,
    };

    void capture(Iterable<ChatMessageRecord> source) {
      for (final message in source) {
        for (final attachment in message.attachments) {
          if (isValidChatAttachmentId(attachment.id)) {
            attachmentIds.add(attachment.id);
          }
        }
        attachmentIds.addAll(
          message.attachmentIdsForCleanup.where(isValidChatAttachmentId),
        );
        final runId = _runIdRequiringCancellation(message);
        if (runId != null) {
          aiRunIdsToCancel.add(runId);
          final owner = _normalizeLookupValue(message.aiRunOwnerUserId);
          if (owner != null) aiRunOwnerUserIds[runId] = owner;
        }
        final lookup = _lookupRequiringReconciliation(message);
        if (lookup != null) aiRunLookups[lookup.identity] = lookup;
      }
    }

    Future<void> store({required bool dataDeleted}) {
      final quarantined = Map<dynamic, dynamic>.from(existingRaw)
        ..['threadId'] = id
        ..['dataDeleted'] = dataDeleted
        ..['canAcknowledge'] = false
        ..['recoveredAttachmentIds'] = _sortedAttachmentIds(attachmentIds)
        ..['recoveredAiRunIdsToCancel'] = _sortedAiRunIds(aiRunIdsToCancel)
        ..['recoveredAiRunCancellations'] = _encodeAiRunCancellations(
          aiRunIdsToCancel,
          aiRunOwnerUserIds,
        )
        ..['recoveredAiRunLookups'] = _encodeAiRunLookups(aiRunLookups.values);
      return deletions.put(id, quarantined);
    }

    capture(messages.values.where((message) => message.threadId == id));
    await store(dataDeleted: false);
    await threads.delete(id);
    final messageEntries = messages
        .toMap()
        .entries
        .where((entry) => entry.value.threadId == id)
        .toList(growable: false);
    capture(messageEntries.map((entry) => entry.value));
    await store(dataDeleted: false);
    final keys = messageEntries
        .map((entry) => entry.key)
        .toList(growable: false);
    if (keys.isNotEmpty) await messages.deleteAll(keys);
    await store(dataDeleted: true);
    return PendingChatThreadDeletion(
      threadId: id,
      attachmentIds: _sortedAttachmentIds(attachmentIds),
      aiRunIdsToCancel: _sortedAiRunIds(aiRunIdsToCancel),
      aiRunOwnerUserIds: Map.unmodifiable(aiRunOwnerUserIds),
      aiRunLookups: _sortedAiRunLookups(aiRunLookups.values),
      dataDeleted: true,
      revision: existing.revision,
      canAcknowledge: false,
    );
  }

  Future<PendingChatThreadDeletion> _deleteThreadData(String id) async {
    final threads = _requireThreads();
    final messages = _requireMessages();
    final deletions = _requireDeletions();
    final existingRaw = deletions.get(id);
    final existing = existingRaw == null
        ? PendingChatThreadDeletion(threadId: id)
        : _decodeDeletionRecord(id, existingRaw);
    final attachmentIds = existing.attachmentIds.toSet();
    final aiRunIdsToCancel = existing.aiRunIdsToCancel.toSet();
    final aiRunOwnerUserIds = Map<String, String>.from(
      existing.aiRunOwnerUserIds,
    );
    final aiRunLookups = {
      for (final lookup in existing.aiRunLookups) lookup.identity: lookup,
    };
    var canAcknowledge = existing.canAcknowledge;

    void captureCleanupIds(Iterable<ChatMessageRecord> source) {
      for (final message in source) {
        for (final attachment in message.attachments) {
          if (isValidChatAttachmentId(attachment.id)) {
            attachmentIds.add(attachment.id);
          } else {
            canAcknowledge = false;
          }
        }
        for (final attachmentId in message.attachmentIdsForCleanup) {
          if (isValidChatAttachmentId(attachmentId)) {
            attachmentIds.add(attachmentId);
          } else {
            canAcknowledge = false;
          }
        }
        final rawRunId = message.aiRunId;
        final runId = _runIdRequiringCancellation(message);
        if (runId != null) {
          aiRunIdsToCancel.add(runId);
          final owner = _normalizeLookupValue(message.aiRunOwnerUserId);
          if (owner == null) {
            canAcknowledge = false;
          } else {
            aiRunOwnerUserIds[runId] = owner;
          }
        } else if (_messageMayNeedRunCancellation(message) &&
            rawRunId != null) {
          canAcknowledge = false;
        }
        final lookup = _lookupRequiringReconciliation(message);
        if (lookup != null) aiRunLookups[lookup.identity] = lookup;
      }
    }

    captureCleanupIds(
      messages.values.where((message) => message.threadId == id),
    );
    var revision = existing.revision + 1;

    // The tombstone is the commit point. It is written before either data box
    // changes and retained until attachment files are also gone. On restart,
    // init() replays this operation and merges any message that raced with the
    // first attempt before deleting it.
    await deletions.put(
      id,
      _encodeDeletionRecord(
        threadId: id,
        attachmentIds: attachmentIds,
        aiRunIdsToCancel: aiRunIdsToCancel,
        aiRunOwnerUserIds: aiRunOwnerUserIds,
        aiRunLookups: aiRunLookups.values,
        dataDeleted: false,
        revision: revision,
        canAcknowledge: canAcknowledge,
      ),
    );
    await threads.delete(id);

    // Re-scan after the thread is gone. A message write that began before the
    // tombstone may have completed while its thread still existed; after this
    // point new writes fail their FK check, and later in-flight writes remove
    // themselves in putMessage's post-check.
    final messageEntries = messages
        .toMap()
        .entries
        .where((entry) => entry.value.threadId == id)
        .toList(growable: false);
    captureCleanupIds(messageEntries.map((entry) => entry.value));
    revision++;
    await deletions.put(
      id,
      _encodeDeletionRecord(
        threadId: id,
        attachmentIds: attachmentIds,
        aiRunIdsToCancel: aiRunIdsToCancel,
        aiRunOwnerUserIds: aiRunOwnerUserIds,
        aiRunLookups: aiRunLookups.values,
        dataDeleted: false,
        revision: revision,
        canAcknowledge: canAcknowledge,
      ),
    );
    final keys = messageEntries
        .map((entry) => entry.key)
        .toList(growable: false);
    if (keys.isNotEmpty) await messages.deleteAll(keys);
    revision++;
    final completed = PendingChatThreadDeletion(
      threadId: id,
      attachmentIds: _sortedAttachmentIds(attachmentIds),
      aiRunIdsToCancel: _sortedAiRunIds(aiRunIdsToCancel),
      aiRunOwnerUserIds: Map.unmodifiable(aiRunOwnerUserIds),
      aiRunLookups: _sortedAiRunLookups(aiRunLookups.values),
      dataDeleted: true,
      revision: revision,
      canAcknowledge: canAcknowledge,
    );
    await deletions.put(
      id,
      _encodeDeletionRecord(
        threadId: id,
        attachmentIds: completed.attachmentIds,
        aiRunIdsToCancel: completed.aiRunIdsToCancel,
        aiRunOwnerUserIds: completed.aiRunOwnerUserIds,
        aiRunLookups: completed.aiRunLookups,
        dataDeleted: true,
        revision: revision,
        canAcknowledge: canAcknowledge,
      ),
    );
    return completed;
  }

  PendingChatThreadDeletion _decodeDeletionRecord(String id, Map raw) {
    final rawSchemaVersion = raw['schemaVersion'];
    final schemaVersion = rawSchemaVersion is int ? rawSchemaVersion : null;
    final attachmentIds = <String>{};
    final aiRunIdsToCancel = <String>{};
    final aiRunOwnerUserIds = <String, String>{};
    final aiRunLookups = <String, PendingAiRunLookup>{};
    final rawCanAcknowledge = raw['canAcknowledge'];
    var canAcknowledge =
        (rawCanAcknowledge == null && schemaVersion == 1) ||
        rawCanAcknowledge == true;
    if (raw['threadId'] != id) canAcknowledge = false;
    dynamic storedIds;
    if (schemaVersion == 1) {
      storedIds = raw['attachments'];
    } else if (schemaVersion == 2 ||
        schemaVersion == 3 ||
        schemaVersion == 4 ||
        schemaVersion == 5) {
      storedIds = raw['attachmentIds'];
    } else {
      canAcknowledge = false;
      storedIds = raw['attachmentIds'] ?? raw['attachments'];
    }
    if (storedIds is! List) {
      canAcknowledge = false;
    } else {
      for (final item in storedIds) {
        final dynamic candidate = item is Map ? item['id'] : item;
        if (item is Map && schemaVersion != 1) canAcknowledge = false;
        if (candidate is String && isValidChatAttachmentId(candidate)) {
          attachmentIds.add(candidate);
        } else {
          canAcknowledge = false;
        }
      }
    }
    final recoveredIds = raw['recoveredAttachmentIds'];
    if (recoveredIds is List) {
      for (final item in recoveredIds) {
        if (item is String && isValidChatAttachmentId(item)) {
          attachmentIds.add(item);
        } else {
          canAcknowledge = false;
        }
      }
    } else if (recoveredIds != null) {
      canAcknowledge = false;
    }
    dynamic storedRunIds;
    if (schemaVersion == 1 || schemaVersion == 2) {
      storedRunIds = const <String>[];
    } else if (schemaVersion == 3 || schemaVersion == 4 || schemaVersion == 5) {
      storedRunIds = raw['aiRunIdsToCancel'];
    } else {
      storedRunIds = raw['aiRunIdsToCancel'];
    }
    if (storedRunIds is! List) {
      canAcknowledge = false;
    } else {
      for (final item in storedRunIds) {
        final runId = _normalizeAiRunId(item);
        if (runId == null) {
          canAcknowledge = false;
        } else {
          aiRunIdsToCancel.add(runId);
        }
      }
    }
    final recoveredRunIds = raw['recoveredAiRunIdsToCancel'];
    if (recoveredRunIds is List) {
      for (final item in recoveredRunIds) {
        final runId = _normalizeAiRunId(item);
        if (runId == null) {
          canAcknowledge = false;
        } else {
          aiRunIdsToCancel.add(runId);
        }
      }
    } else if (recoveredRunIds != null) {
      canAcknowledge = false;
    }
    void readCancellations(dynamic rawCancellations) {
      if (rawCancellations is! List) {
        canAcknowledge = false;
        return;
      }
      for (final item in rawCancellations) {
        if (item is! Map) {
          canAcknowledge = false;
          continue;
        }
        final runId = _normalizeAiRunId(item['runId']);
        final owner = _normalizeLookupValue(item['ownerUserId']);
        if (runId == null || owner == null) {
          canAcknowledge = false;
          continue;
        }
        final previous = aiRunOwnerUserIds[runId];
        if (previous != null && previous != owner) {
          canAcknowledge = false;
          continue;
        }
        aiRunIdsToCancel.add(runId);
        aiRunOwnerUserIds[runId] = owner;
      }
    }

    if (schemaVersion == 5) {
      readCancellations(raw['aiRunCancellations']);
    } else if (aiRunIdsToCancel.isNotEmpty) {
      // Schema <=4 did not bind cancellation to an owner. Never guess from
      // the account currently signed in; retain the tombstone fail-closed.
      canAcknowledge = false;
    }
    final recoveredCancellations = raw['recoveredAiRunCancellations'];
    if (recoveredCancellations != null) {
      readCancellations(recoveredCancellations);
    }
    if (aiRunIdsToCancel.any(
      (runId) => !aiRunOwnerUserIds.containsKey(runId),
    )) {
      canAcknowledge = false;
    }
    dynamic storedLookups;
    if (schemaVersion == 4 || schemaVersion == 5) {
      storedLookups = raw['aiRunLookups'];
    } else if (schemaVersion == 1 || schemaVersion == 2 || schemaVersion == 3) {
      storedLookups = const <dynamic>[];
    } else {
      storedLookups = raw['aiRunLookups'];
    }
    if (storedLookups is! List) {
      canAcknowledge = false;
    } else {
      for (final item in storedLookups) {
        final lookup = _decodeAiRunLookup(item);
        if (lookup == null) {
          canAcknowledge = false;
        } else {
          aiRunLookups[lookup.identity] = lookup;
        }
      }
    }
    final recoveredLookups = raw['recoveredAiRunLookups'];
    if (recoveredLookups is List) {
      for (final item in recoveredLookups) {
        final lookup = _decodeAiRunLookup(item);
        if (lookup == null) {
          canAcknowledge = false;
        } else {
          aiRunLookups[lookup.identity] = lookup;
        }
      }
    } else if (recoveredLookups != null) {
      canAcknowledge = false;
    }
    final rawRevision = raw['revision'];
    final revision = rawRevision is int ? rawRevision : 0;
    if ((schemaVersion == 2 ||
            schemaVersion == 3 ||
            schemaVersion == 4 ||
            schemaVersion == 5) &&
        (rawRevision is! int || revision < 0 || rawCanAcknowledge is! bool)) {
      canAcknowledge = false;
    }
    return PendingChatThreadDeletion(
      threadId: id,
      attachmentIds: _sortedAttachmentIds(attachmentIds),
      aiRunIdsToCancel: _sortedAiRunIds(aiRunIdsToCancel),
      aiRunOwnerUserIds: Map.unmodifiable(aiRunOwnerUserIds),
      aiRunLookups: _sortedAiRunLookups(aiRunLookups.values),
      dataDeleted: raw['dataDeleted'] == true,
      revision: revision,
      canAcknowledge: canAcknowledge,
    );
  }

  Map<String, dynamic> _encodeDeletionRecord({
    required String threadId,
    required Iterable<String> attachmentIds,
    required Iterable<String> aiRunIdsToCancel,
    required Map<String, String> aiRunOwnerUserIds,
    required Iterable<PendingAiRunLookup> aiRunLookups,
    required bool dataDeleted,
    required int revision,
    required bool canAcknowledge,
  }) {
    return {
      'schemaVersion': 5,
      'threadId': threadId,
      'dataDeleted': dataDeleted,
      'revision': revision,
      'canAcknowledge': canAcknowledge,
      'attachmentIds': _sortedAttachmentIds(attachmentIds),
      'aiRunIdsToCancel': _sortedAiRunIds(aiRunIdsToCancel),
      'aiRunCancellations': _encodeAiRunCancellations(
        aiRunIdsToCancel,
        aiRunOwnerUserIds,
      ),
      'aiRunLookups': _encodeAiRunLookups(aiRunLookups),
    };
  }

  List<String> _sortedAttachmentIds(Iterable<String> values) {
    final result = values.toSet().toList()..sort();
    return List.unmodifiable(result);
  }

  List<String> _sortedAiRunIds(Iterable<String> values) {
    final result = values.toSet().toList()..sort();
    return List.unmodifiable(result);
  }

  List<Map<String, String>> _encodeAiRunCancellations(
    Iterable<String> runIds,
    Map<String, String> owners,
  ) {
    return _sortedAiRunIds(runIds)
        .where((runId) => owners[runId]?.trim().isNotEmpty == true)
        .map((runId) => {'runId': runId, 'ownerUserId': owners[runId]!.trim()})
        .toList(growable: false);
  }

  List<PendingAiRunLookup> _sortedAiRunLookups(
    Iterable<PendingAiRunLookup> values,
  ) {
    final unique = <String, PendingAiRunLookup>{
      for (final value in values) value.identity: value,
    };
    final result = unique.values.toList()
      ..sort((a, b) => a.identity.compareTo(b.identity));
    return List.unmodifiable(result);
  }

  List<Map<String, String>> _encodeAiRunLookups(
    Iterable<PendingAiRunLookup> values,
  ) {
    return _sortedAiRunLookups(values)
        .map(
          (lookup) => {
            'ownerUserId': lookup.ownerUserId,
            'requestKey': lookup.requestKey,
          },
        )
        .toList(growable: false);
  }

  PendingAiRunLookup? _decodeAiRunLookup(dynamic value) {
    if (value is! Map) return null;
    final owner = _normalizeLookupValue(value['ownerUserId']);
    final key = _normalizeLookupValue(value['requestKey']);
    if (owner == null || key == null) return null;
    return PendingAiRunLookup(ownerUserId: owner, requestKey: key);
  }

  bool _messageMayNeedRunCancellation(ChatMessageRecord message) {
    return message.role == ChatMessageRole.assistant &&
        (message.status == ChatMessageStatus.sending ||
            message.errorCode == 'hosted_cancel_requested');
  }

  String? _runIdRequiringCancellation(ChatMessageRecord message) {
    if (!_messageMayNeedRunCancellation(message)) return null;
    return _normalizeAiRunId(message.aiRunId);
  }

  PendingAiRunLookup? _lookupRequiringReconciliation(
    ChatMessageRecord message,
  ) {
    if (!_messageMayNeedRunCancellation(message) || message.aiRunId != null) {
      return null;
    }
    final owner = _normalizeLookupValue(message.aiRunOwnerUserId);
    final key = _normalizeLookupValue(message.aiRunRequestKey);
    if (owner == null || key == null) return null;
    return PendingAiRunLookup(ownerUserId: owner, requestKey: key);
  }

  String? _normalizeLookupValue(dynamic value) {
    if (value is! String) return null;
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > 200) return null;
    return normalized;
  }

  String? _normalizeAiRunId(dynamic value) {
    if (value is! String) return null;
    final normalized = value.trim();
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(normalized)) {
      return null;
    }
    return normalized;
  }

  bool _isThreadTombstoned(String id) => _requireDeletions().containsKey(id);

  Future<T> _serializeThreadMutation<T>(Future<T> Function() mutation) {
    // Passing `mutation` as a returned Future through `then<T>` can leave
    // some AOT/test runtimes waiting on the wrong generic completion. Run it
    // in an explicit async continuation so the queue always flattens it.
    final result = _threadMutationTail.then<T>((_) async {
      final value = await mutation();
      return value;
    });
    _threadMutationTail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return result;
  }

  Box<ChatThread> _requireThreads() {
    final box = _threads;
    if (box == null) {
      throw StateError('ChatRepository.init() must be called first.');
    }
    return box;
  }

  Box<ChatMessageRecord> _requireMessages() {
    final box = _messages;
    if (box == null) {
      throw StateError('ChatRepository.init() must be called first.');
    }
    return box;
  }

  Box<Map> _requireDeletions() {
    final box = _deletions;
    if (box == null) {
      throw StateError('ChatRepository.init() must be called first.');
    }
    return box;
  }
}

int _messageRoleOrder(ChatMessageRole role) => switch (role) {
  ChatMessageRole.system => 0,
  ChatMessageRole.user => 1,
  ChatMessageRole.assistant => 2,
};

int compareChatThreads(ChatThread a, ChatThread b) {
  if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
  final byUpdatedAt = b.updatedAt.compareTo(a.updatedAt);
  return byUpdatedAt != 0 ? byUpdatedAt : b.id.compareTo(a.id);
}
