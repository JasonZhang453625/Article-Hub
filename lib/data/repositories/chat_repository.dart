import 'package:hive/hive.dart';

import '../models/chat_attachment.dart';
import '../models/chat_message_record.dart';
import '../models/chat_thread.dart';

class PendingChatThreadDeletion {
  final String threadId;
  final List<String> attachmentIds;
  final List<String> aiRunIdsToCancel;
  final bool dataDeleted;
  final int revision;
  final bool canAcknowledge;

  const PendingChatThreadDeletion({
    required this.threadId,
    this.attachmentIds = const [],
    this.aiRunIdsToCancel = const [],
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

  /// Atomically binds a newly-created server run to the still-current local
  /// generation attempt. Returning null means the message was deleted,
  /// retried, or otherwise superseded and the caller must cancel [runId].
  Future<ChatMessageRecord?> attachAiRunToPendingMessage({
    required String messageId,
    required String? expectedRequestKey,
    required String runId,
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
    String runId,
  );

  /// Removes one successfully-cancelled run from a deletion tombstone.
  Future<PendingChatThreadDeletion?> completeAiRunCancellation(
    String threadId,
    String runId,
  );

  Future<void> completeThreadDeletion(
    String id, {
    required int expectedRevision,
  });
}

class HiveChatRepository implements ChatRepository {
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
      return byCreatedAt != 0 ? byCreatedAt : a.id.compareTo(b.id);
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
  Future<ChatMessageRecord?> attachAiRunToPendingMessage({
    required String messageId,
    required String? expectedRequestKey,
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
    String runId,
  ) {
    return _serializeThreadMutation<PendingChatThreadDeletion>(() async {
      final normalizedRunId = _normalizeAiRunId(runId);
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
      final revision = current.revision + 1;
      if (!current.canAcknowledge) {
        final quarantined = Map<dynamic, dynamic>.from(raw)
          ..['revision'] = revision
          ..['canAcknowledge'] = false
          ..['recoveredAiRunIdsToCancel'] = _sortedAiRunIds(runIds);
        await deletions.put(threadId, quarantined);
        return PendingChatThreadDeletion(
          threadId: threadId,
          attachmentIds: current.attachmentIds,
          aiRunIdsToCancel: _sortedAiRunIds(runIds),
          dataDeleted: current.dataDeleted,
          revision: revision,
          canAcknowledge: false,
        );
      }
      final updated = PendingChatThreadDeletion(
        threadId: threadId,
        attachmentIds: current.attachmentIds,
        aiRunIdsToCancel: _sortedAiRunIds(runIds),
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
      final updated = PendingChatThreadDeletion(
        threadId: threadId,
        attachmentIds: current.attachmentIds,
        aiRunIdsToCancel: _sortedAiRunIds(runIds),
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
          dataDeleted: updated.dataDeleted,
          revision: updated.revision,
          canAcknowledge: true,
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
          current.aiRunIdsToCancel.isNotEmpty) {
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
        if (runId != null) aiRunIdsToCancel.add(runId);
      }
    }

    Future<void> store({required bool dataDeleted}) {
      final quarantined = Map<dynamic, dynamic>.from(existingRaw)
        ..['threadId'] = id
        ..['dataDeleted'] = dataDeleted
        ..['canAcknowledge'] = false
        ..['recoveredAttachmentIds'] = _sortedAttachmentIds(attachmentIds)
        ..['recoveredAiRunIdsToCancel'] = _sortedAiRunIds(aiRunIdsToCancel);
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
        } else if (_messageMayNeedRunCancellation(message) &&
            rawRunId != null) {
          canAcknowledge = false;
        }
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
    final rawCanAcknowledge = raw['canAcknowledge'];
    var canAcknowledge =
        (rawCanAcknowledge == null && schemaVersion == 1) ||
        rawCanAcknowledge == true;
    if (raw['threadId'] != id) canAcknowledge = false;
    dynamic storedIds;
    if (schemaVersion == 1) {
      storedIds = raw['attachments'];
    } else if (schemaVersion == 2 || schemaVersion == 3) {
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
    } else if (schemaVersion == 3) {
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
    final rawRevision = raw['revision'];
    final revision = rawRevision is int ? rawRevision : 0;
    if ((schemaVersion == 2 || schemaVersion == 3) &&
        (rawRevision is! int || revision < 0 || rawCanAcknowledge is! bool)) {
      canAcknowledge = false;
    }
    return PendingChatThreadDeletion(
      threadId: id,
      attachmentIds: _sortedAttachmentIds(attachmentIds),
      aiRunIdsToCancel: _sortedAiRunIds(aiRunIdsToCancel),
      dataDeleted: raw['dataDeleted'] == true,
      revision: revision,
      canAcknowledge: canAcknowledge,
    );
  }

  Map<String, dynamic> _encodeDeletionRecord({
    required String threadId,
    required Iterable<String> attachmentIds,
    required Iterable<String> aiRunIdsToCancel,
    required bool dataDeleted,
    required int revision,
    required bool canAcknowledge,
  }) {
    return {
      'schemaVersion': 3,
      'threadId': threadId,
      'dataDeleted': dataDeleted,
      'revision': revision,
      'canAcknowledge': canAcknowledge,
      'attachmentIds': _sortedAttachmentIds(attachmentIds),
      'aiRunIdsToCancel': _sortedAiRunIds(aiRunIdsToCancel),
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

  bool _messageMayNeedRunCancellation(ChatMessageRecord message) {
    return message.role == ChatMessageRole.assistant &&
        (message.status == ChatMessageStatus.sending ||
            message.errorCode == 'hosted_cancel_requested');
  }

  String? _runIdRequiringCancellation(ChatMessageRecord message) {
    if (!_messageMayNeedRunCancellation(message)) return null;
    return _normalizeAiRunId(message.aiRunId);
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
    final result = _threadMutationTail.then<T>((_) => mutation());
    _threadMutationTail = result.then<void>((_) {}, onError: (_, _) {});
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

int compareChatThreads(ChatThread a, ChatThread b) {
  if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
  final byUpdatedAt = b.updatedAt.compareTo(a.updatedAt);
  return byUpdatedAt != 0 ? byUpdatedAt : b.id.compareTo(a.id);
}
