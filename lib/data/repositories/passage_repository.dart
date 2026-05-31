import 'package:hive/hive.dart';
import '../models/passage.dart';

class ArticleRepository {
  // Keep the legacy Hive box name so existing local data stays readable.
  static const String _boxName = 'passages';
  late Box<Article> _box;

  Future<void> init() async {
    _box = await Hive.openBox<Article>(_boxName);
  }

  List<Article> getAll() {
    return _box.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Article? getById(String id) {
    for (final article in _box.values) {
      if (article.id == id) return article;
    }
    return null;
  }

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
    return getAll().where((article) {
      return article.title.toLowerCase().contains(lower) ||
          article.url.toLowerCase().contains(lower) ||
          article.tags.any((tag) => tag.toLowerCase().contains(lower)) ||
          article.notes.toLowerCase().contains(lower);
    }).toList();
  }

  List<Article> filterBySource(String sourceName) {
    if (sourceName.isEmpty) return getAll();
    return getAll()
        .where((article) => article.source.name == sourceName)
        .toList();
  }
}
