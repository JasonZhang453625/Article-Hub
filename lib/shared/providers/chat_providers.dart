import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/models/chat_message_record.dart';
import '../../data/models/chat_thread.dart';
import '../../data/repositories/chat_repository.dart';
import 'article_providers.dart';

final chatRepositoryProvider = FutureProvider<ChatRepository>((ref) async {
  await ref.watch(hiveInitProvider.future);
  final repository = HiveChatRepository();
  await repository.init();
  return repository;
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
      // A generation that was in flight when the app was killed is persisted
      // with status=sending. Mark those as interrupted so the UI can offer a
      // one-tap resume instead of a stuck conversation.
      for (final thread in threads) {
        await _recoverInterrupted(thread.id);
      }
      final activeThreadId = threads.isEmpty ? null : threads.first.id;
      final messages = activeThreadId == null
          ? const <ChatMessageRecord>[]
          : repository.getMessages(activeThreadId);
      state = AsyncValue.data(
        ChatSessionState(
          threads: List.unmodifiable(threads),
          activeThreadId: activeThreadId,
          messages: List.unmodifiable(messages),
        ),
      );
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }

  /// Marks any [ChatMessageStatus.sending] message in [threadId] as
  /// interrupted (persisting the change) and returns the recovered list.
  Future<List<ChatMessageRecord>> _recoverInterrupted(String threadId) async {
    final messages = _repo.getMessages(threadId);
    var changed = false;
    final recovered = messages.map((message) {
      if (message.status != ChatMessageStatus.sending) return message;
      changed = true;
      return message.copyWith(status: ChatMessageStatus.interrupted);
    }).toList(growable: false);
    if (changed) {
      for (final message in recovered) {
        if (message.status == ChatMessageStatus.interrupted) {
          await _repo.putMessage(message);
        }
      }
    }
    return recovered;
  }

  Future<void> startNewThread() async {
    await _ensureLoaded();
    final current = _current;
    state = AsyncValue.data(
      ChatSessionState(
        threads: current.threads,
        activeThreadId: null,
        messages: const [],
      ),
    );
  }

  Future<void> selectThread(String threadId) async {
    await _ensureLoaded();
    final current = _current;
    if (current.activeThreadId == threadId) return;
    if (!current.threads.any((thread) => thread.id == threadId)) return;
    final messages = await _recoverInterrupted(threadId);
    state = AsyncValue.data(
      ChatSessionState(
        threads: current.threads,
        activeThreadId: threadId,
        messages: List.unmodifiable(messages),
      ),
    );
  }

  Future<PersistedUserMessage> addUserMessage(String content) async {
    await _ensureLoaded();
    final current = _current;
    final now = DateTime.now().toUtc();
    var thread = _findThread(current.activeThreadId, current.threads);
    thread ??= ChatThread(
      id: _uuid.v4(),
      title: chatTitleFromMessage(content),
      createdAt: now,
      updatedAt: now,
      lastMessagePreview: chatPreviewFromMessage(content),
    );
    await _repo.putThread(thread);

    final message = ChatMessageRecord(
      id: _uuid.v4(),
      threadId: thread.id,
      role: ChatMessageRole.user,
      content: content,
      createdAt: now,
    );
    await _repo.putMessage(message);

    final updatedThread = thread.copyWith(
      updatedAt: now,
      lastMessagePreview: chatPreviewFromMessage(content),
    );
    await _repo.putThread(updatedThread);
    final threads = _upsertThread(current.threads, updatedThread);
    final messages = current.activeThreadId == updatedThread.id
        ? [...current.messages, message]
        : [message];
    state = AsyncValue.data(
      ChatSessionState(
        threads: List.unmodifiable(threads),
        activeThreadId: updatedThread.id,
        messages: List.unmodifiable(messages),
      ),
    );
    return PersistedUserMessage(threadId: updatedThread.id, message: message);
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
    final current = _current;
    final thread = _findThread(threadId, current.threads);
    if (thread == null) {
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

    final updatedThread = thread.copyWith(
      updatedAt: now,
      lastMessagePreview: chatPreviewFromMessage(content),
    );
    await _repo.putThread(updatedThread);
    final threads = _upsertThread(current.threads, updatedThread);
    final messages = current.activeThreadId == threadId
        ? [...current.messages, message]
        : current.messages;
    state = AsyncValue.data(
      ChatSessionState(
        threads: List.unmodifiable(threads),
        activeThreadId: current.activeThreadId,
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
    final current = _current;
    final now = DateTime.now().toUtc();
    final message = ChatMessageRecord(
      id: _uuid.v4(),
      threadId: threadId,
      role: ChatMessageRole.assistant,
      content: '',
      createdAt: now,
      query: query,
      status: ChatMessageStatus.sending,
    );
    await _repo.putMessage(message);
    final messages = current.activeThreadId == threadId
        ? [...current.messages, message]
        : current.messages;
    state = AsyncValue.data(
      ChatSessionState(
        threads: current.threads,
        activeThreadId: current.activeThreadId,
        messages: List.unmodifiable(messages),
      ),
    );
    return message;
  }

  /// Upserts [updated] and refreshes in-memory state. Used to turn a pending
  /// (sending) message into the final answer, an error, or an interruption.
  Future<void> updateMessage(ChatMessageRecord updated) async {
    await _ensureLoaded();
    final current = _current;
    await _repo.putMessage(updated);
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
    final current = _current;
    final existing = _repo.getMessage(messageId);
    if (existing == null) return;
    final updated = existing.copyWith(feedback: feedback);
    await _repo.putMessage(updated);
    final messages = current.messages
        .map((message) => message.id == messageId ? updated : message)
        .toList(growable: false);
    state = AsyncValue.data(
      ChatSessionState(
        threads: current.threads,
        activeThreadId: current.activeThreadId,
        messages: List.unmodifiable(messages),
      ),
    );
  }

  Future<void> deleteThread(String threadId) async {
    await _ensureLoaded();
    final current = _current;
    await _repo.deleteThread(threadId);
    final threads = current.threads
        .where((thread) => thread.id != threadId)
        .toList(growable: false);

    if (current.activeThreadId != threadId) {
      state = AsyncValue.data(
        ChatSessionState(
          threads: List.unmodifiable(threads),
          activeThreadId: current.activeThreadId,
          messages: current.messages,
        ),
      );
      return;
    }

    final nextThreadId = threads.isEmpty ? null : threads.first.id;
    final messages = nextThreadId == null
        ? const <ChatMessageRecord>[]
        : await _recoverInterrupted(nextThreadId);
    state = AsyncValue.data(
      ChatSessionState(
        threads: List.unmodifiable(threads),
        activeThreadId: nextThreadId,
        messages: List.unmodifiable(messages),
      ),
    );
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

ChatThread? _findThread(String? id, List<ChatThread> threads) {
  if (id == null) return null;
  for (final thread in threads) {
    if (thread.id == id) return thread;
  }
  return null;
}

List<ChatThread> _upsertThread(List<ChatThread> threads, ChatThread updated) {
  final result = <ChatThread>[
    updated,
    ...threads.where((thread) => thread.id != updated.id),
  ];
  result.sort((a, b) {
    final byUpdatedAt = b.updatedAt.compareTo(a.updatedAt);
    return byUpdatedAt != 0 ? byUpdatedAt : b.id.compareTo(a.id);
  });
  return result;
}
