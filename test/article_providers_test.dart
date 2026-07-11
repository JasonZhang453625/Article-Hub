import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/source_platform.dart';
import 'package:memora/data/repositories/article_repository.dart';
import 'package:memora/shared/providers/article_providers.dart';

class _InMemoryArticleRepository implements ArticleRepository {
  final List<Article> _articles = [];
  @override Future<void> init() async {}
  @override List<Article> getAll() {
    final sorted = List<Article>.from(_articles)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return sorted;
  }
  @override Article? getById(String id) => _articles.where((a) => a.id == id).firstOrNull;
  @override Future<void> add(Article article) async => _articles.add(article);
  @override Future<int> importAll(Iterable<Article> articles) async {
    final entries = {for (final a in articles) a.id: a};
    for (final e in entries.entries) {
      final idx = _articles.indexWhere((a) => a.id == e.key);
      if (idx != -1) {
        _articles[idx] = e.value;
      } else {
        _articles.add(e.value);
      }
    }
    return entries.length;
  }
  @override Future<void> update(Article article) async {
    article.updatedAt = DateTime.now();
    final idx = _articles.indexWhere((a) => a.id == article.id);
    if (idx != -1) _articles[idx] = article;
  }
  @override Future<void> delete(String id) async => _articles.removeWhere((a) => a.id == id);
  @override List<Article> search(String q) => [];
  @override List<Article> filterBySource(String s) => [];
  @override Future<void> unsetFolder(String id) async {}
  @override Future<void> unsetFolderBatch(String id) async {
    for (final a in _articles) { if (a.folderId == id) a.folderId = null; }
  }
}

Article _a({required String id, String title = 'Test', String? folderId,
    DateTime? updated}) => Article(
  id: id, url: 'https://e.com/$id', title: title,
  source: SourcePlatform.web, folderId: folderId,
  processingStatus: ProcessingStatus.completed,
)..updatedAt = updated ?? DateTime.now();

ProviderContainer _container(_InMemoryArticleRepository repo) {
  return ProviderContainer(overrides: [
    hiveInitProvider.overrideWith((ref) async {}),
    articleRepositoryProvider.overrideWith((ref) async => repo),
  ]);
}

void main() {
  group('ArticlesNotifier', () {
    // ── add ────────────────────────────────────────────────────────
    test('add inserts article and sorts by updatedAt descending', () async {
      final repo = _InMemoryArticleRepository();
      final container = _container(repo);
      final notifier = container.read(articlesProvider.notifier);
      await container.read(articleRepositoryProvider.future);

      final a = _a(id: '1', title: 'First');
      final b = _a(id: '2', title: 'Second', updated: DateTime.now().add(const Duration(days: 1)));
      await notifier.add(b);
      await notifier.add(a);

      final state = notifier.state.valueOrNull!;
      expect(state.length, 2);
      expect(state[0].id, '2');
      expect(state[1].id, '1');
      container.dispose();
    });

    // ── update ─────────────────────────────────────────────────────
    test('update modifies article in state', () async {
      final repo = _InMemoryArticleRepository();
      final container = _container(repo);
      final notifier = container.read(articlesProvider.notifier);
      await container.read(articleRepositoryProvider.future);

      await notifier.add(_a(id: '1', title: 'Original'));
      await notifier.add(_a(id: '2'));

      final updated = _a(id: '1', title: 'Updated', updated: DateTime.now().add(const Duration(hours: 1)));
      await notifier.update(updated);

      final found = notifier.state.valueOrNull!.where((x) => x.id == '1').first;
      expect(found.title, 'Updated');
      container.dispose();
    });

    // ── importAll ──────────────────────────────────────────────────
    test('importAll adds new and replaces existing by id', () async {
      final repo = _InMemoryArticleRepository();
      final container = _container(repo);
      final notifier = container.read(articlesProvider.notifier);
      await container.read(articleRepositoryProvider.future);

      await notifier.add(_a(id: '1', title: 'Original'));
      final count = await notifier.importAll([
        _a(id: '1', title: 'Replaced'),
        _a(id: '2', title: 'New'),
      ]);

      expect(count, 2);
      final state = notifier.state.valueOrNull!;
      expect(state.length, 2);
      expect(state.where((a) => a.id == '1').first.title, 'Replaced');
      container.dispose();
    });

    // ── addMany ────────────────────────────────────────────────────
    test('addMany creates articles from URLs, skips invalid', () async {
      final repo = _InMemoryArticleRepository();
      final container = _container(repo);
      final notifier = container.read(articlesProvider.notifier);
      await container.read(articleRepositoryProvider.future);

      await notifier.addMany(['https://github.com/flutter', 'not-a-url', 'https://pub.dev/packages']);

      final state = notifier.state.valueOrNull!;
      expect(state.length, 2);
      expect(state.any((a) => a.title == 'github.com'), isTrue);
      expect(state.any((a) => a.title == 'pub.dev'), isTrue);
      container.dispose();
    });

    // ── clearFolder ────────────────────────────────────────────────
    test('clearFolder nils folderId on all articles in the folder', () async {
      final repo = _InMemoryArticleRepository();
      final container = _container(repo);
      final notifier = container.read(articlesProvider.notifier);
      await container.read(articleRepositoryProvider.future);

      await notifier.add(_a(id: '1', folderId: 'f1'));
      await notifier.add(_a(id: '2', folderId: 'f1'));
      await notifier.add(_a(id: '3', folderId: null));

      await notifier.clearFolder('f1');

      final state = notifier.state.valueOrNull!;
      expect(state.where((a) => a.id == '1').first.folderId, isNull);
      expect(state.where((a) => a.id == '2').first.folderId, isNull);
      expect(state.where((a) => a.id == '3').first.folderId, isNull);
      container.dispose();
    });
  });
}
