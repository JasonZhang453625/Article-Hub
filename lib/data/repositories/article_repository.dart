import '../models/passage.dart';

abstract interface class ArticleRepository {
  Future<void> init();
  List<Article> getAll();
  Article? getById(String id);
  Future<void> add(Article article);
  Future<int> importAll(Iterable<Article> articles);
  Future<void> update(Article article);
  Future<void> delete(String id);
  List<Article> search(String query);
  List<Article> filterBySource(String sourceName);
  Future<void> unsetFolder(String folderId);
  Future<void> unsetFolderBatch(String folderId);
}
