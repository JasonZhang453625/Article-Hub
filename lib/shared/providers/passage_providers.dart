import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../data/models/passage.dart';
import '../../data/repositories/passage_repository.dart';

final hiveInitProvider = FutureProvider<void>((ref) async {
  await Hive.initFlutter();
  if (!Hive.isAdapterRegistered(Article.typeId)) {
    Hive.registerAdapter(ArticleAdapter());
  }
  if (!Hive.isAdapterRegistered(1)) {
    Hive.registerAdapter(SourcePlatformAdapter());
  }
});

final articleRepositoryProvider = FutureProvider<ArticleRepository>((
  ref,
) async {
  await ref.watch(hiveInitProvider.future);
  final repo = ArticleRepository();
  await repo.init();
  return repo;
});

final articlesProvider =
    StateNotifierProvider<ArticlesNotifier, AsyncValue<List<Article>>>((ref) {
      return ArticlesNotifier(ref);
    });

class ArticlesNotifier extends StateNotifier<AsyncValue<List<Article>>> {
  final Ref _ref;

  ArticlesNotifier(this._ref) : super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    final repo = await _ref.read(articleRepositoryProvider.future);
    state = AsyncValue.data(repo.getAll());
  }

  Future<void> add(Article article) async {
    final repo = await _ref.read(articleRepositoryProvider.future);
    await repo.add(article);
    state = AsyncValue.data(repo.getAll());
  }

  Future<void> update(Article article) async {
    final repo = await _ref.read(articleRepositoryProvider.future);
    await repo.update(article);
    state = AsyncValue.data(repo.getAll());
  }

  Future<void> delete(String id) async {
    final repo = await _ref.read(articleRepositoryProvider.future);
    await repo.delete(id);
    state = AsyncValue.data(repo.getAll());
  }

  void refresh() {
    _load();
  }
}

final searchQueryProvider = StateProvider<String>((ref) => '');

final selectedSourceProvider = StateProvider<String>((ref) => '');

final filteredArticlesProvider = Provider<AsyncValue<List<Article>>>((ref) {
  final articlesAsync = ref.watch(articlesProvider);
  final query = ref.watch(searchQueryProvider);
  final sourceName = ref.watch(selectedSourceProvider);

  return articlesAsync.whenData((articles) {
    var filtered = articles;

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

    return filtered;
  });
});
