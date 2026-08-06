import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/models/chat_message_record.dart';
import 'package:memora/data/models/chat_thread.dart';
import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/settings.dart';
import 'package:memora/data/repositories/article_repository.dart';
import 'package:memora/data/repositories/chat_repository.dart';
import 'package:memora/data/services/prompt_service.dart';
import 'package:memora/data/services/rag_conversation_service.dart';
import 'package:memora/data/services/retrieval_service.dart';
import 'package:memora/features/chat/chat_screen.dart';
import 'package:memora/features/chat/chat_typing_indicator.dart';
import 'package:memora/shared/providers/chat_providers.dart';
import 'package:memora/shared/providers/passage_providers.dart';
import 'package:memora/shared/providers/settings_providers.dart';

/// Background/foreground lifecycle regression tests.
///
/// Root cause under test: the RAG answer is a single non-streaming HTTP
/// future. When the OS suspends the app (background) the in-flight request is
/// killed, but `ChatScreen` had no `didChangeAppLifecycleState` handler, so on
/// resume the UI stayed stuck: the placeholder stayed `sending`, the typing
/// indicator kept animating and the input bar stayed disabled (up to the 60s
/// network timeout, or forever if a sub-future hangs).
void main() {
  Future<void> pumpChat(
    WidgetTester tester, {
    required List<Article> articles,
    RagConversationService? conversation,
    List<ChatThread> threads = const [],
    List<ChatMessageRecord> messages = const [],
  }) async {
    final chatRepository = _InMemoryChatRepository(threads, messages);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // Never completes: keeps settings loading without touching Hive.
          hiveInitProvider.overrideWith((ref) => Completer<void>().future),
          languageIndexProvider.overrideWith((ref) => 2),
          settingsProvider.overrideWith(
            (ref) => _TestSettingsNotifier(
              ref,
              AppSettings(
                aiBaseUrl: 'https://example.com/v1',
                aiApiKey: 'test-key',
                chatKnowledgeSourceIndex: 1,
              ),
            ),
          ),
          if (conversation != null)
            ragConversationServiceProvider.overrideWith(
              (ref) => conversation,
            ),
          articleRepositoryProvider.overrideWith(
            (ref) async => _InMemoryArticleRepository(articles),
          ),
          chatRepositoryProvider.overrideWith((ref) async => chatRepository),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
  }

  RagConversationService neverCompletingConversation() {
    return RagConversationService(
      retrieve: (query, articles) async => const RetrievalResult(
        articles: [],
        method: RetrievalMethod.none,
        duration: Duration.zero,
      ),
      // Simulates an LLM call that was killed by the OS while the app was
      // suspended: the future never completes.
      complete: ({
        required String systemPrompt,
        required String userMessage,
        List<Map<String, String>> history = const [],
        double temperature = 0.3,
        int maxTokens = 800,
      }) => Completer<String?>().future,
      saveLog: (_) async {},
      promptService: _TestChatPromptService(),
    );
  }

  testWidgets(
    'backgrounding mid-answer must recover as interrupted on resume, '
    'not stay stuck on the typing indicator',
    (tester) async {
      await pumpChat(
        tester,
        articles: [],
        conversation: neverCompletingConversation(),
      );

      await tester.enterText(find.byType(TextField), 'background me');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump(const Duration(milliseconds: 100));

      // The answer is in flight: typing indicator visible, send disabled.
      expect(find.byType(ChatTypingIndicator), findsOneWidget);
      expect(find.byIcon(Icons.send_rounded), findsNothing);

      // App goes to the background while the answer is generating.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(milliseconds: 100));

      // User returns to the app.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      // MUST NOT stay stuck: the stuck placeholder becomes the interrupted
      // card (one-tap retry) and the input is usable again.
      expect(find.byType(ChatTypingIndicator), findsNothing);
      expect(
        find.textContaining('interrupted'),
        findsOneWidget,
        reason: 'the interrupted card should be offered after resume',
      );
      expect(
        find.byIcon(Icons.send_rounded),
        findsOneWidget,
        reason: 'the send button must be re-enabled after resume',
      );
    },
  );

  testWidgets(
    'a late completion arriving after interruption must not clobber '
    'the recovered state',
    (tester) async {
      final gate = Completer<String?>();
      final conversation = RagConversationService(
        retrieve: (query, articles) async => const RetrievalResult(
          articles: [],
          method: RetrievalMethod.none,
          duration: Duration.zero,
        ),
        complete: ({
          required String systemPrompt,
          required String userMessage,
          List<Map<String, String>> history = const [],
          double temperature = 0.3,
          int maxTokens = 800,
        }) => gate.future,
        saveLog: (_) async {},
        promptService: _TestChatPromptService(),
      );
      await pumpChat(tester, articles: [], conversation: conversation);

      await tester.enterText(find.byType(TextField), 'background me');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(ChatTypingIndicator), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(milliseconds: 100));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 100));

      // The dead request finally "answers" long after we recovered.
      gate.complete('Late zombie answer');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Late zombie answer'), findsNothing);
      expect(find.textContaining('interrupted'), findsOneWidget);
    },
  );
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

  _InMemoryChatRepository(
    Iterable<ChatThread> threads,
    Iterable<ChatMessageRecord> messages,
  ) : _threads = {for (final thread in threads) thread.id: thread},
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
    _messages[message.id] = message;
  }

  @override
  Future<void> deleteThread(String id) async {
    _threads.remove(id);
    _messages.removeWhere((_, message) => message.threadId == id);
  }
}
