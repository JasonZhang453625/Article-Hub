import 'package:flutter/material.dart';

import '../../data/models/ai_thinking_level.dart';
import '../../shared/utils/locale_strings.dart';

/// Bottom sheet listing chat tools (web search, future skills, …).
///
/// Presented from the "+" button on the left of the input bar, using the same
/// visual language as [ChatSettingsSheet]: rounded top corners, drag handle,
/// dimmed barrier.
class ChatToolsSheet extends StatelessWidget {
  final LocaleStrings s;

  /// Whether the session-level Agent web-search tool is enabled.
  final bool webSearchEnabled;

  /// Whether the selected AI path exposes a web-search tool.
  final bool webSearchAvailable;

  final AiThinkingLevel thinkingLevel;
  final bool thinkingAvailable;

  final ValueChanged<bool> onToggleWebSearch;
  final ValueChanged<AiThinkingLevel> onThinkingChanged;
  final VoidCallback? onAddImage;
  final VoidCallback? onAddFile;
  final VoidCallback? onOpenSkills;

  const ChatToolsSheet({
    super.key,
    required this.s,
    required this.webSearchEnabled,
    required this.webSearchAvailable,
    required this.thinkingLevel,
    required this.thinkingAvailable,
    required this.onToggleWebSearch,
    required this.onThinkingChanged,
    this.onAddImage,
    this.onAddFile,
    this.onOpenSkills,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.4,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(s.chatTools, style: theme.textTheme.titleMedium),
              const SizedBox(height: 16),
              Row(
                children: [
                  _ChatToolActionButton(
                    key: const ValueKey('chat-tools-image-button'),
                    icon: Icons.image_outlined,
                    label: s.chatToolsImage,
                    onTap: onAddImage,
                  ),
                  const SizedBox(width: 10),
                  _ChatToolActionButton(
                    key: const ValueKey('chat-tools-file-button'),
                    icon: Icons.description_outlined,
                    label: s.chatToolsFile,
                    onTap: onAddFile,
                  ),
                  const SizedBox(width: 10),
                  _ChatToolActionButton(
                    key: const ValueKey('chat-tools-skill-button'),
                    icon: Icons.auto_awesome_outlined,
                    label: 'Skill',
                    onTap: onOpenSkills,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: SwitchListTile(
                  key: const ValueKey('chat-tools-web-search'),
                  secondary: Icon(
                    Icons.public_rounded,
                    color: webSearchEnabled
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                  ),
                  title: Text(
                    s.chatToolsWebSearch,
                    style: theme.textTheme.bodyMedium,
                  ),
                  subtitle: webSearchAvailable
                      ? null
                      : Text(s.webSearchNotConfigured),
                  value: webSearchEnabled,
                  onChanged: webSearchAvailable ? onToggleWebSearch : null,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Icon(
                    Icons.psychology_alt_rounded,
                    size: 20,
                    color: thinkingAvailable
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    s.chatThinkingStrength,
                    style: theme.textTheme.titleSmall,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _ThinkingStrengthSlider(
                value: thinkingLevel,
                enabled: thinkingAvailable,
                labels: [
                  s.chatThinkingNone,
                  s.chatThinkingLow,
                  s.chatThinkingMedium,
                  s.chatThinkingMax,
                ],
                semanticsLabel: s.chatThinkingStrength,
                onChanged: onThinkingChanged,
              ),
              if (!thinkingAvailable) ...[
                const SizedBox(height: 8),
                Text(
                  s.chatThinkingDeepSeekOnly,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Same visual grammar as the three theme/language choices in Settings.
class _ChatToolActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _ChatToolActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onTap != null;
    final isDark = theme.brightness == Brightness.dark;
    final foreground = enabled
        ? theme.colorScheme.onSurface.withValues(alpha: 0.66)
        : theme.colorScheme.onSurface.withValues(alpha: 0.28);

    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDark ? Colors.white12 : const Color(0xFFD7E3EA),
              ),
            ),
            child: Column(
              children: [
                Icon(icon, size: 22, color: foreground),
                const SizedBox(height: 6),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: foreground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ThinkingStrengthSlider extends StatelessWidget {
  final AiThinkingLevel value;
  final bool enabled;
  final List<String> labels;
  final String semanticsLabel;
  final ValueChanged<AiThinkingLevel> onChanged;

  const _ThinkingStrengthSlider({
    required this.value,
    required this.enabled,
    required this.labels,
    required this.semanticsLabel,
    required this.onChanged,
  });

  void _selectForPosition(double dx, double width) {
    if (!enabled || width <= 0) return;
    final index = (dx.clamp(0, width) / width * AiThinkingLevel.values.length)
        .floor()
        .clamp(0, AiThinkingLevel.values.length - 1)
        .toInt();
    onChanged(AiThinkingLevel.values[index]);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final selectedIndex = value.index;
    return Semantics(
      label: semanticsLabel,
      value: labels[selectedIndex],
      enabled: enabled,
      increasedValue: selectedIndex < labels.length - 1
          ? labels[selectedIndex + 1]
          : null,
      decreasedValue: selectedIndex > 0 ? labels[selectedIndex - 1] : null,
      onIncrease: enabled && selectedIndex < AiThinkingLevel.values.length - 1
          ? () => onChanged(AiThinkingLevel.values[selectedIndex + 1])
          : null,
      onDecrease: enabled && selectedIndex > 0
          ? () => onChanged(AiThinkingLevel.values[selectedIndex - 1])
          : null,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return GestureDetector(
            key: const ValueKey('chat-thinking-slider'),
            behavior: HitTestBehavior.opaque,
            onTapDown: enabled
                ? (details) => _selectForPosition(
                    details.localPosition.dx,
                    constraints.maxWidth,
                  )
                : null,
            onHorizontalDragUpdate: enabled
                ? (details) => _selectForPosition(
                    details.localPosition.dx,
                    constraints.maxWidth,
                  )
                : null,
            child: Container(
              height: 44,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Stack(
                children: [
                  AnimatedAlign(
                    key: const ValueKey('chat-thinking-thumb'),
                    alignment: Alignment(
                      -1 + (selectedIndex * 2 / (labels.length - 1)),
                      0,
                    ),
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    child: FractionallySizedBox(
                      widthFactor: 1 / labels.length,
                      heightFactor: 1,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: enabled
                              ? colors.primaryContainer
                              : colors.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: enabled
                              ? [
                                  BoxShadow(
                                    color: colors.shadow.withValues(
                                      alpha: 0.08,
                                    ),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ]
                              : null,
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: List.generate(labels.length, (index) {
                      final selected = index == selectedIndex;
                      return Expanded(
                        child: InkWell(
                          key: ValueKey('chat-thinking-level-$index'),
                          borderRadius: BorderRadius.circular(10),
                          onTap: enabled
                              ? () => onChanged(AiThinkingLevel.values[index])
                              : null,
                          child: Center(
                            child: AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeOut,
                              style: Theme.of(context).textTheme.labelMedium!
                                  .copyWith(
                                    color: !enabled
                                        ? colors.onSurface.withValues(
                                            alpha: 0.38,
                                          )
                                        : selected
                                        ? colors.onPrimaryContainer
                                        : colors.onSurfaceVariant,
                                    fontWeight: selected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                              child: Text(labels[index]),
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
