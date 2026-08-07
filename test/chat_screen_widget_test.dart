import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/models/chat_message_record.dart';
import 'package:memora/data/models/chat_thread.dart';
import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/settings.dart';
import 'package:memora/data/models/source_platform.dart';
import 'package:memora/data/repositories/article_repository.dart';
import 'package:memora/data/repositories/chat_repository.dart';
import 'package:memora/data/services/prompt_service.dart';
import 'package:memora/data/services/rag_conversation_service.dart';
import 'package:memora/data/services/retrieval_service.dart';
import 'package:memora/features/chat/chat_screen.dart';
import 'package:memora/shared/providers/chat_providers.dart';
import 'package:memora/shared/providers/settings_providers.dart';
import 'package:memora/shared/providers/passage_providers.dart';

/// Phase 3.4 widget tests for the Chat screen states.
///
/// `flutter test` runs widget callbacks in a fake-async zone where real Hive
/// file I/O never completes, so instead of seeding Hive we override the
/// repository with an in-memory fake and provide empty local settings. This
/// keeps the test deterministic without touching real Hive boxes.
void main() {
  Future<void> pumpChat(
    WidgetTester tester, {
    required List<Article> articles,
    List<ChatThread> threads = const [],
    List<ChatMessageRecord> messages = const [],
    AppSettings? settings,
    RagConversationService? conversation,
    bool failTerminalAssistantWrites = false,
  }) async {
    final chatRepository = _InMemoryChatRepository(
      threads,
      messages,
      failTerminalAssistantWrites: failTerminalAssistantWrites,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // Never completes: keeps settings loading without touching Hive.
          hiveInitProvider.overrideWith((ref) => Completer<void>().future),
          languageIndexProvider.overrideWith((ref) => 2),
          settingsProvider.overrideWith(
            (ref) => _TestSettingsNotifier(ref, settings),
          ),
          if (conversation != null)
            ragConversationServiceProvider.overrideWith((ref) => conversation),
          // In-memory repository: no file I/O, safe inside fake-async.
          articleRepositoryProvider.overrideWith(
            (ref) async => _InMemoryArticleRepository(articles),
          ),
          chatRepositoryProvider.overrideWith((ref) async => chatRepository),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );
    // Resolve the repository future and rebuild.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
  }

  testWidgets('empty knowledge base shows process-articles prompt', (
    tester,
  ) async {
    await pumpChat(tester, articles: []);

    expect(find.text('Explore your Memora'), findsOneWidget);
    expect(find.textContaining('Process some memories first'), findsOneWidget);
  });

  testWidgets('with knowledge available shows example prompts', (tester) async {
    await pumpChat(
      tester,
      articles: [
        Article(
          id: 'k1',
          url: 'https://example.com',
          title: 'AI Basics',
          source: SourcePlatform.web,
          summary: 'An intro to AI.',
          processingStatus: ProcessingStatus.completed,
        ),
      ],
    );

    expect(find.text('Explore your Memora'), findsOneWidget);
    expect(find.textContaining('Try:'), findsOneWidget);
  });

  testWidgets('asking without AI configured shows config message', (
    tester,
  ) async {
    await pumpChat(
      tester,
      articles: [
        Article(
          id: 'k1',
          url: 'https://example.com',
          title: 'AI Basics',
          source: SourcePlatform.web,
          summary: 'An intro to AI.',
          processingStatus: ProcessingStatus.completed,
        ),
      ],
    );

    await tester.enterText(find.byType(TextField), 'what is ai');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.textContaining('configure your AI provider'), findsOneWidget);
  });

  testWidgets(
    'knowledge base plus general can answer with an empty knowledge base',
    (tester) async {
      final conversation = RagConversationService(
        retrieve: (query, articles) async => const RetrievalResult(
          articles: [],
          method: RetrievalMethod.none,
          duration: Duration.zero,
        ),
        complete:
            ({
              required String systemPrompt,
              required String userMessage,
              List<Map<String, String>> history = const [],
              double temperature = 0.3,
              int maxTokens = 800,
            }) async => 'General answer',
        saveLog: (_) async {},
        promptService: _TestChatPromptService(),
      );
      await pumpChat(
        tester,
        articles: [],
        settings: AppSettings(
          chatAiBaseUrl: 'https://example.com/v1',
          chatAiApiKey: 'test-key',
          chatAnswerLengthIndex: 1,
          chatKnowledgeSourceIndex: 1,
        ),
        conversation: conversation,
      );

      await tester.enterText(find.byType(TextField), 'What is an API?');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();

      expect(find.text('General answer'), findsOneWidget);
    },
  );

  testWidgets(
    'empty local knowledge completes the placeholder instead of leaving dots',
    (tester) async {
      final conversation = RagConversationService(
        retrieve: (query, articles) async => const RetrievalResult(
          articles: [],
          method: RetrievalMethod.none,
          duration: Duration.zero,
        ),
        complete:
            ({
              required String systemPrompt,
              required String userMessage,
              List<Map<String, String>> history = const [],
              double temperature = 0.3,
              int maxTokens = 800,
            }) async => 'unused',
        saveLog: (_) async {},
        promptService: _TestChatPromptService(),
      );
      await pumpChat(
        tester,
        articles: [],
        settings: AppSettings(
          chatAiBaseUrl: 'https://example.com/v1',
          chatAiApiKey: 'test-key',
          chatKnowledgeSourceIndex: 0,
        ),
        conversation: conversation,
      );

      await tester.enterText(find.byType(TextField), 'What did I save?');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Your Memora is empty. Process some memories first, then come back to ask questions.',
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.send_rounded), findsOneWidget);
    },
  );

  testWidgets('final message persistence failure releases the input', (
    tester,
  ) async {
    final article = Article(
      id: 'k1',
      url: 'https://example.com',
      title: 'AI Basics',
      source: SourcePlatform.web,
      summary: 'An intro to AI.',
      processingStatus: ProcessingStatus.completed,
    );
    final conversation = RagConversationService(
      retrieve: (query, articles) async => RetrievalResult(
        articles: [article],
        method: RetrievalMethod.keyword,
        duration: Duration.zero,
      ),
      complete:
          ({
            required String systemPrompt,
            required String userMessage,
            List<Map<String, String>> history = const [],
            double temperature = 0.3,
            int maxTokens = 800,
          }) async => 'Answer [1].',
      saveLog: (_) async {},
      promptService: _TestChatPromptService(),
    );
    await pumpChat(
      tester,
      articles: [article],
      settings: AppSettings(
        chatAiBaseUrl: 'https://example.com/v1',
        chatAiApiKey: 'test-key',
      ),
      conversation: conversation,
      failTerminalAssistantWrites: true,
    );

    await tester.enterText(find.byType(TextField), 'What is AI?');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('assistant update failed'), findsWidgets);
    expect(find.byIcon(Icons.send_rounded), findsOneWidget);
  });

  testWidgets('input bar and send button render', (tester) async {
    await pumpChat(tester, articles: []);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.send_rounded), findsOneWidget);
  });

  testWidgets('restores the most recent local chat after rebuilding', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 7, 30);
    final thread = ChatThread(
      id: 'thread-1',
      title: 'Saved chat',
      createdAt: now,
      updatedAt: now,
      lastMessagePreview: 'Saved answer',
    );
    await pumpChat(
      tester,
      articles: [],
      threads: [thread],
      messages: [
        ChatMessageRecord(
          id: 'message-1',
          threadId: thread.id,
          role: ChatMessageRole.user,
          content: 'Saved question',
          createdAt: now,
        ),
        ChatMessageRecord(
          id: 'message-2',
          threadId: thread.id,
          role: ChatMessageRole.assistant,
          content: 'Saved answer',
          createdAt: now.add(const Duration(seconds: 1)),
        ),
      ],
    );

    expect(find.text('Saved question'), findsOneWidget);
    expect(find.text('Saved answer'), findsOneWidget);
    expect(find.byIcon(Icons.menu_rounded), findsOneWidget);
    expect(find.byIcon(Icons.history_rounded), findsNothing);
    expect(find.byIcon(Icons.add_comment_outlined), findsNothing);
  });

  testWidgets('left sidebar creates a new chat and lists saved chats', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 8, 1);
    final thread = ChatThread(
      id: 'thread-1',
      title: 'Saved chat',
      createdAt: now,
      updatedAt: now,
      lastMessagePreview: 'Saved answer',
    );
    await pumpChat(
      tester,
      articles: [],
      threads: [thread],
      messages: [
        ChatMessageRecord(
          id: 'message-1',
          threadId: thread.id,
          role: ChatMessageRole.user,
          content: 'Saved question',
          createdAt: now,
        ),
      ],
    );

    await tester.tap(find.byKey(const ValueKey('chat-sidebar-button')));
    await tester.pumpAndSettle();

    expect(find.text('Chat History'), findsOneWidget);
    expect(find.text('New Chat'), findsOneWidget);
    expect(find.text('Saved chat'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('chat-new-thread-button')));
    await tester.pumpAndSettle();

    expect(find.text('Saved question'), findsNothing);
    expect(find.text('Explore your Memora'), findsOneWidget);
  });

  testWidgets('left sidebar switches and deletes saved chats', (tester) async {
    final now = DateTime.utc(2026, 8, 1);
    final recent = ChatThread(
      id: 'recent',
      title: 'Recent chat',
      createdAt: now,
      updatedAt: now,
      lastMessagePreview: 'Recent answer',
    );
    final older = ChatThread(
      id: 'older',
      title: 'Older chat',
      createdAt: now.subtract(const Duration(days: 1)),
      updatedAt: now.subtract(const Duration(days: 1)),
      lastMessagePreview: 'Older answer',
    );
    await pumpChat(
      tester,
      articles: [],
      threads: [recent, older],
      messages: [
        ChatMessageRecord(
          id: 'recent-message',
          threadId: recent.id,
          role: ChatMessageRole.user,
          content: 'Recent question',
          createdAt: now,
        ),
        ChatMessageRecord(
          id: 'older-message',
          threadId: older.id,
          role: ChatMessageRole.user,
          content: 'Older question',
          createdAt: now.subtract(const Duration(days: 1)),
        ),
      ],
    );

    await tester.tap(find.byKey(const ValueKey('chat-sidebar-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-thread-older')));
    await tester.pumpAndSettle();

    expect(find.text('Older question'), findsOneWidget);
    expect(find.text('Recent question'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('chat-sidebar-button')));
    await tester.pumpAndSettle();
    final olderTile = find.byKey(const ValueKey('chat-thread-older'));
    await tester.tap(
      find.descendant(
        of: olderTile,
        matching: find.byIcon(Icons.delete_outline_rounded),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('chat-thread-older')), findsNothing);
    expect(find.byKey(const ValueKey('chat-thread-recent')), findsOneWidget);
  });
}

class _TestSettingsNotifier extends SettingsNotifier {
  _TestSettingsNotifier(super.ref, [AppSettings? settings]) {
    state = AsyncValue.data(settings ?? AppSettings());
  }
}

class _TestChatPromptService extends PromptService {
  @override
  Future<String> load(String path, [Map<String, String>? vars]) async {
    if (path == 'chat/system.txt') return 'System prompt';
    if (path == 'chat/user.txt') {
      return 'Context: ${vars?['context'] ?? ''}\n'
          'Question: ${vars?['question'] ?? ''}';
    }
    return path;
  }
}

/// In-memory [ArticleRepository] for widget tests — no Hive, no file I/O.
class _InMemoryArticleRepository implements ArticleRepository {
  final List<Article> _articles;
  _InMemoryArticleRepository(this._articles);

  @override
  Future<void> init() async {}

  @override
  List<Article> getAll() =>
      List<Article>.of(_articles)
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  Article? getById(String id) {
    for (final a in _articles) {
      if (a.id == id) return a;
    }
    return null;
  }

  @override
  Future<void> add(Article article) async => _articles.add(article);

  @override
  Future<int> importAll(Iterable<Article> articles) async {
    _articles.addAll(articles);
    return articles.length;
  }

  @override
  Future<void> update(Article article) async {}

  @override
  Future<void> delete(String id) async =>
      _articles.removeWhere((a) => a.id == id);

  @override
  List<Article> search(String query) => getAll();

  @override
  List<Article> filterBySource(String sourceName) => getAll();

  @override
  Future<void> unsetFolder(String folderId) async {}

  @override
  Future<void> unsetFolderBatch(String folderId) async {}
}

class _InMemoryChatRepository implements ChatRepository {
  final Map<String, ChatThread> _threads;
  final Map<String, ChatMessageRecord> _messages;
  final bool failTerminalAssistantWrites;

  _InMemoryChatRepository(
    Iterable<ChatThread> threads,
    Iterable<ChatMessageRecord> messages, {
    this.failTerminalAssistantWrites = false,
  }) : _threads = {for (final thread in threads) thread.id: thread},
       _messages = {for (final message in messages) message.id: message};

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
    if (failTerminalAssistantWrites &&
        message.role == ChatMessageRole.assistant &&
        message.status != ChatMessageStatus.sending) {
      throw StateError('assistant update failed');
    }
    _messages[message.id] = message;
  }

  @override
  Future<void> deleteThread(String id) async {
    _threads.remove(id);
    _messages.removeWhere((_, message) => message.threadId == id);
  }
}
