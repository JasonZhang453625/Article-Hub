import 'package:flutter/material.dart';
import '../../shared/utils/locale_strings.dart';

/// Bottom sheet listing chat tools (web search, future skills, …).
///
/// Presented from the "+" button on the left of the input bar, using the same
/// visual language as [ChatSettingsSheet]: rounded top corners, drag handle,
/// dimmed barrier.
class ChatToolsSheet extends StatelessWidget {
  final LocaleStrings s;

  /// Whether the session-level web-search fallback is enabled.
  final bool webSearchEnabled;

  /// Whether a web search backend is configured (Tavily key set).
  final bool webSearchAvailable;

  final VoidCallback onToggleWebSearch;

  const ChatToolsSheet({
    super.key,
    required this.s,
    required this.webSearchEnabled,
    required this.webSearchAvailable,
    required this.onToggleWebSearch,
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
                  onChanged: webSearchAvailable
                      ? (_) => onToggleWebSearch()
                      : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
