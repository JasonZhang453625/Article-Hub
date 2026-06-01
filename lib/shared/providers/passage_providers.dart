import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../data/models/passage.dart';
import '../../data/models/settings.dart';
import '../../data/models/filter_group.dart';
import '../../data/models/source_platform.dart';
import '../../data/repositories/passage_repository.dart';
import '../utils/url_helpers.dart';
import 'filter_providers.dart';

final hiveInitProvider = FutureProvider<void>((ref) async {
  await Hive.initFlutter();
  if (!Hive.isAdapterRegistered(Article.typeId)) {
    Hive.registerAdapter(ArticleAdapter());
  }
  if (!Hive.isAdapterRegistered(1)) {
    Hive.registerAdapter(SourcePlatformAdapter());
  }
  if (!Hive.isAdapterRegistered(AppSettings.typeId)) {
    Hive.registerAdapter(AppSettingsAdapter());
  }
  if (!Hive.isAdapterRegistered(FilterGroup.typeId)) {
    Hive.registerAdapter(FilterGroupAdapter());
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

  /// Imports a batch of articles (merge by id) and refreshes state.
  /// Returns the number of articles written.
  Future<int> importAll(Iterable<Article> articles) async {
    final repo = await _ref.read(articleRepositoryProvider.future);
    final count = await repo.importAll(articles);
    state = AsyncValue.data(repo.getAll());
    return count;
  }

  /// Creates and saves an article for each URL, auto-detecting the source
  /// platform and using the domain as a placeholder title. Returns the number
  /// of articles created.
  Future<int> addMany(Iterable<String> urls) async {
    final uuid = const Uuid();
    final articles = <Article>[];
    for (final url in urls) {
      final cleaned = cleanUrl(url);
      if (!isValidUrl(cleaned)) continue;
      articles.add(
        Article(
          id: uuid.v4(),
          url: cleaned,
          title: extractDomain(cleaned),
          source: SourcePlatform.fromUrl(cleaned),
        ),
      );
    }
    if (articles.isEmpty) return 0;
    return importAll(articles);
  }

  void refresh() {
    _load();
  }
}

final searchQueryProvider = StateProvider<String>((ref) => '');

final selectedSourceProvider = StateProvider<String>((ref) => '');

final homeHeaderVisibilityProvider =
    StateNotifierProvider<HomeHeaderVisibilityNotifier, AsyncValue<bool>>((
      ref,
    ) {
      return HomeHeaderVisibilityNotifier(ref);
    });

class HomeHeaderVisibilityNotifier extends StateNotifier<AsyncValue<bool>> {
  static const String _boxName = 'ui_preferences';
  static const String _key = 'show_home_header';

  final Ref _ref;
  Box<dynamic>? _box;

  HomeHeaderVisibilityNotifier(this._ref) : super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    await _ref.read(hiveInitProvider.future);
    _box ??= await Hive.openBox(_boxName);
    final isVisible = _box!.get(_key, defaultValue: true) as bool;
    state = AsyncValue.data(isVisible);
  }

  Future<void> dismiss() async {
    _box ??= await Hive.openBox(_boxName);
    await _box!.put(_key, false);
    state = const AsyncValue.data(false);
  }
}

final filteredArticlesProvider = Provider<AsyncValue<List<Article>>>((ref) {
  final articlesAsync = ref.watch(articlesProvider);
  final query = ref.watch(searchQueryProvider);
  final sourceName = ref.watch(selectedSourceProvider);
  final selectedFilterId = ref.watch(selectedFilterGroupProvider);
  final filterGroupsAsync = ref.watch(filterGroupsProvider);

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

    // Apply custom filter group
    if (selectedFilterId.isNotEmpty) {
      final groups = filterGroupsAsync.valueOrNull ?? [];
      final group = groups.where((g) => g.id == selectedFilterId).firstOrNull;
      if (group != null) {
        filtered = filtered.where((article) {
          bool matchesTags = group.tagPatterns.isEmpty ||
              group.tagPatterns.any((pattern) {
                final lower = pattern.toLowerCase();
                return article.tags
                    .any((tag) => tag.toLowerCase().contains(lower));
              });
          bool matchesSource = group.sourcePlatforms.isEmpty ||
              group.sourcePlatforms.contains(article.source.name);
          return matchesTags && matchesSource;
        }).toList();
      }
    }

    return filtered;
  });
});
