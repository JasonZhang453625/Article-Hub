import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/models/passage.dart';
import '../shared/providers/passage_providers.dart';

/// Resolves an [Article] for routes that may be restored without their `extra`
/// payload (e.g. after the OS kills and restores the process). When [article]
/// is provided it is used directly; otherwise the article is looked up by [id]
/// from the repository. If it cannot be found, a friendly fallback is shown
/// instead of crashing on a null cast.
class ArticleResolver extends ConsumerWidget {
  final Article? article;
  final String? id;
  final Widget Function(Article article) builder;

  const ArticleResolver({
    super.key,
    required this.article,
    required this.id,
    required this.builder,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final existing = article;
    if (existing != null) {
      return builder(existing);
    }

    final articleId = id;
    if (articleId == null || articleId.isEmpty) {
      return _NotFoundScaffold();
    }

    final repoAsync = ref.watch(articleRepositoryProvider);
    return repoAsync.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => _NotFoundScaffold(message: 'Failed to load article: $e'),
      data: (repo) {
        final found = repo.getById(articleId);
        if (found == null) {
          return _NotFoundScaffold();
        }
        return builder(found);
      },
    );
  }
}

class _NotFoundScaffold extends StatelessWidget {
  final String message;

  const _NotFoundScaffold({this.message = 'This article is no longer available.'});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/');
            }
          },
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.article_outlined,
                size: 48,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
