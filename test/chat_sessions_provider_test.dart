import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/models/chat_message_record.dart';
import 'package:memora/data/models/chat_thread.dart';
import 'package:memora/data/repositories/chat_repository.dart';
import 'package:memora/data/services/chat_attachment_service.dart';
import 'package:memora/data/services/hosted_agent_service.dart';
import 'package:memora/shared/providers/attachment_providers.dart';
import 'package:memora/shared/providers/chat_providers.dart';

void main() {
  Future<void> waitForLoad(ProviderContainer container) async {
    container.read(chatSessionsProvider.notifier);
    while (container.read(chatSessionsProvider).isLoading) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<_MemoryChatRepository> ambiguousRepository({
    String ownerUserId = 'user-1',
    ChatMessageStatus status = ChatMessageStatus.sending,
    String? errorCode,
  }) async {
    final repository = _MemoryChatRepository();
    final now = DateTime.utc(2026, 8, 12);
    await repository.putThread(
      ChatThread(
        id: 'ambiguous-thread',
        title: 'Ambiguous create',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await repository.putMessage(
      ChatMessageRecord(
        id: 'ambiguous-message',
        threadId: 'ambiguous-thread',
        role: ChatMessageRole.assistant,
        content: 'partial',
        createdAt: now,
        query: 'Question',
        status: status,
        errorCode: errorCode,
        aiRunRequestKey: 'attempt-ambiguous',
        aiRunOwnerUserId: ownerUserId,
      ),
    );
    return repository;
  }

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

    await sessions.renameThread(first.threadId, '  Renamed first chat  ');
    await sessions.setThreadPinned(first.threadId, true);
    state = container.read(chatSessionsProvider).requireValue;
    expect(state.threads.first.id, first.threadId);
    expect(state.threads.first.title, 'Renamed first chat');
    expect(state.threads.first.isPinned, isTrue);
    expect(repository.getThread(first.threadId)!.isPinned, isTrue);

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

  test(
    'recovers in-flight generations without losing partial output',
    () async {
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
          content: 'Partial answer already saved',
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
      expect(state.messages.last.content, 'Partial answer already saved');
      await Future<void>.delayed(Duration.zero);
      expect(
        repository.getMessage('a1')!.status,
        ChatMessageStatus.interrupted,
      );
    },
  );

  test(
    'keeps a hosted run sending so the UI can reconnect after restart',
    () async {
      final repository = _MemoryChatRepository();
      final now = DateTime.utc(2026, 7, 30);
      final thread = ChatThread(
        id: 'hosted-thread',
        title: 'Hosted',
        createdAt: now,
        updatedAt: now,
      );
      await repository.putThread(thread);
      await repository.putMessage(
        ChatMessageRecord(
          id: 'hosted-answer',
          threadId: thread.id,
          role: ChatMessageRole.assistant,
          content: 'partial',
          createdAt: now,
          query: 'Question',
          status: ChatMessageStatus.sending,
          aiRunId: 'run-1',
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
      expect(state.messages.single.status, ChatMessageStatus.sending);
      expect(state.messages.single.aiRunId, 'run-1');
      expect(
        await container
            .read(chatSessionsProvider.notifier)
            .pendingServerMessages(),
        hasLength(1),
      );
    },
  );

  test(
    'pending unacknowledgeable deletion still cleans valid attachments',
    () async {
      final repository = _MemoryChatRepository()
        ..pendingThreadDeletions = const [
          PendingChatThreadDeletion(
            threadId: 'pending-thread',
            attachmentIds: ['attachment-valid_1', 'attachment-valid-2'],
            dataDeleted: true,
            revision: 7,
            canAcknowledge: false,
          ),
        ];
      final attachments = _RecordingChatAttachmentService();
      final container = ProviderContainer(
        overrides: [
          chatRepositoryProvider.overrideWith((ref) async => repository),
          chatAttachmentServiceProvider.overrideWithValue(attachments),
        ],
      );
      addTearDown(container.dispose);

      container.read(chatSessionsProvider.notifier);
      while (container.read(chatSessionsProvider).isLoading) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await attachments.firstDelete.future;
      await Future<void>.delayed(Duration.zero);

      expect(attachments.deletedBatches, [
        ['attachment-valid_1', 'attachment-valid-2'],
      ]);
      expect(repository.completeThreadDeletionCalls, 0);
    },
  );

  test(
    'deleteThread cancels durable runs before acknowledging tombstone',
    () async {
      final repository = _MemoryChatRepository();
      final now = DateTime.utc(2026, 8, 10);
      await repository.putThread(
        ChatThread(
          id: 'delete-run-thread',
          title: 'Delete run',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await repository.putMessage(
        ChatMessageRecord(
          id: 'delete-run-message',
          threadId: 'delete-run-thread',
          role: ChatMessageRole.assistant,
          content: 'partial',
          createdAt: now,
          status: ChatMessageStatus.sending,
          aiRunId: 'run-delete-provider',
          aiRunRequestKey: 'attempt-delete-provider',
        ),
      );
      final cancelled = <String>[];
      final container = ProviderContainer(
        overrides: [
          chatRepositoryProvider.overrideWith((ref) async => repository),
          hostedAgentRunCancellerProvider.overrideWithValue((runId) async {
            cancelled.add(runId);
          }),
        ],
      );
      addTearDown(container.dispose);
      final sessions = container.read(chatSessionsProvider.notifier);
      while (container.read(chatSessionsProvider).isLoading) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      await sessions.deleteThread('delete-run-thread');

      expect(cancelled, ['run-delete-provider']);
      expect(repository.pendingThreadDeletions, isEmpty);
      expect(repository.getThread('delete-run-thread'), isNull);
    },
  );

  test(
    'failed deletion cancellation survives and retries from tombstone',
    () async {
      final repository = _MemoryChatRepository();
      final now = DateTime.utc(2026, 8, 10, 1);
      await repository.putThread(
        ChatThread(
          id: 'retry-cancel-thread',
          title: 'Retry cancel',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await repository.putMessage(
        ChatMessageRecord(
          id: 'retry-cancel-message',
          threadId: 'retry-cancel-thread',
          role: ChatMessageRole.assistant,
          content: '',
          createdAt: now,
          status: ChatMessageStatus.sending,
          aiRunId: 'run-retry-cancel',
          aiRunRequestKey: 'attempt-retry-cancel',
        ),
      );
      var shouldFail = true;
      var attempts = 0;
      final container = ProviderContainer(
        overrides: [
          chatRepositoryProvider.overrideWith((ref) async => repository),
          hostedAgentRunCancellerProvider.overrideWithValue((runId) async {
            attempts++;
            if (shouldFail) throw StateError('offline');
          }),
        ],
      );
      addTearDown(container.dispose);
      final sessions = container.read(chatSessionsProvider.notifier);
      while (container.read(chatSessionsProvider).isLoading) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      await sessions.deleteThread('retry-cancel-thread');
      expect(repository.pendingThreadDeletions.single.aiRunIdsToCancel, [
        'run-retry-cancel',
      ]);
      shouldFail = false;

      await sessions.retryPendingRunCancellations();

      expect(attempts, 2);
      expect(repository.pendingThreadDeletions, isEmpty);
    },
  );

  test('startup retries a persisted message-level Stop request', () async {
    final repository = _MemoryChatRepository();
    final now = DateTime.utc(2026, 8, 10, 2);
    await repository.putThread(
      ChatThread(
        id: 'restart-stop-thread',
        title: 'Restart stop',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await repository.putMessage(
      ChatMessageRecord(
        id: 'restart-stop-message',
        threadId: 'restart-stop-thread',
        role: ChatMessageRole.assistant,
        content: 'partial',
        createdAt: now,
        status: ChatMessageStatus.interrupted,
        errorCode: 'hosted_cancel_requested',
        aiRunId: 'run-restart-stop',
        aiRunRequestKey: 'attempt-restart-stop',
      ),
    );
    final cancelled = Completer<String>();
    final container = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWith((ref) async => repository),
        hostedAgentRunCancellerProvider.overrideWithValue((runId) async {
          if (!cancelled.isCompleted) cancelled.complete(runId);
        }),
      ],
    );
    addTearDown(container.dispose);

    container.read(chatSessionsProvider.notifier);
    while (container.read(chatSessionsProvider).isLoading) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(await cancelled.future, 'run-restart-stop');
    for (var i = 0; i < 20; i++) {
      if (repository.getMessage('restart-stop-message')?.errorCode ==
          'hosted_run_cancelled') {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    final restored = repository.getMessage('restart-stop-message');
    expect(restored?.status, ChatMessageStatus.interrupted);
    expect(restored?.errorCode, 'hosted_run_cancelled');
  });

  test(
    'a generation retry uses a new persisted idempotency attempt key',
    () async {
      final repository = _MemoryChatRepository();
      final container = ProviderContainer(
        overrides: [
          chatRepositoryProvider.overrideWith((ref) async => repository),
        ],
      );
      addTearDown(container.dispose);

      final sessions = container.read(chatSessionsProvider.notifier);
      final user = await sessions.addUserMessage('Retry this answer');
      final pending = await sessions.addPendingMessage(
        threadId: user.threadId,
        query: 'Retry this answer',
      );
      final firstAttemptKey = pending.aiRunRequestKey;

      expect(firstAttemptKey, isNotNull);
      expect(firstAttemptKey, isNot(pending.id));
      final retried = pending.retrying(aiRunRequestKey: 'attempt-2');
      expect(retried.id, pending.id);
      expect(retried.aiRunRequestKey, 'attempt-2');
      expect(retried.aiRunRequestKey, isNot(firstAttemptKey));
    },
  );

  test(
    'startup keeps an owner-scoped create pending until lookup attaches',
    () async {
      final repository = await ambiguousRepository();
      var lookups = 0;
      final container = ProviderContainer(
        overrides: [
          chatRepositoryProvider.overrideWith((ref) async => repository),
          hostedAgentRunLookupProvider.overrideWithValue((
            requestKey, {
            expectedOwnerUserId,
          }) async {
            lookups++;
            expect(requestKey, 'attempt-ambiguous');
            expect(expectedOwnerUserId, 'user-1');
            return const HostedAgentRunLookup(
              runId: 'run-reconciled',
              status: 'running',
            );
          }),
        ],
      );
      addTearDown(container.dispose);
      await waitForLoad(container);

      expect(
        container
            .read(chatSessionsProvider)
            .requireValue
            .messages
            .single
            .status,
        ChatMessageStatus.sending,
      );
      final retryNeeded = await container
          .read(chatSessionsProvider.notifier)
          .reconcileAmbiguousServerRuns(ownerUserId: 'user-1');

      expect(retryNeeded, isFalse);
      expect(lookups, 1);
      expect(
        repository.getMessage('ambiguous-message')?.aiRunId,
        'run-reconciled',
      );
      expect(
        await container
            .read(chatSessionsProvider.notifier)
            .pendingServerMessages(ownerUserId: 'user-1'),
        hasLength(1),
      );
    },
  );

  test(
    'three backed-off 404s complete an ambiguous create as interrupted',
    () async {
      final repository = await ambiguousRepository();
      var lookups = 0;
      final container = ProviderContainer(
        overrides: [
          chatRepositoryProvider.overrideWith((ref) async => repository),
          hostedAgentRunLookupProvider.overrideWithValue((
            _, {
            expectedOwnerUserId,
          }) async {
            expect(expectedOwnerUserId, 'user-1');
            lookups++;
            throw const HostedAgentLookupException(
              message: 'not found',
              statusCode: 404,
              retryable: false,
              notFound: true,
            );
          }),
        ],
      );
      addTearDown(container.dispose);
      await waitForLoad(container);

      final retryNeeded = await container
          .read(chatSessionsProvider.notifier)
          .reconcileAmbiguousServerRuns(ownerUserId: 'user-1');

      final restored = repository.getMessage('ambiguous-message');
      expect(retryNeeded, isFalse);
      expect(lookups, 3);
      expect(restored?.status, ChatMessageStatus.interrupted);
      expect(restored?.errorCode, 'hosted_run_not_found');
    },
  );

  test('lookup timeout keeps the owner attempt pending', () async {
    final repository = await ambiguousRepository();
    var lookups = 0;
    final container = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWith((ref) async => repository),
        hostedAgentRunLookupProvider.overrideWithValue((
          _, {
          expectedOwnerUserId,
        }) async {
          expect(expectedOwnerUserId, 'user-1');
          lookups++;
          throw const HostedAgentLookupException(
            message: 'timeout',
            retryable: true,
          );
        }),
      ],
    );
    addTearDown(container.dispose);
    await waitForLoad(container);

    final retryNeeded = await container
        .read(chatSessionsProvider.notifier)
        .reconcileAmbiguousServerRuns(ownerUserId: 'user-1');

    expect(retryNeeded, isTrue);
    expect(lookups, 1);
    expect(
      repository.getMessage('ambiguous-message')?.status,
      ChatMessageStatus.sending,
    );
    expect(repository.getMessage('ambiguous-message')?.aiRunId, isNull);
  });

  test('a different account never looks up another owner attempt', () async {
    final repository = await ambiguousRepository(ownerUserId: 'user-old');
    var lookups = 0;
    final container = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWith((ref) async => repository),
        hostedAgentRunLookupProvider.overrideWithValue((
          _, {
          expectedOwnerUserId,
        }) async {
          lookups++;
          throw StateError('must not be called');
        }),
      ],
    );
    addTearDown(container.dispose);
    await waitForLoad(container);

    final retryNeeded = await container
        .read(chatSessionsProvider.notifier)
        .reconcileAmbiguousServerRuns(ownerUserId: 'user-new');

    expect(retryNeeded, isFalse);
    expect(lookups, 0);
    expect(
      repository.getMessage('ambiguous-message')?.status,
      ChatMessageStatus.sending,
    );
  });

  test('Stop reconciles then cancels an accepted ambiguous create', () async {
    final repository = await ambiguousRepository(
      status: ChatMessageStatus.interrupted,
      errorCode: 'hosted_cancel_requested',
    );
    final cancelled = <String>[];
    final container = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWith((ref) async => repository),
        hostedAgentRunLookupProvider.overrideWithValue(
          (_, {expectedOwnerUserId}) async => const HostedAgentRunLookup(
            runId: 'run-stop-reconciled',
            status: 'running',
          ),
        ),
        hostedAgentRunCancellerProvider.overrideWithValue((runId) async {
          cancelled.add(runId);
        }),
      ],
    );
    addTearDown(container.dispose);
    await waitForLoad(container);

    final retryNeeded = await container
        .read(chatSessionsProvider.notifier)
        .reconcileAmbiguousServerRuns(ownerUserId: 'user-1');

    final restored = repository.getMessage('ambiguous-message');
    expect(retryNeeded, isFalse);
    expect(cancelled, ['run-stop-reconciled']);
    expect(restored?.aiRunId, 'run-stop-reconciled');
    expect(restored?.status, ChatMessageStatus.interrupted);
    expect(restored?.errorCode, 'hosted_run_cancelled');
  });

  test('retry fails closed while an owner attempt is unresolved', () async {
    final message = ChatMessageRecord(
      id: 'unresolved-retry',
      threadId: 'thread',
      role: ChatMessageRole.assistant,
      content: '',
      createdAt: DateTime.utc(2026, 8, 12),
      status: ChatMessageStatus.sending,
      aiRunRequestKey: 'attempt-old',
      aiRunOwnerUserId: 'user-1',
    );

    expect(
      () => message.retrying(aiRunRequestKey: 'attempt-new'),
      throwsStateError,
    );
  });

  test(
    'a delayed message write cannot switch the active thread back',
    () async {
      final repository = _MemoryChatRepository();
      final container = ProviderContainer(
        overrides: [
          chatRepositoryProvider.overrideWith((ref) async => repository),
        ],
      );
      addTearDown(container.dispose);

      final sessions = container.read(chatSessionsProvider.notifier);
      final first = await sessions.addUserMessage('First thread');
      final firstAnswer = await sessions.addAssistantMessage(
        threadId: first.threadId,
        content: 'First answer',
      );
      await sessions.startNewThread();
      final second = await sessions.addUserMessage('Second thread');
      await sessions.selectThread(first.threadId);

      final gate = Completer<void>();
      final started = Completer<void>();
      repository.nextPutMessageGate = gate;
      repository.nextPutMessageStarted = started;
      final update = sessions.updateMessage(
        firstAnswer.copyWith(content: 'Late'),
      );
      await started.future;
      await sessions.selectThread(second.threadId);
      gate.complete();
      await update;

      final state = container.read(chatSessionsProvider).requireValue;
      expect(state.activeThreadId, second.threadId);
      expect(state.messages.single.content, 'Second thread');
      expect(repository.getMessage(firstAnswer.id)?.content, 'Late');
    },
  );

  test(
    'addUserMessage cannot switch back after selecting another thread',
    () async {
      final repository = _MemoryChatRepository();
      final container = ProviderContainer(
        overrides: [
          chatRepositoryProvider.overrideWith((ref) async => repository),
        ],
      );
      addTearDown(container.dispose);

      final sessions = container.read(chatSessionsProvider.notifier);
      final first = await sessions.addUserMessage('First thread');
      await sessions.startNewThread();
      final second = await sessions.addUserMessage('Second thread');
      await sessions.selectThread(first.threadId);

      final gate = Completer<void>();
      final started = Completer<void>();
      repository.nextPutMessageGate = gate;
      repository.nextPutMessageStarted = started;
      final lateAdd = sessions.addUserMessage('Late first message');
      await started.future;

      await sessions.selectThread(second.threadId);
      gate.complete();
      final persisted = await lateAdd;

      final state = container.read(chatSessionsProvider).requireValue;
      expect(state.activeThreadId, second.threadId);
      expect(state.messages, hasLength(1));
      expect(state.messages.single.content, 'Second thread');
      expect(persisted.threadId, first.threadId);
      expect(repository.getMessage(persisted.message.id), persisted.message);
    },
  );

  test(
    'addUserMessage cannot resurrect a thread deleted after its first write',
    () async {
      final repository = _MemoryChatRepository();
      final container = ProviderContainer(
        overrides: [
          chatRepositoryProvider.overrideWith((ref) async => repository),
        ],
      );
      addTearDown(container.dispose);

      final sessions = container.read(chatSessionsProvider.notifier);
      await sessions.startNewThread();

      final threadGate = Completer<void>();
      final threadStarted = Completer<void>();
      final messageGate = Completer<void>();
      final messageStarted = Completer<void>();
      repository.nextPutThreadGate = threadGate;
      repository.nextPutThreadStarted = threadStarted;
      repository.nextPutMessageGate = messageGate;
      repository.nextPutMessageStarted = messageStarted;

      final lateAdd = sessions.addUserMessage('Deleted while adding');
      await threadStarted.future;
      threadGate.complete();
      await messageStarted.future;

      final deletedThreadId = repository.getThreads().single.id;
      await sessions.deleteThread(deletedThreadId);
      messageGate.complete();
      await expectLater(lateAdd, throwsA(isA<StateError>()));

      final state = container.read(chatSessionsProvider).requireValue;
      expect(state.threads, isEmpty);
      expect(state.activeThreadId, isNull);
      expect(state.messages, isEmpty);
      expect(repository.getThread(deletedThreadId), isNull);
      expect(repository.getMessages(deletedThreadId), isEmpty);
    },
  );

  test(
    'selectThread keeps the latest selection when recoveries finish out of order',
    () async {
      final repository = _MemoryChatRepository();
      final container = ProviderContainer(
        overrides: [
          chatRepositoryProvider.overrideWith((ref) async => repository),
        ],
      );
      addTearDown(container.dispose);

      final sessions = container.read(chatSessionsProvider.notifier);
      await sessions.startNewThread();
      final now = DateTime.utc(2026, 8, 9);
      final threadA = ChatThread(
        id: 'thread-a',
        title: 'Thread A',
        createdAt: now,
        updatedAt: now,
      );
      final threadB = ChatThread(
        id: 'thread-b',
        title: 'Thread B',
        createdAt: now.add(const Duration(seconds: 1)),
        updatedAt: now.add(const Duration(seconds: 1)),
      );
      await repository.putThread(threadA);
      await repository.putThread(threadB);
      await repository.putMessage(
        ChatMessageRecord(
          id: 'pending-a',
          threadId: threadA.id,
          role: ChatMessageRole.assistant,
          content: 'Partial A',
          createdAt: now,
          status: ChatMessageStatus.sending,
        ),
      );
      await repository.putMessage(
        ChatMessageRecord(
          id: 'pending-b',
          threadId: threadB.id,
          role: ChatMessageRole.assistant,
          content: 'Partial B',
          createdAt: now.add(const Duration(seconds: 1)),
          status: ChatMessageStatus.sending,
        ),
      );

      final gateA = Completer<void>();
      final startedA = Completer<void>();
      final gateB = Completer<void>();
      final startedB = Completer<void>();
      repository.putMessageGatesByThread[threadA.id] = gateA;
      repository.putMessageStartedByThread[threadA.id] = startedA;
      repository.putMessageGatesByThread[threadB.id] = gateB;
      repository.putMessageStartedByThread[threadB.id] = startedB;

      final selectA = sessions.selectThread(threadA.id);
      await startedA.future;
      final selectB = sessions.selectThread(threadB.id);
      await startedB.future;

      gateB.complete();
      await selectB;
      gateA.complete();
      await selectA;

      final state = container.read(chatSessionsProvider).requireValue;
      expect(state.activeThreadId, threadB.id);
      expect(state.messages, hasLength(1));
      expect(state.messages.single.id, 'pending-b');
      expect(state.messages.single.status, ChatMessageStatus.interrupted);
      expect(
        repository.getMessage('pending-a')?.status,
        ChatMessageStatus.interrupted,
      );
      expect(
        repository.getMessage('pending-b')?.status,
        ChatMessageStatus.interrupted,
      );
    },
  );

  test(
    'reselecting the current thread cancels an older pending selection',
    () async {
      final repository = _MemoryChatRepository();
      final container = ProviderContainer(
        overrides: [
          chatRepositoryProvider.overrideWith((ref) async => repository),
        ],
      );
      addTearDown(container.dispose);

      final sessions = container.read(chatSessionsProvider.notifier);
      await sessions.startNewThread();
      final now = DateTime.utc(2026, 8, 9, 1);
      final threadA = ChatThread(
        id: 'aba-thread-a',
        title: 'Thread A',
        createdAt: now,
        updatedAt: now,
      );
      final threadB = ChatThread(
        id: 'aba-thread-b',
        title: 'Thread B',
        createdAt: now.add(const Duration(seconds: 1)),
        updatedAt: now.add(const Duration(seconds: 1)),
      );
      await repository.putThread(threadA);
      await repository.putThread(threadB);
      await repository.putMessage(
        ChatMessageRecord(
          id: 'aba-message-a',
          threadId: threadA.id,
          role: ChatMessageRole.user,
          content: 'Visible A',
          createdAt: now,
        ),
      );
      await repository.putMessage(
        ChatMessageRecord(
          id: 'aba-pending-b',
          threadId: threadB.id,
          role: ChatMessageRole.assistant,
          content: 'Partial B',
          createdAt: now.add(const Duration(seconds: 1)),
          status: ChatMessageStatus.sending,
        ),
      );
      await sessions.selectThread(threadA.id);

      final gateB = Completer<void>();
      final startedB = Completer<void>();
      repository.putMessageGatesByThread[threadB.id] = gateB;
      repository.putMessageStartedByThread[threadB.id] = startedB;
      final selectB = sessions.selectThread(threadB.id);
      await startedB.future;

      expect(
        container.read(chatSessionsProvider).requireValue.activeThreadId,
        threadA.id,
      );
      await sessions.selectThread(threadA.id);
      gateB.complete();
      await selectB;

      final state = container.read(chatSessionsProvider).requireValue;
      expect(state.activeThreadId, threadA.id);
      expect(state.messages, hasLength(1));
      expect(state.messages.single.id, 'aba-message-a');
      expect(
        repository.getMessage('aba-pending-b')?.status,
        ChatMessageStatus.interrupted,
      );
    },
  );
}

class _MemoryChatRepository implements ChatRepository {
  final Map<String, ChatThread> _threads = {};
  final Map<String, ChatMessageRecord> _messages = {};
  List<PendingChatThreadDeletion> pendingThreadDeletions = const [];
  int completeThreadDeletionCalls = 0;
  Completer<void>? nextPutThreadGate;
  Completer<void>? nextPutThreadStarted;
  Completer<void>? nextPutMessageGate;
  Completer<void>? nextPutMessageStarted;
  final Map<String, Completer<void>> putMessageGatesByThread = {};
  final Map<String, Completer<void>> putMessageStartedByThread = {};

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
    final gate = nextPutThreadGate;
    if (gate != null) {
      nextPutThreadGate = null;
      nextPutThreadStarted?.complete();
      nextPutThreadStarted = null;
      await gate.future;
    }
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
    final threadGate = putMessageGatesByThread.remove(message.threadId);
    if (threadGate != null) {
      putMessageStartedByThread.remove(message.threadId)?.complete();
      await threadGate.future;
    }
    final gate = threadGate == null ? nextPutMessageGate : null;
    if (gate != null) {
      nextPutMessageGate = null;
      nextPutMessageStarted?.complete();
      nextPutMessageStarted = null;
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
        !_threads.containsKey(current.threadId) ||
        current.status != ChatMessageStatus.sending ||
        current.aiRunId != null ||
        current.aiRunRequestKey != expectedRequestKey ||
        (current.aiRunOwnerUserId != null &&
            current.aiRunOwnerUserId != ownerUserId)) {
      return null;
    }
    final updated = current.copyWith(aiRunOwnerUserId: ownerUserId);
    _messages[messageId] = updated;
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
  List<PendingChatThreadDeletion> getPendingThreadDeletions() {
    return List.unmodifiable(pendingThreadDeletions);
  }

  @override
  Future<PendingChatThreadDeletion> queueAiRunCancellation(
    String threadId,
    String runId,
  ) async {
    PendingChatThreadDeletion? existing;
    for (final deletion in pendingThreadDeletions) {
      if (deletion.threadId == threadId) existing = deletion;
    }
    final runIds = {...?existing?.aiRunIdsToCancel, runId}.toList()..sort();
    final updated = PendingChatThreadDeletion(
      threadId: threadId,
      attachmentIds: existing?.attachmentIds ?? const [],
      aiRunIdsToCancel: runIds,
      aiRunLookups: existing?.aiRunLookups ?? const [],
      dataDeleted: true,
      revision: (existing?.revision ?? 0) + 1,
      canAcknowledge: existing?.canAcknowledge ?? true,
    );
    pendingThreadDeletions = [
      ...pendingThreadDeletions.where(
        (deletion) => deletion.threadId != threadId,
      ),
      updated,
    ];
    return updated;
  }

  @override
  Future<PendingChatThreadDeletion?> completeAiRunCancellation(
    String threadId,
    String runId,
  ) async {
    PendingChatThreadDeletion? existing;
    for (final deletion in pendingThreadDeletions) {
      if (deletion.threadId == threadId) existing = deletion;
    }
    if (existing == null) return null;
    final runIds = existing.aiRunIdsToCancel
        .where((id) => id != runId)
        .toList();
    final updated = PendingChatThreadDeletion(
      threadId: threadId,
      attachmentIds: existing.attachmentIds,
      aiRunIdsToCancel: runIds,
      aiRunLookups: existing.aiRunLookups,
      dataDeleted: existing.dataDeleted,
      revision: existing.revision + 1,
      canAcknowledge: existing.canAcknowledge,
    );
    pendingThreadDeletions = [
      ...pendingThreadDeletions.where(
        (deletion) => deletion.threadId != threadId,
      ),
      updated,
    ];
    return updated;
  }

  @override
  Future<PendingChatThreadDeletion?> resolveAiRunLookup(
    String threadId, {
    required String ownerUserId,
    required String requestKey,
    String? runId,
  }) async {
    PendingChatThreadDeletion? existing;
    for (final deletion in pendingThreadDeletions) {
      if (deletion.threadId == threadId) existing = deletion;
    }
    if (existing == null) return null;
    final lookups = existing.aiRunLookups
        .where(
          (item) =>
              item.ownerUserId != ownerUserId || item.requestKey != requestKey,
        )
        .toList();
    final runIds = {...existing.aiRunIdsToCancel, ?runId}.toList()..sort();
    final updated = PendingChatThreadDeletion(
      threadId: threadId,
      attachmentIds: existing.attachmentIds,
      aiRunIdsToCancel: runIds,
      aiRunLookups: lookups,
      dataDeleted: existing.dataDeleted,
      revision: existing.revision + 1,
      canAcknowledge: existing.canAcknowledge,
    );
    pendingThreadDeletions = [
      ...pendingThreadDeletions.where((item) => item.threadId != threadId),
      updated,
    ];
    return updated;
  }

  @override
  Future<void> completeThreadDeletion(
    String id, {
    required int expectedRevision,
  }) async {
    completeThreadDeletionCalls++;
    pendingThreadDeletions = pendingThreadDeletions
        .where((deletion) => deletion.threadId != id)
        .toList();
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
      aiRunLookups: lookups,
      dataDeleted: true,
      revision: 1,
    );
    pendingThreadDeletions = [
      ...pendingThreadDeletions.where((pending) => pending.threadId != id),
      deletion,
    ];
    return deletion;
  }
}

class _RecordingChatAttachmentService extends ChatAttachmentService {
  final List<List<String>> deletedBatches = [];
  final Completer<void> firstDelete = Completer<void>();

  @override
  Future<void> deletePersistedIds(Iterable<String> attachmentIds) async {
    deletedBatches.add(List<String>.of(attachmentIds));
    if (!firstDelete.isCompleted) firstDelete.complete();
  }
}
