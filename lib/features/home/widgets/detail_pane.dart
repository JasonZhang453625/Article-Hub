import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/display_providers.dart';
import '../../../shared/providers/article_providers.dart';
import '../../reader/summary_screen.dart';

class DetailPane extends ConsumerWidget {
  const DetailPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedId = ref.watch(selectedArticleIdProvider);
    final theme = Theme.of(context);

    if (selectedId == null) {
      return _EmptyState(theme: theme);
    }

    final articlesAsync = ref.watch(articlesProvider);
    final article = articlesAsync.maybeWhen(
      data: (list) => list.where((a) => a.id == selectedId).firstOrNull,
      orElse: () => null,
    );

    if (article == null) {
      ref.read(selectedArticleIdProvider.notifier).state = null;
      return _EmptyState(theme: theme);
    }

    return Column(
      children: [
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLowest,
            border: Border(
              bottom: BorderSide(
                color: theme.dividerColor.withValues(alpha: 0.15),
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.auto_awesome_rounded,
                  size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                article.source.displayName,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 20),
                tooltip: 'Close',
                onPressed: () {
                  ref.read(selectedArticleIdProvider.notifier).state = null;
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: SummaryContent(article: article),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  final ThemeData theme;

  const _EmptyState({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.touch_app_rounded,
            size: 40,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.15),
          ),
          const SizedBox(height: 12),
          Text(
            'Select an article to view its summary',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
            ),
          ),
        ],
      ),
    );
  }
}
