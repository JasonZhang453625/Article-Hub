enum AiThinkingLevel { none, low, medium, max }

extension AiThinkingLevelValue on AiThinkingLevel {
  /// DeepSeek currently exposes three effective states: disabled, high, max.
  /// Its API maps both low and medium compatibility values to high.
  String? get deepSeekReasoningEffort => switch (this) {
    AiThinkingLevel.none => null,
    AiThinkingLevel.low || AiThinkingLevel.medium => 'high',
    AiThinkingLevel.max => 'max',
  };
}
