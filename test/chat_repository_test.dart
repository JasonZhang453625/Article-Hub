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
        ),
      );

      final restored = repository.getMessage('m1');
      expect(restored!.status, ChatMessageStatus.sending);
      expect(restored.query, 'Question');
      expect(restored.aiRunId, 'run-9');
      expect(restored.aiRunEventSeq, 4);
    },
  );

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
          attachmentContext: 'File contents',
          attachmentContextIncludesImages: false,
        ),
      );

      final restored = repository.getMessage('m2')!;
      expect(restored.attachments.single.originalFileName, 'note.txt');
      expect(restored.attachmentContext, 'File contents');
      expect(restored.attachmentContextIncludesImages, isFalse);
    },
  );
}
