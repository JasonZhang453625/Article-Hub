import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/passage.dart';
import '../../shared/providers/locale_provider.dart';
import 'chat_message.dart';
import 'chat_citation_chips.dart';
import 'chat_feedback.dart';
import 'chat_no_result.dart';
import 'chat_typing_indicator.dart';

class ChatBubble extends ConsumerWidget {
  final ChatMessage message;
  final Map<String, Article> articlesById;
  final ValueChanged<int> onFeedback;
  final ValueChanged<String> onCitationClick;
  final ValueChanged<String> onSuggestionTap;
  final ValueChanged<ChatMessage> onRetry;
  final Future<void> Function(ChatMessage) onSave;
  final VoidCallback onBrowseKnowledge;

  const ChatBubble({
    super.key,
    required this.message,
    required this.articlesById,
    required this.onFeedback,
    required this.onCitationClick,
    required this.onSuggestionTap,
    required this.onRetry,
    required this.onSave,
    required this.onBrowseKnowledge,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final s = ref.watch(stringsProvider);
    final isUser = message.role == MessageRole.user;

    if (message.isPending && message.text.trim().isEmpty) {
      // The in-flight answer is a real (persisted) message now — render the
      // typing animation on it so an app restart can still recover it.
      return const ChatTypingIndicator();
    }

    if (message.isInterrupted && message.text.trim().isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.error_outline_rounded,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      s.aiGenericError,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => onRetry(message),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: Text(s.retry),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (isUser) {
      // User questions animate in as well: a quick fade + slight rise, so
      // sending a message doesn't snap it into place.
      return TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        builder: (context, value, child) => Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 10 * (1 - value)),
            child: child,
          ),
        ),
        child: Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.82,
            ),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              borderRadius: BorderRadius.circular(
                18,
              ).copyWith(bottomRight: const Radius.circular(4)),
            ),
            child: SelectableText(
              message.text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onPrimary,
                fontSize: 16,
              ),
            ),
          ),
        ),
      );
    }

    // Assistant answers render full-width (ChatGPT-style) with the text
    // column capped at a comfortable reading width and centered. The
    // AnimatedSize makes a streaming answer unfold like a waterfall — the
    // bubble height grows smoothly as tokens arrive, so text appears from
    // the top downward instead of popping in all at once. The viewport
    // itself never auto-scrolls; only the user's own scrolling moves it.
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MarkdownBody(
          data: message.text,
          selectable: true,
          styleSheet: MarkdownStyleSheet(
            pPadding: const EdgeInsets.only(bottom: 4),
            p: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurface,
              fontSize: 17,
              height: 1.2,
            ),
            strong: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurface,
              fontWeight: FontWeight.w700,
              fontSize: 17,
              height: 1.2,
            ),
            em: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurface,
              fontStyle: FontStyle.italic,
              fontSize: 17,
              height: 1.2,
            ),
            code: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              fontFamily: 'monospace',
              fontSize: 14,
            ),
            codeblockDecoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: theme.colorScheme.outline.withValues(alpha: 0.2),
              ),
            ),
            blockquote: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              fontSize: 17,
              height: 1.2,
            ),
            blockquoteDecoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: theme.colorScheme.primary.withValues(alpha: 0.4),
                  width: 3,
                ),
              ),
            ),
            listBullet: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurface,
              fontSize: 17,
            ),
            h1: theme.textTheme.titleLarge?.copyWith(
              color: theme.colorScheme.onSurface,
            ),
            h2: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurface,
              fontSize: 19,
              height: 1.4,
            ),
            h3: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.onSurface,
              fontSize: 17,
              height: 1.4,
            ),
            a: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.primary,
              decoration: TextDecoration.underline,
              fontSize: 17,
              height: 1.2,
            ),
          ),
        ),
        if (message.isInterrupted) ...[
          const SizedBox(height: 12),
          _InterruptedAnswerNotice(
            message: message,
            onRetry: onRetry,
            label: s.aiGenericError,
            retryLabel: s.retry,
          ),
        ],
        if (message.articleIds.isNotEmpty) ...[
          const SizedBox(height: 12),
          CitationChips(
            articleIds: message.articleIds,
            articlesById: articlesById,
            onCitationClick: onCitationClick,
          ),
        ],
        if (message.webUrls.isNotEmpty) ...[
          const SizedBox(height: 8),
          WebCitationChips(urls: message.webUrls),
        ],
        if (message.isNoResult) ...[
          const SizedBox(height: 12),
          ChatNoResultActions(
            query: message.query ?? '',
            weakArticleIds: message.weakArticleIds,
            articlesById: articlesById,
            onSuggestionTap: onSuggestionTap,
            onBrowseKnowledge: onBrowseKnowledge,
            onCitationClick: onCitationClick,
          ),
        ],
        if (message.isPending) ...[
          const SizedBox(height: 6),
          const ChatTypingIndicator(),
        ] else if (!message.isNoResult &&
            !message.isInterrupted &&
            message.text.trim().isNotEmpty) ...[
          const SizedBox(height: 10),
          ChatFeedbackRow(
            message: message,
            onFeedback: onFeedback,
            onRetry: onRetry,
            onSave: onSave,
            retryLabel: s.retry,
            saveTooltip: s.saveAnswerTooltip,
            saveSavingLabel: s.saveAnswerSaving,
          ),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ClipRect(
            child: AnimatedSize(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

class _InterruptedAnswerNotice extends StatelessWidget {
  final ChatMessage message;
  final ValueChanged<ChatMessage> onRetry;
  final String label;
  final String retryLabel;

  const _InterruptedAnswerNotice({
    required this.message,
    required this.onRetry,
    required this.label,
    required this.retryLabel,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 18,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: () => onRetry(message),
            icon: const Icon(Icons.refresh_rounded, size: 17),
            label: Text(retryLabel),
          ),
        ],
      ),
    );
  }
}
