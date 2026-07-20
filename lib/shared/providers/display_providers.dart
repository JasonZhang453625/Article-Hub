import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/models/passage.dart';
import '../../data/models/filter_group.dart';
import 'article_providers.dart';
import 'filter_providers.dart';
import 'settings_providers.dart';

final selectedArticleIdProvider = StateProvider<String?>((ref) => null);

final filteredArticlesProvider = Provider<AsyncValue<List<Article>>>((ref) {
  final articlesAsync = ref.watch(articlesProvider);
  final query = ref.watch(searchQueryProvider);
  final sourceName = ref.watch(selectedSourceProvider);
  final selectedFilterId = ref.watch(selectedFilterGroupProvider);
  final folderId = ref.watch(selectedFolderIdProvider);
  final newestFirst = ref.watch(memorySortNewestFirstProvider);

  final filterGroupsAsync = selectedFilterId.isNotEmpty
      ? ref.watch(filterGroupsProvider)
      : const AsyncValue.data(<FilterGroup>[]);

  return articlesAsync.whenData((articles) {
    var filtered = articles;

    if (folderId.isNotEmpty) {
      if (folderId == '__unfiled') {
        filtered = filtered.where((a) => a.folderId == null).toList();
      } else {
        filtered = filtered.where((a) => a.folderId == folderId).toList();
      }
    }

    if (query.isNotEmpty) {
      final lower = query.toLowerCase();
      filtered = filtered.where((article) {
        return article.title.toLowerCase().contains(lower) ||
            article.url.toLowerCase().contains(lower) ||
            article.notes.toLowerCase().contains(lower) ||
            article.tags.any((tag) => tag.toLowerCase().contains(lower));
      }).toList();
    }

    if (sourceName.isNotEmpty) {
      filtered = filtered
          .where((article) => article.source.name == sourceName)
          .toList();
    }

    if (selectedFilterId.isNotEmpty) {
      final groups = filterGroupsAsync.valueOrNull ?? [];
      final group = groups.where((g) => g.id == selectedFilterId).firstOrNull;
      if (group != null) {
        filtered = filtered.where((article) {
          bool matchesTags =
              group.tagPatterns.isEmpty ||
              group.tagPatterns.any((pattern) {
                final lower = pattern.toLowerCase();
                return article.tags.any(
                  (tag) => tag.toLowerCase().contains(lower),
                );
              });
          bool matchesSource =
              group.sourcePlatforms.isEmpty ||
              group.sourcePlatforms.contains(article.source.name);
          return matchesTags && matchesSource;
        }).toList();
      }
    }

    return sortArticlesByCreatedAt(filtered, newestFirst: newestFirst);
  });
});

List<Article> sortArticlesByCreatedAt(
  Iterable<Article> articles, {
  required bool newestFirst,
}) {
  return articles.toList()..sort(
    newestFirst
        ? (a, b) => b.createdAt.compareTo(a.createdAt)
        : (a, b) => a.createdAt.compareTo(b.createdAt),
  );
}

final knowledgeBaseArticlesProvider = Provider<AsyncValue<List<Article>>>((
  ref,
) {
  final filtered = ref.watch(filteredArticlesProvider);
  return filtered.whenData(
    (articles) => articles
        .where((a) => a.processingStatus == ProcessingStatus.completed)
        .toList(),
  );
});

final pendingArticlesProvider = Provider<AsyncValue<List<Article>>>((ref) {
  final filtered = ref.watch(filteredArticlesProvider);
  return filtered.whenData(
    (articles) => articles
        .where((a) => a.processingStatus != ProcessingStatus.completed)
        .toList(),
  );
});
