import 'package:flutter_test/flutter_test.dart';
import 'package:memora/data/models/chat_message_record.dart';
import 'package:memora/data/services/rag_conversation_service.dart';
import 'package:memora/features/chat/chat_screen.dart';

void main() {
  test(
    'completed hosted history omits attachment text and keeps taint sticky',
    () {
      final createdAt = DateTime.utc(2026, 8, 23);
      ChatMessageRecord message({
        required String id,
        required ChatMessageRole role,
        required String content,
        String? attachmentContext,
        bool privateEvidenceUsed = false,
        ChatMessageStatus status = ChatMessageStatus.completed,
      }) {
        return ChatMessageRecord(
          id: id,
          threadId: 'thread-1',
          role: role,
          content: content,
          createdAt: createdAt,
          attachmentContext: attachmentContext,
          privateEvidenceUsed: privateEvidenceUsed,
          status: status,
        );
      }

      final history = buildCompletedChatHistory([
        message(id: 'u1', role: ChatMessageRole.user, content: 'safe q1'),
        message(id: 'a1', role: ChatMessageRole.assistant, content: 'safe a1'),
        message(
          id: 'u2',
          role: ChatMessageRole.user,
          content: 'private q2',
          attachmentContext: 'TOP SECRET ATTACHMENT TEXT',
        ),
        message(
          id: 'a2',
          role: ChatMessageRole.assistant,
          content: 'private a2',
          privateEvidenceUsed: true,
        ),
        message(id: 'u3', role: ChatMessageRole.user, content: 'follow-up q3'),
        message(
          id: 'a3',
          role: ChatMessageRole.assistant,
          content: 'follow-up a3',
        ),
        message(
          id: 'u4',
          role: ChatMessageRole.user,
          content: 'incomplete private question',
          attachmentContext: 'SHOULD NOT ENTER HISTORY',
        ),
      ]);

      expect(history.map((turn) => turn.role), [
        'user',
        'assistant',
        'user',
        'assistant',
        'user',
        'assistant',
      ]);
      expect(history.map((turn) => turn.privateEvidence), [
        false,
        false,
        true,
        true,
        true,
        true,
      ]);
      expect(history.map((turn) => turn.content), [
        'safe q1',
        'safe a1',
        'private q2',
        'private a2',
        'follow-up q3',
        'follow-up a3',
      ]);
      expect(
        history.map((turn) => turn.content).join('\n'),
        isNot(contains('TOP SECRET ATTACHMENT TEXT')),
      );
      expect(
        history.map((turn) => turn.toHostedMessage()).toList(),
        everyElement(containsPair('private_evidence', isA<bool>())),
      );
    },
  );

  test('retrying clears the previous assistant result provenance', () {
    final completed = ChatMessageRecord(
      id: 'assistant-1',
      threadId: 'thread-1',
      role: ChatMessageRole.assistant,
      content: 'old private answer',
      createdAt: DateTime.utc(2026, 8, 23),
      status: ChatMessageStatus.completed,
      privateEvidenceUsed: true,
    );

    final retrying = completed.retrying(aiRunRequestKey: 'retry-key');

    expect(retrying.status, ChatMessageStatus.sending);
    expect(retrying.privateEvidenceUsed, isFalse);
  });

  test('private source user keeps a retry request tainted without history', () {
    final sourceUser = ChatMessageRecord(
      id: 'user-private',
      threadId: 'thread-1',
      role: ChatMessageRole.user,
      content: 'Retry this private question',
      createdAt: DateTime.utc(2026, 8, 23),
      status: ChatMessageStatus.completed,
      privateEvidenceUsed: true,
    );

    expect(
      chatRequestHasPrivateEvidence(currentUser: sourceUser, history: const []),
      isTrue,
    );
  });

  test('retry repairs an assistant-only legacy provenance pair', () {
    final createdAt = DateTime.utc(2026, 8, 23);
    final sourceUser = ChatMessageRecord(
      id: 'legacy-user',
      threadId: 'thread-1',
      role: ChatMessageRole.user,
      content: 'Legacy private question',
      createdAt: createdAt,
    );
    final previousAssistant = ChatMessageRecord(
      id: 'legacy-assistant',
      threadId: 'thread-1',
      role: ChatMessageRole.assistant,
      content: 'Legacy private answer',
      createdAt: createdAt.add(const Duration(seconds: 1)),
      privateEvidenceUsed: true,
    );

    final repaired = repairRetrySourceUserProvenance(
      sourceUser: sourceUser,
      previousAssistant: previousAssistant,
      history: const [],
    );

    expect(sourceUser.privateEvidenceUsed, isFalse);
    expect(repaired.privateEvidenceUsed, isTrue);
    expect(
      chatRequestHasPrivateEvidence(currentUser: repaired, history: const []),
      isTrue,
    );
  });

  test('legacy local method makes its pair and later pairs sticky', () {
    final createdAt = DateTime.utc(2026, 8, 23);
    final history = buildCompletedChatHistory([
      ChatMessageRecord(
        id: 'legacy-user',
        threadId: 'thread-1',
        role: ChatMessageRole.user,
        content: 'What did I save?',
        createdAt: createdAt,
      ),
      ChatMessageRecord(
        id: 'legacy-assistant',
        threadId: 'thread-1',
        role: ChatMessageRole.assistant,
        content: 'A local answer [1].',
        createdAt: createdAt.add(const Duration(seconds: 1)),
        method: 'keyword+web',
      ),
      ChatMessageRecord(
        id: 'later-user',
        threadId: 'thread-1',
        role: ChatMessageRole.user,
        content: 'And then?',
        createdAt: createdAt.add(const Duration(seconds: 2)),
      ),
      ChatMessageRecord(
        id: 'later-assistant',
        threadId: 'thread-1',
        role: ChatMessageRole.assistant,
        content: 'A later answer.',
        createdAt: createdAt.add(const Duration(seconds: 3)),
      ),
    ]);

    expect(history, hasLength(4));
    expect(history.every((turn) => turn.privateEvidence), isTrue);
  });

  test(
    'legacy article ids stay private while a web-only pair stays public',
    () {
      final createdAt = DateTime.utc(2026, 8, 23);
      List<RagConversationTurn> historyFor(ChatMessageRecord assistant) {
        return buildCompletedChatHistory([
          ChatMessageRecord(
            id: '${assistant.id}-user',
            threadId: assistant.threadId,
            role: ChatMessageRole.user,
            content: 'Question',
            createdAt: createdAt,
          ),
          assistant,
        ]);
      }

      final citedHistory = historyFor(
        ChatMessageRecord(
          id: 'legacy-cited-assistant',
          threadId: 'thread-cited',
          role: ChatMessageRole.assistant,
          content: 'A cited answer [1].',
          createdAt: createdAt.add(const Duration(seconds: 1)),
          articleIds: const ['article-1'],
          method: 'web',
        ),
      );
      final publicWebHistory = historyFor(
        ChatMessageRecord(
          id: 'legacy-web-assistant',
          threadId: 'thread-web',
          role: ChatMessageRole.assistant,
          content: 'A public web answer [w1].',
          createdAt: createdAt.add(const Duration(seconds: 1)),
          method: 'web',
        ),
      );

      expect(citedHistory.every((turn) => turn.privateEvidence), isTrue);
      expect(publicWebHistory.every((turn) => !turn.privateEvidence), isTrue);
    },
  );
}
