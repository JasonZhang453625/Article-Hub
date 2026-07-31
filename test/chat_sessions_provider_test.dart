import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/models/chat_message_record.dart';
import 'package:memora/data/models/chat_thread.dart';
import 'package:memora/data/repositories/chat_repository.dart';
import 'package:memora/shared/providers/chat_providers.dart';

void main() {
  test('creates, switches, updates and deletes local chat sessions', () async {
    final repository = _MemoryChatRepository();
    final container = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWith((ref) async => repository),
      ],
    );
    addTearDown(container.dispose);

    final sessions = container.read(chatSessionsProvider.notifier);
    await sessions.startNewThread();
    final first = await sessions.addUserMessage('First local conversation');
    final firstAnswer = await sessions.addAssistantMessage(
      threadId: first.threadId,
      content: 'First answer',
      logId: 'log-1',
    );
    await sessions.updateFeedback(firstAnswer.id, 1);

    await sessions.startNewThread();
    final second = await sessions.addUserMessage('Second conversation');

    var state = container.read(chatSessionsProvider).requireValue;
    expect(state.threads, hasLength(2));
    expect(state.activeThreadId, second.threadId);
    expect(state.messages.single.content, 'Second conversation');

    await sessions.selectThread(first.threadId);
    state = container.read(chatSessionsProvider).requireValue;
    expect(state.messages, hasLength(2));
    expect(state.messages.last.feedback, 1);

    await sessions.deleteThread(first.threadId);
    state = container.read(chatSessionsProvider).requireValue;
    expect(state.threads.single.id, second.threadId);
    expect(state.activeThreadId, second.threadId);
    expect(repository.getMessages(first.threadId), isEmpty);
  });

  test('recovers in-flight generations as interrupted on load', () async {
    final repository = _MemoryChatRepository();
    final now = DateTime.utc(2026, 7, 30);
    final thread = ChatThread(
      id: 't1',
      title: 'Interrupted',
      createdAt: now,
      updatedAt: now,
    );
    await repository.putThread(thread);
    await repository.putMessage(
      ChatMessageRecord(
        id: 'u1',
        threadId: 't1',
        role: ChatMessageRole.user,
        content: 'Question',
        createdAt: now,
      ),
    );
    await repository.putMessage(
      ChatMessageRecord(
        id: 'a1',
        threadId: 't1',
        role: ChatMessageRole.assistant,
        content: '',
        createdAt: now.add(const Duration(seconds: 1)),
        query: 'Question',
        status: ChatMessageStatus.sending,
      ),
    );

    final container = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWith((ref) async => repository),
      ],
    );
    addTearDown(container.dispose);

    container.read(chatSessionsProvider.notifier);
    while (container.read(chatSessionsProvider).isLoading) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    final state = container.read(chatSessionsProvider).requireValue;
    expect(state.messages.last.id, 'a1');
    expect(state.messages.last.status, ChatMessageStatus.interrupted);
    expect(
      repository.getMessage('a1')!.status,
      ChatMessageStatus.interrupted,
    );
  });
}

class _MemoryChatRepository implements ChatRepository {
  final Map<String, ChatThread> _threads = {};
  final Map<String, ChatMessageRecord> _messages = {};

  @override
  Future<void> init() async {}

  @override
  List<ChatThread> getThreads() {
    final threads = _threads.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return threads;
  }

  @override
  ChatThread? getThread(String id) => _threads[id];

  @override
  List<ChatMessageRecord> getMessages(String threadId) {
    final messages =
        _messages.values
            .where((message) => message.threadId == threadId)
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return messages;
  }

  @override
  ChatMessageRecord? getMessage(String id) => _messages[id];

  @override
  Future<void> putThread(ChatThread thread) async {
    _threads[thread.id] = thread;
  }

  @override
  Future<void> putMessage(ChatMessageRecord message) async {
    _messages[message.id] = message;
  }

  @override
  Future<void> deleteThread(String id) async {
    _threads.remove(id);
    _messages.removeWhere((_, message) => message.threadId == id);
  }
}
