import 'package:hive/hive.dart';
import '../models/passage.dart';
import 'article_repository.dart';

class HiveArticleRepository implements ArticleRepository {
  static const String boxName = 'passages';
  late Box<Article> _box;

  @override
  Future<void> init() async {
    _box = await Hive.openBox<Article>(boxName);
  }

  @override
  List<Article> getAll() {
    return _box.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  @override
  Article? getById(String id) => _box.get(id);

  @override
  Future<void> add(Article article) async {
    await _box.put(article.id, article);
  }

  @override
  Future<int> importAll(Iterable<Article> articles) async {
    final entries = {for (final a in articles) a.id: a};
    if (entries.isEmpty) return 0;
    await _box.putAll(entries);
    return entries.length;
  }

  @override
  Future<void> update(Article article) async {
    article.updatedAt = DateTime.now();
    await _box.put(article.id, article);
  }

  @override
  Future<void> delete(String id) async {
    await _box.delete(id);
  }

  @override
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

  @override
  List<Article> filterBySource(String sourceName) {
    if (sourceName.isEmpty) return getAll();
    final results = _box.values
        .where((article) => article.source.name == sourceName)
        .toList();
    results.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return results;
  }

  @override
  Future<void> unsetFolder(String folderId) async {
    for (final article in _box.values) {
      if (article.folderId == folderId) {
        article.folderId = null;
        await article.save();
      }
    }
  }

  @override
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
