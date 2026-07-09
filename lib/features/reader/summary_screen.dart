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
                      style: FilledButton.styleFrom(backgroundColor: Colors.red),
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
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('${s2.saveFailed}: $e')),
                  );
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

    return SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Source badge
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: a.source.accentColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    a.source.icon,
                    size: 16,
                    color: a.source.accentColor,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${a.source.displayName}  ·  ${formatRelative(a.updatedAt)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: isDark ? Colors.white54 : const Color(0xFF6C8594),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (a.isFavorite) ...[
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.star_rounded,
                    color: Color(0xFFF5B301),
                    size: 16,
                  ),
                ],
              ],
            ),

            const SizedBox(height: 16),

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

            // Tags
            if (a.tags.isNotEmpty) ...[
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
    if (settings == null ||
        settings.aiBaseUrl.trim().isEmpty ||
        settings.aiApiKey.trim().isEmpty) {
      return;
    }

    final result = await ref
        .read(summaryRegenerationProvider.notifier)
        .regenerate(widget.article, settings);
    if (!mounted || result.succeeded) return;

    final s = ref.read(stringsProvider);
    final detail = result.error;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          detail == null ? s.summaryFailed : '${s.summaryFailed}\n$detail',
        ),
      ),
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
    final summary = widget.article.summary;
    final aiConfigured = ref.watch(aiConfiguredProvider);
    final s = ref.watch(stringsProvider);
    final regenerating = _isRegenerating();

    if (summary == null || summary.isEmpty) {
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
                Icons.auto_awesome_rounded,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                s.aiSummary,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              if (aiConfigured)
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
              p: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
              strong: theme.textTheme.bodyLarge?.copyWith(
                height: 1.6,
                fontWeight: FontWeight.w700,
              ),
              em: theme.textTheme.bodyLarge?.copyWith(
                height: 1.6,
                fontStyle: FontStyle.italic,
              ),
              listBullet: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
            ),
          ),
        ],
      ),
    );
  }
}
