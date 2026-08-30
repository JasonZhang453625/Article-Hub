enum AiThinkingLevel { none, low, medium, max }

extension AiThinkingLevelValue on AiThinkingLevel {
  /// DeepSeek exposes disabled plus three effective effort levels: low, high,
  /// and max. The UI's historical `medium` enum value is the high setting.
  String? get deepSeekReasoningEffort => switch (this) {
    AiThinkingLevel.none => null,
    AiThinkingLevel.low => 'low',
    AiThinkingLevel.medium => 'high',
    AiThinkingLevel.max => 'max',
  };
}
