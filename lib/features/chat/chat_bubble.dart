import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/passage.dart';
import 'chat_message.dart';
import 'chat_citation_chips.dart';
import 'chat_feedback.dart';
import 'chat_no_result.dart';

class ChatBubble extends ConsumerWidget {
  final ChatMessage message;
  final List<Article> articles;
  final ValueChanged<int> onFeedback;
  final ValueChanged<String> onCitationClick;
  final ValueChanged<String> onSuggestionTap;
  final VoidCallback onBrowseKnowledge;

  const ChatBubble({
    super.key,
    required this.message,
    required this.articles,
    required this.onFeedback,
    required this.onCitationClick,
    required this.onSuggestionTap,
    required this.onBrowseKnowledge,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isUser = message.role == MessageRole.user;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        decoration: BoxDecoration(
          color: isUser
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(18).copyWith(
            bottomRight: isUser ? const Radius.circular(4) : null,
            bottomLeft: !isUser ? const Radius.circular(4) : null,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            isUser
                ? SelectableText(
                    message.text,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onPrimary,
                    ),
                  )
                : MarkdownBody(
                    data: message.text,
                    selectable: true,
                    styleSheet: MarkdownStyleSheet(
                      p: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                      strong: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                      em: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontStyle: FontStyle.italic,
                      ),
                      code: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface,
                        backgroundColor: theme.colorScheme.surfaceContainerHighest,
                        fontFamily: 'monospace',
                        fontSize: 13,
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
                      ),
                      blockquoteDecoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            color: theme.colorScheme.primary.withValues(alpha: 0.4),
                            width: 3,
                          ),
                        ),
                      ),
                      listBullet: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                      h1: theme.textTheme.titleLarge?.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                      h2: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                      h3: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                      a: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.primary,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
            if (!isUser && message.articleIds.isNotEmpty) ...[
              const SizedBox(height: 12),
              CitationChips(
                articleIds: message.articleIds,
                articles: articles,
                onCitationClick: onCitationClick,
              ),
            ],
            if (!isUser && message.isNoResult) ...[
              const SizedBox(height: 12),
              ChatNoResultActions(
                query: message.query ?? '',
                weakArticleIds: message.weakArticleIds,
                articles: articles,
                onSuggestionTap: onSuggestionTap,
                onBrowseKnowledge: onBrowseKnowledge,
                onCitationClick: onCitationClick,
              ),
            ],
            if (!isUser && !message.isNoResult && message.logId != null) ...[
              const SizedBox(height: 10),
              ChatFeedbackRow(
                message: message,
                onFeedback: onFeedback,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
