import 'package:hive/hive.dart';

import '../models/chat_message_record.dart';
import '../models/chat_thread.dart';

abstract class ChatRepository {
  Future<void> init();

  List<ChatThread> getThreads();

  ChatThread? getThread(String id);

  List<ChatMessageRecord> getMessages(String threadId);

  ChatMessageRecord? getMessage(String id);

  Future<void> putThread(ChatThread thread);

  Future<void> putMessage(ChatMessageRecord message);

  Future<void> deleteThread(String id);
}

class HiveChatRepository implements ChatRepository {
  static const String threadsBoxName = 'chat_threads';
  static const String messagesBoxName = 'chat_messages';

  Box<ChatThread>? _threads;
  Box<ChatMessageRecord>? _messages;

  @override
  Future<void> init() async {
    _threads ??= await Hive.openBox<ChatThread>(threadsBoxName);
    _messages ??= await Hive.openBox<ChatMessageRecord>(messagesBoxName);
  }

  @override
  List<ChatThread> getThreads() {
    final threads = _requireThreads().values.toList(growable: false);
    return threads.toList()..sort((a, b) {
      final byUpdatedAt = b.updatedAt.compareTo(a.updatedAt);
      return byUpdatedAt != 0 ? byUpdatedAt : b.id.compareTo(a.id);
    });
  }

  @override
  ChatThread? getThread(String id) => _requireThreads().get(id);

  @override
  List<ChatMessageRecord> getMessages(String threadId) {
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
  ChatMessageRecord? getMessage(String id) => _requireMessages().get(id);

  @override
  Future<void> putThread(ChatThread thread) {
    return _requireThreads().put(thread.id, thread);
  }

  @override
  Future<void> putMessage(ChatMessageRecord message) {
    return _requireMessages().put(message.id, message);
  }

  @override
  Future<void> deleteThread(String id) async {
    await _requireThreads().delete(id);
    final messages = _requireMessages();
    final keys = messages.keys
        .where((key) => messages.get(key)?.threadId == id)
        .toList(growable: false);
    if (keys.isNotEmpty) await messages.deleteAll(keys);
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
}
