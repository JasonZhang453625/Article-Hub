import 'package:flutter/material.dart';

import '../../shared/utils/locale_strings.dart' show LocaleStrings;
import '../../shared/widgets/delayed_reveal.dart';

class ChatEmptyState extends StatelessWidget {
  final bool hasKnowledge;
  final LocaleStrings s;

  const ChatEmptyState({super.key, required this.hasKnowledge, required this.s});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: DelayedReveal(
        delayMs: 100,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline_rounded, size: 64,
                color: theme.colorScheme.onSurfaceVariant.withAlpha(80)),
            const SizedBox(height: 16),
            Text(s.askKnowledgeBase, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                hasKnowledge ? s.tryExamples : s.knowledgeBaseEmpty,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
