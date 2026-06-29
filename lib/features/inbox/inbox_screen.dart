import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/models/passage.dart';
import '../../shared/providers/pipeline_provider.dart';
import '../../shared/providers/locale_provider.dart';
import '../../shared/providers/passage_providers.dart';
import '../../shared/utils/locale_strings.dart';

class InboxScreen extends ConsumerStatefulWidget {
  const InboxScreen({super.key});

  @override
  ConsumerState<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends ConsumerState<InboxScreen> {
  bool _recoveryStarted = false;

  void _recoverInterrupted(List<Article> articles) {
    if (_recoveryStarted) return;
    final interrupted = articles
        .where((a) => a.processingStatus == ProcessingStatus.processing)
        .toList();
    if (interrupted.isEmpty) return;
    _recoveryStarted = true;
    Future.microtask(() async {
      final pipeline = ref.read(processingPipelineProvider);
      for (final article in interrupted) {
        await pipeline.process(article);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final pendingAsync = ref.watch(pendingArticlesProvider);

    // Reset recovery flag when data reloads (e.g. after all recovered).
    pendingAsync.whenData((articles) {
      if (articles.isEmpty) {
        _recoveryStarted = false;
      }
    });

    return Scaffold(
      appBar: AppBar(title: Text(s.tabInbox)),
      body: pendingAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Error: $e'),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () => ref.invalidate(articlesProvider),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (articles) {
          if (articles.isEmpty) {
            _recoveryStarted = false;
            return const _EmptyInbox();
          }

          _recoverInterrupted(articles);

          final processing =
              articles.where((a) => a.processingStatus == ProcessingStatus.processing).toList();
          final pending =
              articles.where((a) => a.processingStatus == ProcessingStatus.pending).toList();
          final failed =
              articles.where((a) => a.processingStatus == ProcessingStatus.failed).toList();

          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              if (processing.isNotEmpty) ...[
                _SectionHeader(s.processing, processing.length),
                for (final article in processing)
                  _InboxTile(
                    article: article,
                    subtitle: _stageLabel(article.processingStage, s),
                    showRetry: false,
                  ),
              ],
              if (pending.isNotEmpty) ...[
                _SectionHeader(s.waiting, pending.length),
                for (final article in pending)
                  _InboxTile(article: article, subtitle: s.queued, showRetry: false),
              ],
              if (failed.isNotEmpty) ...[
                _SectionHeader(s.failedSection, failed.length),
                for (final article in failed)
                  _InboxTile(
                    article: article,
                    subtitle: article.processingError ?? 'Unknown error',
                    showRetry: true,
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  String _stageLabel(ProcessingStage? stage, LocaleStrings s) {
    switch (stage) {
      case ProcessingStage.metadata:
        return s.fetchingMetadata;
      case ProcessingStage.content:
        return s.extractingContent;
      case ProcessingStage.summary:
        return s.generatingSummary;
      case ProcessingStage.tags:
        return s.generatingTags;
      case ProcessingStage.folderSuggestion:
        return s.suggestingFolder;
      case ProcessingStage.indexing:
        return s.indexing;
      default:
        return s.processing;
    }
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;
  const _SectionHeader(this.title, this.count);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(99),
            ),
            child: Text(
              '$count',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _InboxTile extends ConsumerWidget {
  final Article article;
  final String subtitle;
  final bool showRetry;

  const _InboxTile({
    required this.article,
    required this.subtitle,
    required this.showRetry,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final colorScheme = Theme.of(context).colorScheme;

    return ListTile(
      leading: Icon(
        _statusIcon(article.processingStatus),
        color: _statusColor(article.processingStatus, colorScheme),
      ),
      title: Text(
        article.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: article.processingStatus == ProcessingStatus.failed
              ? colorScheme.error
              : null,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (article.retryCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(
                'x${article.retryCount}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          if (showRetry)
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: s.retry,
              onPressed: () {
                try {
                  ref.read(processingPipelineProvider).retry(article);
                } catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('${s.saveFailed}: $e')),
                  );
                }
              },
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded),
            tooltip: s.delete,
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(s.deleteArticleQ),
                  content: Text('${s.removeFromInbox} "${article.title}"'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(s.cancel),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(s.delete),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                try {
                  await ref.read(articlesProvider.notifier).delete(article.id);
                } catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('${s.saveFailed}: $e')),
                  );
                }
              }
            },
          ),
        ],
      ),
    );
  }

  IconData _statusIcon(ProcessingStatus status) {
    switch (status) {
      case ProcessingStatus.pending:
        return Icons.schedule_rounded;
      case ProcessingStatus.processing:
        return Icons.sync_rounded;
      case ProcessingStatus.failed:
        return Icons.error_outline_rounded;
      default:
        return Icons.article_outlined;
    }
  }

  Color _statusColor(ProcessingStatus status, ColorScheme scheme) {
    switch (status) {
      case ProcessingStatus.pending:
        return scheme.onSurfaceVariant;
      case ProcessingStatus.processing:
        return scheme.primary;
      case ProcessingStatus.failed:
        return scheme.error;
      default:
        return scheme.onSurface;
    }
  }
}

class _EmptyInbox extends ConsumerWidget {
  const _EmptyInbox();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.inbox_rounded,
            size: 64,
            color: Theme.of(context).colorScheme.onSurfaceVariant.withAlpha(80),
          ),
          const SizedBox(height: 16),
          Text(
            s.inboxEmpty,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            s.inboxEmptyDesc,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}
