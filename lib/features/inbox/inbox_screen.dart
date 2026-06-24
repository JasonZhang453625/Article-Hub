import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/models/passage.dart';
import '../../data/services/processing_pipeline.dart';
import '../../shared/providers/passage_providers.dart';

class InboxScreen extends ConsumerWidget {
  const InboxScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pendingAsync = ref.watch(pendingArticlesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Inbox')),
      body: pendingAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (articles) {
          if (articles.isEmpty) {
            return const _EmptyInbox();
          }

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
                _SectionHeader('Processing', processing.length),
                for (final article in processing)
                  _InboxTile(
                    article: article,
                    subtitle: _stageLabel(article.processingStage),
                    showRetry: false,
                  ),
              ],
              if (pending.isNotEmpty) ...[
                _SectionHeader('Waiting', pending.length),
                for (final article in pending)
                  _InboxTile(article: article, subtitle: 'Queued', showRetry: false),
              ],
              if (failed.isNotEmpty) ...[
                _SectionHeader('Failed', failed.length),
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

  String _stageLabel(ProcessingStage? stage) {
    switch (stage) {
      case ProcessingStage.metadata:
        return 'Fetching metadata';
      case ProcessingStage.content:
        return 'Extracting content';
      case ProcessingStage.summary:
        return 'Generating summary';
      case ProcessingStage.tags:
        return 'Generating tags';
      case ProcessingStage.folderSuggestion:
        return 'Suggesting folder';
      case ProcessingStage.indexing:
        return 'Indexing';
      default:
        return 'Processing';
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
              tooltip: 'Retry',
              onPressed: () {
                ref.read(processingPipelineProvider).retry(article);
              },
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded),
            tooltip: 'Delete',
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Delete article?'),
                  content: Text('Remove "${article.title}" from inbox?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                ref.read(articlesProvider.notifier).delete(article.id);
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

class _EmptyInbox extends StatelessWidget {
  const _EmptyInbox();

  @override
  Widget build(BuildContext context) {
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
            'Inbox is empty',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Shared links will appear here while processing.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}
