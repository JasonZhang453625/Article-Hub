import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../data/models/passage.dart';
import '../../data/models/settings.dart';
import '../../data/models/source_platform.dart';
import '../../data/models/filter_group.dart';
import '../../data/models/folder.dart';
import '../../data/repositories/passage_repository.dart';
import '../../data/repositories/article_repository.dart';
import '../../data/services/index_service.dart';
import '../../data/services/embedding_service.dart';
import '../../data/services/sync_outbox_service.dart';
import '../utils/url_helpers.dart';
import 'ai_providers.dart';
import 'sync_providers.dart';

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
  final repo = HiveArticleRepository();
  await repo.init();
  return repo;
});

final articlesProvider =
    StateNotifierProvider<ArticlesNotifier, AsyncValue<List<Article>>>((ref) {
      return ArticlesNotifier(ref);
    });

class ArticlesNotifier extends StateNotifier<AsyncValue<List<Article>>> {
  final Ref _ref;
  List<Article> _cached = [];

  ArticlesNotifier(this._ref) : super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    final repo = await _ref.read(articleRepositoryProvider.future);
    _cached = repo.getAll();
    state = AsyncValue.data(List.unmodifiable(_cached));
  }

  void _emit() {
    state = AsyncValue.data(List.unmodifiable(_cached));
  }

  Future<void> add(Article article) async {
    final repo = await _ref.read(articleRepositoryProvider.future);
    await repo.add(article);
    await _enqueueArticle(article);
    _cached.add(article);
    _cached.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _emit();
  }

  Future<void> update(Article article) async {
    final repo = await _ref.read(articleRepositoryProvider.future);
    await repo.update(article);
    await _enqueueArticle(article);
    final idx = _cached.indexWhere((a) => a.id == article.id);
    if (idx != -1) {
      _cached[idx] = article;
      _cached.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    }
    _emit();
  }

  Future<void> updateGeneratedSummary(
    String articleId,
    String? generatedTitle,
    String summary,
    String? coverImageUrl,
  ) async {
    final repo = await _ref.read(articleRepositoryProvider.future);
    final current = repo.getById(articleId);
    if (current == null) return;

    final updated = current.copyWith(
      title: generatedTitle ?? current.title,
      summary: summary,
      summaryFeedback: Article.clearValue,
      coverImageUrl: coverImageUrl ?? current.coverImageUrl,
    );
    await repo.update(updated);
    await _enqueueArticle(updated);

    final idx = _cached.indexWhere((a) => a.id == articleId);
    if (idx != -1) {
      _cached[idx] = updated;
      _cached.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    }
    _emit();

    _updateIndex(updated);
  }

  void _updateIndex(Article article) {
    final embedding = _ref.read(embeddingServiceProvider);
    final index = _ref.read(indexServiceProvider);
    if (embedding == null) return;
    if (article.summary == null || article.summary!.isEmpty) return;

    final input = IndexService.buildEmbeddingInput(article);
    embedding
        .embed(input)
        .then((result) {
          if (result == null) return;
          index.put(
            IndexRecord(
              articleId: article.id,
              model: result.model,
              fingerprint: contentFingerprint(
                article.title,
                article.summary!,
                article.tags,
              ),
              vector: result.vector,
            ),
          );
        })
        .catchError((e) {
          // Index update is best-effort; don't fail the summary save.
        });
  }

  Future<void> delete(String id) async {
    final repo = await _ref.read(articleRepositoryProvider.future);
    await repo.delete(id);
    await _ref
        .read(syncOutboxProvider)
        .enqueue(
          SyncOutboxRecord.create(
            collection: SyncCollections.articles,
            itemId: id,
            operation: SyncOperation.delete,
          ),
        );
    _ref.read(indexServiceProvider).delete(id).catchError((_) {});
    _cached.removeWhere((a) => a.id == id);
    _emit();
  }

  Future<int> importAll(Iterable<Article> articles) async {
    final repo = await _ref.read(articleRepositoryProvider.future);
    final imported = articles.toList(growable: false);
    final count = await repo.importAll(imported);
    for (final article in imported) {
      await _enqueueArticle(article);
      final idx = _cached.indexWhere((a) => a.id == article.id);
      if (idx != -1) {
        _cached[idx] = article;
      } else {
        _cached.add(article);
      }
    }
    _cached.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _emit();
    return count;
  }

  Future<void> _enqueueArticle(Article article) {
    return _ref
        .read(syncOutboxProvider)
        .enqueue(
          SyncOutboxRecord.create(
            collection: SyncCollections.articles,
            itemId: article.id,
            operation: SyncOperation.upsert,
            payload: article.toJson(),
          ),
        );
  }

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

  Future<void> clearFolder(String folderId) async {
    final repo = await _ref.read(articleRepositoryProvider.future);
    await repo.unsetFolderBatch(folderId);
    for (final article in _cached) {
      if (article.folderId == folderId) {
        article.folderId = null;
        await _enqueueArticle(article);
      }
    }
    _emit();
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
