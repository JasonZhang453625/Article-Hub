import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/services/chat_context_window.dart';

void main() {
  const window = ChatContextWindow();
  String repeated(String value, int count) => List.filled(count, value).join();

  test('keeps only the most recent complete pairs within the token budget', () {
    final history = [
      RagConversationTurn(role: 'user', content: repeated('旧', 40)),
      RagConversationTurn(role: 'assistant', content: repeated('答', 40)),
      RagConversationTurn(role: 'user', content: repeated('新', 40)),
      RagConversationTurn(role: 'assistant', content: repeated('回', 40)),
    ];

    final selected = window.selectRecentCompleteTurns(
      history,
      tokenBudget: 100,
    );

    expect(selected, hasLength(2));
    expect(selected.first.content, repeated('新', 40));
    expect(selected.last.content, repeated('回', 40));
  });

  test('drops unpaired and system messages from conversational history', () {
    final selected = window.selectRecentCompleteTurns(const [
      RagConversationTurn(role: 'system', content: 'Old system prompt'),
      RagConversationTurn(role: 'user', content: 'Unanswered question'),
    ], tokenBudget: 1000);

    expect(selected, isEmpty);
  });

  test('reserves system, latest user, output and safety tokens first', () {
    final history = [
      RagConversationTurn(role: 'user', content: repeated('old ', 80)),
      RagConversationTurn(role: 'assistant', content: repeated('answer ', 80)),
      const RagConversationTurn(role: 'user', content: 'recent question'),
      const RagConversationTurn(role: 'assistant', content: 'recent answer'),
    ];

    final selected = window.selectForPrompt(
      systemPrompt: 'system',
      userMessage: 'latest question with evidence',
      history: history,
      maxOutputTokens: 200,
      contextWindowTokens: 420,
      safetyMarginTokens: 100,
    );

    expect(selected, hasLength(2));
    expect(selected.first.content, 'recent question');
    expect(selected.last.content, 'recent answer');
  });
}
