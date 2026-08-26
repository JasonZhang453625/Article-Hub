import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown/markdown.dart' as md;
import 'dart:convert';

import '../../data/models/passage.dart';
import '../../data/models/chat_attachment.dart';
import '../../shared/providers/locale_provider.dart';
import '../../shared/utils/locale_strings.dart';
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

    if (message.isPending &&
        message.text.trim().isEmpty &&
        message.toolEvents.isEmpty) {
      // The in-flight answer is a real (persisted) message now. Show the
      // animated working label while the Agent thinks, before any tool call
      // or visible text has arrived.
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _WorkingIndicator(
          toolEvents: message.toolEvents,
          thinkingLabel: s.chatWorkingThinking,
          retrievingLabel: s.chatWorkingRetrieving,
          boilingLabel: s.chatWorkingBoiling,
        ),
      );
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
            margin: const EdgeInsets.only(bottom: 25),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (message.attachments.isNotEmpty) ...[
                  _ChatMessageAttachments(
                    attachments: message.attachments,
                    foregroundColor: theme.colorScheme.onPrimary,
                  ),
                  if (message.text.trim().isNotEmpty)
                    const SizedBox(height: 10),
                ],
                if (message.text.trim().isNotEmpty)
                  SelectableText(
                    message.text,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onPrimary,
                      fontSize: 16,
                    ),
                  ),
              ],
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
        if (message.isPending && message.text.trim().isEmpty)
          _WorkingIndicator(
            toolEvents: message.toolEvents,
            thinkingLabel: s.chatWorkingThinking,
            retrievingLabel: s.chatWorkingRetrieving,
            boilingLabel: s.chatWorkingBoiling,
          ),
        if (message.toolEvents.isNotEmpty)
          _ToolCallList(events: message.toolEvents, s: s),
        MarkdownBody(
          data: message.text,
          selectable: true,
          builders: {'pre': _CodeBlockBuilder()},
          styleSheet: MarkdownStyleSheet(
            blockSpacing: 18,
            pPadding: const EdgeInsets.only(bottom: 12),
            horizontalRuleDecoration: const BoxDecoration(),
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
        if (message.isPending && message.text.trim().isNotEmpty) ...[
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

class _ChatMessageAttachments extends StatelessWidget {
  final List<ChatAttachment> attachments;
  final Color foregroundColor;

  const _ChatMessageAttachments({
    required this.attachments,
    required this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: attachments
          .map(
            (attachment) => Container(
              key: ValueKey('chat-message-attachment-${attachment.id}'),
              constraints: const BoxConstraints(maxWidth: 220),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: foregroundColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: foregroundColor.withValues(alpha: 0.24),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    attachment.isImage
                        ? Icons.image_outlined
                        : Icons.description_outlined,
                    size: 18,
                    color: foregroundColor,
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      attachment.originalFileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.labelMedium?.copyWith(color: foregroundColor),
                    ),
                  ),
                ],
              ),
            ),
          )
          .toList(growable: false),
    );
  }
}

class _CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) {
    // flutter_markdown 0.7.x keeps code text flowing through the inline
    // pipeline when a custom `pre` builder is registered. Returning a widget
    // (instead of null) consumes the text node so the inline stack drains and
    // parsing completes; the actual code content is read from the element in
    // visitElementAfterWithContext.
    return const SizedBox.shrink();
  }

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    md.Element? codeElement;
    for (final child in element.children ?? const <md.Node>[]) {
      if (child is md.Element && child.tag == 'code') {
        codeElement = child;
        break;
      }
    }
    final code = _trimParserNewline(element.textContent);
    return _CodeBlock(
      language: _languageLabel(codeElement?.attributes['class']),
      code: code,
    );
  }

  static String _trimParserNewline(String value) {
    return value.endsWith('\n') ? value.substring(0, value.length - 1) : value;
  }

  static String _languageLabel(String? className) {
    final languageClass = className
        ?.split(' ')
        .map((value) => value.trim())
        .firstWhere((value) => value.startsWith('language-'), orElse: () => '');
    final language = languageClass?.replaceFirst('language-', '') ?? '';
    if (language.isEmpty) return 'TEXT';

    switch (language.toLowerCase()) {
      case 'csharp':
      case 'cs':
        return 'C#';
      case 'cpp':
      case 'c++':
        return 'C++';
      case 'javascript':
      case 'js':
        return 'JavaScript';
      case 'typescript':
      case 'ts':
        return 'TypeScript';
      default:
        return language.toUpperCase();
    }
  }
}

class _CodeBlock extends StatefulWidget {
  final String language;
  final String code;

  const _CodeBlock({required this.language, required this.code});

  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  var _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final codeStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: colorScheme.onSurface,
      fontFamily: 'monospace',
      fontSize: 14,
      height: 1.45,
    );

    return Container(
      // Paragraphs have a 12px trailing gap. Keep the code card 3px below
      // its preceding paragraph, so the visible gap is 15px; use 15px below
      // the card before the following paragraph.
      margin: const EdgeInsets.only(top: 3, bottom: 15),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.25)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: colorScheme.surfaceContainerHigh,
            padding: const EdgeInsets.only(left: 12, right: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.language,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _copy,
                  tooltip: _copied ? '已复制' : '复制代码',
                  icon: Icon(
                    _copied ? Icons.check_rounded : Icons.content_copy_rounded,
                    size: 18,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          Scrollbar(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(12),
              child: Text(widget.code, style: codeStyle, softWrap: false),
            ),
          ),
        ],
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

class _WorkingIndicator extends StatefulWidget {
  final List<String> toolEvents;
  final String thinkingLabel;
  final String retrievingLabel;
  final String boilingLabel;

  const _WorkingIndicator({
    required this.toolEvents,
    required this.thinkingLabel,
    required this.retrievingLabel,
    required this.boilingLabel,
  });

  @override
  State<_WorkingIndicator> createState() => _WorkingIndicatorState();
}

class _WorkingIndicatorState extends State<_WorkingIndicator> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    var label = widget.thinkingLabel;
    if (widget.toolEvents.isNotEmpty) {
      final hasCompletedTool = widget.toolEvents.any(
        (raw) => raw.contains('"state":"completed"'),
      );
      label = hasCompletedTool ? widget.boilingLabel : widget.retrievingLabel;
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
            ),
          ),
          const SizedBox(width: 10),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: Text(
              label,
              key: ValueKey(label),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolCallList extends StatelessWidget {
  final List<String> events;
  final LocaleStrings s;

  const _ToolCallList({required this.events, required this.s});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final rows = <Widget>[];
    for (final raw in events) {
      Map<String, dynamic> event;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) continue;
        event = decoded;
      } catch (_) {
        continue;
      }
      final tool = (event['tool'] ?? '').toString().trim();
      final state = (event['state'] ?? '').toString();
      if (tool.isEmpty || state.isEmpty) continue;

      final String line;
      final IconData icon;
      switch (state) {
        case 'started':
          icon = Icons.build_circle_outlined;
          final query = (event['query'] ?? '').toString().trim();
          line = tool == 'web_search'
              ? query.isEmpty
                    ? '🔎 ${s.chatToolSearching}'
                    : '🔎 ${s.chatToolSearching}: $query'
              : '🛠️ ${s.chatToolCalling}: $tool';
          break;
        case 'completed':
          icon = Icons.check_circle_outline;
          final sourceCount = event['sourceCount'];
          final sources = sourceCount is num && sourceCount > 0
              ? ' (${sourceCount.toInt()} ${s.chatToolSources})'
              : '';
          line = '✓ ${s.chatToolCompleted}: $tool$sources';
          break;
        case 'failed':
          icon = Icons.error_outline;
          line = '⚠️ ${s.chatToolFailed}: $tool';
          break;
        default:
          icon = Icons.settings_outlined;
          line = tool;
      }
      rows.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(icon, size: 16, color: colorScheme.onSurfaceVariant),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  line,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }
}
