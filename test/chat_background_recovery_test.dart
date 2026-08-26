import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/models/chat_message_record.dart';
import 'package:memora/data/models/chat_thread.dart';
import 'package:memora/data/models/ai_image_input.dart';
import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/settings.dart';
import 'package:memora/data/repositories/article_repository.dart';
import 'package:memora/data/repositories/chat_repository.dart';
import 'package:memora/data/services/auth_service.dart';
import 'package:memora/data/services/prompt_service.dart';
import 'package:memora/data/services/hosted_agent_service.dart';
import 'package:memora/data/services/rag_conversation_service.dart';
import 'package:memora/data/services/retrieval_service.dart';
import 'package:memora/features/chat/chat_screen.dart';
import 'package:memora/features/chat/chat_typing_indicator.dart';
import 'package:memora/shared/providers/chat_providers.dart';
import 'package:memora/shared/providers/auth_provider.dart';
import 'package:memora/shared/providers/passage_providers.dart';
import 'package:memora/shared/providers/settings_providers.dart';

final _hostedAgentAvailabilityProvider = StateProvider<HostedAgentService?>(
  (ref) => null,
);

final _testAuthSession = AuthSession(
  accessToken: 'header.payload.signature',
  refreshToken: 'refresh-user-1',
  refreshTokenExpiresAt: null,
  user: const AuthUser(
    id: 'user-1',
    email: 'user-1@example.com',
    displayName: null,
    status: 'active',
    plan: 'free',
    storageUsedBytes: '0',
  ),
  device: const AuthDevice(
    id: 'device-1',
    userId: 'user-1',
    deviceName: 'Test device',
    platform: 'test',
    appVersion: null,
  ),
);

/// Background/foreground lifecycle regression tests.
///
/// The chat request is a persisted streaming generation. A normal switch to
/// another app must not turn that generation into an interrupted answer on
/// resume: the Dart stream may still complete while the Flutter activity is
/// covered. If Android kills the process, the persisted `sending` record is
/// recovered on the next app launch by the chat-session provider.
void main() {
  Future<_InMemoryChatRepository> pumpChat(
    WidgetTester tester, {
    required List<Article> articles,
    RagConversationService? conversation,
    List<ChatThread> threads = const [],
    List<ChatMessageRecord> messages = const [],
    HostedAgentService? hostedAgent,
    bool dynamicHostedAgent = false,
    _InMemoryChatRepository? chatRepository,
    HostedAgentRunCanceller? runCanceller,
  }) async {
    final repository =
        chatRepository ?? _InMemoryChatRepository(threads, messages);
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
                chatAiBaseUrl: 'https://example.com/v1',
                chatAiApiKey: 'test-key',
                chatKnowledgeSourceIndex: 1,
              ),
            ),
          ),
          if (conversation != null)
            ragConversationServiceProvider.overrideWith((ref) => conversation),
          if (dynamicHostedAgent)
            hostedAgentServiceProvider.overrideWith(
              (ref) => ref.watch(_hostedAgentAvailabilityProvider),
            )
          else if (hostedAgent != null)
            hostedAgentServiceProvider.overrideWith((ref) => hostedAgent),
          articleRepositoryProvider.overrideWith(
            (ref) async => _InMemoryArticleRepository(articles),
          ),
          chatRepositoryProvider.overrideWith((ref) async => repository),
          if (runCanceller != null)
            currentSessionProvider.overrideWithValue(_testAuthSession),
          if (runCanceller != null)
            hostedAgentRunCancellerProvider.overrideWithValue(runCanceller),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    return repository;
  }

  Future<void> pumpUntil(WidgetTester tester, bool Function() condition) async {
    for (var i = 0; i < 20 && !condition(); i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
  }

  RagConversationService gatedConversation(Completer<String?> gate) {
    return RagConversationService(
      retrieve: (query, articles) async => const RetrievalResult(
        articles: [],
        method: RetrievalMethod.none,
        duration: Duration.zero,
      ),
      // Simulates an LLM call that continues while the app is covered by
      // another app and completes after the user returns.
      complete:
          ({
            required String systemPrompt,
            required String userMessage,
            List<Map<String, String>> history = const [],
            double temperature = 0.3,
            int maxTokens = 800,
          }) => gate.future,
      completeStream:
          ({
            required String systemPrompt,
            required String userMessage,
            List<Map<String, String>> history = const [],
            double temperature = 0.3,
            int maxTokens = 800,
          }) => gate.future.asStream().map((value) => value ?? ''),
      saveLog: (_) async {},
      promptService: _TestChatPromptService(),
    );
  }

  RagConversationService durableConversation(HostedAgentService hostedAgent) {
    return RagConversationService(
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
      agentRunStream:
          ({
            required String systemPrompt,
            required String userMessage,
            required String userQuestion,
            required images,
            List<Map<String, String>> history = const [],
            double temperature = 0.3,
            int maxTokens = 800,
            required bool webSearch,
            void Function(HostedAgentEvent event)? onEvent,
            FutureOr<void> Function(String runId)? onRunCreated,
            String? idempotencyKey,
          }) => hostedAgent.chatStream(
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            userQuestion: userQuestion,
            images: images,
            history: history,
            temperature: temperature,
            maxTokens: maxTokens,
            webSearch: webSearch,
            onEvent: onEvent,
            onRunCreated: onRunCreated,
            idempotencyKey: idempotencyKey ?? 'test-durable-run',
          ),
      agentCompletionError: () => hostedAgent.lastError,
      saveLog: (_) async {},
      promptService: _TestChatPromptService(),
    );
  }

  testWidgets(
    'backgrounding mid-answer keeps the request alive until it completes',
    (tester) async {
      final gate = Completer<String?>();
      await pumpChat(
        tester,
        articles: [],
        conversation: gatedConversation(gate),
      );

      await tester.enterText(find.byType(TextField), 'background me');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump(const Duration(milliseconds: 100));

      // The answer is in flight: working indicator visible, send disabled.
      expect(find.textContaining('Thinking'), findsOneWidget);
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

      // Returning to the app must not discard the in-flight request.
      expect(find.textContaining('Thinking'), findsOneWidget);
      expect(find.byIcon(Icons.send_rounded), findsNothing);

      gate.complete('Completed while the app was covered');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Completed while the app was covered'), findsOneWidget);
      expect(find.byIcon(Icons.send_rounded), findsOneWidget);
    },
  );

  testWidgets('a late completion arriving after resume is accepted', (
    tester,
  ) async {
    final gate = Completer<String?>();
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
          }) => gate.future,
      completeStream:
          ({
            required String systemPrompt,
            required String userMessage,
            List<Map<String, String>> history = const [],
            double temperature = 0.3,
            int maxTokens = 800,
          }) => gate.future.asStream().map((value) => value ?? ''),
      saveLog: (_) async {},
      promptService: _TestChatPromptService(),
    );
    await pumpChat(tester, articles: [], conversation: conversation);

    await tester.enterText(find.byType(TextField), 'background me');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Thinking'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 100));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 100));

    // The request finally answers after the app has returned to the foreground.
    gate.complete('Late zombie answer');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Late zombie answer'), findsOneWidget);
    expect(find.textContaining('Thinking'), findsNothing);
  });

  testWidgets('a live durable run is not resumed by rebuild or lifecycle', (
    tester,
  ) async {
    final hostedAgent = _GatedHostedAgentService();
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
      agentRunStream:
          ({
            required String systemPrompt,
            required String userMessage,
            required String userQuestion,
            required images,
            List<Map<String, String>> history = const [],
            double temperature = 0.3,
            int maxTokens = 800,
            required bool webSearch,
            void Function(HostedAgentEvent event)? onEvent,
            FutureOr<void> Function(String runId)? onRunCreated,
            String? idempotencyKey,
          }) => hostedAgent.chatStream(
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            userQuestion: userQuestion,
            images: images,
            history: history,
            temperature: temperature,
            maxTokens: maxTokens,
            webSearch: webSearch,
            onEvent: onEvent,
            onRunCreated: onRunCreated,
            idempotencyKey: idempotencyKey,
          ),
      agentCompletionError: () => hostedAgent.lastError,
      saveLog: (_) async {},
      promptService: _TestChatPromptService(),
    );
    await pumpChat(
      tester,
      articles: [],
      conversation: conversation,
      hostedAgent: hostedAgent,
    );

    await tester.enterText(find.byType(TextField), 'one durable run');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump(const Duration(milliseconds: 100));
    expect(hostedAgent.chatCalls, 1);
    expect(hostedAgent.resumeCalls, 0);

    await tester.pump(const Duration(milliseconds: 100));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 100));
    expect(hostedAgent.chatCalls, 1);
    expect(hostedAgent.resumeCalls, 0);

    hostedAgent.complete();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('single live answer'), findsOneWidget);
    expect(hostedAgent.chatCalls, 1);
    expect(hostedAgent.resumeCalls, 0);
  });

  testWidgets(
    'a live SSE transport failure stays pending and resumes the same run',
    (tester) async {
      final hostedAgent = _TransportInterruptedHostedAgentService();
      final repository = await pumpChat(
        tester,
        articles: [],
        conversation: durableConversation(hostedAgent),
        hostedAgent: hostedAgent,
      );

      await tester.enterText(find.byType(TextField), 'resume this run');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await pumpUntil(tester, () => hostedAgent.resumeCalls == 1);

      final thread = repository.getThreads().single;
      final pending = repository
          .getMessages(thread.id)
          .singleWhere((message) => message.role == ChatMessageRole.assistant);
      expect(pending.status, ChatMessageStatus.sending);
      expect(pending.aiRunId, 'transport-run');
      expect(find.textContaining('Hosted Agent request failed'), findsNothing);

      hostedAgent.completeResume();
      await pumpUntil(
        tester,
        () =>
            repository.getMessage(pending.id)?.status ==
            ChatMessageStatus.completed,
      );

      final completed = repository.getMessage(pending.id);
      expect(completed?.content, 'answer after reconnect');
      expect(completed?.aiRunId, 'transport-run');
      expect(completed?.aiRunEventSeq, 6);
    },
  );

  testWidgets('recovery finalizer persists only cited web sources', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 8, 9, 10);
    final thread = ChatThread(
      id: 'citation-thread',
      title: 'Citation recovery',
      createdAt: now,
      updatedAt: now,
    );
    final pending = ChatMessageRecord(
      id: 'citation-answer',
      threadId: thread.id,
      role: ChatMessageRole.assistant,
      content: 'partial answer',
      createdAt: now,
      status: ChatMessageStatus.sending,
      webUrls: const ['https://stale.example'],
      aiRunId: 'run-citations',
      aiRunEventSeq: 3,
    );
    final hostedAgent = _RecoveryHostedAgentService(
      answer: 'Recovered answer [w2] [w99]',
      eventSeq: 9,
      sources: const [
        HostedAgentSource(
          id: 'w1',
          title: 'Unused',
          url: 'https://unused.example',
          content: 'unused source',
          score: 0.7,
        ),
        HostedAgentSource(
          id: 'w2',
          title: 'Cited',
          url: 'https://cited.example',
          content: 'cited source',
          score: 0.9,
        ),
      ],
    );

    final repository = await pumpChat(
      tester,
      articles: [],
      threads: [thread],
      messages: [pending],
      hostedAgent: hostedAgent,
    );
    await pumpUntil(
      tester,
      () =>
          repository.getMessage(pending.id)?.status ==
          ChatMessageStatus.completed,
    );

    final recovered = repository.getMessage(pending.id);
    expect(hostedAgent.resumeRunIds, ['run-citations']);
    expect(hostedAgent.resumeAfterEventSeqs, [3]);
    expect(recovered?.content, 'Recovered answer [w2] [w99]');
    expect(recovered?.status, ChatMessageStatus.completed);
    expect(recovered?.webUrls, ['https://cited.example']);
    expect(recovered?.method, 'web');
    expect(recovered?.aiRunEventSeq, 9);
  });

  testWidgets(
    'background public recovery does not inherit active private provenance',
    (tester) async {
      final now = DateTime.utc(2026, 8, 23, 12);
      final activePrivate = ChatThread(
        id: 'active-private-thread',
        title: 'Active private',
        createdAt: now,
        updatedAt: now,
      );
      final backgroundPublic = ChatThread(
        id: 'background-public-thread',
        title: 'Background public',
        createdAt: now.subtract(const Duration(minutes: 1)),
        updatedAt: now.subtract(const Duration(minutes: 1)),
      );
      final activePrivateUser = ChatMessageRecord(
        id: 'active-private-user',
        threadId: activePrivate.id,
        role: ChatMessageRole.user,
        content: 'Private active question',
        createdAt: now,
        privateEvidenceUsed: true,
      );
      final activePrivateAssistant = ChatMessageRecord(
        id: 'active-private-assistant',
        threadId: activePrivate.id,
        role: ChatMessageRole.assistant,
        content: 'Private active answer',
        createdAt: now.add(const Duration(seconds: 1)),
        privateEvidenceUsed: true,
      );
      final backgroundUser = ChatMessageRecord(
        id: 'background-public-user',
        threadId: backgroundPublic.id,
        role: ChatMessageRole.user,
        content: 'Public background question',
        createdAt: now.add(const Duration(seconds: 2)),
      );
      final backgroundPending = ChatMessageRecord(
        id: 'background-public-assistant',
        threadId: backgroundPublic.id,
        role: ChatMessageRole.assistant,
        content: '',
        createdAt: now.add(const Duration(seconds: 3)),
        status: ChatMessageStatus.sending,
        aiRunId: 'run-background-public',
      );
      final hostedAgent = _RecoveryHostedAgentService(
        answer: 'Recovered public answer',
        eventSeq: 4,
      );

      final repository = await pumpChat(
        tester,
        articles: [],
        threads: [activePrivate, backgroundPublic],
        messages: [
          activePrivateUser,
          activePrivateAssistant,
          backgroundUser,
          backgroundPending,
        ],
        hostedAgent: hostedAgent,
      );
      await pumpUntil(
        tester,
        () =>
            repository.getMessage(backgroundPending.id)?.status ==
            ChatMessageStatus.completed,
      );

      expect(
        repository.getMessage(backgroundUser.id)?.privateEvidenceUsed,
        isFalse,
      );
      expect(
        repository.getMessage(backgroundPending.id)?.privateEvidenceUsed,
        isFalse,
      );
      expect(
        repository.getMessage(activePrivateAssistant.id)?.privateEvidenceUsed,
        isTrue,
      );
    },
  );

  testWidgets('background sticky recovery taints its own completed pair only', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 8, 23, 13);
    final activePublic = ChatThread(
      id: 'active-public-thread',
      title: 'Active public',
      createdAt: now,
      updatedAt: now,
    );
    final backgroundPrivate = ChatThread(
      id: 'background-private-thread',
      title: 'Background private',
      createdAt: now.subtract(const Duration(minutes: 1)),
      updatedAt: now.subtract(const Duration(minutes: 1)),
    );
    final activePublicUser = ChatMessageRecord(
      id: 'active-public-user',
      threadId: activePublic.id,
      role: ChatMessageRole.user,
      content: 'Public active question',
      createdAt: now,
    );
    final activePublicAssistant = ChatMessageRecord(
      id: 'active-public-assistant',
      threadId: activePublic.id,
      role: ChatMessageRole.assistant,
      content: 'Public active answer',
      createdAt: now.add(const Duration(seconds: 1)),
    );
    final priorPrivateUser = ChatMessageRecord(
      id: 'background-prior-private-user',
      threadId: backgroundPrivate.id,
      role: ChatMessageRole.user,
      content: 'Earlier private question',
      createdAt: now.add(const Duration(seconds: 2)),
      privateEvidenceUsed: true,
    );
    final priorPrivateAssistant = ChatMessageRecord(
      id: 'background-prior-private-assistant',
      threadId: backgroundPrivate.id,
      role: ChatMessageRole.assistant,
      content: 'Earlier private answer',
      createdAt: now.add(const Duration(seconds: 3)),
      privateEvidenceUsed: true,
    );
    final backgroundCurrentUser = ChatMessageRecord(
      id: 'background-current-user',
      threadId: backgroundPrivate.id,
      role: ChatMessageRole.user,
      content: 'Later background question',
      createdAt: now.add(const Duration(seconds: 4)),
    );
    final backgroundPending = ChatMessageRecord(
      id: 'background-private-assistant',
      threadId: backgroundPrivate.id,
      role: ChatMessageRole.assistant,
      content: '',
      createdAt: now.add(const Duration(seconds: 5)),
      status: ChatMessageStatus.sending,
      aiRunId: 'run-background-private',
    );
    final hostedAgent = _RecoveryHostedAgentService(
      answer: 'Recovered sticky answer',
      eventSeq: 5,
    );

    final repository = await pumpChat(
      tester,
      articles: [],
      threads: [activePublic, backgroundPrivate],
      messages: [
        activePublicUser,
        activePublicAssistant,
        priorPrivateUser,
        priorPrivateAssistant,
        backgroundCurrentUser,
        backgroundPending,
      ],
      hostedAgent: hostedAgent,
    );
    await pumpUntil(
      tester,
      () =>
          repository.getMessage(backgroundPending.id)?.status ==
          ChatMessageStatus.completed,
    );

    expect(
      repository.getMessage(backgroundCurrentUser.id)?.privateEvidenceUsed,
      isTrue,
    );
    expect(
      repository.getMessage(backgroundPending.id)?.privateEvidenceUsed,
      isTrue,
    );
    expect(
      repository.getMessage(activePublicAssistant.id)?.privateEvidenceUsed,
      isFalse,
    );
  });

  testWidgets('terminal recovery keeps an already persisted partial prefix', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 8, 9, 10, 30);
    final thread = ChatThread(
      id: 'failed-partial-thread',
      title: 'Failed partial recovery',
      createdAt: now,
      updatedAt: now,
    );
    final pending = ChatMessageRecord(
      id: 'failed-partial-answer',
      threadId: thread.id,
      role: ChatMessageRole.assistant,
      content: 'Persisted partial prefix',
      createdAt: now,
      status: ChatMessageStatus.sending,
      aiRunId: 'run-failed-partial',
      aiRunEventSeq: 4,
    );
    final hostedAgent = _RecoveryHostedAgentService(
      answer: '',
      eventSeq: 8,
      terminalStatus: 'failed',
      terminalError: 'provider rejected request',
    );

    final repository = await pumpChat(
      tester,
      articles: [],
      threads: [thread],
      messages: [pending],
      hostedAgent: hostedAgent,
    );
    await pumpUntil(
      tester,
      () =>
          repository.getMessage(pending.id)?.status == ChatMessageStatus.failed,
    );

    final recovered = repository.getMessage(pending.id);
    expect(hostedAgent.resumeRunIds, ['run-failed-partial']);
    expect(hostedAgent.resumeAfterEventSeqs, [4]);
    expect(recovered?.content, startsWith('Persisted partial prefix\n\n'));
    expect(recovered?.status, ChatMessageStatus.failed);
    expect(recovered?.errorCode, 'hosted_run_failed');
    expect(recovered?.aiRunEventSeq, 8);
  });

  testWidgets('a pending run resumes when the hosted provider becomes ready', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 8, 9, 11);
    final thread = ChatThread(
      id: 'provider-thread',
      title: 'Provider recovery',
      createdAt: now,
      updatedAt: now,
    );
    final pending = ChatMessageRecord(
      id: 'provider-answer',
      threadId: thread.id,
      role: ChatMessageRole.assistant,
      content: '',
      createdAt: now,
      status: ChatMessageStatus.sending,
      aiRunId: 'run-provider-ready',
    );
    final hostedAgent = _RecoveryHostedAgentService(
      answer: 'Recovered after provider became ready',
      eventSeq: 4,
    );

    final repository = await pumpChat(
      tester,
      articles: [],
      threads: [thread],
      messages: [pending],
      dynamicHostedAgent: true,
    );
    expect(hostedAgent.resumeRunIds, isEmpty);
    expect(
      repository.getMessage(pending.id)?.status,
      ChatMessageStatus.sending,
    );

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ChatScreen)),
    );
    container.read(_hostedAgentAvailabilityProvider.notifier).state =
        hostedAgent;
    await pumpUntil(
      tester,
      () =>
          repository.getMessage(pending.id)?.status ==
          ChatMessageStatus.completed,
    );

    final recovered = repository.getMessage(pending.id);
    expect(hostedAgent.resumeRunIds, ['run-provider-ready']);
    expect(recovered?.content, 'Recovered after provider became ready');
    expect(recovered?.status, ChatMessageStatus.completed);
    expect(recovered?.aiRunEventSeq, 4);
  });

  testWidgets(
    'durable recovery retries a failed repository enumeration after backoff',
    (tester) async {
      final now = DateTime.utc(2026, 8, 9, 11, 30);
      final thread = ChatThread(
        id: 'retry-thread',
        title: 'Retry recovery',
        createdAt: now,
        updatedAt: now,
      );
      final pending = ChatMessageRecord(
        id: 'retry-answer',
        threadId: thread.id,
        role: ChatMessageRole.assistant,
        content: '',
        createdAt: now,
        status: ChatMessageStatus.sending,
        aiRunId: 'run-retry-enumeration',
      );
      final hostedAgent = _RecoveryHostedAgentService(
        answer: 'Recovered after enumeration retry',
        eventSeq: 5,
      );

      final repository = await pumpChat(
        tester,
        articles: [],
        threads: [thread],
        messages: [pending],
        dynamicHostedAgent: true,
      );
      // Initialization has already enumerated successfully. Arm only the next
      // explicit durable-recovery scan so the provider itself still loads.
      repository.failNextGetThreads();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(ChatScreen)),
      );
      container.read(_hostedAgentAvailabilityProvider.notifier).state =
          hostedAgent;
      for (var i = 0; i < 5 && repository.getThreadsFailuresThrown == 0; i++) {
        await tester.pump();
      }

      expect(repository.getThreadsFailuresThrown, 1);
      expect(hostedAgent.resumeRunIds, isEmpty);
      expect(
        repository.getMessage(pending.id)?.status,
        ChatMessageStatus.sending,
      );

      // Advance virtual time beyond the bounded retry delay, then allow the
      // retried async scan and finalizer to drain their microtasks.
      await tester.pump(const Duration(seconds: 5));
      await pumpUntil(
        tester,
        () =>
            repository.getMessage(pending.id)?.status ==
            ChatMessageStatus.completed,
      );

      final recovered = repository.getMessage(pending.id);
      expect(repository.getThreadsFailuresThrown, 1);
      expect(repository.getThreadsCalls, greaterThanOrEqualTo(3));
      expect(hostedAgent.resumeRunIds, ['run-retry-enumeration']);
      expect(recovered?.content, 'Recovered after enumeration retry');
      expect(recovered?.status, ChatMessageStatus.completed);
      expect(recovered?.aiRunEventSeq, 5);
    },
  );

  testWidgets(
    'a retryable poison run does not starve its recovery batch or lock input',
    (tester) async {
      final now = DateTime.utc(2026, 8, 9, 11, 45);
      final thread = ChatThread(
        id: 'poison-recovery-thread',
        title: 'Poison recovery',
        createdAt: now,
        updatedAt: now,
      );
      final poison = ChatMessageRecord(
        id: 'poison-answer',
        threadId: thread.id,
        role: ChatMessageRole.assistant,
        content: 'persisted poison partial',
        createdAt: now,
        status: ChatMessageStatus.sending,
        aiRunId: 'run-poison',
        aiRunEventSeq: 2,
      );
      final healthy = ChatMessageRecord(
        id: 'healthy-answer',
        threadId: thread.id,
        role: ChatMessageRole.assistant,
        content: '',
        createdAt: now.add(const Duration(seconds: 1)),
        status: ChatMessageStatus.sending,
        aiRunId: 'run-healthy',
      );
      final hostedAgent = _PoisonRecoveryHostedAgentService();

      final repository = await pumpChat(
        tester,
        articles: [],
        threads: [thread],
        messages: [poison, healthy],
        hostedAgent: hostedAgent,
      );
      await pumpUntil(
        tester,
        () =>
            hostedAgent.poisonResumeCalls >= 1 &&
            repository.getMessage(healthy.id)?.status ==
                ChatMessageStatus.completed,
      );

      // The poison entry is first in the same scan, but its retryable failure
      // must not prevent the following durable run from being finalized.
      expect(hostedAgent.resumeRunIds.take(2).toList(), [
        'run-poison',
        'run-healthy',
      ]);
      expect(repository.getMessage(healthy.id)?.content, 'healthy recovered');
      expect(repository.getMessage(healthy.id)?.aiRunEventSeq, 7);
      expect(
        hostedAgent.resumeRunIds.where((runId) => runId == 'run-healthy'),
        hasLength(1),
      );

      // Initial attempt plus the scheduler's three bounded backoffs.
      const retryDelays = [
        Duration(milliseconds: 300),
        Duration(milliseconds: 600),
        Duration(milliseconds: 1200),
      ];
      for (var index = 0; index < retryDelays.length; index++) {
        await tester.pump(retryDelays[index]);
        await pumpUntil(
          tester,
          () => hostedAgent.poisonResumeCalls >= index + 2,
        );
      }
      expect(hostedAgent.poisonResumeCalls, 4);
      expect(
        repository.getMessage(poison.id)?.status,
        ChatMessageStatus.sending,
      );

      // Advancing beyond the next exponential slot proves the automatic
      // retry budget is exhausted. The durable record remains recoverable on
      // a future lifecycle signal, but it must not leave chat input locked.
      await tester.pump(const Duration(milliseconds: 2500));
      await tester.pump();
      expect(hostedAgent.poisonResumeCalls, 4);
      final input = tester.widget<TextField>(find.byType(TextField));
      final sendButton = tester.widget<IconButton>(
        find.byKey(const ValueKey('chat-send-button')),
      );
      expect(input.enabled, isNot(false));
      expect(sendButton.onPressed, isNotNull);
    },
  );

  testWidgets('deleting a thread during a live run cannot resurrect it', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 8, 9, 12);
    final thread = ChatThread(
      id: 'delete-thread',
      title: 'Delete during run',
      createdAt: now,
      updatedAt: now,
    );
    final putGate = Completer<void>();
    final putStarted = Completer<void>();
    final repository = _InMemoryChatRepository([thread], const [])
      ..putGate = putGate
      ..putStarted = putStarted
      ..putGatePredicate = (message) => message.aiRunId == 'live-run';
    final hostedAgent = _GatedHostedAgentService();

    await pumpChat(
      tester,
      articles: [],
      threads: [thread],
      conversation: durableConversation(hostedAgent),
      hostedAgent: hostedAgent,
      chatRepository: repository,
    );
    await tester.enterText(find.byType(TextField), 'delete this run');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump(const Duration(milliseconds: 100));
    await pumpUntil(tester, () => putStarted.isCompleted);
    expect(putStarted.isCompleted, isTrue);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ChatScreen)),
    );
    await container.read(chatSessionsProvider.notifier).deleteThread(thread.id);
    expect(repository.getThread(thread.id), isNull);

    putGate.complete();
    hostedAgent.complete();
    await pumpUntil(tester, () => hostedAgent.chatFinished.isCompleted);
    await tester.pump();
    await tester.pump();

    expect(repository.getThread(thread.id), isNull);
    expect(repository.getMessages(thread.id), isEmpty);
    expect(find.text('single live answer'), findsNothing);
    expect(find.byType(ChatTypingIndicator), findsNothing);
    expect(hostedAgent.chatCalls, 1);
    expect(hostedAgent.resumeCalls, 0);
  });

  testWidgets(
    'lifecycle resume before onRunCreated queues recovery until live completion',
    (tester) async {
      final now = DateTime.utc(2026, 8, 9, 13);
      final liveThread = ChatThread(
        id: 'live-thread',
        title: 'Live thread',
        createdAt: now,
        updatedAt: now,
      );
      final oldThread = ChatThread(
        id: 'old-thread',
        title: 'Old pending thread',
        createdAt: now.subtract(const Duration(minutes: 2)),
        updatedAt: now.subtract(const Duration(minutes: 1)),
      );
      final oldPending = ChatMessageRecord(
        id: 'old-pending-answer',
        threadId: oldThread.id,
        role: ChatMessageRole.assistant,
        content: '',
        createdAt: oldThread.updatedAt,
        status: ChatMessageStatus.sending,
        aiRunId: 'old-run',
      );
      final hostedAgent = _PreCreateGatedHostedAgentService();

      final repository = await pumpChat(
        tester,
        articles: [],
        threads: [liveThread, oldThread],
        messages: [oldPending],
        conversation: durableConversation(hostedAgent),
        dynamicHostedAgent: true,
      );
      await tester.enterText(find.byType(TextField), 'start a live run');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump(const Duration(milliseconds: 100));
      expect(hostedAgent.chatStarted.isCompleted, isTrue);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(ChatScreen)),
      );
      container.read(_hostedAgentAvailabilityProvider.notifier).state =
          hostedAgent;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 100));
      expect(hostedAgent.resumeRunIds, isEmpty);

      hostedAgent.allowRunCreation();
      await pumpUntil(tester, () => hostedAgent.runCreated.isCompleted);
      expect(hostedAgent.resumeRunIds, isEmpty);

      hostedAgent.completeLiveAnswer();
      await pumpUntil(
        tester,
        () => hostedAgent.resumeRunIds.contains('old-run'),
      );
      await pumpUntil(
        tester,
        () =>
            repository.getMessage(oldPending.id)?.status ==
            ChatMessageStatus.completed,
      );

      final recovered = repository.getMessage(oldPending.id);
      expect(hostedAgent.chatCalls, 1);
      expect(hostedAgent.resumeRunIds, ['old-run']);
      expect(find.text('live answer'), findsOneWidget);
      expect(recovered?.content, 'old resumed answer');
      expect(recovered?.status, ChatMessageStatus.completed);
    },
  );

  testWidgets('Stop before onRunCreated cancels the late durable run', (
    tester,
  ) async {
    final hostedAgent = _PreCreateGatedHostedAgentService();
    final cancelled = <String>[];
    final repository = await pumpChat(
      tester,
      articles: [],
      conversation: durableConversation(hostedAgent),
      hostedAgent: hostedAgent,
      runCanceller: (runId, {expectedOwnerUserId}) async {
        expect(expectedOwnerUserId, 'user-1');
        cancelled.add(runId);
      },
    );

    await tester.enterText(find.byType(TextField), 'stop before create');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await pumpUntil(tester, () => hostedAgent.chatStarted.isCompleted);
    expect(find.byKey(const ValueKey('chat-stop-icon')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('chat-send-button')));
    await tester.pump();
    hostedAgent.allowRunCreation();
    await pumpUntil(tester, () => hostedAgent.runCreated.isCompleted);
    await pumpUntil(tester, () => cancelled.isNotEmpty);
    hostedAgent.completeLiveAnswer();
    await tester.pump();
    await tester.pump();

    final assistant = repository
        .getMessages(repository.getThreads().single.id)
        .where((message) => message.role == ChatMessageRole.assistant)
        .single;
    expect(cancelled, ['live-run']);
    expect(assistant.aiRunId, 'live-run');
    expect(assistant.status, ChatMessageStatus.interrupted);
    expect(assistant.errorCode, 'hosted_run_cancelled');
    expect(find.text('live answer'), findsNothing);
    expect(find.byKey(const ValueKey('chat-stop-icon')), findsNothing);
  });

  testWidgets('run created after thread deletion is cancelled from tombstone', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 8, 10, 2);
    final thread = ChatThread(
      id: 'precreate-delete-thread',
      title: 'Precreate delete',
      createdAt: now,
      updatedAt: now,
    );
    final hostedAgent = _PreCreateGatedHostedAgentService();
    final cancelled = <String>[];
    final repository = await pumpChat(
      tester,
      articles: [],
      threads: [thread],
      conversation: durableConversation(hostedAgent),
      hostedAgent: hostedAgent,
      runCanceller: (runId, {expectedOwnerUserId}) async {
        expect(expectedOwnerUserId, 'user-1');
        cancelled.add(runId);
      },
    );

    await tester.enterText(find.byType(TextField), 'delete before create');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await pumpUntil(tester, () => hostedAgent.chatStarted.isCompleted);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ChatScreen)),
    );
    await container.read(chatSessionsProvider.notifier).deleteThread(thread.id);
    final pendingDeletion = repository.getPendingThreadDeletions().single;
    expect(pendingDeletion.aiRunIdsToCancel, isEmpty);
    expect(pendingDeletion.aiRunLookups, hasLength(1));
    expect(pendingDeletion.aiRunLookups.single.ownerUserId, 'user-1');

    hostedAgent.allowRunCreation();
    await pumpUntil(tester, () => hostedAgent.runCreated.isCompleted);
    await pumpUntil(tester, () => cancelled.isNotEmpty);
    hostedAgent.completeLiveAnswer();
    await tester.pump();
    await tester.pump();

    expect(cancelled, ['live-run']);
    expect(repository.getThread(thread.id), isNull);
    expect(repository.getMessages(thread.id), isEmpty);
    expect(repository.getPendingThreadDeletions(), isEmpty);
    expect(find.text('live answer'), findsNothing);
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

class _GatedHostedAgentService extends HostedAgentService {
  final Completer<void> _gate = Completer<void>();
  final Completer<void> chatFinished = Completer<void>();
  int chatCalls = 0;
  int resumeCalls = 0;

  _GatedHostedAgentService()
    : super(
        getSession: () => null,
        refreshSession: () async => null,
        model: 'test-agent',
      );

  @override
  bool get isConfigured => true;

  @override
  String? get currentUserId => 'user-1';

  void complete() => _gate.complete();

  @override
  Stream<String> chatStream({
    required String systemPrompt,
    required String userMessage,
    required String userQuestion,
    List<AiImageInput> images = const [],
    List<Map<String, String>> history = const [],
    double temperature = 0.3,
    int maxTokens = 800,
    bool webSearch = false,
    void Function(HostedAgentEvent event)? onEvent,
    FutureOr<void> Function(String runId)? onRunCreated,
    String? idempotencyKey,
  }) async* {
    chatCalls++;
    lastRunId = 'live-run';
    await onRunCreated?.call('live-run');
    await _gate.future;
    try {
      yield 'single live answer';
    } finally {
      if (!chatFinished.isCompleted) chatFinished.complete();
    }
  }

  @override
  Stream<String> resumeStream(
    String runId, {
    int afterEventSeq = 0,
    void Function(HostedAgentEvent event)? onEvent,
  }) async* {
    resumeCalls++;
    yield 'duplicate resumed answer';
  }
}

class _TransportInterruptedHostedAgentService extends HostedAgentService {
  final Completer<void> _resumeGate = Completer<void>();
  int resumeCalls = 0;

  _TransportInterruptedHostedAgentService()
    : super(
        getSession: () => null,
        refreshSession: () async => null,
        model: 'test-agent',
      );

  @override
  bool get isConfigured => true;

  @override
  String? get currentUserId => 'user-1';

  void completeResume() => _resumeGate.complete();

  @override
  Stream<String> chatStream({
    required String systemPrompt,
    required String userMessage,
    required String userQuestion,
    List<AiImageInput> images = const [],
    List<Map<String, String>> history = const [],
    double temperature = 0.3,
    int maxTokens = 800,
    bool webSearch = false,
    void Function(HostedAgentEvent event)? onEvent,
    FutureOr<void> Function(String runId)? onRunCreated,
    String? idempotencyKey,
  }) async* {
    lastRunId = 'transport-run';
    lastRunStatus = 'running';
    await onRunCreated?.call('transport-run');
    lastError = 'Hosted Agent request failed: connection reset';
  }

  @override
  Stream<String> resumeStream(
    String runId, {
    int afterEventSeq = 0,
    void Function(HostedAgentEvent event)? onEvent,
  }) async* {
    resumeCalls++;
    await _resumeGate.future;
    lastRunId = runId;
    lastRunStatus = 'completed';
    lastEventSeq = 6;
    lastChunkIsFullAnswer = true;
    yield 'answer after reconnect';
  }
}

class _RecoveryHostedAgentService extends HostedAgentService {
  final String answer;
  final int eventSeq;
  final List<HostedAgentSource> sources;
  final String? terminalStatus;
  final String? terminalError;
  final List<String> resumeRunIds = [];
  final List<int> resumeAfterEventSeqs = [];

  _RecoveryHostedAgentService({
    required this.answer,
    required this.eventSeq,
    this.sources = const [],
    this.terminalStatus,
    this.terminalError,
  }) : super(
         getSession: () => null,
         refreshSession: () async => null,
         model: 'test-agent',
       );

  @override
  bool get isConfigured => true;

  @override
  Stream<String> resumeStream(
    String runId, {
    int afterEventSeq = 0,
    void Function(HostedAgentEvent event)? onEvent,
  }) async* {
    resumeRunIds.add(runId);
    resumeAfterEventSeqs.add(afterEventSeq);
    lastRunId = runId;
    lastEventSeq = eventSeq;
    lastSources = List.unmodifiable(sources);
    lastRunStatus = terminalStatus;
    lastError = terminalError;
    if (answer.isEmpty) return;
    lastChunkIsFullAnswer = true;
    yield answer;
  }
}

class _PoisonRecoveryHostedAgentService extends HostedAgentService {
  final List<String> resumeRunIds = [];
  int poisonResumeCalls = 0;

  _PoisonRecoveryHostedAgentService()
    : super(
        getSession: () => null,
        refreshSession: () async => null,
        model: 'test-agent',
      );

  @override
  bool get isConfigured => true;

  @override
  Stream<String> resumeStream(
    String runId, {
    int afterEventSeq = 0,
    void Function(HostedAgentEvent event)? onEvent,
  }) async* {
    resumeRunIds.add(runId);
    lastRunId = runId;
    if (runId == 'run-poison') {
      poisonResumeCalls++;
      throw const HostedAgentResumeException(
        message: 'Injected retryable recovery failure.',
        retryable: true,
      );
    }

    lastEventSeq = 7;
    lastSources = const [];
    lastRunStatus = 'completed';
    lastError = null;
    lastChunkIsFullAnswer = true;
    yield 'healthy recovered';
  }
}

class _PreCreateGatedHostedAgentService extends HostedAgentService {
  final Completer<void> chatStarted = Completer<void>();
  final Completer<void> runCreated = Completer<void>();
  final Completer<void> _allowRunCreation = Completer<void>();
  final Completer<void> _allowLiveAnswer = Completer<void>();
  final List<String> resumeRunIds = [];
  int chatCalls = 0;

  _PreCreateGatedHostedAgentService()
    : super(
        getSession: () => null,
        refreshSession: () async => null,
        model: 'test-agent',
      );

  @override
  bool get isConfigured => true;

  @override
  String? get currentUserId => 'user-1';

  void allowRunCreation() {
    if (!_allowRunCreation.isCompleted) _allowRunCreation.complete();
  }

  void completeLiveAnswer() {
    if (!_allowLiveAnswer.isCompleted) _allowLiveAnswer.complete();
  }

  @override
  Stream<String> chatStream({
    required String systemPrompt,
    required String userMessage,
    required String userQuestion,
    List<AiImageInput> images = const [],
    List<Map<String, String>> history = const [],
    double temperature = 0.3,
    int maxTokens = 800,
    bool webSearch = false,
    void Function(HostedAgentEvent event)? onEvent,
    FutureOr<void> Function(String runId)? onRunCreated,
    String? idempotencyKey,
  }) async* {
    chatCalls++;
    if (!chatStarted.isCompleted) chatStarted.complete();
    await _allowRunCreation.future;
    lastRunId = 'live-run';
    await onRunCreated?.call('live-run');
    if (!runCreated.isCompleted) runCreated.complete();
    await _allowLiveAnswer.future;
    yield 'live answer';
  }

  @override
  Stream<String> resumeStream(
    String runId, {
    int afterEventSeq = 0,
    void Function(HostedAgentEvent event)? onEvent,
  }) async* {
    resumeRunIds.add(runId);
    lastRunId = runId;
    lastEventSeq = 12;
    lastSources = const [];
    yield 'old resumed answer';
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
  final Map<String, PendingChatThreadDeletion> _deletions = {};
  int _getThreadsFailuresRemaining = 0;
  int getThreadsCalls = 0;
  int getThreadsFailuresThrown = 0;
  Completer<void>? putGate;
  Completer<void>? putStarted;
  bool Function(ChatMessageRecord message)? putGatePredicate;

  _InMemoryChatRepository(
    Iterable<ChatThread> threads,
    Iterable<ChatMessageRecord> messages,
  ) : _threads = {for (final thread in threads) thread.id: thread},
      _messages = {for (final message in messages) message.id: message};

  @override
  Future<void> init() async {}

  @override
  List<ChatThread> getThreads() {
    getThreadsCalls++;
    if (_getThreadsFailuresRemaining > 0) {
      _getThreadsFailuresRemaining--;
      getThreadsFailuresThrown++;
      throw StateError('Injected chat thread enumeration failure.');
    }
    final threads = _threads.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return threads;
  }

  void failNextGetThreads() {
    _getThreadsFailuresRemaining++;
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
    if (!_threads.containsKey(message.threadId)) {
      throw StateError('Cannot persist a message for a missing chat thread.');
    }
    final gate = putGate;
    if (gate != null && (putGatePredicate?.call(message) ?? true)) {
      putGate = null;
      putGatePredicate = null;
      putStarted?.complete();
      putStarted = null;
      await gate.future;
    }
    _messages[message.id] = message;
    if (!_threads.containsKey(message.threadId)) {
      _messages.remove(message.id);
      throw StateError('Chat thread was deleted while persisting its message.');
    }
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
