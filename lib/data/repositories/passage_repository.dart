import 'package:hive/hive.dart';
import '../models/passage.dart';

class ArticleRepository {
  // Keep the legacy Hive box name so existing local data stays readable.
  // The class name is `Article`, but the box is still `'passages'` for
  // backward compatibility with data written by older builds.
  static const String boxName = 'passages';
  late Box<Article> _box;

  Future<void> init() async {
    _box = await Hive.openBox<Article>(boxName);
  }

  List<Article> getAll() {
    return _box.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Article? getById(String id) => _box.get(id);

  Future<void> add(Article article) async {
    await _box.put(article.id, article);
  }

  /// Merges a batch of articles into the box, keyed by id. Existing articles
  /// with the same id are overwritten; others are left untouched. Returns the
  /// number of articles written.
  Future<int> importAll(Iterable<Article> articles) async {
    final entries = {for (final a in articles) a.id: a};
    if (entries.isEmpty) return 0;
    await _box.putAll(entries);
    return entries.length;
  }

  Future<void> update(Article article) async {
    article.updatedAt = DateTime.now();
    await _box.put(article.id, article);
  }

  Future<void> delete(String id) async {
    await _box.delete(id);
  }

  List<Article> search(String query) {
    if (query.isEmpty) return getAll();
    final lower = query.toLowerCase();
    final results = _box.values.where((article) {
      return article.title.toLowerCase().contains(lower) ||
          article.url.toLowerCase().contains(lower) ||
          article.tags.any((tag) => tag.toLowerCase().contains(lower)) ||
          article.notes.toLowerCase().contains(lower);
    }).toList();
    results.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return results;
  }

  List<Article> filterBySource(String sourceName) {
    if (sourceName.isEmpty) return getAll();
    final results = _box.values
        .where((article) => article.source.name == sourceName)
        .toList();
    results.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return results;
  }

  /// Moves every article currently in [folderId] to the unfiled state
  /// (folderId = null). Used when a folder is deleted so its contents
  /// don't dangle pointing at a non-existent folder.
  Future<void> unsetFolder(String folderId) async {
    for (final article in _box.values) {
      if (article.folderId == folderId) {
        article.folderId = null;
        await article.save();
      }
    }
  }

  /// Batch version of [unsetFolder] — single `putAll` instead of per-article
  /// `.save()`. Also bumps `updatedAt` so the cache sorts correctly.
  Future<void> unsetFolderBatch(String folderId) async {
    final updates = <String, Article>{};
    for (final article in _box.values) {
      if (article.folderId == folderId) {
        article.folderId = null;
        article.updatedAt = DateTime.now();
        updates[article.id] = article;
      }
    }
    if (updates.isNotEmpty) {
      await _box.putAll(updates);
    }
  }
}
