import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:go_router/go_router.dart';
import '../../data/models/passage.dart';
import '../../config/routes.dart';
import '../../shared/providers/locale_provider.dart';
import '../../shared/providers/passage_providers.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/utils/date_formatter.dart';
import '../../shared/utils/snackbar_helpers.dart';
import 'summary_regeneration_provider.dart';

class SummaryScreen extends ConsumerWidget {
  final Article article;

  const SummaryScreen({super.key, required this.article});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);

    // Watch the provider so the page auto-refreshes when the background
    // summarization finishes and updates the article.
    final articlesAsync = ref.watch(articlesProvider);
    final latest = articlesAsync.maybeWhen(
      data: (list) => list.where((a) => a.id == article.id).firstOrNull,
      orElse: () => null,
    );
    // Fall back to the route-passed article if provider hasn't loaded yet.
    final a = latest ?? article;

    return Scaffold(
      appBar: AppBar(
        title: Text(a.source.displayName, style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_browser_rounded),
            tooltip: s.openInBrowser,
            onPressed: () {
              context.push(AppRoutes.readerWithId(a.id), extra: a);
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded, color: Colors.red),
            tooltip: s.delete,
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(s.deleteArticle),
                  content: Text(s.deleteConfirm),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: Text(s.cancel),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.red,
                      ),
                      child: Text(s.delete),
                    ),
                  ],
                ),
              );
              if (confirmed == true && context.mounted) {
                try {
                  await ref.read(articlesProvider.notifier).delete(a.id);
                  if (context.mounted) Navigator.of(context).pop();
                } catch (e) {
                  if (!context.mounted) return;
                  final s2 = ref.read(stringsProvider);
                  showAppSnackBar(context, message: '${s2.saveFailed}: $e');
                }
              }
            },
          ),
        ],
      ),
      body: SummaryContent(article: a),
    );
  }
}

class SummaryContent extends ConsumerWidget {
  final Article article;

  const SummaryContent({super.key, required this.article});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final s = ref.watch(stringsProvider);

    final articlesAsync = ref.watch(articlesProvider);
    final latest = articlesAsync.maybeWhen(
      data: (list) => list.where((a) => a.id == article.id).firstOrNull,
      orElse: () => null,
    );
    final a = latest ?? article;
    final regeneratingTags = ref.watch(
      summaryRegenerationProvider.select(
        (ids) => ids.contains(article.id),
      ),
    )
        ? ref.watch(
            summaryRegenerationTagsProvider.select(
              (tags) => tags[article.id] ?? const <String>[],
            ),
          )
        : const <String>[];

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title
          Text(
            a.title,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              height: 1.3,
            ),
          ),

          const SizedBox(height: 24),

          // Summary section
          _SummarySection(article: a, theme: theme, isDark: isDark),

          const SizedBox(height: 16),

          // Tags — merge with the current list so a newly generated summary
          // (whose tags may not be in this screen's article snapshot yet)
          // never loses the tags the user just saw.
          if (a.tags.isNotEmpty || regeneratingTags.isNotEmpty) ...[
            if (regeneratingTags.isNotEmpty) ...[
              Text(
                s.tags,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              _TagsWrap(
                tags: regeneratingTags,
                theme: theme,
                isDark: isDark,
              ),
              const SizedBox(height: 16),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: a.tags
                  .map(
                    (tag) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.08)
                            : const Color(0xFFF2F6F9),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        tag,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 16),
          ],

          // Notes
          if (a.notes.isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.05)
                    : const Color(0xFFF8FAFB),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                a.notes,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: isDark ? Colors.white70 : const Color(0xFF4A6B7C),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // URL display
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.04)
                  : const Color(0xFFF2F6F9),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              a.url,
              style: theme.textTheme.bodySmall?.copyWith(
                color: isDark ? Colors.white38 : const Color(0xFF98ADB8),
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          const SizedBox(height: 32),

          // Read Original button
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () {
                context.push(AppRoutes.readerWithId(a.id), extra: a);
              },
              icon: const Icon(Icons.chrome_reader_mode_rounded),
              label: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(s.readOriginal),
              ),
            ),
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _TagsWrap extends StatelessWidget {
  final List<String> tags;
  final ThemeData theme;
  final bool isDark;

  const _TagsWrap({
    required this.tags,
    required this.theme,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: tags
          .map(
            (tag) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : const Color(0xFFF2F6F9),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                tag,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}

class _SummarySection extends ConsumerStatefulWidget {
  final Article article;
  final ThemeData theme;
  final bool isDark;

  const _SummarySection({
    required this.article,
    required this.theme,
    required this.isDark,
  });

  @override
  ConsumerState<_SummarySection> createState() => _SummarySectionState();
}

class _SummarySectionState extends ConsumerState<_SummarySection> {
  Future<void> _regenerate() async {
    final settings = ref.read(settingsProvider).valueOrNull;
    if (settings == null || ref.read(summaryAiGatewayProvider) == null) {
      return;
    }

    final result = await ref
        .read(summaryRegenerationProvider.notifier)
        .regenerate(widget.article, settings);
    if (!mounted || result.succeeded) return;

    final s = ref.read(stringsProvider);
    final detail = result.error;
    showAppSnackBar(
      context,
      message: detail == null ? s.summaryFailed : '${s.summaryFailed}\n$detail',
    );
  }

  bool _isRegenerating() {
    return ref.watch(
      summaryRegenerationProvider.select(
        (articleIds) => articleIds.contains(widget.article.id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final isDark = widget.isDark;
    final summary = widget.article.displayMemoryMarkdown;
    final aiConfigured = ref.watch(summaryAiGatewayProvider) != null;
    final s = ref.watch(stringsProvider);
    final pipelineGenerating =
        widget.article.processingStage == ProcessingStage.summary;
    final regenerating = _isRegenerating() || pipelineGenerating;

    if (summary.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.04)
              : const Color(0xFFF8FAFB),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : const Color(0xFFE8EEF2),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.auto_awesome_rounded,
                  size: 20,
                  color: isDark ? Colors.white38 : const Color(0xFF98ADB8),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    aiConfigured
                        ? s.aiSummaryNotGenerated
                        : s.aiSummaryNotAvailable,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: isDark ? Colors.white38 : const Color(0xFF98ADB8),
                    ),
                  ),
                ),
              ],
            ),
            if (aiConfigured) ...[
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: regenerating ? null : _regenerate,
                  icon: regenerating
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_awesome_rounded, size: 18),
                  label: Text(regenerating ? s.generating : s.generateSummary),
                ),
              ),
            ],
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.04)
            : const Color(0xFFF8FAFB),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : const Color(0xFFE8EEF2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                widget.article.isFullText
                    ? Icons.article_outlined
                    : Icons.auto_awesome_rounded,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                widget.article.isFullText
                    ? (widget.article.imageUnderstanding != null
                          ? s.imageTranscriptionFullText
                          : s.memoryLabelOriginal)
                    : s.memoryLabelAi,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (widget.article.lastProcessedAt != null) ...[
                const SizedBox(width: 8),
                Text(
                  formatRelative(widget.article.lastProcessedAt!),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary.withValues(alpha: 0.65),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
              const Spacer(),
              if (aiConfigured && !widget.article.isFullText)
                InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: regenerating ? null : _regenerate,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: regenerating
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            Icons.refresh_rounded,
                            size: 18,
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.6,
                            ),
                          ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          MarkdownBody(
            data: summary,
            selectable: true,
            styleSheet: MarkdownStyleSheet(
              p: theme.textTheme.bodyLarge?.copyWith(
                fontSize: 17,
                height: 1.4,
              ),
              strong: theme.textTheme.bodyLarge?.copyWith(
                fontSize: 17,
                height: 1.4,
                fontWeight: FontWeight.w700,
              ),
              em: theme.textTheme.bodyLarge?.copyWith(
                fontSize: 17,
                height: 1.4,
                fontStyle: FontStyle.italic,
              ),
              listBullet: theme.textTheme.bodyLarge?.copyWith(
                fontSize: 17,
                height: 1.4,
              ),
            ),
          ),
          if (!widget.article.isFullText &&
              widget.article.imageUnderstanding != null) ...[
            const SizedBox(height: 12),
            const Divider(),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              title: Text(
                s.imageTranscriptionFullText,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: MarkdownBody(
                    data: widget.article.imageUnderstanding!.combinedMarkdown,
                    selectable: true,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
