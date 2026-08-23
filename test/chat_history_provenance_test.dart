import 'package:flutter_test/flutter_test.dart';
import 'package:memora/data/models/chat_message_record.dart';
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
}
