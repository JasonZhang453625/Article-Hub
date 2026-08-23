import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:memora/data/models/chat_message_record.dart';
import 'package:memora/data/models/chat_attachment.dart';
import 'package:memora/data/models/chat_thread.dart';
import 'package:memora/data/repositories/chat_repository.dart';

void main() {
  late Directory tempDir;
  late HiveChatRepository repository;
  String repeated(String value, int count) => List.filled(count, value).join();

  setUp(() async {
    await Hive.close();
    tempDir = await Directory.systemTemp.createTemp('memora-chat-test-');
    Hive.init(tempDir.path);
    if (!Hive.isAdapterRegistered(ChatThread.typeId)) {
      Hive.registerAdapter(ChatThreadAdapter());
    }
    if (!Hive.isAdapterRegistered(ChatMessageRecord.typeId)) {
      Hive.registerAdapter(ChatMessageRecordAdapter());
    }
    repository = HiveChatRepository();
    await repository.init();
  });

  tearDown(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  test('persists threads and returns messages in stable time order', () async {
    final createdAt = DateTime.utc(2026, 7, 30, 10);
    final thread = ChatThread(
      id: 'thread-1',
      title: 'Agent memory',
      createdAt: createdAt,
      updatedAt: createdAt,
    );
    await repository.putThread(thread);
    await repository.putMessage(
      ChatMessageRecord(
        id: 'message-2',
        threadId: thread.id,
        role: ChatMessageRole.assistant,
        content: 'Second',
        createdAt: createdAt.add(const Duration(seconds: 2)),
        articleIds: const ['article-1'],
        feedback: 1,
      ),
    );
    await repository.putMessage(
      ChatMessageRecord(
        id: 'message-1',
        threadId: thread.id,
        role: ChatMessageRole.user,
        content: 'First',
        createdAt: createdAt.add(const Duration(seconds: 1)),
      ),
    );

    final messages = repository.getMessages(thread.id);

    expect(repository.getThreads().single.title, 'Agent memory');
    expect(messages.map((message) => message.id), ['message-1', 'message-2']);
    expect(messages.last.articleIds, ['article-1']);
    expect(messages.last.feedback, 1);
  });

  test('deleting a thread also removes only its messages', () async {
    final now = DateTime.utc(2026, 7, 30);
    for (final id in ['thread-1', 'thread-2']) {
      await repository.putThread(
        ChatThread(id: id, title: id, createdAt: now, updatedAt: now),
      );
      await repository.putMessage(
        ChatMessageRecord(
          id: 'message-$id',
          threadId: id,
          role: ChatMessageRole.user,
          content: id,
          createdAt: now,
        ),
      );
    }

    await repository.deleteThread('thread-1');

    expect(repository.getThread('thread-1'), isNull);
    expect(repository.getMessages('thread-1'), isEmpty);
    expect(repository.getMessages('thread-2'), hasLength(1));
  });

  test(
    'thread deletion tombstone survives restart until files are acked',
    () async {
      final now = DateTime.utc(2026, 8, 9);
      const attachment = ChatAttachment(
        id: 'delete-attachment',
        kind: ChatAttachmentKind.file,
        localPath: 'attachments/chat/delete-attachment/note.txt',
        mimeType: 'text/plain',
        originalFileName: 'note.txt',
        byteLength: 4,
        sha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      await repository.putThread(
        ChatThread(
          id: 'durable-delete',
          title: 'Delete me',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await repository.putMessage(
        ChatMessageRecord(
          id: 'durable-delete-message',
          threadId: 'durable-delete',
          role: ChatMessageRole.user,
          content: 'Sensitive attachment',
          createdAt: now,
          attachments: const [attachment],
        ),
      );

      await repository.deleteThread('durable-delete');

      expect(repository.getThread('durable-delete'), isNull);
      expect(repository.getMessages('durable-delete'), isEmpty);
      expect(repository.getPendingThreadDeletions(), hasLength(1));
      expect(repository.getPendingThreadDeletions().single.dataDeleted, isTrue);
      expect(repository.getPendingThreadDeletions().single.attachmentIds, [
        attachment.id,
      ]);

      final reopened = HiveChatRepository();
      await reopened.init();
      expect(reopened.getThread('durable-delete'), isNull);
      expect(reopened.getMessages('durable-delete'), isEmpty);
      expect(reopened.getPendingThreadDeletions(), hasLength(1));

      final pending = reopened.getPendingThreadDeletions().single;
      await reopened.completeThreadDeletion(
        'durable-delete',
        expectedRevision: pending.revision,
      );
      expect(reopened.getPendingThreadDeletions(), isEmpty);
    },
  );

  test(
    'thread deletion retains live Agent runs until cancellation is acked',
    () async {
      final now = DateTime.utc(2026, 8, 10);
      await repository.putThread(
        ChatThread(
          id: 'run-delete',
          title: 'Delete live run',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await repository.putMessage(
        ChatMessageRecord(
          id: 'run-delete-message',
          threadId: 'run-delete',
          role: ChatMessageRole.assistant,
          content: 'partial',
          createdAt: now,
          status: ChatMessageStatus.sending,
          aiRunId: 'run-live-1',
          aiRunRequestKey: 'attempt-1',
          aiRunOwnerUserId: 'user-owner',
        ),
      );

      final deletion = await repository.deleteThread('run-delete');

      expect(deletion.aiRunIdsToCancel, ['run-live-1']);
      await expectLater(
        repository.completeThreadDeletion(
          deletion.threadId,
          expectedRevision: deletion.revision,
        ),
        throwsStateError,
      );

      final cancelled = await repository.completeAiRunCancellation(
        deletion.threadId,
        'run-live-1',
      );
      expect(cancelled?.aiRunIdsToCancel, isEmpty);
      await repository.completeThreadDeletion(
        deletion.threadId,
        expectedRevision: cancelled!.revision,
      );
      expect(repository.getPendingThreadDeletions(), isEmpty);
    },
  );

  test(
    'onRunCreated attach is atomic with deletion and late ids re-tombstone',
    () async {
      final now = DateTime.utc(2026, 8, 10, 1);
      await repository.putThread(
        ChatThread(
          id: 'attach-delete',
          title: 'Attach race',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await repository.putMessage(
        ChatMessageRecord(
          id: 'attach-delete-message',
          threadId: 'attach-delete',
          role: ChatMessageRole.assistant,
          content: '',
          createdAt: now,
          status: ChatMessageStatus.sending,
          aiRunRequestKey: 'attempt-attach',
          aiRunOwnerUserId: 'user-owner',
        ),
      );

      final attached = await repository.attachAiRunToPendingMessage(
        messageId: 'attach-delete-message',
        expectedRequestKey: 'attempt-attach',
        expectedOwnerUserId: 'user-owner',
        runId: 'run-attached',
      );
      expect(attached?.aiRunId, 'run-attached');
      final deletion = await repository.deleteThread('attach-delete');
      expect(deletion.aiRunIdsToCancel, ['run-attached']);
      expect(
        await repository.attachAiRunToPendingMessage(
          messageId: 'attach-delete-message',
          expectedRequestKey: 'attempt-attach',
          expectedOwnerUserId: 'user-owner',
          runId: 'run-too-late',
        ),
        isNull,
      );

      var current = await repository.completeAiRunCancellation(
        'attach-delete',
        'run-attached',
      );
      await repository.completeThreadDeletion(
        'attach-delete',
        expectedRevision: current!.revision,
      );
      expect(repository.getPendingThreadDeletions(), isEmpty);

      current = await repository.queueAiRunCancellation(
        'attach-delete',
        'run-too-late',
        ownerUserId: 'user-owner',
      );
      expect(current.dataDeleted, isTrue);
      expect(current.aiRunIdsToCancel, ['run-too-late']);
      final cleared = await repository.completeAiRunCancellation(
        'attach-delete',
        'run-too-late',
      );
      await repository.completeThreadDeletion(
        'attach-delete',
        expectedRevision: cleared!.revision,
      );
      expect(repository.getPendingThreadDeletions(), isEmpty);
    },
  );

  test(
    'pending tombstone hides data and rejects resurrection writes',
    () async {
      final now = DateTime.utc(2026, 8, 9, 1);
      final thread = ChatThread(
        id: 'hidden-delete',
        title: 'Must stay hidden',
        createdAt: now,
        updatedAt: now,
      );
      final message = ChatMessageRecord(
        id: 'hidden-delete-message',
        threadId: thread.id,
        role: ChatMessageRole.user,
        content: 'Deleted content',
        createdAt: now,
      );
      await repository.putThread(thread);
      await repository.putMessage(message);

      final deletions = Hive.box<Map>(HiveChatRepository.deletionsBoxName);
      await deletions.put(thread.id, {
        'schemaVersion': 2,
        'threadId': thread.id,
        'dataDeleted': false,
        'revision': 1,
        'canAcknowledge': true,
        'attachmentIds': <String>[],
      });

      expect(
        Hive.box<ChatThread>(HiveChatRepository.threadsBoxName).get(thread.id),
        isNotNull,
      );
      expect(
        Hive.box<ChatMessageRecord>(
          HiveChatRepository.messagesBoxName,
        ).get(message.id),
        isNotNull,
      );
      expect(repository.getThreads(), isEmpty);
      expect(repository.getThread(thread.id), isNull);
      expect(repository.getMessages(thread.id), isEmpty);
      expect(repository.getMessage(message.id), isNull);

      await expectLater(repository.putThread(thread), throwsStateError);
      await expectLater(
        repository.putMessage(
          ChatMessageRecord(
            id: 'late-hidden-message',
            threadId: thread.id,
            role: ChatMessageRole.assistant,
            content: 'Must be rejected',
            createdAt: now.add(const Duration(seconds: 1)),
          ),
        ),
        throwsStateError,
      );
    },
  );

  test('malformed and unknown tombstones cannot be acknowledged', () async {
    final deletions = Hive.box<Map>(HiveChatRepository.deletionsBoxName);
    await deletions.put('malformed-delete', {
      'schemaVersion': 2,
      'threadId': 'malformed-delete',
      'dataDeleted': true,
      'revision': 4,
      'canAcknowledge': true,
      'attachmentIds': ['valid-attachment', '../invalid'],
    });
    await deletions.put('unknown-delete', {
      'schemaVersion': 99,
      'threadId': 'unknown-delete',
      'dataDeleted': true,
      'revision': 8,
      'canAcknowledge': true,
      'attachmentIds': <String>[],
    });
    await deletions.put('wrong-types-delete', {
      'schemaVersion': '2',
      'threadId': 'wrong-types-delete',
      'dataDeleted': true,
      'revision': '8',
      'canAcknowledge': 'true',
      'attachmentIds': <String>[],
    });

    final pendingById = {
      for (final deletion in repository.getPendingThreadDeletions())
        deletion.threadId: deletion,
    };
    final malformed = pendingById['malformed-delete']!;
    final unknown = pendingById['unknown-delete']!;
    final wrongTypes = pendingById['wrong-types-delete']!;
    expect(malformed.canAcknowledge, isFalse);
    expect(malformed.attachmentIds, ['valid-attachment']);
    expect(unknown.canAcknowledge, isFalse);
    expect(wrongTypes.canAcknowledge, isFalse);

    await expectLater(
      repository.completeThreadDeletion(
        malformed.threadId,
        expectedRevision: malformed.revision,
      ),
      throwsStateError,
    );
    await expectLater(
      repository.completeThreadDeletion(
        unknown.threadId,
        expectedRevision: unknown.revision,
      ),
      throwsStateError,
    );
    expect(deletions.containsKey(malformed.threadId), isTrue);
    expect(deletions.containsKey(unknown.threadId), isTrue);
    expect(deletions.containsKey(wrongTypes.threadId), isTrue);
  });

  test('schema 4 run cancellation without owner stays quarantined', () async {
    final deletions = Hive.box<Map>(HiveChatRepository.deletionsBoxName);
    await deletions.put('legacy-run-delete', {
      'schemaVersion': 4,
      'threadId': 'legacy-run-delete',
      'dataDeleted': true,
      'revision': 3,
      'canAcknowledge': true,
      'attachmentIds': <String>[],
      'aiRunIdsToCancel': <String>['run-legacy-ownerless'],
      'aiRunLookups': <Map<String, String>>[],
    });

    final pending = repository.getPendingThreadDeletions().singleWhere(
      (item) => item.threadId == 'legacy-run-delete',
    );
    expect(pending.aiRunIdsToCancel, ['run-legacy-ownerless']);
    expect(pending.aiRunOwnerUserIds, isEmpty);
    expect(pending.canAcknowledge, isFalse);

    final unchanged = await repository.completeAiRunCancellation(
      pending.threadId,
      'run-legacy-ownerless',
    );
    expect(unchanged?.aiRunIdsToCancel, ['run-legacy-ownerless']);
    await expectLater(
      repository.completeThreadDeletion(
        pending.threadId,
        expectedRevision: pending.revision,
      ),
      throwsStateError,
    );
  });

  test(
    'unknown tombstone keeps opaque data while deleting owned chat data',
    () async {
      final now = DateTime.utc(2026, 8, 9, 2);
      const threadId = 'future-delete';
      const messageId = 'future-delete-message';
      const futureAttachmentId = 'future-attachment';
      const messageAttachment = ChatAttachment(
        id: 'message-attachment',
        kind: ChatAttachmentKind.file,
        localPath: 'attachments/chat/message-attachment/private.txt',
        mimeType: 'text/plain',
        originalFileName: 'private.txt',
        byteLength: 7,
        sha256:
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      );
      await repository.putThread(
        ChatThread(
          id: threadId,
          title: 'Future deletion',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await repository.putMessage(
        ChatMessageRecord(
          id: messageId,
          threadId: threadId,
          role: ChatMessageRole.user,
          content: 'Sensitive',
          createdAt: now,
          attachments: const [messageAttachment],
        ),
      );
      final deletions = Hive.box<Map>(HiveChatRepository.deletionsBoxName);
      await deletions.put(threadId, {
        'schemaVersion': 99,
        'threadId': threadId,
        'dataDeleted': false,
        'revision': 7,
        'canAcknowledge': true,
        'attachmentIds': const [futureAttachmentId],
        'futureField': const {'opaque': 'keep-me'},
      });

      final reopened = HiveChatRepository();
      await reopened.init();

      final raw = deletions.get(threadId)!;
      expect(raw['schemaVersion'], 99);
      expect(raw['futureField'], const {'opaque': 'keep-me'});
      expect(raw['dataDeleted'], isTrue);
      expect(raw['canAcknowledge'], isFalse);
      expect(raw['recoveredAttachmentIds'], [
        futureAttachmentId,
        messageAttachment.id,
      ]);
      expect(
        Hive.box<ChatThread>(HiveChatRepository.threadsBoxName).get(threadId),
        isNull,
      );
      expect(
        Hive.box<ChatMessageRecord>(
          HiveChatRepository.messagesBoxName,
        ).get(messageId),
        isNull,
      );
      final pending = reopened.getPendingThreadDeletions().singleWhere(
        (deletion) => deletion.threadId == threadId,
      );
      expect(pending.dataDeleted, isTrue);
      expect(pending.canAcknowledge, isFalse);
      expect(pending.attachmentIds, [futureAttachmentId, messageAttachment.id]);
    },
  );

  test(
    'non-finite tombstone numbers are isolated without aborting the batch',
    () async {
      final deletions = Hive.box<Map>(HiveChatRepository.deletionsBoxName);
      final malformed = <String, Map<String, dynamic>>{
        'nan-schema-delete': {
          'schemaVersion': double.nan,
          'threadId': 'nan-schema-delete',
          'dataDeleted': true,
          'revision': 1,
          'canAcknowledge': true,
          'attachmentIds': <String>[],
        },
        'infinite-schema-delete': {
          'schemaVersion': double.infinity,
          'threadId': 'infinite-schema-delete',
          'dataDeleted': true,
          'revision': 2,
          'canAcknowledge': true,
          'attachmentIds': <String>[],
        },
        'nan-revision-delete': {
          'schemaVersion': 2,
          'threadId': 'nan-revision-delete',
          'dataDeleted': true,
          'revision': double.nan,
          'canAcknowledge': true,
          'attachmentIds': <String>[],
        },
        'infinite-revision-delete': {
          'schemaVersion': 2,
          'threadId': 'infinite-revision-delete',
          'dataDeleted': true,
          'revision': double.negativeInfinity,
          'canAcknowledge': true,
          'attachmentIds': <String>[],
        },
      };
      for (final entry in malformed.entries) {
        await deletions.put(entry.key, entry.value);
      }
      await deletions.put('valid-neighbor-delete', {
        'schemaVersion': 2,
        'threadId': 'valid-neighbor-delete',
        'dataDeleted': true,
        'revision': 12,
        'canAcknowledge': true,
        'attachmentIds': const ['valid-neighbor-attachment'],
      });

      final pendingById = {
        for (final deletion in repository.getPendingThreadDeletions())
          deletion.threadId: deletion,
      };

      expect(pendingById['valid-neighbor-delete']?.canAcknowledge, isTrue);
      expect(pendingById['valid-neighbor-delete']?.attachmentIds, [
        'valid-neighbor-attachment',
      ]);
      for (final id in malformed.keys) {
        final pending = pendingById[id]!;
        expect(pending.canAcknowledge, isFalse, reason: id);
        await expectLater(
          repository.completeThreadDeletion(
            id,
            expectedRevision: pending.revision,
          ),
          throwsStateError,
        );
      }
    },
  );

  test('thread deletion acknowledgement rejects a stale revision', () async {
    final deletions = Hive.box<Map>(HiveChatRepository.deletionsBoxName);
    await deletions.put('revision-delete', {
      'schemaVersion': 2,
      'threadId': 'revision-delete',
      'dataDeleted': true,
      'revision': 11,
      'canAcknowledge': true,
      'attachmentIds': <String>[],
    });

    await expectLater(
      repository.completeThreadDeletion(
        'revision-delete',
        expectedRevision: 10,
      ),
      throwsStateError,
    );
    expect(deletions.containsKey('revision-delete'), isTrue);

    await repository.completeThreadDeletion(
      'revision-delete',
      expectedRevision: 11,
    );
    expect(deletions.containsKey('revision-delete'), isFalse);
  });

  test('deleteMessage removes only the selected Hive record', () async {
    final now = DateTime.utc(2026, 8, 9);
    await repository.putThread(
      ChatThread(
        id: 'message-thread',
        title: 'Messages',
        createdAt: now,
        updatedAt: now,
      ),
    );
    for (final id in ['delete-me', 'keep-me']) {
      await repository.putMessage(
        ChatMessageRecord(
          id: id,
          threadId: 'message-thread',
          role: ChatMessageRole.user,
          content: id,
          createdAt: now,
        ),
      );
    }

    await repository.deleteMessage('delete-me');

    expect(repository.getMessage('delete-me'), isNull);
    expect(repository.getMessage('keep-me'), isNotNull);
    expect(repository.getThread('message-thread'), isNotNull);
  });

  test('persists pin state and sorts pinned threads first', () async {
    final now = DateTime.utc(2026, 8, 9);
    await repository.putThread(
      ChatThread(id: 'newer', title: 'Newer', createdAt: now, updatedAt: now),
    );
    await repository.putThread(
      ChatThread(
        id: 'pinned-older',
        title: 'Pinned older',
        createdAt: now.subtract(const Duration(days: 1)),
        updatedAt: now.subtract(const Duration(days: 1)),
        isPinned: true,
      ),
    );

    final threads = repository.getThreads();
    expect(threads.map((thread) => thread.id), ['pinned-older', 'newer']);
    expect(repository.getThread('pinned-older')!.isPinned, isTrue);
  });

  test('updateThreadIfExists does not create a missing thread', () async {
    final now = DateTime.utc(2026, 8, 9);

    final updated = await repository.updateThreadIfExists(
      'missing-thread',
      title: 'Ghost',
      isPinned: true,
      activityAt: now,
      lastMessagePreview: 'must not be created',
    );

    expect(updated, isNull);
    expect(repository.getThread('missing-thread'), isNull);
    expect(repository.getThreads(), isEmpty);
  });

  test('activity touch preserves the existing title and pin', () async {
    final now = DateTime.utc(2026, 8, 9, 10);
    final activityAt = now.add(const Duration(minutes: 1));
    await repository.putThread(
      ChatThread(
        id: 'touch-thread',
        title: 'User title',
        createdAt: now,
        updatedAt: now,
        lastMessagePreview: 'Earlier preview',
        isPinned: true,
      ),
    );

    final updated = await repository.updateThreadIfExists(
      'touch-thread',
      activityAt: activityAt,
      lastMessagePreview: 'Latest preview',
    );

    expect(updated?.title, 'User title');
    expect(updated?.isPinned, isTrue);
    expect(updated?.updatedAt, activityAt);
    expect(updated?.lastMessagePreview, 'Latest preview');
    final restored = repository.getThread('touch-thread')!;
    expect(restored.title, 'User title');
    expect(restored.isPinned, isTrue);
  });

  test('older activity cannot regress thread preview or timestamp', () async {
    final newestActivity = DateTime.utc(2026, 8, 9, 12);
    await repository.putThread(
      ChatThread(
        id: 'monotonic-thread',
        title: 'Current title',
        createdAt: newestActivity.subtract(const Duration(hours: 1)),
        updatedAt: newestActivity,
        lastMessagePreview: 'Newest preview',
      ),
    );

    final updated = await repository.updateThreadIfExists(
      'monotonic-thread',
      activityAt: newestActivity.subtract(const Duration(minutes: 1)),
      lastMessagePreview: 'Stale preview',
    );

    expect(updated?.updatedAt, newestActivity);
    expect(updated?.lastMessagePreview, 'Newest preview');
    final restored = repository.getThread('monotonic-thread')!;
    expect(restored.updatedAt, newestActivity);
    expect(restored.lastMessagePreview, 'Newest preview');
  });

  test('chat titles are normalized and bounded by Unicode characters', () {
    expect(chatTitleFromMessage('  hello\n  world  '), 'hello world');
    expect(chatTitleFromMessage(repeated('记', 40)).runes.length, 33);
    expect(chatTitleFromMessage(repeated('记', 40)), endsWith('…'));
  });

  test(
    'round-trips interrupted status and durable run metadata through Hive',
    () async {
      final now = DateTime.utc(2026, 7, 30);
      await repository.putThread(
        ChatThread(id: 't1', title: 'T', createdAt: now, updatedAt: now),
      );
      await repository.putMessage(
        ChatMessageRecord(
          id: 'm1',
          threadId: 't1',
          role: ChatMessageRole.assistant,
          content: 'partial server answer',
          createdAt: now,
          query: 'Question',
          status: ChatMessageStatus.sending,
          aiRunId: 'run-9',
          aiRunEventSeq: 4,
          aiRunRequestKey: 'request-attempt-1',
          aiRunOwnerUserId: 'user-1',
          privateEvidenceUsed: true,
        ),
      );

      final restored = repository.getMessage('m1');
      expect(restored!.status, ChatMessageStatus.sending);
      expect(restored.query, 'Question');
      expect(restored.aiRunId, 'run-9');
      expect(restored.aiRunEventSeq, 4);
      expect(restored.aiRunRequestKey, 'request-attempt-1');
      expect(restored.aiRunOwnerUserId, 'user-1');
      expect(restored.privateEvidenceUsed, isTrue);
    },
  );

  test('reads pre-owner chat records with a null owner', () async {
    final now = DateTime.utc(2026, 8, 12);
    await repository.putThread(
      ChatThread(
        id: 'legacy-owner-thread',
        title: 'Legacy owner',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await Hive.close();
    Hive.init(tempDir.path);
    Hive.registerAdapter(_PreOwnerChatMessageRecordAdapter(), override: true);
    final legacyBox = await Hive.openBox<ChatMessageRecord>(
      HiveChatRepository.messagesBoxName,
    );
    await legacyBox.put(
      'legacy-owner-message',
      ChatMessageRecord(
        id: 'legacy-owner-message',
        threadId: 'legacy-owner-thread',
        role: ChatMessageRole.assistant,
        content: 'partial',
        createdAt: now,
        query: 'Question',
        status: ChatMessageStatus.sending,
        aiRunRequestKey: 'legacy-attempt',
      ),
    );
    await Hive.close();
    Hive.init(tempDir.path);
    Hive.registerAdapter(ChatMessageRecordAdapter(), override: true);

    final reopened = HiveChatRepository();
    await reopened.init();
    final restored = reopened.getMessage('legacy-owner-message');

    expect(restored, isNotNull);
    expect(restored?.aiRunRequestKey, 'legacy-attempt');
    expect(restored?.aiRunOwnerUserId, isNull);
    expect(restored?.privateEvidenceUsed, isFalse);
  });

  test(
    'create owner and run attachment share one repository CAS attempt',
    () async {
      final now = DateTime.utc(2026, 8, 12, 1);
      await repository.putThread(
        ChatThread(
          id: 'owner-cas-thread',
          title: 'Owner CAS',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await repository.putMessage(
        ChatMessageRecord(
          id: 'owner-cas-message',
          threadId: 'owner-cas-thread',
          role: ChatMessageRole.assistant,
          content: '',
          createdAt: now,
          status: ChatMessageStatus.sending,
          aiRunRequestKey: 'attempt-owner-cas',
        ),
      );

      final marked = await repository.markAiRunCreateStarted(
        messageId: 'owner-cas-message',
        expectedRequestKey: 'attempt-owner-cas',
        ownerUserId: 'user-owner',
      );
      expect(marked?.aiRunOwnerUserId, 'user-owner');
      expect(
        await repository.markAiRunCreateStarted(
          messageId: 'owner-cas-message',
          expectedRequestKey: 'attempt-owner-cas',
          ownerUserId: 'different-user',
        ),
        isNull,
      );
      expect(
        await repository.attachAiRunToPendingMessage(
          messageId: 'owner-cas-message',
          expectedRequestKey: 'attempt-owner-cas',
          expectedOwnerUserId: 'different-user',
          runId: 'run-wrong-owner',
        ),
        isNull,
      );
      final attached = await repository.attachAiRunToPendingMessage(
        messageId: 'owner-cas-message',
        expectedRequestKey: 'attempt-owner-cas',
        expectedOwnerUserId: 'user-owner',
        runId: 'run-owner-cas',
      );
      expect(attached?.aiRunId, 'run-owner-cas');
    },
  );

  test(
    'thread deletion retains an unresolved owner lookup tombstone',
    () async {
      final now = DateTime.utc(2026, 8, 12, 2);
      await repository.putThread(
        ChatThread(
          id: 'lookup-delete-thread',
          title: 'Lookup tombstone',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await repository.putMessage(
        ChatMessageRecord(
          id: 'lookup-delete-message',
          threadId: 'lookup-delete-thread',
          role: ChatMessageRole.assistant,
          content: '',
          createdAt: now,
          status: ChatMessageStatus.sending,
          aiRunRequestKey: 'attempt-delete-lookup',
          aiRunOwnerUserId: 'user-owner',
        ),
      );

      final deletion = await repository.deleteThread('lookup-delete-thread');
      expect(deletion.aiRunLookups, hasLength(1));
      expect(deletion.aiRunLookups.single.requestKey, 'attempt-delete-lookup');
      await expectLater(
        repository.completeThreadDeletion(
          deletion.threadId,
          expectedRevision: deletion.revision,
        ),
        throwsStateError,
      );

      final resolved = await repository.resolveAiRunLookup(
        deletion.threadId,
        ownerUserId: 'user-owner',
        requestKey: 'attempt-delete-lookup',
        runId: 'run-delete-lookup',
      );
      expect(resolved?.aiRunLookups, isEmpty);
      expect(resolved?.aiRunIdsToCancel, ['run-delete-lookup']);
    },
  );

  test('rejects a message whose thread does not exist', () async {
    final now = DateTime.utc(2026, 8, 9);

    await expectLater(
      repository.putMessage(
        ChatMessageRecord(
          id: 'orphan',
          threadId: 'missing-thread',
          role: ChatMessageRole.assistant,
          content: 'late answer',
          createdAt: now,
        ),
      ),
      throwsStateError,
    );
    expect(repository.getMessage('orphan'), isNull);
  });

  test(
    'round-trips attachment metadata and prepared context through Hive',
    () async {
      final now = DateTime.utc(2026, 8, 9);
      await repository.putThread(
        ChatThread(
          id: 't2',
          title: 'Attachment',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await repository.putMessage(
        ChatMessageRecord(
          id: 'm2',
          threadId: 't2',
          role: ChatMessageRole.user,
          content: 'Read this',
          createdAt: now,
          attachments: const [
            ChatAttachment(
              id: 'attachment-1',
              kind: ChatAttachmentKind.file,
              localPath: 'attachments/chat/attachment-1/note.txt',
              mimeType: 'text/plain',
              originalFileName: 'note.txt',
              byteLength: 4,
              sha256:
                  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            ),
          ],
          attachmentIdsForCleanup: const ['ownership-only-id'],
          attachmentContext: 'File contents',
          attachmentContextIncludesImages: false,
        ),
      );

      await Hive.close();
      Hive.init(tempDir.path);
      final reopened = HiveChatRepository();
      await reopened.init();
      final restored = reopened.getMessage('m2')!;
      expect(restored.attachments.single.originalFileName, 'note.txt');
      expect(restored.attachmentIdsForCleanup, [
        'attachment-1',
        'ownership-only-id',
      ]);
      expect(restored.attachmentContext, 'File contents');
      expect(restored.attachmentContextIncludesImages, isFalse);
    },
  );

  test('extracts attachment ownership id from corrupt metadata', () {
    final stored = <Object?>[
      {
        'id': 'recoverable-attachment',
        'localPath': '',
        'mimeType': null,
        'originalFileName': null,
        'byteLength': -1,
        'sha256': 'not-a-digest',
      },
      {'id': '../unsafe', 'sha256': 'also-invalid'},
    ];

    expect(chatAttachmentsFromStored(stored), isEmpty);
    expect(chatAttachmentIdsFromStored(stored), ['recoverable-attachment']);
  });

  test('client-tool run tuple is immutable across late attach races', () async {
    final now = DateTime.utc(2026, 8, 12);
    await repository.putThread(
      ChatThread(
        id: 'tool-thread',
        title: 'Tool run',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await repository.putMessage(
      ChatMessageRecord(
        id: 'tool-message',
        threadId: 'tool-thread',
        role: ChatMessageRole.assistant,
        content: '',
        createdAt: now,
        status: ChatMessageStatus.sending,
        aiRunRequestKey: 'tool-attempt',
      ),
    );
    final toolsRepository = repository as ClientToolChatRepository;
    final marked = await toolsRepository.markAiRunClientToolsCreateStarted(
      messageId: 'tool-message',
      expectedRequestKey: 'tool-attempt',
      ownerUserId: 'user-1',
      ownerDeviceId: 'device-1',
      protocolVersion: 3,
      clientToolsVersion: 1,
      knowledgeMode: 'only',
    );
    expect(marked?.usesDeviceClientTools, isTrue);
    expect(marked?.aiRunOwnerDeviceId, 'device-1');
    expect(
      await toolsRepository.attachAiRunClientToolsToPendingMessage(
        messageId: 'tool-message',
        expectedRequestKey: 'tool-attempt',
        expectedOwnerUserId: 'user-1',
        expectedOwnerDeviceId: 'device-2',
        expectedProtocolVersion: 3,
        expectedClientToolsVersion: 1,
        expectedKnowledgeMode: 'only',
        runId: 'wrong-device-run',
      ),
      isNull,
    );
    final attached = await toolsRepository
        .attachAiRunClientToolsToPendingMessage(
          messageId: 'tool-message',
          expectedRequestKey: 'tool-attempt',
          expectedOwnerUserId: 'user-1',
          expectedOwnerDeviceId: 'device-1',
          expectedProtocolVersion: 3,
          expectedClientToolsVersion: 1,
          expectedKnowledgeMode: 'only',
          runId: 'correct-run',
        );
    expect(attached?.aiRunId, 'correct-run');

    await Hive.close();
    Hive.init(tempDir.path);
    final reopened = HiveChatRepository();
    await reopened.init();
    final restored = reopened.getMessage('tool-message');
    expect(restored?.aiRunOwnerUserId, 'user-1');
    expect(restored?.aiRunOwnerDeviceId, 'device-1');
    expect(restored?.aiRunProtocolVersion, 3);
    expect(restored?.aiRunClientToolsVersion, 1);
    expect(restored?.aiRunKnowledgeMode, 'only');
  });
}

/// Writer matching schema fields 0..21 from builds before owner-scoped run
/// reconciliation. The production adapter's null-aware field 22 read must
/// accept this payload without migration.
class _PreOwnerChatMessageRecordAdapter extends TypeAdapter<ChatMessageRecord> {
  @override
  int get typeId => ChatMessageRecord.typeId;

  @override
  ChatMessageRecord read(BinaryReader reader) =>
      throw UnsupportedError('Legacy adapter is write-only in this test.');

  @override
  void write(BinaryWriter writer, ChatMessageRecord obj) {
    writer
      ..writeByte(22)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.threadId)
      ..writeByte(2)
      ..write(2)
      ..writeByte(3)
      ..write(obj.content)
      ..writeByte(4)
      ..write(obj.createdAt)
      ..writeByte(5)
      ..write(obj.articleIds)
      ..writeByte(6)
      ..write(obj.weakArticleIds)
      ..writeByte(7)
      ..write(obj.method)
      ..writeByte(8)
      ..write(obj.logId)
      ..writeByte(9)
      ..write(obj.isNoResult)
      ..writeByte(10)
      ..write(obj.query)
      ..writeByte(11)
      ..write(obj.feedback)
      ..writeByte(12)
      ..write(0)
      ..writeByte(13)
      ..write(obj.errorCode)
      ..writeByte(14)
      ..write(obj.webUrls)
      ..writeByte(15)
      ..write(obj.aiRunId)
      ..writeByte(16)
      ..write(obj.aiRunEventSeq)
      ..writeByte(17)
      ..write(const <Map<String, dynamic>>[])
      ..writeByte(18)
      ..write(obj.attachmentContext)
      ..writeByte(19)
      ..write(obj.attachmentContextIncludesImages)
      ..writeByte(20)
      ..write(obj.aiRunRequestKey)
      ..writeByte(21)
      ..write(obj.attachmentIdsForCleanup);
  }
}
