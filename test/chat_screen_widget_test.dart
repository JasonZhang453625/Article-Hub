import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/models/chat_message_record.dart';
import 'package:memora/data/models/chat_thread.dart';
import 'package:memora/data/models/memory_document.dart';
import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/settings.dart';
import 'package:memora/data/models/source_platform.dart';
import 'package:memora/data/repositories/article_repository.dart';
import 'package:memora/data/repositories/chat_repository.dart';
import 'package:memora/data/services/processing_pipeline.dart';
import 'package:memora/data/services/hosted_agent_service.dart';
import 'package:memora/data/services/prompt_service.dart';
import 'package:memora/data/services/rag_conversation_service.dart';
import 'package:memora/data/services/retrieval_service.dart';
import 'package:memora/data/services/sync_mutation_service.dart';
import 'package:memora/data/services/sync_outbox_service.dart';
import 'package:memora/data/services/sync_shadow_service.dart';
import 'package:memora/features/chat/chat_screen.dart';
import 'package:memora/features/chat/chat_typing_indicator.dart';
import 'package:memora/shared/providers/chat_providers.dart';
import 'package:memora/shared/providers/pipeline_provider.dart';
import 'package:memora/shared/providers/settings_providers.dart';
import 'package:memora/shared/providers/passage_providers.dart';
import 'package:memora/shared/providers/sync_providers.dart';

/// Phase 3.4 widget tests for the Chat screen states.
///
/// `flutter test` runs widget callbacks in a fake-async zone where real Hive
/// file I/O never completes, so instead of seeding Hive we override the
/// repository with an in-memory fake and provide empty local settings. This
/// keeps the test deterministic without touching real Hive boxes.
void main() {
  Future<_InMemoryChatRepository> pumpChat(
    WidgetTester tester, {
    required List<Article> articles,
    List<ChatThread> threads = const [],
    List<ChatMessageRecord> messages = const [],
    AppSettings? settings,
    RagConversationService? conversation,
    bool failTerminalAssistantWrites = false,
    bool webSearchEnabled = false,
    Brightness brightness = Brightness.light,
    int languageIndex = 2,
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
          languageIndexProvider.overrideWith((ref) => languageIndex),
          chatWebSearchEnabledProvider.overrideWith((ref) => webSearchEnabled),
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
        child: MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: const ChatScreen(),
        ),
      ),
    );
    // Resolve the repository future and rebuild.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    return chatRepository;
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

  testWidgets('renders streamed answer text before the stream completes', (
    tester,
  ) async {
    final streamController = StreamController<String>();
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
          }) async => fail('stream completion should be used'),
      completeStream:
          ({
            required String systemPrompt,
            required String userMessage,
            List<Map<String, String>> history = const [],
            double temperature = 0.3,
            int maxTokens = 800,
          }) => streamController.stream,
      saveLog: (_) async {},
      promptService: _TestChatPromptService(),
    );
    await pumpChat(
      tester,
      articles: [],
      settings: AppSettings(
        chatAiBaseUrl: 'https://example.com/v1',
        chatAiApiKey: 'test-key',
        chatKnowledgeSourceIndex: 1,
      ),
      conversation: conversation,
    );

    await tester.enterText(find.byType(TextField), 'stream me');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();

    streamController.add('First');
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('First'), findsOneWidget);
    expect(find.byType(ChatTypingIndicator), findsOneWidget);

    streamController.add(' second');
    streamController.close();
    await tester.pumpAndSettle();

    expect(find.textContaining('First second'), findsOneWidget);
    expect(find.byType(ChatTypingIndicator), findsNothing);
  });

  testWidgets('keeps tools and chat history available while answering', (
    tester,
  ) async {
    final streamController = StreamController<String>();
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
          }) async => fail('stream completion should be used'),
      completeStream:
          ({
            required String systemPrompt,
            required String userMessage,
            List<Map<String, String>> history = const [],
            double temperature = 0.3,
            int maxTokens = 800,
          }) => streamController.stream,
      saveLog: (_) async {},
      promptService: _TestChatPromptService(),
    );
    await pumpChat(
      tester,
      articles: [],
      settings: AppSettings(
        chatAiBaseUrl: 'https://example.com/v1',
        chatAiApiKey: 'test-key',
        chatKnowledgeSourceIndex: 1,
      ),
      conversation: conversation,
    );

    await tester.enterText(find.byType(TextField), 'keep navigating');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    expect(find.textContaining('Thinking'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('chat-tools-button')));
    await tester.pump();
    expect(find.text('Tools'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const ValueKey('chat-sidebar-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Chat History'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('chat-sidebar-close-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await streamController.close();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'working status highlights characters, reveals dots, and rotates',
    (tester) async {
      final streamController = StreamController<String>();
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
            }) async => fail('stream completion should be used'),
        completeStream:
            ({
              required String systemPrompt,
              required String userMessage,
              List<Map<String, String>> history = const [],
              double temperature = 0.3,
              int maxTokens = 800,
            }) => streamController.stream,
        saveLog: (_) async {},
        promptService: _TestChatPromptService(),
      );
      await pumpChat(
        tester,
        articles: [],
        languageIndex: 1,
        settings: AppSettings(
          chatAiBaseUrl: 'https://example.com/v1',
          chatAiApiKey: 'test-key',
          chatKnowledgeSourceIndex: 1,
        ),
        conversation: conversation,
      );

      await tester.enterText(find.byType(TextField), '测试动画');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();

      TextSpan statusSpan() {
        final text = tester.widget<Text>(
          find.byKey(const ValueKey('chat-working-status-text')),
        );
        return text.textSpan! as TextSpan;
      }

      var spans = statusSpan().children!.cast<TextSpan>();
      expect(statusSpan().toPlainText(), '思考中...');
      expect(spans[0].style!.fontWeight, FontWeight.w600);
      expect(spans[0].style!.color, isNot(spans[1].style!.color));
      expect(spans[3].style!.color, Colors.transparent);

      await tester.pump(const Duration(milliseconds: 260));
      spans = statusSpan().children!.cast<TextSpan>();
      expect(spans[1].style!.fontWeight, FontWeight.w600);
      expect(spans[0].style!.fontWeight, FontWeight.w400);

      await tester.pump(const Duration(milliseconds: 520));
      spans = statusSpan().children!.cast<TextSpan>();
      expect(spans[3].style!.color, isNot(Colors.transparent));
      expect(spans[4].style!.color, Colors.transparent);

      await tester.pump(const Duration(milliseconds: 780));
      expect(statusSpan().toPlainText(), '分析中...');

      await streamController.close();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'shows tool calls without reasoning and keeps them beside the final answer',
    (tester) async {
      final releaseTool = Completer<void>();
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
            }) async => fail('Agent stream should be used'),
        agentCompleteStream:
            ({
              required String systemPrompt,
              required String userMessage,
              List<Map<String, String>> history = const [],
              double temperature = 0.3,
              int maxTokens = 800,
              required bool webSearch,
              void Function(HostedAgentEvent event)? onEvent,
            }) async* {
              onEvent?.call(
                const HostedAgentEvent(
                  type: 'tool.call.started',
                  data: {
                    'callId': 'search-1',
                    'tool': 'web_search',
                    'query': '中国人口 最新数据',
                  },
                ),
              );
              await releaseTool.future;
              onEvent?.call(
                const HostedAgentEvent(
                  type: 'tool.call.completed',
                  data: {
                    'callId': 'search-1',
                    'tool': 'web_search',
                    'sourceCount': 3,
                  },
                ),
              );
              yield 'Final sourced answer [w1].';
            },
        saveLog: (_) async {},
        promptService: _TestChatPromptService(),
      );
      await pumpChat(
        tester,
        articles: [],
        settings: AppSettings(
          chatAiBaseUrl: 'https://example.com/v1',
          chatAiApiKey: 'test-key',
          chatKnowledgeSourceIndex: 1,
        ),
        conversation: conversation,
      );

      await tester.enterText(find.byType(TextField), 'Search population');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.textContaining('Searching the web'), findsOneWidget);
      expect(find.textContaining('中国人口 最新数据'), findsOneWidget);
      expect(find.textContaining('thinking'), findsNothing);

      releaseTool.complete();
      await tester.pumpAndSettle();

      expect(find.textContaining('Final sourced answer'), findsOneWidget);
      expect(find.textContaining('Searching the web'), findsNothing);
      expect(find.textContaining('Tool completed'), findsOneWidget);
      expect(find.textContaining('中国人口 最新数据'), findsNothing);
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

  testWidgets(
    'empty local result persists sticky private provenance on both messages',
    (tester) async {
      final createdAt = DateTime.utc(2026, 8, 23);
      final thread = ChatThread(
        id: 'private-thread',
        title: 'Private history',
        createdAt: createdAt,
        updatedAt: createdAt.add(const Duration(seconds: 1)),
      );
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
      final repository = await pumpChat(
        tester,
        articles: [],
        threads: [thread],
        messages: [
          ChatMessageRecord(
            id: 'private-user',
            threadId: thread.id,
            role: ChatMessageRole.user,
            content: 'Private question',
            createdAt: createdAt,
            privateEvidenceUsed: true,
          ),
          ChatMessageRecord(
            id: 'private-assistant',
            threadId: thread.id,
            role: ChatMessageRole.assistant,
            content: 'Private answer',
            createdAt: createdAt.add(const Duration(seconds: 1)),
            privateEvidenceUsed: true,
          ),
        ],
        settings: AppSettings(
          chatAiBaseUrl: 'https://example.com/v1',
          chatAiApiKey: 'test-key',
          chatKnowledgeSourceIndex: 0,
        ),
        conversation: conversation,
      );

      await tester.enterText(find.byType(TextField), 'What did I save next?');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();

      final records = repository.getMessages(thread.id);
      final user = records.singleWhere(
        (message) => message.content == 'What did I save next?',
      );
      final assistant = records.singleWhere((message) => message.isNoResult);
      expect(user.privateEvidenceUsed, isTrue);
      expect(assistant.privateEvidenceUsed, isTrue);
    },
  );

  testWidgets(
    'an unpaired private crash anchor keeps Web off for the next message',
    (tester) async {
      final createdAt = DateTime.utc(2026, 8, 23);
      final thread = ChatThread(
        id: 'crash-anchor-thread',
        title: 'Crash anchor',
        createdAt: createdAt,
        updatedAt: createdAt.add(const Duration(seconds: 1)),
      );
      var webSearches = 0;
      final conversation = RagConversationService(
        retrieve: (query, articles) async => const RetrievalResult(
          articles: [],
          method: RetrievalMethod.none,
          duration: Duration.zero,
        ),
        webSearch: (query, {topK = 5}) async {
          webSearches++;
          return const [];
        },
        complete:
            ({
              required String systemPrompt,
              required String userMessage,
              List<Map<String, String>> history = const [],
              double temperature = 0.3,
              int maxTokens = 800,
            }) async => 'Safe answer.',
        saveLog: (_) async {},
        promptService: _TestChatPromptService(),
      );
      final repository = await pumpChat(
        tester,
        articles: [],
        threads: [thread],
        messages: [
          ChatMessageRecord(
            id: 'crashed-private-user',
            threadId: thread.id,
            role: ChatMessageRole.user,
            content: 'Private source question',
            createdAt: createdAt,
            privateEvidenceUsed: true,
          ),
          ChatMessageRecord(
            id: 'crashed-assistant',
            threadId: thread.id,
            role: ChatMessageRole.assistant,
            content: '',
            createdAt: createdAt.add(const Duration(seconds: 1)),
            status: ChatMessageStatus.interrupted,
          ),
        ],
        settings: AppSettings(
          chatAiBaseUrl: 'https://example.com/v1',
          chatAiApiKey: 'test-key',
          chatKnowledgeSourceIndex: 1,
        ),
        conversation: conversation,
        webSearchEnabled: true,
      );

      await tester.enterText(find.byType(TextField), 'Continue safely');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();

      expect(webSearches, 0);
      expect(find.text('Safe answer.'), findsOneWidget);
      final records = repository.getMessages(thread.id);
      final nextUser = records.singleWhere(
        (message) => message.content == 'Continue safely',
      );
      final nextAssistant = records.singleWhere(
        (message) => message.content == 'Safe answer.',
      );
      expect(nextUser.privateEvidenceUsed, isTrue);
      expect(nextAssistant.privateEvidenceUsed, isTrue);
    },
  );

  testWidgets(
    'retry regenerates the existing answer without duplicating the question',
    (tester) async {
      final article = Article(
        id: 'k1',
        url: 'https://example.com',
        title: 'AI Basics',
        source: SourcePlatform.web,
        summary: 'An intro to AI.',
        processingStatus: ProcessingStatus.completed,
      );
      var completionCalls = 0;
      final completionHistories = <List<Map<String, String>>>[];
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
            }) async {
              completionCalls++;
              completionHistories.add(history);
              if (completionCalls == 1) return 'First answer [1].';
              return 'Second answer [1].';
            },
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
      );

      await tester.enterText(find.byType(TextField), 'What is AI?');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();

      expect(find.text('First answer [1].'), findsOneWidget);
      expect(find.byIcon(Icons.refresh_outlined), findsOneWidget);

      await tester.tap(find.byIcon(Icons.refresh_outlined));
      await tester.pumpAndSettle();

      expect(find.text('Second answer [1].'), findsOneWidget);
      expect(find.text('First answer [1].'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is SelectableText && widget.data == 'What is AI?',
        ),
        findsOneWidget,
      );
      expect(completionCalls, 2);
      expect(completionHistories.last, isEmpty);
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

    expect(find.textContaining('could not finish this answer'), findsWidgets);
    expect(find.byIcon(Icons.send_rounded), findsOneWidget);
  });

  testWidgets('input bar and send button render', (tester) async {
    await pumpChat(tester, articles: []);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.send_rounded), findsOneWidget);
  });

  testWidgets(
    'restores input focus after the tools sheet close animation completes',
    (tester) async {
      await pumpChat(tester, articles: []);

      bool inputHasFocus() =>
          FocusManager.instance.primaryFocus?.debugLabel == 'chat-input';

      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(inputHasFocus(), isTrue);

      await tester.tap(find.byKey(const ValueKey('chat-tools-button')));
      await tester.pump();
      expect(find.text('Tools'), findsOneWidget);
      expect(inputHasFocus(), isFalse);
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      expect(inputHasFocus(), isFalse);

      await tester.pumpAndSettle();
      expect(inputHasFocus(), isTrue);
    },
  );

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

  testWidgets('top controls float without a session-title app bar', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 8, 9);
    final thread = ChatThread(
      id: 'thread-top-chrome',
      title: 'Hidden session title',
      createdAt: now,
      updatedAt: now,
    );
    await pumpChat(
      tester,
      articles: [],
      threads: [thread],
      messages: [
        ChatMessageRecord(
          id: 'top-message',
          threadId: thread.id,
          role: ChatMessageRole.user,
          content: 'Message behind the top fade',
          createdAt: now,
        ),
      ],
    );

    expect(find.byType(AppBar), findsNothing);
    expect(find.text('Hidden session title'), findsNothing);
    expect(find.byKey(const ValueKey('chat-sidebar-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-settings-button')), findsOneWidget);
    expect(
      tester.getCenter(find.byKey(const ValueKey('chat-sidebar-surface'))).dx,
      tester.getCenter(find.byKey(const ValueKey('chat-tools-button'))).dx + 2,
    );
    expect(
      tester.getCenter(find.byKey(const ValueKey('chat-settings-surface'))).dx,
      tester.getCenter(find.byKey(const ValueKey('chat-send-button'))).dx,
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('chat-message-list'))).dy,
      0,
    );
    expect(
      tester
          .getTopLeft(
            find.byKey(const ValueKey('chat-message-reveal-top-message')),
          )
          .dy,
      tester
              .getBottomLeft(find.byKey(const ValueKey('chat-sidebar-surface')))
              .dy +
          12,
    );

    for (final key in const [
      ValueKey('chat-sidebar-surface'),
      ValueKey('chat-settings-surface'),
    ]) {
      final surface = tester.widget<Material>(find.byKey(key));
      expect(surface.color, Colors.white);
      expect(surface.shape, isA<CircleBorder>());
    }

    final fade = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('chat-top-fade')),
    );
    final gradient = (fade.decoration as BoxDecoration).gradient!;
    expect(gradient.colors.first, Colors.white);
    expect(gradient.colors.last.a, 0);
  });

  testWidgets('top fade switches to dark in dark mode', (tester) async {
    await pumpChat(tester, articles: [], brightness: Brightness.dark);

    final fade = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('chat-top-fade')),
    );
    final gradient = (fade.decoration as BoxDecoration).gradient!;
    expect(gradient.colors.first, Colors.black);
    expect(gradient.colors.last.a, 0);

    for (final key in const [
      ValueKey('chat-sidebar-surface'),
      ValueKey('chat-settings-surface'),
    ]) {
      final surface = tester.widget<Material>(find.byKey(key));
      expect(surface.color, Colors.black);
      final shape = surface.shape! as CircleBorder;
      expect(shape.side.color, const Color(0xFFB8C0C8));
      expect(shape.side.width, 1);
    }
  });

  testWidgets(
    'restores a partial killed answer and animates the loaded message',
    (tester) async {
      final now = DateTime.utc(2026, 7, 30);
      final thread = ChatThread(
        id: 'thread-interrupted',
        title: 'Interrupted chat',
        createdAt: now,
        updatedAt: now,
      );
      await pumpChat(
        tester,
        articles: [],
        threads: [thread],
        messages: [
          ChatMessageRecord(
            id: 'interrupted-question',
            threadId: thread.id,
            role: ChatMessageRole.user,
            content: 'Continue this answer',
            createdAt: now,
          ),
          ChatMessageRecord(
            id: 'interrupted-answer',
            threadId: thread.id,
            role: ChatMessageRole.assistant,
            content: 'This part was saved before the app was killed.',
            createdAt: now.add(const Duration(seconds: 1)),
            query: 'Continue this answer',
            status: ChatMessageStatus.interrupted,
          ),
        ],
      );

      expect(
        find.text('This part was saved before the app was killed.'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
      expect(
        find.byKey(const ValueKey('chat-message-reveal-interrupted-answer')),
        findsOneWidget,
      );
      expect(find.byType(AnimatedSize), findsOneWidget);
    },
  );

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
    expect(
      find.descendant(of: find.byType(Drawer), matching: find.byType(Divider)),
      findsNothing,
    );
    final savedTile = tester.widget<ListTile>(
      find.byKey(const ValueKey('chat-thread-thread-1')),
    );
    expect(savedTile.dense, isTrue);
    expect(savedTile.visualDensity, const VisualDensity(vertical: -1));

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

  testWidgets('history selection animates after the drawer has closed', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 8, 30);
    final recent = ChatThread(
      id: 'animated-recent',
      title: 'Animated recent',
      createdAt: now,
      updatedAt: now,
    );
    final older = ChatThread(
      id: 'animated-older',
      title: 'Animated older',
      createdAt: now.subtract(const Duration(days: 1)),
      updatedAt: now.subtract(const Duration(days: 1)),
    );
    await pumpChat(
      tester,
      articles: [],
      threads: [recent, older],
      messages: [
        ChatMessageRecord(
          id: 'animated-recent-message',
          threadId: recent.id,
          role: ChatMessageRole.user,
          content: 'Current conversation',
          createdAt: now,
        ),
        ChatMessageRecord(
          id: 'animated-older-message',
          threadId: older.id,
          role: ChatMessageRole.assistant,
          content: 'Selected conversation',
          createdAt: now.subtract(const Duration(days: 1)),
        ),
      ],
    );

    await tester.tap(find.byKey(const ValueKey('chat-sidebar-button')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('chat-thread-animated-older')),
    );
    await tester.pump();

    // The conversation does not change underneath the closing drawer.
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Current conversation'), findsOneWidget);
    expect(find.text('Selected conversation'), findsNothing);

    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('Selected conversation'), findsOneWidget);
    final opacityFinder = find.byKey(
      const ValueKey('chat-conversation-opacity-animated-older'),
    );
    expect(tester.widget<Opacity>(opacityFinder).opacity, 0);

    await tester.pump(const Duration(milliseconds: 160));
    final midOpacity = tester.widget<Opacity>(opacityFinder).opacity;
    expect(midOpacity, greaterThan(0));
    expect(midOpacity, lessThan(1));

    await tester.pumpAndSettle();
    expect(tester.widget<Opacity>(opacityFinder).opacity, 1);
  });

  testWidgets('long press renames and pins a saved chat', (tester) async {
    final now = DateTime.utc(2026, 8, 9);
    final recent = ChatThread(
      id: 'recent-actions',
      title: 'Recent chat',
      createdAt: now,
      updatedAt: now,
    );
    final older = ChatThread(
      id: 'older-actions',
      title: 'Older chat',
      createdAt: now.subtract(const Duration(days: 1)),
      updatedAt: now.subtract(const Duration(days: 1)),
    );
    await pumpChat(tester, articles: [], threads: [recent, older]);
    await tester.tap(find.byKey(const ValueKey('chat-sidebar-button')));
    await tester.pumpAndSettle();

    final olderTile = find.byKey(const ValueKey('chat-thread-older-actions'));
    await tester.longPress(olderTile);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-thread-rename-action')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('chat-thread-rename-field')),
      'Renamed chat',
    );
    await tester.tap(find.byKey(const ValueKey('chat-thread-rename-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Renamed chat'), findsOneWidget);

    await tester.longPress(olderTile);
    await tester.pumpAndSettle();
    expect(find.text('Pin'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat-thread-pin-action')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('chat-thread-pin-older-actions')),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(olderTile).dy,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(const ValueKey('chat-thread-recent-actions')),
            )
            .dy,
      ),
    );
  });

  testWidgets('chat history list stays clipped at its top boundary', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 8, 9);
    final threads = List.generate(
      16,
      (index) => ChatThread(
        id: 'overflow-$index',
        title: 'Chat $index',
        createdAt: now.subtract(Duration(minutes: index)),
        updatedAt: now.subtract(Duration(minutes: index)),
      ),
    );
    await pumpChat(tester, articles: [], threads: threads);
    await tester.tap(find.byKey(const ValueKey('chat-sidebar-button')));
    await tester.pumpAndSettle();

    final list = find.byKey(const ValueKey('chat-thread-list'));
    final first = find.byKey(const ValueKey('chat-thread-overflow-0'));
    await tester.drag(list, const Offset(0, 220));
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(first).dy,
      greaterThanOrEqualTo(tester.getTopLeft(list).dy),
    );
  });

  testWidgets('assistant answer shows a save button and saving adds a memory', (
    tester,
  ) async {
    final articles = <Article>[];
    final repository = _InMemoryArticleRepository(articles);
    final thread = ChatThread(
      id: 't1',
      title: 'Chat',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    final messages = [
      ChatMessageRecord(
        id: 'a1',
        threadId: thread.id,
        role: ChatMessageRole.assistant,
        content: 'Here is a useful answer.',
        createdAt: DateTime.now(),
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hiveInitProvider.overrideWith((ref) => Completer<void>().future),
          languageIndexProvider.overrideWith((ref) => 2),
          settingsProvider.overrideWith(
            (ref) => _TestSettingsNotifier(ref, AppSettings()),
          ),
          articleRepositoryProvider.overrideWith((ref) async => repository),
          chatRepositoryProvider.overrideWith(
            (ref) async => _InMemoryChatRepository([thread], messages),
          ),
          // No-op sync layer: article.add() enqueues a cloud mutation.
          syncMutationProvider.overrideWith((ref) => _NoopSyncMutation()),
          // Fake pipeline: records the answer as full-text memory immediately.
          processingPipelineProvider.overrideWith((ref) {
            return _FakeProcessingPipeline(ref.read(articlesProvider.notifier));
          }),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();

    final saveButton = find.byKey(const ValueKey('chat-save-button-a1'));
    expect(saveButton, findsOneWidget);
    expect(
      saveButton.hitTestable(),
      findsOneWidget,
      reason: 'save button must be tappable',
    );
    expect(find.byIcon(Icons.bookmark_add_outlined), findsOneWidget);

    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    final exception = tester.takeException();
    expect(exception, isNull, reason: 'save flow must not throw');
    // Any snackbar (success or failure) proves the save callback ran.
    expect(
      find.byType(SnackBar),
      findsWidgets,
      reason: 'save must produce a snackbar',
    );
    final snackBarText = tester
        .widget<Text>(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.byType(Text),
          ),
        )
        .data;
    expect(
      snackBarText,
      'Answer saved to Memora',
      reason: 'success snackbar should appear after saving, got: $snackBarText',
    );

    expect(
      articles.any((a) => a.url == 'memora://chat/a1'),
      isTrue,
      reason: 'saving an answer must create a full-text memory article',
    );
    final saved = articles.firstWhere((a) => a.url == 'memora://chat/a1');
    expect(saved.isFullText, isTrue);
    expect(saved.processingStatus, ProcessingStatus.completed);
    // No question text on this record, so the app title is the fallback.
    expect(saved.title, 'Memora');
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

/// No-op cloud mutation sink for tests that exercise article.add().
class _NoopSyncMutation extends SyncMutationService {
  _NoopSyncMutation()
    : super(outbox: SyncOutboxService(), shadow: SyncShadowService());

  @override
  Future<void> upsert({
    String? accountId,
    required String collection,
    required String itemId,
    required Map<String, dynamic> payload,
    int? baseEntityRevision,
    Map<String, dynamic>? basePayload,
  }) async {}
}

/// Pipeline double for the save-answer test: records the injected content as
/// a completed full-text memory without touching AI/embedding services.
class _FakeProcessingPipeline extends ProcessingPipeline {
  _FakeProcessingPipeline(ArticlesNotifier articles)
    : super(
        articles: articles,
        getSettings: () => null,
        getFolders: () => const [],
      );

  @override
  Future<Article?> processFile(
    Article article,
    String content, {
    bool fullText = false,
    String? fullTextFormat,
    MemoryGeneration? fullTextGeneration,
  }) async {
    return article.copyWith(
      memory: MemoryDocument.fullText(body: content, format: 'plain'),
      isFullText: true,
      processingStatus: ProcessingStatus.completed,
      processingStage: Article.clearValue,
      lastProcessedAt: DateTime.now(),
    );
  }
}

class _InMemoryChatRepository implements ChatRepository {
  final Map<String, ChatThread> _threads;
  final Map<String, ChatMessageRecord> _messages;
  final Map<String, PendingChatThreadDeletion> _deletions = {};
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
    final threads = _threads.values.toList()..sort(compareChatThreads);
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
  Future<ChatThread?> updateThreadIfExists(
    String id, {
    String? title,
    bool? isPinned,
    DateTime? activityAt,
    String? lastMessagePreview,
  }) async {
    final current = _threads[id];
    if (current == null) return null;
    var updated = current.copyWith(title: title, isPinned: isPinned);
    if (activityAt != null && !activityAt.isBefore(current.updatedAt)) {
      updated = updated.copyWith(
        updatedAt: activityAt,
        lastMessagePreview: lastMessagePreview,
      );
    }
    _threads[id] = updated;
    return updated;
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
  Future<ChatMessageRecord?> markAiRunCreateStarted({
    required String messageId,
    required String expectedRequestKey,
    required String ownerUserId,
  }) async {
    final current = _messages[messageId];
    if (current == null ||
        current.status != ChatMessageStatus.sending ||
        current.aiRunId != null ||
        current.aiRunRequestKey != expectedRequestKey ||
        (current.aiRunOwnerUserId != null &&
            current.aiRunOwnerUserId != ownerUserId)) {
      return null;
    }
    final updated = current.copyWith(aiRunOwnerUserId: ownerUserId);
    await putMessage(updated);
    return updated;
  }

  @override
  Future<ChatMessageRecord?> attachAiRunToPendingMessage({
    required String messageId,
    required String? expectedRequestKey,
    required String? expectedOwnerUserId,
    required String runId,
  }) async {
    final current = _messages[messageId];
    if (current == null ||
        !_threads.containsKey(current.threadId) ||
        current.aiRunRequestKey != expectedRequestKey ||
        current.aiRunOwnerUserId != expectedOwnerUserId ||
        (current.status != ChatMessageStatus.sending &&
            current.errorCode != 'hosted_cancel_requested')) {
      return null;
    }
    final updated = current.copyWith(aiRunId: runId, aiRunEventSeq: 0);
    try {
      await putMessage(updated);
    } on StateError {
      return null;
    }
    return updated;
  }

  @override
  Future<ChatMessageRecord?> completeAiRunReconciliationNotFound({
    required String messageId,
    required String expectedRequestKey,
    required String ownerUserId,
  }) async {
    final current = _messages[messageId];
    if (current == null ||
        current.aiRunId != null ||
        current.aiRunRequestKey != expectedRequestKey ||
        current.aiRunOwnerUserId != ownerUserId) {
      return null;
    }
    final updated = current.copyWith(
      status: ChatMessageStatus.interrupted,
      errorCode: current.errorCode == 'hosted_cancel_requested'
          ? 'hosted_run_cancelled'
          : 'hosted_run_not_found',
    );
    _messages[messageId] = updated;
    return updated;
  }

  @override
  Future<ChatMessageRecord?> requestAiRunCancellation({
    required String messageId,
    required String? expectedRequestKey,
  }) async {
    final current = _messages[messageId];
    if (current == null || current.aiRunRequestKey != expectedRequestKey) {
      return null;
    }
    final updated = current.copyWith(
      status: ChatMessageStatus.interrupted,
      errorCode: 'hosted_cancel_requested',
    );
    _messages[messageId] = updated;
    return updated;
  }

  @override
  Future<ChatMessageRecord?> completeUncreatedAiRunCancellation({
    required String messageId,
    required String? expectedRequestKey,
  }) async {
    final current = _messages[messageId];
    if (current == null ||
        current.aiRunRequestKey != expectedRequestKey ||
        current.aiRunId != null) {
      return null;
    }
    final updated = current.copyWith(
      status: ChatMessageStatus.interrupted,
      errorCode: 'hosted_run_cancelled',
    );
    _messages[messageId] = updated;
    return updated;
  }

  @override
  Future<void> deleteMessage(String id) async {
    _messages.remove(id);
  }

  @override
  List<PendingChatThreadDeletion> getPendingThreadDeletions() =>
      List.unmodifiable(_deletions.values);

  @override
  Future<PendingChatThreadDeletion> queueAiRunCancellation(
    String threadId,
    String runId, {
    String? ownerUserId,
  }) async {
    final existing = _deletions[threadId];
    final runIds = {...?existing?.aiRunIdsToCancel, runId}.toList()..sort();
    final runOwners = <String, String>{
      ...?existing?.aiRunOwnerUserIds,
      runId: ?ownerUserId,
    };
    final updated = PendingChatThreadDeletion(
      threadId: threadId,
      attachmentIds: existing?.attachmentIds ?? const [],
      aiRunIdsToCancel: runIds,
      aiRunOwnerUserIds: runOwners,
      aiRunLookups: existing?.aiRunLookups ?? const [],
      dataDeleted: true,
      revision: (existing?.revision ?? 0) + 1,
      canAcknowledge: (existing?.canAcknowledge ?? true) && ownerUserId != null,
    );
    _deletions[threadId] = updated;
    return updated;
  }

  @override
  Future<PendingChatThreadDeletion?> completeAiRunCancellation(
    String threadId,
    String runId,
  ) async {
    final existing = _deletions[threadId];
    if (existing == null) return null;
    final updated = PendingChatThreadDeletion(
      threadId: threadId,
      attachmentIds: existing.attachmentIds,
      aiRunIdsToCancel: existing.aiRunIdsToCancel
          .where((id) => id != runId)
          .toList(),
      aiRunOwnerUserIds: Map<String, String>.from(existing.aiRunOwnerUserIds)
        ..remove(runId),
      aiRunLookups: existing.aiRunLookups,
      dataDeleted: existing.dataDeleted,
      revision: existing.revision + 1,
      canAcknowledge: existing.canAcknowledge,
    );
    _deletions[threadId] = updated;
    return updated;
  }

  @override
  Future<PendingChatThreadDeletion?> resolveAiRunLookup(
    String threadId, {
    required String ownerUserId,
    required String requestKey,
    String? runId,
  }) async {
    final existing = _deletions[threadId];
    if (existing == null) return null;
    final updated = PendingChatThreadDeletion(
      threadId: threadId,
      attachmentIds: existing.attachmentIds,
      aiRunIdsToCancel: {...existing.aiRunIdsToCancel, ?runId}.toList(),
      aiRunOwnerUserIds: {...existing.aiRunOwnerUserIds, ?runId: ownerUserId},
      aiRunLookups: existing.aiRunLookups
          .where(
            (item) =>
                item.ownerUserId != ownerUserId ||
                item.requestKey != requestKey,
          )
          .toList(),
      dataDeleted: existing.dataDeleted,
      revision: existing.revision + 1,
      canAcknowledge: existing.canAcknowledge,
    );
    _deletions[threadId] = updated;
    return updated;
  }

  @override
  Future<void> completeThreadDeletion(
    String id, {
    required int expectedRevision,
  }) async {
    _deletions.remove(id);
  }

  @override
  Future<PendingChatThreadDeletion> deleteThread(String id) async {
    final runIds =
        _messages.values
            .where(
              (message) =>
                  message.threadId == id &&
                  message.aiRunId != null &&
                  (message.status == ChatMessageStatus.sending ||
                      message.errorCode == 'hosted_cancel_requested'),
            )
            .map((message) => message.aiRunId!)
            .toSet()
            .toList()
          ..sort();
    final runOwners = <String, String>{};
    var canAcknowledge = true;
    for (final message in _messages.values.where(
      (message) => message.threadId == id && runIds.contains(message.aiRunId),
    )) {
      final owner = message.aiRunOwnerUserId;
      if (owner == null) {
        canAcknowledge = false;
      } else {
        runOwners[message.aiRunId!] = owner;
      }
    }
    final lookups = _messages.values
        .where(
          (message) =>
              message.threadId == id &&
              message.aiRunId == null &&
              message.aiRunOwnerUserId != null &&
              message.aiRunRequestKey != null &&
              (message.status == ChatMessageStatus.sending ||
                  message.errorCode == 'hosted_cancel_requested'),
        )
        .map(
          (message) => PendingAiRunLookup(
            ownerUserId: message.aiRunOwnerUserId!,
            requestKey: message.aiRunRequestKey!,
          ),
        )
        .toList();
    _threads.remove(id);
    _messages.removeWhere((_, message) => message.threadId == id);
    final deletion = PendingChatThreadDeletion(
      threadId: id,
      aiRunIdsToCancel: runIds,
      aiRunOwnerUserIds: runOwners,
      aiRunLookups: lookups,
      dataDeleted: true,
      revision: 1,
      canAcknowledge: canAcknowledge,
    );
    _deletions[id] = deletion;
    return deletion;
  }
}
