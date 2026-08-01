import 'rag_context_builder.dart';

class RagConversationTurn {
  final String role;
  final String content;

  const RagConversationTurn({required this.role, required this.content});

  Map<String, String> toMessage() => {'role': role, 'content': content};
}

class ChatContextWindow {
  static const int defaultContextWindowTokens = 8192;
  static const int defaultSafetyMarginTokens = 512;
  static const int _messageOverheadTokens = 4;
  static const int _promptPrimingTokens = 3;

  const ChatContextWindow();

  List<RagConversationTurn> selectForPrompt({
    required String systemPrompt,
    required String userMessage,
    required List<RagConversationTurn> history,
    required int maxOutputTokens,
    int contextWindowTokens = defaultContextWindowTokens,
    int safetyMarginTokens = defaultSafetyMarginTokens,
  }) {
    return selectRecentCompleteTurns(
      history,
      tokenBudget:
          contextWindowTokens -
          estimateFixedPromptTokens(
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            maxOutputTokens: maxOutputTokens,
            safetyMarginTokens: safetyMarginTokens,
          ),
    );
  }

  int estimateFixedPromptTokens({
    required String systemPrompt,
    required String userMessage,
    required int maxOutputTokens,
    int safetyMarginTokens = defaultSafetyMarginTokens,
  }) {
    return estimateMessageTokens(systemPrompt) +
        estimateMessageTokens(userMessage) +
        maxOutputTokens +
        safetyMarginTokens +
        _promptPrimingTokens;
  }

  List<RagConversationTurn> selectRecentCompleteTurns(
    List<RagConversationTurn> history, {
    required int tokenBudget,
  }) {
    if (tokenBudget <= 0 || history.isEmpty) return const [];

    final pairs = <List<RagConversationTurn>>[];
    RagConversationTurn? pendingUser;
    for (final turn in history) {
      final role = turn.role.trim().toLowerCase();
      final content = turn.content.trim();
      if (content.isEmpty) continue;
      if (role == 'user') {
        pendingUser = RagConversationTurn(role: 'user', content: content);
      } else if (role == 'assistant' && pendingUser != null) {
        pairs.add([
          pendingUser,
          RagConversationTurn(role: 'assistant', content: content),
        ]);
        pendingUser = null;
      }
    }

    final selectedPairs = <List<RagConversationTurn>>[];
    var usedTokens = 0;
    for (final pair in pairs.reversed) {
      final pairTokens = pair.fold<int>(
        0,
        (total, turn) => total + estimateMessageTokens(turn.content),
      );
      if (usedTokens + pairTokens > tokenBudget) break;
      selectedPairs.insert(0, pair);
      usedTokens += pairTokens;
    }

    return List.unmodifiable(selectedPairs.expand((pair) => pair));
  }

  int estimateMessageTokens(String content) {
    return RagContextBuilder.estimateTokens(content) + _messageOverheadTokens;
  }
}
