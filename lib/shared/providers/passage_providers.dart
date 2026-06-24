import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../data/models/passage.dart';
import '../../data/models/settings.dart';
import '../../data/models/filter_group.dart';
import '../../data/models/folder.dart';
import '../../data/models/source_platform.dart';
import '../../data/repositories/passage_repository.dart';
import '../../data/services/index_service.dart';
import '../../data/services/embedding_service.dart';
import '../../data/services/retrieval_service.dart';
import '../../data/services/retrieval_log_service.dart';
import '../utils/url_helpers.dart';
import 'filter_providers.dart';
import 'settings_providers.dart';

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
  if (!Hive.isAdapterRegistered(Folder.typeId)) {
    Hive.registerAdapter(FolderAdapter());
  }
  if (!Hive.isAdapterRegistered(IndexRecordAdapter().typeId)) {
    Hive.registerAdapter(IndexRecordAdapter());
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
    // Also remove the vector index entry if one exists.
    _ref.read(indexServiceProvider).delete(id).catchError((_) {});
    state = AsyncValue.data(repo.getAll());
  }

  /// Move article to its suggested folder and clear the suggestion.
  Future<void> confirmFolderSuggestion(String id) async {
    final repo = await _ref.read(articleRepositoryProvider.future);
    final article = repo.getById(id);
    if (article == null || article.suggestedFolderId == null) return;
    final updated = article.copyWith(
      folderId: article.suggestedFolderId,
      suggestedFolderId: Article.clearValue,
    );
    await repo.update(updated);
    state = AsyncValue.data(repo.getAll());
  }

  /// Dismiss the folder suggestion without moving.
  Future<void> dismissFolderSuggestion(String id) async {
    final repo = await _ref.read(articleRepositoryProvider.future);
    final article = repo.getById(id);
    if (article == null) return;
    final updated = article.copyWith(suggestedFolderId: Article.clearValue);
    await repo.update(updated);
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

final selectedFolderIdProvider = StateProvider<String>((ref) => '');

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
  final folderId = ref.watch(selectedFolderIdProvider);

  return articlesAsync.whenData((articles) {
    var filtered = articles;

    // Filter by folder
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

final foldersProvider =
    StateNotifierProvider<FoldersNotifier, AsyncValue<List<Folder>>>((ref) {
      return FoldersNotifier(ref);
    });

class FoldersNotifier extends StateNotifier<AsyncValue<List<Folder>>> {
  final Ref _ref;
  static const String _boxName = 'folders';

  FoldersNotifier(this._ref) : super(const AsyncValue.loading()) {
    _load();
  }

  Future<Box<Folder>> _openBox() async {
    await _ref.read(hiveInitProvider.future);
    return Hive.openBox<Folder>(_boxName);
  }

  Future<void> _load() async {
    final box = await _openBox();
    final folders = box.values.toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    state = AsyncValue.data(folders);
  }

  Future<void> add(Folder folder) async {
    final box = await _openBox();
    await box.put(folder.id, folder);
    await _load();
  }

  Future<void> update(Folder folder) async {
    final box = await _openBox();
    await box.put(folder.id, folder);
    await _load();
  }

  Future<void> delete(String id) async {
    final box = await _openBox();
    // Capture the deleted folder's parent so its children can be reparented
    // (otherwise their parentId would dangle, orphaning them from the tree).
    final deleted = box.get(id);
    final newParentId = deleted?.parentId;
    await box.delete(id);
    // Reparent any subfolders of the deleted folder to its parent.
    for (final folder in box.values.toList()) {
      if (folder.parentId == id) {
        folder.parentId = newParentId;
        await folder.save();
      }
    }
    // Move articles in this folder to unfiled.
    final repo = await _ref.read(articleRepositoryProvider.future);
    await repo.unsetFolder(id);
    await _load();
    _ref.read(articlesProvider.notifier).refresh();
  }

  void refresh() => _load();
}

/// Articles that have completed processing — shown in the knowledge base tab.
final knowledgeBaseArticlesProvider = Provider<AsyncValue<List<Article>>>((ref) {
  final filtered = ref.watch(filteredArticlesProvider);
  return filtered.whenData(
    (articles) => articles
        .where((a) => a.processingStatus == ProcessingStatus.completed)
        .toList(),
  );
});

/// Articles that are pending, processing, or failed — shown in the inbox tab.
final pendingArticlesProvider = Provider<AsyncValue<List<Article>>>((ref) {
  final filtered = ref.watch(filteredArticlesProvider);
  return filtered.whenData(
    (articles) => articles
        .where((a) => a.processingStatus != ProcessingStatus.completed)
        .toList(),
  );
});

/// Embedding service configured from user settings.
final embeddingServiceProvider = Provider<EmbeddingService?>((ref) {
  final settings = ref.watch(settingsProvider).valueOrNull;
  if (settings == null) return null;
  if (settings.embeddingBaseUrl.trim().isEmpty ||
      settings.embeddingApiKey.trim().isEmpty ||
      settings.embeddingModel.trim().isEmpty) {
    return null;
  }
  return EmbeddingService(
    baseUrl: settings.embeddingBaseUrl,
    apiKey: settings.embeddingApiKey,
    model: settings.embeddingModel,
  );
});

/// Whether embedding is fully configured.
final embeddingConfiguredProvider = Provider<bool>((ref) {
  return ref.watch(embeddingServiceProvider) != null;
});

/// Local vector index service.
final indexServiceProvider = Provider<IndexService>((ref) {
  ref.watch(hiveInitProvider);
  return IndexService();
});

/// Retrieval service for knowledge base queries.
final retrievalServiceProvider = Provider<RetrievalService?>((ref) {
  final embedding = ref.watch(embeddingServiceProvider);
  final index = ref.watch(indexServiceProvider);
  if (embedding == null) return null;
  return RetrievalService(embedding: embedding, index: index);
});

/// Local retrieval log service.
final retrievalLogServiceProvider = Provider<RetrievalLogService>((ref) {
  return RetrievalLogService();
});
