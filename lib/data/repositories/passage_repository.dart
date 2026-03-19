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
    return _box.values.firstWhere(
      (article) => article.id == id,
      orElse: () => throw StateError('Article not found'),
    );
  }

  Future<void> add(Article article) async {
    await _box.put(article.id, article);
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
